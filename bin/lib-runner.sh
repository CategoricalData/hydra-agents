#!/usr/bin/env bash
# lib-runner.sh — load the agent-runner adapter named by the config's `runner`.
#
# hydra-agents must not be tied to one agent runner (hydra-agents#7; README §
# Design principles). The runner-neutral core is the file protocol and the
# worktree/tmux layout; anything that depends on the runner (how to launch an
# agent, which settings isolate it, how to check its version, which doorbells it
# supports) is an adapter in bin/runners/<runner>.sh. Adding a runner means adding
# one file that defines:
#
#   ha_runner_check_version                    warn (stderr) if too old; return 0
#   ha_runner_prepare_worktree <wt> <branch>   enforce the isolation contract in
#                                              this worktree (docs/cross-worktree-
#                                              messages.md § Project isolation);
#                                              non-zero means "do not launch"
#   ha_runner_write_project_guard <root>       write a private repo's checked-in
#                                              guard (the caller commits it)
#   ha_runner_check_project_guard <root>       verify it; print problems, non-zero
#                                              if any
#   ha_runner_launch_cmd <session> <model> [--resume]
#                                              print the command that starts the
#                                              agent in its tmux pane, named <session>
#   HA_RUNNER_DOORBELLS                        doorbell backends, best first
#                                              (bin/lib-doorbell.sh)
#   HA_RUNNER_GUARDED_DOORBELLS                backends for guarded sessions (a
#                                              runner that holds inbound messages
#                                              there lists only scripted ones)
#   HA_RUNNER_PROCESS                          the agent's process name, used to
#                                              detect a live agent in a worktree
#
# Usage (after ha_load_config):
#   . "$(dirname "$0")/lib-runner.sh"
#   ha_load_runner || exit 1

ha_load_runner() {
    local dir f fn
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    f="$dir/runners/${HA_RUNNER:-claude-code}.sh"
    if [ ! -r "$f" ]; then
        echo "error: no adapter for runner '${HA_RUNNER:-claude-code}' (expected $f)." >&2
        echo "       Set \"runner\" in hydra-agents.json to one of: $(cd "$dir/runners" && ls *.sh | sed 's/\.sh$//' | tr '\n' ' ')" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    . "$f"
    for fn in ha_runner_check_version ha_runner_prepare_worktree ha_runner_launch_cmd \
              ha_runner_write_project_guard ha_runner_check_project_guard; do
        if ! declare -F "$fn" >/dev/null; then
            echo "error: runner adapter $f does not define $fn." >&2
            return 1
        fi
    done
    return 0
}
