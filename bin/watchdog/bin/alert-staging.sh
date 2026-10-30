#!/usr/bin/env bash
# alert-staging.sh — one-shot memory-pressure alert to the staging (coordinator) agent.
#
# Called by health-monitor.sh when a threshold trips. There is NO Claude in the
# watchdog: this is a plain script that observes and warns. It never remediates.
# The coordinator decides what to do (pause a build, hold the build slot, stop
# sessions); this script only delivers the warning + evidence.
#
# Two tiers (chosen by health-monitor.sh; see its threshold comment):
#   acute    the machine is close to the swap-exhaustion livelock. Delivered to
#            the coordinator's inbox AND typed into its tmux session to wake it
#            (an idle agent never sees its inbox until its next turn — on
#            2026-10-30 the coordinator sat idle for 45 minutes while a build
#            pushed the box over). Cooldown ACUTE_COOLDOWN_SECS (10 min).
#   chronic  swap has been high for a while but nothing is stalling yet: the
#            fleet's resident set is near capacity. Inbox only, at most once a
#            day. Firing this every 15 minutes is what turned the old single-tier
#            alert into 288 ignorable messages over 4 weeks.
#
# Design constraints (see ../README.md "Alerting staging on danger"):
#   - No agent, no polling on the watchdog side. Runs, writes files, exits.
#     Nothing reads a reply: the watchdog has no inbox because it has no reader.
#   - Channels: coordinator inbox message, an attention marker (out-of-band,
#     watched by the user), and for acute only a tmux wake-up.
#   - The coordinator is resolved by lib-coordinator.sh (real git worktrees only).
#
# Args (all passed in by health-monitor so we don't re-collect):
#   $1 reason slug     e.g. "swap99-avail1532-psi0"
#   $2 one-line human summary of what tripped (with the numbers)
#   $3 top-RSS process line (the leading offender), optional
#   $4 tier            acute | chronic   (default: acute)
#
# Env: WATCHDOG_WAKE=0 disables the tmux wake-up. See lib-coordinator.sh for
# coordinator discovery env.
#
# Exit 0 on send, on cooldown-suppression, or if no coordinator is found
# (none of these is an error worth failing the health tick over).

set -u

_AS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-coordinator.sh
. "$_AS_DIR/lib-coordinator.sh"

HOST="$(hostname -s 2>/dev/null || echo host)"
ATTENTION_DIR="$HOME/.cache/claude-attention"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/watchdog/logs}"
ACUTE_COOLDOWN_SECS="${ACUTE_COOLDOWN_SECS:-600}"
CHRONIC_COOLDOWN_SECS="${CHRONIC_COOLDOWN_SECS:-86400}"

reason="${1:-unspecified}"
summary="${2:-memory pressure detected}"
offender="${3:-}"
tier="${4:-acute}"
case "$tier" in acute|chronic) ;; *) tier=acute ;; esac

if [ "$tier" = acute ]; then
  COOLDOWN_STAMP="$WATCHDOG_STATE_DIR/.last-staging-alert"
  COOLDOWN_SECS="$ACUTE_COOLDOWN_SECS"
else
  COOLDOWN_STAMP="$WATCHDOG_STATE_DIR/.last-staging-alert-chronic"
  COOLDOWN_SECS="$CHRONIC_COOLDOWN_SECS"
fi

now_epoch=$(date -u +%s)
ts_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
ts_file=$(date -u +'%Y-%m-%dT%H-%M-%SZ')   # colons→dashes for portable filenames
# Acute keeps the long-standing marker name; chronic gets its own file so a daily
# digest can never overwrite (and hide) a recent acute warning.
marker="$ATTENTION_DIR/watchdog-${HOST}-memory-pressure.txt"
[ "$tier" = chronic ] && marker="$ATTENTION_DIR/watchdog-${HOST}-memory-pressure-chronic.txt"

# --- de-bounce: skip if this tier alerted within its cooldown window ---
if [ -f "$COOLDOWN_STAMP" ]; then
  last=$(cat "$COOLDOWN_STAMP" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now_epoch - last)) -lt "$COOLDOWN_SECS" ]; then
    exit 0
  fi
fi

wd_resolve_coordinator_dir
staging_dir="$WD_COORDINATOR_DIR"
if [ -z "$staging_dir" ]; then
  # No coordinator worktree right now. Still record an attention marker so the
  # danger is not lost, then exit cleanly.
  mkdir -p "$ATTENTION_DIR"
  {
    echo "watchdog: ${HOST} memory pressure (${tier}) — ${reason}"
    echo "$summary"
    [ -n "$offender" ] && echo "offender: $offender"
    echo "at ${ts_iso}; NO coordinator worktree found under ${WATCHDOG_WORKTREES_ROOT} — message not delivered. ${WD_COORDINATOR_NOTE}"
  } > "$marker"
  printf '%s\n' "$now_epoch" > "$COOLDOWN_STAMP"
  exit 0
fi
staging_inbox="${staging_dir}${WATCHDOG_INBOX_SUBDIR}"
staging_name=$(basename "$staging_dir")
fname="${ts_file}-watchdog-${HOST}-memory-pressure-${tier}.md"

# --- compose the message (advisory; the coordinator decides the action) ---
if [ "$tier" = acute ]; then
  msg_body="# ⚠ ${HOST}: ACUTE memory pressure — freeze risk now

**From:** watchdog (script-generated — there is no watchdog agent)
**To:** ${staging_name}
**Date:** ${ts_iso}
**Severity:** urgent — act within minutes

RAM and swap are both nearly exhausted, or tasks are already stalling on memory.
This is the regime that turned into a full livelock with no OOM kill on
2026-07-08 and 2026-10-30: once the next memory-hungry step starts, the box can
go from here to unresponsive in about two minutes.

**What tripped:** ${summary}"
else
  msg_body="# ${HOST}: chronic memory pressure (daily digest)

**From:** watchdog (script-generated — there is no watchdog agent)
**To:** ${staging_name}
**Date:** ${ts_iso}
**Severity:** not urgent — capacity warning, sent at most once a day

Swap has stayed high, but nothing is stalling yet. The resident set (usually the
agent sessions themselves) is near the machine's capacity, so the next heavy
build has little room. An acute alert will follow if it gets dangerous.

**What tripped:** ${summary}"
fi

if [ -n "$offender" ]; then
  msg_body="${msg_body}

**Leading resident-memory process right now:**
\`\`\`
${offender}
\`\`\`"
fi

if [ "$tier" = acute ]; then
  msg_body="${msg_body}

**Recommended now (your call):** find what is growing (\`ps -eo pid,rss,etime,args --sort=-rss | head\`)
and pause or stop the heavy build before its next memory-hungry stage; don't grant
the build slot to anything new until available memory recovers. Stopping a few
idle or very long-lived agent sessions also frees memory quickly."
else
  msg_body="${msg_body}

**Recommended (your call):** shrink the resident set before the next heavy build:
cap the number of live sessions, and restart sessions that have been running for
weeks (they grow to 2-3x the memory of a fresh session)."
fi

msg_body="${msg_body}

**No reply channel.** Nothing on the watchdog side reads a response. Evidence:
\`${WATCHDOG_STATE_DIR}/health.log\` (tail)."
[ -n "$WD_COORDINATOR_NOTE" ] && msg_body="${msg_body}

**Watchdog routing note:** ${WD_COORDINATOR_NOTE}"
msg_body="${msg_body}

— watchdog/alert-staging.sh (tier=${tier}, reason=${reason})"

# --- deliver: write directly to the coordinator's inbox, then verify it landed ---
delivered=0
if printf '%s\n' "$msg_body" > "$staging_inbox/$fname" && [ -s "$staging_inbox/$fname" ]; then
  delivered=1
fi

# --- acute only: wake the coordinator's session (an idle agent never reads its inbox) ---
woke=""
if [ "$tier" = acute ] && [ "${WATCHDOG_WAKE:-1}" != 0 ]; then
  sess="$(wd_coordinator_tmux_session "$staging_dir")"
  if [ -n "$sess" ]; then
    # Text and Enter as separate send-keys: a single call is often swallowed by
    # the TUI's paste detection. The second Enter is insurance; if the text was
    # already submitted it only adds an empty line.
    if tmux send-keys -t "=${sess}:" "[watchdog] ACUTE memory pressure on ${HOST}: ${summary}. Read ${WATCHDOG_INBOX_SUBDIR}/${fname} and act now." 2>/dev/null; then
      sleep 1; tmux send-keys -t "=${sess}:" Enter 2>/dev/null
      sleep 2; tmux send-keys -t "=${sess}:" Enter 2>/dev/null
      woke="$sess"
    fi
  fi
fi

# --- attention marker: out-of-band channel the user watches ---
mkdir -p "$ATTENTION_DIR"
{
  echo "watchdog: ${HOST} memory pressure (${tier}) — ${reason}"
  echo "$summary"
  [ -n "$offender" ] && echo "offender: $offender"
  echo "at ${ts_iso}; message → ${staging_name} inbox (delivered=${delivered})${woke:+; woke tmux session ${woke}}"
  [ -n "$WD_COORDINATOR_NOTE" ] && echo "routing note: $WD_COORDINATOR_NOTE"
  echo "detail: ${WATCHDOG_STATE_DIR}/health.log tail"
} > "$marker"

# --- record cooldown stamp only once we've actually alerted ---
printf '%s\n' "$now_epoch" > "$COOLDOWN_STAMP"

exit 0
