#!/usr/bin/env bash
# heartbeat.sh — script-side heartbeat.
# Runs forever as a systemd Service. Writes one timestamped line every 5s and
# fsyncs. If this log STOPS at time T, the kernel/IO stopped working at ~T.
# See ~/watchdog/runbook.md for the freeze-window analysis recipe.

set -u
LOG="/home/josh/watchdog/logs/heartbeat.log"
INTERVAL=5
MAX_BYTES=$((20 * 1024 * 1024))   # 20 MB

while :; do
  # rotate inline (cheap; one stat per tick)
  if [ -f "$LOG" ]; then
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$MAX_BYTES" ]; then
      mv "$LOG" "$LOG.1"
    fi
  fi

  # ISO-8601 UTC + monotonic uptime + load1, single line + fsync.
  ts=$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')
  up=$(awk '{print $1}' /proc/uptime)
  la=$(awk '{print $1}' /proc/loadavg)
  printf 'tick ts=%s uptime=%s load1=%s\n' "$ts" "$up" "$la" >> "$LOG"
  sync -d "$LOG" 2>/dev/null

  sleep "$INTERVAL"
done
