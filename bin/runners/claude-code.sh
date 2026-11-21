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
#   - Isolation settings, in the worktree's .claude/settings.local.json
#     (machine-local, gitignored), merged into whatever is there:
#       * worker worktrees: isolatePeerMachines: true, so any send off this machine
#         needs approval, even in bypass mode;
#       * staging worktrees (standardizedBranches): no isolatePeerMachines, because
#         staging coordinators of one project on different machines message each
#         other, restricted by protocol to the config's stagingPeers;
#       * every worktree: a ListAgents deny (unless denyListAgents is "false"), so
#         peers are addressed by computed name, never by listing the account.
#     Worktree-local rather than user-level, because a true isolatePeerMachines in
#     any scope can't be turned off by another, and staging needs off-machine sends.
#   - Doorbell: SendMessage is a tool the agent calls, so the claude-sendmessage
#     backend tells the agent what to send (see lib-doorbell.sh); tmux is the
#     fallback.

HA_RUNNER_DOORBELLS="claude-sendmessage tmux"
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

# ha_runner_prepare_worktree <worktree-path> <branch>: write the isolation
# settings described above. Requires jq and a loaded config (ha_load_config).
ha_runner_prepare_worktree() {
    local wt="$1" branch="$2" f tmp isolate deny
    f="$wt/.claude/settings.local.json"
    if ha_is_standardized_branch "$branch"; then isolate=false; else isolate=true; fi
    if [ "${HA_DENY_LIST_AGENTS:-true}" = "false" ]; then deny=false; else deny=true; fi
    mkdir -p "$wt/.claude" || return 1
    [ -s "$f" ] || printf '{}\n' > "$f"
    if ! jq empty "$f" 2>/dev/null; then
        echo "error: $f is not valid JSON; not touching it. Fix it, then rerun." >&2
        return 1
    fi
    tmp="$f.tmp.$$"
    # Staging may already carry an isolatePeerMachines: true written by hand or by
    # an older harness; leave it (turning isolation OFF is a human's call).
    if jq --argjson isolate "$isolate" --argjson deny "$deny" '
          (if $isolate then .isolatePeerMachines = true else . end)
        | (if $deny then
             .permissions = (.permissions // {})
             | .permissions.deny = (((.permissions.deny // []) + ["ListAgents"]) | unique)
           else . end)
        ' "$f" > "$tmp" && mv -f "$tmp" "$f"; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo "error: failed to write isolation settings to $f" >&2
    return 1
}

# ha_runner_launch_cmd <session> <model> [--resume]: the command typed into the
# agent's tmux pane. An older claude-remote without -n forwards it to `claude`,
# which takes the same flag.
ha_runner_launch_cmd() {
    local session="$1" model="$2" resume=""
    [ "${3:-}" = "--resume" ] && resume=" --continue"
    printf 'claude-remote %s -m %s -n %s%s' "$session" "$model" "$session" "$resume"
}
