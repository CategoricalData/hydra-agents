#!/usr/bin/env bash
# lib-coordinator.sh — find the live coordinator (staging) worktree, and its tmux
# session, for the watchdog's alerts and liveness heartbeat. Sourced by
# alert-staging.sh and heartbeat-staging.sh so both resolve the target the same way.
#
# Why this is careful: on 2026-10-30 a machine froze after ~4 weeks of danger
# alerts had all been delivered to a dead folder. The coordinator worktree had
# been renamed (staging-gce -> staging), but the old directory survived holding
# only its message folders. The old glob took the first `staging*/` with a
# writable inbox, and `staging-gce/` sorts before `staging/`, so every alert and
# heartbeat went where nothing read them. Hence the rules below:
#   1. An explicit WATCHDOG_STAGING_DIR wins, if it is a usable worktree.
#   2. Otherwise only REAL git worktrees with a writable inbox are candidates —
#      never a leftover folder that merely has an inbox.
#   3. Among several candidates, an exact `staging` beats prefixed variants; any
#      remaining ambiguity is reported (WD_COORDINATOR_NOTE) rather than hidden.
#
# Env:
#   WATCHDOG_WORKTREES_ROOT  directory holding the project's worktrees
#                            (default: Hydra's layout on the reference machine)
#   WATCHDOG_STAGING_DIR     explicit coordinator worktree name under that root
#   WATCHDOG_INBOX_SUBDIR    inbox path inside a worktree
#                            (default: claude-hydra-messages/inbox)

WATCHDOG_WORKTREES_ROOT="${WATCHDOG_WORKTREES_ROOT:-$HOME/projects/github/CategoricalData/hydra/worktrees}"
WATCHDOG_INBOX_SUBDIR="${WATCHDOG_INBOX_SUBDIR:-claude-hydra-messages/inbox}"

# _wd_usable_worktree <dir/> — true if dir is a git worktree with a writable inbox.
_wd_usable_worktree() {
  local d="$1"
  [ -e "${d}.git" ] && [ -d "${d}${WATCHDOG_INBOX_SUBDIR}" ] && [ -w "${d}${WATCHDOG_INBOX_SUBDIR}" ]
}

# wd_resolve_coordinator_dir — sets WD_COORDINATOR_DIR to the coordinator
# worktree path (with a trailing slash), or "" if none, and WD_COORDINATOR_NOTE
# to a human-readable warning when resolution was not clean (explicit dir
# unusable, several candidates, or stray non-worktree staging* folders).
# Call it directly, NOT as $(...): a command substitution runs in a subshell and
# both variables would be lost.
wd_resolve_coordinator_dir() {
  WD_COORDINATOR_NOTE=""
  WD_COORDINATOR_DIR=""
  local d chosen="" exact="" n=0 strays=""
  if [ -n "${WATCHDOG_STAGING_DIR:-}" ]; then
    d="$WATCHDOG_WORKTREES_ROOT/${WATCHDOG_STAGING_DIR%/}/"
    if _wd_usable_worktree "$d"; then WD_COORDINATOR_DIR="$d"; return 0; fi
    WD_COORDINATOR_NOTE="WATCHDOG_STAGING_DIR=$WATCHDOG_STAGING_DIR is not a git worktree with a writable inbox; fell back to discovery. "
  fi
  for d in "$WATCHDOG_WORKTREES_ROOT"/staging*/; do
    [ -d "$d" ] || continue
    if _wd_usable_worktree "$d"; then
      n=$((n + 1))
      [ -z "$chosen" ] && chosen="$d"
      [ "$(basename "$d")" = "staging" ] && exact="$d"
    elif [ -d "${d}${WATCHDOG_INBOX_SUBDIR}" ]; then
      strays="$strays $(basename "$d")"
    fi
  done
  [ -n "$exact" ] && chosen="$exact"
  [ "$n" -gt 1 ] && WD_COORDINATOR_NOTE="${WD_COORDINATOR_NOTE}$n candidate coordinator worktrees; using $(basename "$chosen"). Set WATCHDOG_STAGING_DIR to pin one. "
  [ -n "$strays" ] && WD_COORDINATOR_NOTE="${WD_COORDINATOR_NOTE}Ignored non-worktree folder(s) with an inbox:${strays} (messages there are never read). "
  WD_COORDINATOR_DIR="$chosen"
}

# wd_coordinator_tmux_session <dir> — prints the name of a tmux session that has
# a pane whose current directory is <dir> (the coordinator agent's session), or
# nothing. Lets an acute alert wake the coordinator instead of waiting for its
# next turn. WATCHDOG_WAKE_TMUX_SESSION overrides discovery.
wd_coordinator_tmux_session() {
  local dir="${1%/}"
  if [ -n "${WATCHDOG_WAKE_TMUX_SESSION:-}" ]; then printf '%s\n' "$WATCHDOG_WAKE_TMUX_SESSION"; return 0; fi
  command -v tmux >/dev/null 2>&1 || return 0
  tmux list-panes -a -F '#{session_name}	#{pane_current_path}' 2>/dev/null \
    | awk -F'\t' -v d="$dir" '$2 == d { print $1; exit }'
}
