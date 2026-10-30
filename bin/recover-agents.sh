#!/usr/bin/env bash
# Relaunch agent sessions after a machine crash: one tmux session per worktree,
# each running `claude-remote <session> -m <model> --continue` so the prior
# conversation resumes, optionally followed by a wake-up prompt.
#
# Which worktrees (pick one source):
#   --roster FILE          lines of "<worktree-dir-name> [model]" ('#' comments ok)
#   --live-within MIN      worktrees whose Claude transcript was written in the last
#                          MIN minutes: the sessions that were actually alive
#                          before the crash (pick MIN to reach a couple of hours
#                          before the crash, e.g. 300 if it was ~3 h ago)
#   (neither)              every bug_*/feature_*/task_* worktree — usually far too
#                          many; see --max
#
# Options:
#   --max N            launch at most N sessions this run (default 25). Restore in
#                      batches and check memory between them: restoring a whole
#                      fleet at once is how a crashed machine gets crashed again.
#   --model M          model for worktrees with no model in the roster and none
#                      found in their transcript (default: the config's spawn model)
#   --prompt TEXT      wake-up prompt sent to each new session (e.g. "read
#                      <recovery brief>, then run the startup procedure")
#   --dry-run          print what would be launched, launch nothing
#
# Models: a roster line's model wins; otherwise the model of the worktree's most
# recent Claude transcript is reused, so a restart never silently changes an
# agent's model (claude-remote's own default would). Session names match
# spawn-issue-worktree.sh (HA_SESSION_PREFIX + name); existing sessions are
# skipped, never duplicated. See docs/crash-recovery.md.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-config.sh"

WORKTREES_DIR="${HA_WORKTREES_DIR:-${HOME}/projects/github/CategoricalData/hydra/worktrees}"
TRANSCRIPTS_DIR="${HOME}/.claude/projects"

roster="" live_within="" max=25 default_model="" prompt="" dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --roster) roster="$2"; shift 2 ;;
    --live-within) live_within="$2"; shift 2 ;;
    --max) max="$2"; shift 2 ;;
    --model) default_model="$2"; shift 2 ;;
    --prompt) prompt="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$WORKTREES_DIR" ]; then
  echo "error: $WORKTREES_DIR not found" >&2
  exit 1
fi

# Session name: must match spawn-issue-worktree.sh, or recovery looks for the
# wrong name and launches a DUPLICATE agent (hydra-agents#1). Per-project
# HA_SESSION_PREFIX, plus a `hostname -s` suffix for standardized branches.
session_name_for() {
  local wt_path="$1" wt_name="$2" prefix="" sess_branch="$2"
  if CLAUDE_PROJECT_DIR="$wt_path" ha_load_config >/dev/null 2>&1; then
    prefix="$HA_SESSION_PREFIX"
    local _std
    for _std in ${HA_STANDARDIZED_BRANCHES}; do
      if [ "$wt_name" = "$_std" ]; then sess_branch="${wt_name}-${HA_MACHINE}"; break; fi
    done
    [ -z "$default_model" ] && default_model="${HA_SPAWN_MODEL:-}"
  fi
  printf '%s%s' "$prefix" "$sess_branch"
}

# Claude Code stores a worktree's transcripts under a directory named after its
# path with '/', '_' and '.' replaced by '-'.
transcript_dir_for() { printf '%s/%s' "$TRANSCRIPTS_DIR" "$(printf '%s' "$1" | sed 's#[/_.]#-#g')"; }

# Model of the worktree's most recent transcript, as a claude-remote alias.
model_from_transcript() {
  local tdir f m
  tdir="$(transcript_dir_for "$1")"
  f="$(ls -t "$tdir"/*.jsonl 2>/dev/null | head -1)" || true
  [ -n "$f" ] || return 0
  m="$(grep -ohE '"model":"claude-[^"]+"' "$f" 2>/dev/null | tail -1)" || true
  case "$m" in *opus*) echo opus ;; *sonnet*) echo sonnet ;; *haiku*) echo haiku ;; esac
}

# --- collect candidates: "<name> <model-or-empty>" ---
candidates=()
if [ -n "$roster" ]; then
  while read -r name model _; do
    case "$name" in ''|\#*) continue ;; esac
    candidates+=("$name ${model:-}")
  done < "$roster"
elif [ -n "$live_within" ]; then
  # find -mmin works on GNU and BSD find alike (unlike touch -d / date -d).
  for wt_path in "$WORKTREES_DIR"/*/; do
    wt_path="${wt_path%/}"
    tdir="$(transcript_dir_for "$wt_path")"
    [ -d "$tdir" ] || continue
    [ -n "$(find "$tdir" -maxdepth 1 -name '*.jsonl' -mmin "-$live_within" 2>/dev/null | head -1)" ] \
      && candidates+=("$(basename "$wt_path") ")
  done
else
  for wt_path in "$WORKTREES_DIR"/bug_*/ "$WORKTREES_DIR"/feature_*/ "$WORKTREES_DIR"/task_*/; do
    [ -d "$wt_path" ] && candidates+=("$(basename "$wt_path") ")
  done
fi

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "no candidate worktrees found" >&2
  exit 0
fi

launched=() skipped=() missing=() deferred=()
for c in "${candidates[@]}"; do
  wt="${c%% *}"; model="${c#* }"
  wt_path="${WORKTREES_DIR}/${wt}"
  if [ ! -e "$wt_path/.git" ]; then missing+=("$wt"); continue; fi
  session="$(session_name_for "$wt_path" "$wt")"
  # `=` forces exact-name matching (tmux otherwise prefix-matches — hydra-agents#1).
  if tmux has-session -t "=$session" 2>/dev/null; then skipped+=("$session (already running)"); continue; fi
  [ -z "$model" ] && model="$(model_from_transcript "$wt_path")"
  [ -z "$model" ] && model="${default_model:-opus}"
  if [ "${#launched[@]}" -ge "$max" ]; then deferred+=("$wt $model"); continue; fi

  launched+=("$session ($model)")
  [ "$dry_run" = 1 ] && continue
  tmux new-session -d -s "$session" -c "$wt_path"
  tmux set-window-option -t "=$session:" automatic-rename off 2>/dev/null || true
  tmux rename-window -t "=$session:" "$wt" 2>/dev/null || true
  tmux send-keys -t "=$session:" "claude-remote $session -m $model --continue" Enter
  if [ -n "$prompt" ]; then
    sleep 10   # let the TUI come up; the first launch after a CLI update is slower
    # Text and Enter separately, then an insurance Enter: the TUI's paste
    # detection often swallows the first Enter, leaving the prompt unsent.
    tmux send-keys -t "=$session:" "$prompt"; sleep 1
    tmux send-keys -t "=$session:" Enter; sleep 2
    tmux send-keys -t "=$session:" Enter
  else
    sleep 2
  fi
done

[ "$dry_run" = 1 ] && echo "(dry run — nothing launched)"
echo "Launched ${#launched[@]} session(s):"
# (Each loop is guarded by a length check: on bash 3.2, "${arr[@]}" of an empty
# array is an unbound-variable error under set -u.)
if [ "${#launched[@]}" -gt 0 ]; then for s in "${launched[@]}"; do echo "  + $s"; done; fi
if [ "${#skipped[@]}" -gt 0 ]; then echo "Skipped ${#skipped[@]}:"; for s in "${skipped[@]}"; do echo "  - $s"; done; fi
if [ "${#missing[@]}" -gt 0 ]; then echo "Not a worktree (ignored) ${#missing[@]}:"; for s in "${missing[@]}"; do echo "  ? $s"; done; fi
if [ "${#deferred[@]}" -gt 0 ]; then
  echo "Deferred by --max ${max}: ${#deferred[@]} more. Check memory (free -h), then rerun;"
  echo "already-running sessions are skipped, so a rerun continues where this stopped."
fi
echo
echo "Verify each pane is working, not idling at the prompt: tmux capture-pane -t =<session>: -p | tail"
