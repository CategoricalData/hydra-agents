#!/bin/bash
# health-watchdog.sh — macOS resource watchdog for a machine running an agent fleet.
#
# The macOS counterpart of ../bin/health-monitor.sh (Linux, systemd). A plain
# script, not an agent: launchd runs it every 60 s (see launchd.plist.template),
# it appends one line to health.log, and on sustained memory pressure or low
# disk it warns the staging agent, then exits. It observes and warns; it never
# remediates. Staging decides what to do (typically: throttle or pause heavy
# build workers). See ../README.md "macOS" for install and design.
#
# Portable to macOS's stock /bin/bash 3.2 and BSD userland (see
# docs/pitfalls.md "Fleet scripts must run on bash 3.2 and BSD userland").
#
# Configuration (environment; set in the launchd plist):
#   WATCHDOG_STATE_DIR      log + state dir            (default ~/watchdog/logs)
#   WATCHDOG_INBOX          staging agent's inbox dir  (default: unset = no
#                           inbox message, attention marker only)
#   WATCHDOG_ATTENTION_DIR  attention-marker dir       (default ~/.cache/claude-attention)
#   WATCHDOG_DISK_MIN_GB    alert below this many GB free on /   (default 20)
#   WATCHDOG_COOLDOWN_SECS  minimum gap between alerts           (default 1800)
#   WATCHDOG_LOG_MAX_BYTES  rotate health.log above this size    (default 5 MiB)

set -u

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/watchdog/logs}"
INBOX="${WATCHDOG_INBOX:-}"
ATTENTION_DIR="${WATCHDOG_ATTENTION_DIR:-$HOME/.cache/claude-attention}"
DISK_MIN_GB="${WATCHDOG_DISK_MIN_GB:-20}"
COOLDOWN_SECS="${WATCHDOG_COOLDOWN_SECS:-1800}"
LOG_MAX_BYTES="${WATCHDOG_LOG_MAX_BYTES:-5242880}"

LOG="$STATE_DIR/health.log"
STAMP="$STATE_DIR/.last-alert"
HOST="$(hostname -s 2>/dev/null || echo unknown)"

mkdir -p "$STATE_DIR"

# Rotate crudely so the log never matters as a disk consumer; keep one .1.
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt "$LOG_MAX_BYTES" ]; then
    mv "$LOG" "$LOG.1"
fi

# kern.memorystatus_vm_pressure_level: 1=normal, 2=warning, 4=critical
PRESSURE="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)"
FREE_PCT="$(memory_pressure -Q 2>/dev/null | awk -F': *' '/percentage/ {gsub(/%/,"",$2); print $2}')"
FREE_PCT="${FREE_PCT:-unknown}"
LOAD="$(sysctl -n vm.loadavg | awk '{print $2}')"
DISK_AVAIL_GB="$(df -g / | awk 'NR==2 {print $4}')"
NOW_EPOCH="$(date +%s)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "$NOW_ISO pressure=$PRESSURE free_pct=$FREE_PCT load=$LOAD disk_avail_gb=$DISK_AVAIL_GB" >> "$LOG"

REASON=""
if [ "$PRESSURE" -ge 4 ] 2>/dev/null; then
    REASON="critical memory pressure (level $PRESSURE, free ${FREE_PCT}%)"
elif [ "$PRESSURE" -ge 2 ] 2>/dev/null; then
    # Warning level must be sustained (this sample and the previous one).
    if tail -2 "$LOG" | head -1 | grep -q 'pressure=[24] '; then
        REASON="sustained memory-pressure warning (level $PRESSURE, free ${FREE_PCT}%)"
    fi
fi
if [ "${DISK_AVAIL_GB:-999}" -lt "$DISK_MIN_GB" ] 2>/dev/null; then
    REASON="${REASON:+$REASON; }low disk (${DISK_AVAIL_GB} GB free on /)"
fi

[ -z "$REASON" ] && exit 0

# De-bounce: at most one alert per cooldown window.
LAST="$(cat "$STAMP" 2>/dev/null || echo 0)"
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
[ $((NOW_EPOCH - LAST)) -lt "$COOLDOWN_SECS" ] && exit 0

TOP_PROCS="$(ps -Ao rss=,comm= | sort -rn | head -5 | awk '{printf "  %.1f GB %s\n", $1/1048576, $2}')"

DELIVERED="no inbox configured"
if [ -n "$INBOX" ]; then
    if [ -d "$INBOX" ] && [ -w "$INBOX" ]; then
        FNAME="$(date -u +%Y-%m-%dT%H-%M-%SZ)-watchdog-${HOST}-resource-alert.md"
        cat > "$INBOX/$FNAME" <<EOF
# Resource alert: ${HOST}: ${REASON}

**From:** health watchdog on ${HOST} (a script; no agent, no reply channel)
**Date:** ${NOW_ISO}
**Suggested response (your call):** apply back-pressure: keep at most one heavy
build running, and pause or defer workers until pressure clears.

Snapshot: pressure_level=${PRESSURE} free=${FREE_PCT}% load=${LOAD} disk_avail=${DISK_AVAIL_GB} GB
Top resident memory:
${TOP_PROCS}

Log: ${LOG}
EOF
        if [ -s "$INBOX/$FNAME" ]; then DELIVERED="delivered to $INBOX"; else DELIVERED="write to $INBOX failed"; fi
    else
        DELIVERED="inbox $INBOX missing or unwritable"
    fi
fi

mkdir -p "$ATTENTION_DIR"
echo "$NOW_ISO $HOST: $REASON ($DELIVERED)" > "$ATTENTION_DIR/watchdog-${HOST}-resource-alert.txt"
echo "$NOW_EPOCH" > "$STAMP"
echo "$NOW_ISO ALERT: $REASON ($DELIVERED)" >> "$LOG"
exit 0
