#!/usr/bin/env bash
# Claude Code terminal styling for SSH+tmux+iTerm2 (GCE remote).
# Title -> git branch (relayed to iTerm2 tab via `set-titles on`); tab tint by
# state via OSC-6 + window bg via OSC Ph, both wrapped in tmux passthrough
# (`allow-passthrough on`).
#   Usage: term-style.sh <running|idle|done>
state="${1:-done}"

# --- Honor "completed" marker -------------------------------------------
# A sub-Claude that explicitly tinted blue (via claude-tab-color.sh b)
# drops a marker so subsequent Stop / PreToolUse / Notification hook
# firings don't overwrite the blue with done-green or running-cream.
# The marker is cleared by any non-blue claude-tab-color.sh call, or
# manually with `rm`. Marker key is the worktree directory's basename.
marker="$HOME/.cache/claude-attention/$(basename "$PWD")-completed.txt"
if [ -f "$marker" ]; then
  exit 0
fi

# --- Resolve the target pane + its tty from tmux (CLAUDE_TTY is unreliable
#     in the hook env on this remote, so prefer tmux's own view). ----------
pane=""; tty=""
if [ -n "$TMUX" ]; then
  # The pane whose tty matches our controlling terminal, else the active pane.
  pane=$(tmux display -p '#{pane_id}' 2>/dev/null)
  tty=$(tmux display -p '#{pane_tty}' 2>/dev/null)
fi
[ -z "$tty" ] && tty="${CLAUDE_TTY:-/dev/tty}"

# --- Bare branch label for $PWD -----------------------------------------
case "$PWD" in
  */worktrees/*) branch=$(echo "$PWD" | sed -E 's#.*/worktrees/([^/]+).*#\1#') ;;
  */wiki|*/wiki/*) branch="wiki" ;;
  *)
    branch=$(git -C "$PWD" branch --show-current 2>/dev/null)
    [ -z "$branch" ] && branch=$(basename "$PWD") ;;
esac

# --- Title: set the tmux pane title (authoritative; relayed to iTerm2). --
if [ -n "$pane" ]; then
  tmux select-pane -t "$pane" -T "$branch" 2>/dev/null
elif [ -n "$TMUX" ]; then
  tmux select-pane -T "$branch" 2>/dev/null
else
  printf '\033]0;%s\007' "$branch" > "$tty" 2>/dev/null
fi

# --- Tab tint by state via iTerm2 OSC-6 ---------------------------------
case "$state" in
  running) osc=$'\033]6;1;bg;red;brightness;255\a\033]6;1;bg;green;brightness;248\a\033]6;1;bg;blue;brightness;224\a'; bg='f6f4e6' ;;  # cream
  *)       osc=$'\033]6;1;bg;red;brightness;200\a\033]6;1;bg;green;brightness;255\a\033]6;1;bg;blue;brightness;200\a'; bg='e8f6e8' ;;  # green
esac
if [ -n "$TMUX" ]; then
  payload="${osc//$'\033'/$'\033\033'}"
  printf '\033Ptmux;%s\033\\' "$payload" > "$tty" 2>/dev/null
else
  printf '%s' "$osc" > "$tty" 2>/dev/null
fi

# --- Window bg tint via OSC Ph (terminatorless; needs OWN passthrough write).
# Matches color.sh's pattern: OSC-6 and OSC Ph must not share a payload
# (escape-doubling mangles the boundary, leaving the tab "murky").
bgosc=$(printf '\033]Ph%s' "$bg")
if [ -n "$TMUX" ]; then
  bgwrapped="${bgosc//$'\033'/$'\033\033'}"
  printf '\033Ptmux;%s\033\\' "$bgwrapped" > "$tty" 2>/dev/null
else
  printf '%s' "$bgosc" > "$tty" 2>/dev/null
fi
exit 0
