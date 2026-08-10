#!/usr/bin/env bash
# health-monitor.sh — append a compact system snapshot to ~/watchdog/logs/health.log
# Runs every 60s via systemd timer. Designed to be cheap and crash-survivable:
#   - flushes after every block so the kernel doesn't lose much on a hard reset
#   - rotates at 50 MB
#   - records absolute UTC time + monotonic uptime so we can spot gaps after a reboot
#
# See ~/watchdog/runbook.md for the interpretation guide.

set -u
LOG="/home/josh/watchdog/logs/health.log"
MAX_BYTES=$((50 * 1024 * 1024))   # 50 MB rotate threshold

# rotate if too big — keep one .1 backup
if [ -f "$LOG" ]; then
  sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$MAX_BYTES" ]; then
    mv "$LOG" "$LOG.1"
  fi
fi

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
uptime_secs() { awk '{print int($1)}' /proc/uptime; }
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

{
  echo "===== $(ts)  uptime=$(uptime_secs)s  boot_id=$(boot_id) ====="
} >> "$LOG"
# Flush the header immediately. If the kernel freezes mid-snapshot, at least
# the timestamp + boot_id of the last attempted snapshot is preserved on disk.
sync -d "$LOG" 2>/dev/null

{
  echo "--- loadavg ---"
  cat /proc/loadavg
  awk '/^procs_running/ {pr=$2} /^procs_blocked/ {pb=$2} END {printf "procs_running=%s procs_blocked=%s\n", pr, pb}' /proc/stat

  echo "--- mem (MiB) ---"
  free -m | awk 'NR<=3'
  for psi in cpu memory io; do
    f=/proc/pressure/$psi
    [ -r "$f" ] && printf "psi.%s: %s\n" "$psi" "$(tr -s '[:space:]' ' ' < "$f")"
  done

  echo "--- swap ---"
  awk 'NR==1 || /./' /proc/swaps
  awk '/^pswpin|^pswpout|^pgmajfault|^pgpgin|^pgpgout|^nr_dirty|^nr_writeback|^oom_kill/' /proc/vmstat

  echo "--- diskstats (sda) ---"
  awk '$3=="sda" {printf "reads=%s read_ms=%s writes=%s write_ms=%s io_ms=%s ios_in_progress=%s\n", $4, $7, $8, $11, $13, $12}' /proc/diskstats

  echo "--- disk (root) ---"
  df -h --output=target,size,used,avail,pcent / 2>/dev/null

  echo "--- top 8 RSS processes ---"
  ps -eo pid,user,pcpu,rss,vsz,etime,comm --sort=-rss --no-headers | head -8 \
    | awk '{printf "pid=%s user=%s cpu=%s%% rss=%dMB vsz=%dMB elapsed=%s comm=%s\n", $1,$2,$3,$4/1024,$5/1024,$6,$7}'

  echo "--- claude / ghc / stack / cabal / guile process count ---"
  for p in claude ghc stack cabal guile node python rustc cargo; do
    n=$(pgrep -c -x "$p" 2>/dev/null)
    [ -z "$n" ] && n=0
    [ "$n" -gt 0 ] && printf "%s=%d  " "$p" "$n"
  done
  echo

  echo "--- recent kernel warnings (last 5 min) ---"
  if dmesg -T --since '5 min ago' >/dev/null 2>&1; then
    dmesg -T --since '5 min ago' 2>/dev/null \
      | grep -iE 'oom|killed process|panic|hung_task|soft lockup|hard lockup|nmi|mce|segfault|stall|warning|error' \
      | tail -15
  else
    dmesg -T 2>/dev/null | tail -200 \
      | grep -iE 'oom|killed process|panic|hung_task|soft lockup|hard lockup|nmi|mce|segfault|stall|warning|error' \
      | tail -15
  fi

  echo "--- recent journal warnings (last 5 min, prio<=warning) ---"
  journalctl --since '5 min ago' -p warning --no-pager 2>/dev/null \
    | grep -vE 'sshd\[.*(Invalid user|Disconnected|Received disconnect|Connection closed|Bye Bye|preauth)' \
    | tail -15

  echo "--- GCE maintenance-event (if any) ---"
  curl -s --max-time 1 -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/maintenance-event" 2>/dev/null \
    || echo "(metadata unreachable)"
  echo

  echo "===== END $(ts) ====="
  echo
} >> "$LOG" 2>&1

sync -d "$LOG" 2>/dev/null || sync

# ----------------------------------------------------------------------------
# Danger check → alert the staging-gce agent (advisory only; never remediate).
# Thresholds chosen from the 2026-07-08 freeze: swap hit 100%, PSI mem-stall
# some-avg10 reached 74% at the last complete snapshot. We fire EARLIER than
# that — while there's still headroom to act. alert-staging.sh de-bounces, so
# this staying true every tick during a squeeze does not spam.
#   Trigger:  swap used >= 90%  OR  PSI memory some-avg10 >= 40%
# ----------------------------------------------------------------------------
ALERT="/home/josh/watchdog/bin/alert-staging.sh"
if [ -x "$ALERT" ]; then
  # swap used % (integer); 0 if no swap configured
  swap_pct=$(free | awk '/^Swap:/ { if ($2>0) printf "%d", ($3*100)/$2; else print 0 }')
  [ -z "$swap_pct" ] && swap_pct=0
  # PSI memory some-avg10 (integer part); 0 if unavailable
  psi_mem=$(awk '/^some/ { for(i=1;i<=NF;i++) if($i ~ /^avg10=/){split($i,a,"=");print int(a[2]);exit} }' \
              /proc/pressure/memory 2>/dev/null)
  [ -z "$psi_mem" ] && psi_mem=0

  if [ "$swap_pct" -ge 90 ] || [ "$psi_mem" -ge 40 ]; then
    mem_avail=$(free -m | awk '/^Mem:/ {print $7}')
    pblocked=$(awk '/^procs_blocked/ {print $2}' /proc/stat)
    top_rss=$(ps -eo pid,user,pcpu,rss,etime,comm --sort=-rss --no-headers 2>/dev/null | head -1 \
                | awk '{printf "pid=%s user=%s cpu=%s%% rss=%dMB elapsed=%s comm=%s", $1,$2,$3,$4/1024,$5,$6}')
    reason="swap${swap_pct}-psi${psi_mem}"
    summary="swap ${swap_pct}% used, mem-avail ${mem_avail}MB, procs_blocked ${pblocked}, PSI mem-stall(avg10) ${psi_mem}%"
    "$ALERT" "$reason" "$summary" "$top_rss" >/dev/null 2>&1 || true
  fi
fi

# ----------------------------------------------------------------------------
# Liveness heartbeat → staging (dead-man's switch). Called every tick; the
# script self-gates to send once per ~10 min. Because it rides this collector,
# the heartbeats stop exactly when this collector (or the machine) stops — which
# is the absence-signal staging watches for. See heartbeat-staging.sh.
# ----------------------------------------------------------------------------
HEARTBEAT="/home/josh/watchdog/bin/heartbeat-staging.sh"
[ -x "$HEARTBEAT" ] && "$HEARTBEAT" >/dev/null 2>&1 || true
