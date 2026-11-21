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
# spawn-issue-worktree.sh (ha_session_name_for), and the runner adapter
# (bin/runners/<runner>.sh) names each agent session after its tmux session, so
# its messaging address is the same as before the crash. Existing sessions are
# skipped, never duplicated; so is a worktree where the runner's process is still
# running under some other session name (reported, for a human to retire). Before
# launching, the adapter writes each worktree's cross-session isolation settings,
# as at spawn; a worktree whose settings can't be written is not launched. See
# docs/crash-recovery.md.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-config.sh"
. "$HERE/lib-runner.sh"

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
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The runner adapter comes from the project's config; load it once up front.
ha_load_config >/dev/null 2>&1 || true
ha_load_runner || exit 1
ha_runner_check_version   # warns (never fails), e.g. below Claude Code's messaging minimum

if [ ! -d "$WORKTREES_DIR" ]; then
  echo "error: $WORKTREES_DIR not found" >&2
  exit 1
fi

# Session name: must match spawn-issue-worktree.sh, or recovery looks for the
# wrong name and launches a DUPLICATE agent (hydra-agents#1). Per-project
# HA_SESSION_PREFIX, plus a `hostname -s` suffix for standardized branches.
session_name_for() {
  local wt_path="$1" wt_name="$2"
  if CLAUDE_PROJECT_DIR="$wt_path" ha_load_config >/dev/null 2>&1; then
    [ -z "$default_model" ] && default_model="${HA_SPAWN_MODEL:-}"
  fi
  ha_session_name_for "$wt_name"
}

# PIDs of the runner's agent processes (HA_RUNNER_PROCESS, e.g. `claude`) whose
# working directory is $1. A live one means the
# worktree's agent survived (or was relaunched by hand) under a session name this
# script doesn't know: launching another would give two agents one worktree, and
# two sessions one SendMessage name. Linux reads /proc; elsewhere lsof, if present.
claude_pids_in() {
  local dir pid
  dir="$(cd "$1" && pwd -P)" || return 0
  if [ -d /proc/self ]; then
    for pid in $(pgrep -x "${HA_RUNNER_PROCESS:-claude}" 2>/dev/null); do
      [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$dir" ] && printf '%s ' "$pid"
    done
  elif command -v lsof >/dev/null 2>&1; then
    for pid in $(pgrep -x "${HA_RUNNER_PROCESS:-claude}" 2>/dev/null); do
      lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep -qx "n$dir" && printf '%s ' "$pid"
    done
  fi
  return 0
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
  pids="$(claude_pids_in "$wt_path")"
  if [ -n "$pids" ]; then skipped+=("$session (${HA_RUNNER_PROCESS:-claude} already running in $wt: pid ${pids% }; retire it or rename its tmux session to $session)"); continue; fi
  [ -z "$model" ] && model="$(model_from_transcript "$wt_path")"
  [ -z "$model" ] && model="${default_model:-opus}"
  if [ "${#launched[@]}" -ge "$max" ]; then deferred+=("$wt $model"); continue; fi

  if [ "$dry_run" = 1 ]; then launched+=("$session ($model)"); continue; fi
  CLAUDE_PROJECT_DIR="$wt_path" ha_load_config >/dev/null 2>&1 || true
  if ! ha_runner_prepare_worktree "$wt_path" "$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "$wt")"; then
    skipped+=("$session (could not write isolation settings; see the error above)"); continue
  fi
  launched+=("$session ($model)")
  tmux new-session -d -s "$session" -c "$wt_path"
  tmux set-window-option -t "=$session:" automatic-rename off 2>/dev/null || true
  # A private project's window title is its opaque session name (titles leave the project).
  if [ "${HA_PRIVATE:-true}" = true ]; then title="$session"; else title="$wt"; fi
  tmux rename-window -t "=$session:" "$title" 2>/dev/null || true
  # The runner adapter names the session after its tmux session, so the agent
  # keeps its pre-crash messaging address, and resumes its prior conversation.
  tmux send-keys -t "=$session:" "$(ha_runner_launch_cmd "$session" "$model" --resume)" Enter
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
