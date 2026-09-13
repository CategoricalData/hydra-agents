#!/usr/bin/env bash
# Relaunch one tmux session per active Hydra worktree, each running
# `claude-remote --continue` so the prior conversation resumes.
#
# Active worktrees = directories under
#   ~/projects/github/CategoricalData/hydra/worktrees/
# whose name starts with `bug_` or `feature_`. Excludes main/integration/
# staging/closed.
#
# Idempotent: if a tmux session for a worktree already exists, it is skipped.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-config.sh"

WORKTREES_DIR="${HOME}/projects/github/CategoricalData/hydra/worktrees"

# The session name MUST match what spawn-issue-worktree.sh created, or this
# relauncher won't find the running session and will start a DUPLICATE agent
# in a worktree that already has one (see hydra-agents#1). Session names are
# machine-global and prefixed with the per-project HA_SESSION_PREFIX; resolve
# that prefix per-worktree by loading its project's hydra-agents.json. Falls
# back to the unprefixed dirname if a worktree has no resolvable config.
session_name_for() {
    local wt_path="$1" wt_name="$2" prefix=""
    if CLAUDE_PROJECT_DIR="$wt_path" ha_load_config >/dev/null 2>&1; then
        prefix="$HA_SESSION_PREFIX"
    fi
    printf '%s%s' "$prefix" "$wt_name"
}

if [ ! -d "$WORKTREES_DIR" ]; then
  echo "error: $WORKTREES_DIR not found" >&2
  exit 1
fi

# Collect candidate worktrees.
mapfile -t worktrees < <(
  find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d \
    \( -name 'bug_*' -o -name 'feature_*' \) \
    -printf '%f\n' | sort
)

if [ "${#worktrees[@]}" -eq 0 ]; then
  echo "no bug_*/feature_* worktrees found under $WORKTREES_DIR" >&2
  exit 0
fi

# tmux session name derived from worktree dirname. tmux disallows '.' and ':'
# in session names; underscores in worktree dirs are fine.
launched=()
skipped=()
for wt in "${worktrees[@]}"; do
  wt_path="${WORKTREES_DIR}/${wt}"
  session="$(session_name_for "$wt_path" "$wt")"

  # `=` forces exact-name matching (tmux otherwise prefix-matches, a
  # cross-project mis-target risk — hydra-agents#1).
  if tmux has-session -t "=$session" 2>/dev/null; then
    skipped+=("$session (already running)")
    continue
  fi

  # Launch via interactive bash so ~/.bashrc is sourced and `claude-remote`
  # is defined. `exec` inside the subshell would replace bash; we leave bash
  # in place so when claude exits the session stays attached to a shell.
  tmux new-session -d -s "$session" -c "$wt_path" \
    "bash -i -c 'claude-remote --continue; exec bash'"
  launched+=("$session")
done

echo
echo "Launched ${#launched[@]} session(s):"
for s in "${launched[@]}"; do echo "  + $s"; done

if [ "${#skipped[@]}" -gt 0 ]; then
  echo
  echo "Skipped ${#skipped[@]}:"
  for s in "${skipped[@]}"; do echo "  - $s"; done
fi

echo
echo "Attach with:  tmux attach -t <session>"
echo "List all:     tmux ls"
