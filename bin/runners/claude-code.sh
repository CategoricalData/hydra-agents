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
#   - Isolation (docs/cross-worktree-messages.md § Project isolation). The guard
#     applies when the repo is private OR the machine is sensitive (lib-config.sh):
#       * private repo: the guard is CHECKED IN to the repo's .claude/settings.json
#         (isolatePeerMachines: true, crossSessionInbound: hold|refuse, a ListAgents
#         deny), so it travels with every clone and can't be switched off locally.
#         bin/project-guard writes or verifies it; spawn and recovery verify it.
#       * guarded (private, or a sensitive machine): the same three settings are
#         also written to the worktree's .claude/settings.local.json (machine-local,
#         gitignored), which covers a public repo on a sensitive machine, whose
#         checked-in file must not carry them, and a private repo whose checked-in
#         guard is missing.
#       * sensitive machine: filesystem-scope deny rules (Read/Edit of credential
#         stores and personal folders under ~), optionally the Bash sandbox
#         (sandboxBash), and a loud warning if the agent runs in bypass mode.
#       * every worktree: a ListAgents deny unless denyListAgents is "false".
#     isolatePeerMachines also applies to staging: a guarded project's
#     cross-machine staging sends each need a human's approval.
#   - Doorbell: SendMessage is a tool the agent calls, so the claude-sendmessage
#     backend tells the agent what to send (see lib-doorbell.sh); tmux is the
#     fallback.

HA_RUNNER_DOORBELLS="claude-sendmessage tmux"
# Guarded sessions hold (or refuse) cross-session messages, even from their own
# project (verified on v2.1.314: a same-machine, same-mode send was held for the
# human's approval), so the native doorbell can't reach them: ring tmux.
HA_RUNNER_GUARDED_DOORBELLS="tmux"

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

# The guard: confine sends to this machine, hold or refuse inbound, deny listing.
_HA_GUARD_FILTER='.isolatePeerMachines = true
    | .crossSessionInbound = $inbound
    | .permissions = (.permissions // {})
    | .permissions.deny = (((.permissions.deny // []) + ["ListAgents"]) | unique)'

# ha_runner_prepare_worktree <worktree-path> <branch>: write the worktree-local
# settings described above, and verify a private repo's checked-in guard.
# Requires jq and a loaded config (ha_load_config).
ha_runner_prepare_worktree() {
    local wt="$1" branch="$2" f p rules mode
    f="$wt/.claude/settings.local.json"

    if [ "${HA_DENY_LIST_AGENTS:-true}" != "false" ]; then
        _ha_merge_json "$f" '.permissions = (.permissions // {})
            | .permissions.deny = (((.permissions.deny // []) + ["ListAgents"]) | unique)' || return 1
    fi

    if [ "${HA_GUARDED:-true}" = true ]; then
        _ha_merge_json "$f" "$_HA_GUARD_FILTER" --arg inbound "${HA_INBOUND:-hold}" || return 1
    elif [ "$(jq -r '.isolatePeerMachines // false' "$f" 2>/dev/null)" = true ]; then
        # Loosening is a human's call: report a leftover guard, don't remove it.
        echo "note: $f sets isolatePeerMachines: true, but this project is public on an open" >&2
        echo "      machine. Left as is; remove it by hand to loosen this worktree." >&2
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
        echo "WARNING: this project is PRIVATE, but its checked-in guard is missing or incomplete in" >&2
        echo "         $wt/.claude/settings.json. This worktree is guarded by its local settings," >&2
        echo "         but other clones are not. Run bin/project-guard --write in a worktree, commit" >&2
        echo "         .claude/settings.json, and merge it (bin/project-guard --check shows what's missing)." >&2
        echo "" >&2
    fi
    return 0
}

# ha_runner_write_project_guard <worktree-root>: merge the guard into the repo's
# checked-in .claude/settings.json (the caller commits it).
ha_runner_write_project_guard() {
    _ha_merge_json "$1/.claude/settings.json" "$_HA_GUARD_FILTER" --arg inbound "${HA_INBOUND:-hold}"
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
    jq -e '.crossSessionInbound == "hold" or .crossSessionInbound == "refuse"' "$f" >/dev/null \
        || { echo "missing: crossSessionInbound: \"hold\" or \"refuse\""; bad=1; }
    jq -e '(.permissions.deny // []) | index("ListAgents")' "$f" >/dev/null \
        || { echo "missing: permissions.deny includes \"ListAgents\""; bad=1; }
    return "$bad"
}

# ha_runner_launch_cmd <session> <model> [--resume]: the command typed into the
# agent's tmux pane. An older claude-remote without -n forwards it to `claude`,
# which takes the same flag.
ha_runner_launch_cmd() {
    local session="$1" model="$2" resume=""
    [ "${3:-}" = "--resume" ] && resume=" --continue"
    printf 'claude-remote %s -m %s -n %s%s' "$session" "$model" "$session" "$resume"
}
