#!/usr/bin/env bash
# heartbeat-staging.sh — periodic liveness ping to the Hydra staging agent.
#
# A dead-man's switch. The watchdog sends staging a quiet "monitor is alive"
# message every ~10 minutes. Staging's job is to notice when these STOP: if the
# newest liveness note is older than 15 minutes, the monitor (or the whole
# machine) has died, and that ABSENCE is itself the alert. See
# ~/watchdog/README.md "Liveness heartbeat to staging" and the staging-side
# contract in the Hydra repo (claude/external-alerts.md).
#
# Like alert-staging.sh, this is a plain script — no Claude, no polling, no
# inbox on our side. It runs, writes one file, exits.
#
# Distinct from alert-staging.sh:
#   - QUIET: inbox note only, NO attention-marker (routine beats must not cry wolf).
#   - SELF-OVERWRITING: a STABLE filename, so each beat replaces the previous one
#     in staging's inbox instead of piling up ~144 files/day. Staging always sees
#     exactly one "latest liveness" note; its mtime/body is the freshness signal.
#
# Driven by health-monitor.sh (already on a 60s timer) via an interval stamp, so
# liveness is tied to the very collector whose health it asserts: if that
# collector stops, the heartbeats stop — which is exactly the signal we want.
#
# Exit 0 on send, on interval-suppression, or if no staging worktree is found.

set -u

WT_ROOT="/home/josh/projects/github/CategoricalData/hydra/worktrees"
INTERVAL_STAMP="/home/josh/watchdog/logs/.last-staging-heartbeat"
SEND_INTERVAL_SECS=600   # 10 min send cadence (staging alarms at >15 min silence)

# Stable filename → each send overwrites the last in staging's inbox.
BEAT_FNAME="watchdog-alpha-liveness.md"

now_epoch=$(date -u +%s)
ts_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# --- interval gate: only send if >= SEND_INTERVAL since the last beat ---
if [ -f "$INTERVAL_STAMP" ]; then
  last=$(cat "$INTERVAL_STAMP" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now_epoch - last)) -lt "$SEND_INTERVAL_SECS" ]; then
    exit 0   # not due yet
  fi
fi

# --- resolve the staging worktree by glob (name starts with "staging") ---
staging_dir=""
for d in "$WT_ROOT"/staging*/; do
  [ -d "$d" ] || continue
  if [ -d "${d}claude-hydra-messages/inbox" ]; then staging_dir="$d"; break; fi
  [ -z "$staging_dir" ] && staging_dir="$d"
done
[ -z "$staging_dir" ] && exit 0   # no staging worktree here; nothing to do
staging_inbox="${staging_dir}claude-hydra-messages/inbox"
staging_name=$(basename "$staging_dir")

uptime_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)

# --- compose the quiet liveness note ---
msg_body=$(cat <<EOF
# ♥ watchdog liveness — alpha monitor is alive

**From:** watchdog (script-generated — there is no watchdog agent)
**To:** ${staging_name}
**Date:** ${ts_iso}
**Kind:** routine liveness heartbeat (not an alert — nothing is wrong)

The \`alpha\` monitoring process is alive as of **${ts_iso}** (host uptime
${uptime_s}s). Sent about every 10 minutes.

**This is a dead-man's switch — the signal is its ABSENCE.** If the newest note
with this title is **older than 15 minutes**, the monitor or the machine has
likely died. Treat that staleness as a condition to respond to (see the handling
guidance for a stale/absent liveness heartbeat in \`claude/external-alerts.md\`):
check whether \`alpha\` is reachable and whether the last thing the logs show is a
freeze signature (\`~/watchdog/logs/\` and \`~/watchdog/archive/\`).

This message **overwrites in place** (stable filename), so there is always
exactly one liveness note in your inbox — its freshness is the whole point.
Archiving or reading it is optional; a fresh one replaces it on the next beat.
No reply channel — nothing here reads a response.

— watchdog/heartbeat-staging.sh
EOF
)

# --- deliver: overwrite the single liveness note in staging's inbox ---
mkdir -p "$staging_inbox"
printf '%s\n' "$msg_body" > "$staging_inbox/$BEAT_FNAME" 2>/dev/null

# --- record the send time only after a successful write ---
if [ -s "$staging_inbox/$BEAT_FNAME" ]; then
  printf '%s\n' "$now_epoch" > "$INTERVAL_STAMP"
fi

exit 0
