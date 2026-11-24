#!/usr/bin/env bash
# runners/claude-code.sh — the Claude Code runner adapter (hydra-agents#7).
#
# The harness is runner-neutral: the file protocol (inbox/outbox/archive) is the
# core, and everything specific to one agent runner lives in an adapter under
# bin/runners/, selected by the config's `runner` field and loaded by
# bin/lib-runner.sh. The interface (see lib-runner.sh for the contract):
#
#   ha_runner_check_version                  warn if the runner is too old; never fail
#   ha_runner_prepare_worktree <wt> <branch> write the runner's isolation settings
#   ha_runner_launch_cmd <session> <model> [--resume]
#                                            print the shell command that starts an agent
#   HA_RUNNER_DOORBELLS                      the runner's doorbell backends, best first
#
# Claude Code specifics implemented here:
#
#   - Version: cross-session messaging (SendMessage) needs v2.1.224+ (v2.1.234 on
#     native Windows; this check uses the Unix minimum).
#   - Launch: claude-remote, with --name equal to the tmux session name, so the
#     session's SendMessage address is computable. --continue resumes.
#   - Scoped messaging, every worktree (docs/cross-worktree-messages.md § Project
#     isolation): a PreToolUse hook (bin/claude-hooks/peer-scope.sh) on SendMessage
#     and ListAgents. A send to one of this project's own sessions goes through
#     without a prompt; a send to any other session asks the human (it isn't
#     blocked); ListAgents asks too (or is denied, listAgents: "deny"), because it
#     lists every project on the account. An ask rule for SendMessage would outrank
#     the hook's "allow", so the adapter removes the earlier "every send asks" rule.
#   - Isolation, guarded worktrees (the repo is private OR the machine is sensitive,
#     lib-config.sh). Inbound is accepted, because the protection rests on the
#     sender side: guarded sessions launch with --settings
#     '{"crossSessionInbound":"accept"}' (privateInbound). It must be set at launch:
#     project and local settings may only make crossSessionInbound stricter, so an
#     "accept" there is ignored and the permission-mode-class rule holds cross-mode
#     messages anyway (verified on v2.1.314). A stricter privateInbound (hold or
#     refuse) also goes into the guard, where it does apply.
#       * private repo: the guard (isolatePeerMachines: true and the peer-scope hook)
#         is CHECKED IN to the repo's .claude/settings.json, so it travels with every
#         clone. bin/project-guard writes or verifies it; spawn and recovery verify it.
#       * guarded: the same settings also go to the worktree's
#         .claude/settings.local.json (machine-local, gitignored): isolatePeerMachines
#         makes every send to another machine need approval, staging's included.
#       * sensitive machine: filesystem-scope deny rules (Read/Edit of credential
#         stores and personal folders under ~), optionally the Bash sandbox
#         (sandboxBash), and a loud warning if the agent runs in bypass mode.
#     stagingPeers names this project's staging sessions on other machines: the hook
#     allows them, and isolatePeerMachines still asks for each of those sends.
#   - Doorbell: SendMessage is a tool the agent calls, so the claude-sendmessage
#     backend tells the agent what to send (see lib-doorbell.sh); tmux is the
#     fallback.

HA_RUNNER_DOORBELLS="claude-sendmessage tmux"
# Guarded sessions accept inbound messages, so the native doorbell reaches them on
# the same terms as any other session: delivered when the two sessions share a
# permission mode, held otherwise, even with crossSessionInbound: accept (verified on
# v2.1.314); a held one falls back to tmux. A send the human declined at a prompt is
# not a failed one: never ring tmux instead.
HA_RUNNER_GUARDED_DOORBELLS="claude-sendmessage tmux"

# Paths under ~ that a sensitive machine's agents may not Read or Edit. Extend with
# the config's sensitivePaths (space-separated, ~-relative). ~/.claude/projects is
# deliberately absent: a session reads its own (large) tool results from there.
HA_RUNNER_SENSITIVE_PATHS=".ssh .gnupg .aws .azure .config/gcloud .config/gh .kube .docker
.password-store .netrc .git-credentials .npmrc .pypirc Documents Desktop Downloads Pictures
Library/Mail Library/Messages"
HA_RUNNER_PROCESS="claude"   # the agent's process name, for live-agent checks

HA_MIN_CLAUDE_MESSAGING_VERSION="2.1.224"

# ha_version_ge <a> <b>: true if dotted version a >= b. Pure bash (no sort -V,
# which BSD/macOS sort lacks in older releases).
ha_version_ge() {
    local IFS=.
    local -a a=($1) b=($2)
    local i x y
    for i in 0 1 2; do
        x="${a[$i]:-0}"; y="${b[$i]:-0}"
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        x="${x:-0}"; y="${y:-0}"
        if [ "$x" -gt "$y" ]; then return 0; fi
        if [ "$x" -lt "$y" ]; then return 1; fi
    done
    return 0
}

# ha_runner_check_version: print a warning to stderr if `claude` is missing or
# older than HA_MIN_CLAUDE_MESSAGING_VERSION. Always returns 0: an old CLI still
# works with the tmux fallback, so this informs rather than blocks.
ha_runner_check_version() {
    local out ver
    if ! out="$(claude --version 2>/dev/null)"; then
        echo "warning: could not run 'claude --version'; cannot confirm native messaging support." >&2
        return 0
    fi
    ver="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "$ver" ]; then
        echo "warning: unrecognized 'claude --version' output: $out" >&2
        return 0
    fi
    if ! ha_version_ge "$ver" "$HA_MIN_CLAUDE_MESSAGING_VERSION"; then
        echo "warning: Claude Code $ver predates $HA_MIN_CLAUDE_MESSAGING_VERSION, so it has no" >&2
        echo "         cross-session messaging (SendMessage). Agents will be reachable only by" >&2
        echo "         the tmux ping. Upgrade with 'claude update' (docs/cross-worktree-messages.md)." >&2
    fi
    return 0
}

# _ha_merge_json <file> <jq-filter> [jq args...]: apply a jq filter to a JSON file
# in place (creating it as {} if absent); refuses an invalid file.
_ha_merge_json() {
    local f="$1" filter="$2" tmp; shift 2
    mkdir -p "$(dirname "$f")" || return 1
    [ -s "$f" ] || printf '{}\n' > "$f"
    if ! jq empty "$f" 2>/dev/null; then
        echo "error: $f is not valid JSON; not touching it. Fix it, then rerun." >&2
        return 1
    fi
    tmp="$f.tmp.$$"
    if jq "$@" "$filter" "$f" > "$tmp" && mv -f "$tmp" "$f"; then return 0; fi
    rm -f "$tmp" 2>/dev/null || true
    echo "error: failed to update $f" >&2
    return 1
}

# The guard (guarded worktrees and a private repo's checked-in settings): sends to
# other machines need approval, and inbound is held or refused only if
# privateInbound asks for it (an "accept" here would be ignored, so the key is left
# out).
_HA_GUARD_FILTER='.isolatePeerMachines = true
    | (if $inbound == "accept" then del(.crossSessionInbound) else .crossSessionInbound = $inbound end)'

# Scoped messaging (every worktree): SendMessage and ListAgents go through
# bin/claude-hooks/peer-scope.sh, which allows sends to this project's own sessions
# and asks the human for anything else. An ask rule for SendMessage outranks a
# hook's "allow", so the filter also removes the earlier "every send asks" rule and
# the ListAgents deny (re-added only for listAgents: "deny"), and replaces any older
# peer-scope hook entry with this one. $cmd is the hook command; $deny_list is
# "true" to keep ListAgents denied.
_HA_SCOPE_FILTER='.permissions = (.permissions // {})
    | .permissions.ask = ((.permissions.ask // []) - ["SendMessage"])
    | (if (.permissions.ask | length) == 0 then del(.permissions.ask) else . end)
    | .permissions.deny = ((.permissions.deny // []) - ["ListAgents"]
        + (if $deny_list == "true" then ["ListAgents"] else [] end))
    | .hooks = (.hooks // {})
    | .hooks.PreToolUse = (((.hooks.PreToolUse // [])
        | map(select((.hooks // []) | all((.command // "") | test("peer-scope") | not))))
        + [{matcher: "SendMessage|ListAgents", hooks: [{type: "command", command: $cmd}]}])'

# _ha_scope_merge <settings-file> <hook-command>
_ha_scope_merge() {
    local deny_list=false
    [ "${HA_LIST_AGENTS:-ask}" = deny ] && deny_list=true
    _ha_merge_json "$1" "$_HA_SCOPE_FILTER" --arg cmd "$2" --arg deny_list "$deny_list"
}

# ha_runner_prepare_worktree <worktree-path> <branch>: write the worktree-local
# settings described above, and verify a private repo's checked-in guard.
# Requires jq and a loaded config (ha_load_config).
ha_runner_prepare_worktree() {
    local wt="$1" branch="$2" f p rules mode
    f="$wt/.claude/settings.local.json"

    # Every worktree: scoped messaging, with the hook from this checkout (an
    # absolute path is fine in machine-local settings).
    _ha_scope_merge "$f" "\"$HA_AGENTS_DIR/bin/claude-hooks/peer-scope.sh\"" || return 1

    if [ "${HA_GUARDED:-true}" = true ]; then
        _ha_merge_json "$f" "$_HA_GUARD_FILTER" --arg inbound "${HA_INBOUND:-accept}" || return 1
    elif [ "$(jq -r '.isolatePeerMachines // false' "$f" 2>/dev/null)" = true ] \
            || [ "$(jq -r '.crossSessionInbound // "accept"' "$f" 2>/dev/null)" != accept ]; then
        # Loosening is a human's call: report a leftover guard, don't remove it.
        echo "note: $f still carries the messaging guard (isolatePeerMachines or crossSessionInbound)," >&2
        echo "      but this project is public on an open machine. Left as is; remove those keys" >&2
        echo "      by hand to loosen this worktree." >&2
    fi

    if [ "${HA_SENSITIVE:-true}" = true ]; then
        rules="[]"
        for p in $HA_RUNNER_SENSITIVE_PATHS ${HA_SENSITIVE_PATHS:-}; do
            rules="$(jq -c --arg p "$p" '. + ["Read(~/\($p))", "Read(~/\($p)/**)", "Edit(~/\($p))", "Edit(~/\($p)/**)"]' <<<"$rules")"
        done
        _ha_merge_json "$f" '.permissions = (.permissions // {})
            | .permissions.deny = (((.permissions.deny // []) + $rules) | unique)' --argjson rules "$rules" || return 1
        if [ "${HA_SANDBOX_BASH:-false}" = true ]; then
            _ha_merge_json "$f" '.sandbox = ((.sandbox // {}) + {enabled: true})' || return 1
        fi
        # Bypass mode skips the permission layer these rules live in
        # (docs/sandbox-permissions.md). Say so, loudly.
        mode="$(jq -rs 'map(.permissions.defaultMode // empty) | last // ""' \
            "$wt/.claude/settings.json" "$f" 2>/dev/null || true)"
        if [ "$mode" = bypassPermissions ] || [ -f "$HOME/.hydra-sandbox" ]; then
            echo "" >&2
            echo "WARNING: this machine is marked sensitive, but agents here run in bypass mode" >&2
            echo "         (~/.hydra-sandbox or defaultMode: bypassPermissions). Bypass weakens the" >&2
            echo "         filesystem deny rules just written. Use a prompting mode or the Bash sandbox" >&2
            echo "         on a sensitive machine (docs/cross-worktree-messages.md § Project isolation)." >&2
            echo "" >&2
        fi
    fi

    if [ "${HA_PRIVATE:-true}" = true ] && ! ha_runner_check_project_guard "$wt" >/dev/null 2>&1; then
        echo "" >&2
        echo "WARNING: this project is PRIVATE, but its checked-in guard is missing, incomplete or stale" >&2
        echo "         in $wt/.claude/settings.json. This worktree is guarded by its local settings," >&2
        echo "         but other clones are not. Run bin/project-guard --write in a worktree, commit" >&2
        echo "         .claude/settings.json, and merge it (bin/project-guard --check shows what's wrong)." >&2
        echo "" >&2
    fi
    return 0
}

# _ha_checked_in_hook_cmd: the peer-scope hook command for checked-in settings,
# relative to the worktree root (agentsDir from the config; an absolute agentsDir
# stays absolute).
_ha_checked_in_hook_cmd() {
    local adir
    adir="$(jq -r '.agentsDir // "./agents"' "$HA_CONFIG_FILE" 2>/dev/null)"
    case "$adir" in
        /*) printf '"%s/bin/claude-hooks/peer-scope.sh"' "$adir" ;;
        *)  printf '"$CLAUDE_PROJECT_DIR"/%s/bin/claude-hooks/peer-scope.sh' "${adir#./}" ;;
    esac
}

# ha_runner_write_project_guard <worktree-root>: merge the guard into the repo's
# checked-in .claude/settings.json (the caller commits it).
ha_runner_write_project_guard() {
    _ha_merge_json "$1/.claude/settings.json" "$_HA_GUARD_FILTER" --arg inbound "${HA_INBOUND:-accept}" \
        && _ha_scope_merge "$1/.claude/settings.json" "$(_ha_checked_in_hook_cmd)"
}

# ha_runner_check_project_guard <worktree-root>: verify the checked-in guard.
# Prints each problem; returns non-zero if there is any.
ha_runner_check_project_guard() {
    local root="$1" f bad=0
    f="$root/.claude/settings.json"
    if [ ! -f "$f" ]; then echo "missing: $f"; return 1; fi
    if ! jq empty "$f" 2>/dev/null; then echo "invalid JSON: $f"; return 1; fi
    if ! git -C "$root" ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
        echo "not checked in: .claude/settings.json is not tracked by git"; bad=1
    fi
    jq -e '.isolatePeerMachines == true' "$f" >/dev/null || { echo "missing: isolatePeerMachines: true"; bad=1; }
    jq -e '[.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | .command // "" | select(test("peer-scope"))] | length > 0' "$f" >/dev/null \
        || { echo "missing: the peer-scope PreToolUse hook (SendMessage|ListAgents)"; bad=1; }
    if jq -e '(.permissions.ask // []) | index("SendMessage")' "$f" >/dev/null; then
        echo "stale: permissions.ask includes \"SendMessage\" (it outranks the hook, so every send would ask)"; bad=1
    fi
    if [ "${HA_LIST_AGENTS:-ask}" != deny ] && jq -e '(.permissions.deny // []) | index("ListAgents")' "$f" >/dev/null; then
        echo "stale: permissions.deny includes \"ListAgents\" (listAgents is \"ask\")"; bad=1
    fi
    return "$bad"
}

# ha_runner_launch_cmd <session> <model> [--resume]: the command typed into the
# agent's tmux pane. An older claude-remote without -n forwards it to `claude`,
# which takes the same flag; claude-remote forwards --settings too. A guarded
# session gets its inbound policy here, the only scope where "accept" applies.
# A staging session (a standardized branch, e.g. "staging") gets it on every machine:
# staging peers on other machines may run in a different permission mode, and the
# default rule would hold their messages for approval on the receiving side.
ha_runner_launch_cmd() {
    local session="$1" model="$2" resume="" inbound="" b want=false
    [ "${3:-}" = "--resume" ] && resume=" --continue"
    [ "${HA_GUARDED:-true}" = true ] && want=true
    for b in ${HA_STANDARDIZED_BRANCHES:-staging}; do
        case "$session" in *"$b"*) want=true ;; esac
    done
    if [ "$want" = true ]; then
        inbound=" --settings '{\"crossSessionInbound\":\"${HA_INBOUND:-accept}\"}'"
    fi
    printf 'claude-remote %s -m %s -n %s%s%s' "$session" "$model" "$session" "$inbound" "$resume"
}
