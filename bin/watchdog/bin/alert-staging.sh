#!/usr/bin/env bash
# alert-staging.sh — one-shot memory-pressure alert to the Hydra staging agent.
#
# Called by health-monitor.sh when a danger threshold trips. There is NO Claude
# in the watchdog: this is a plain script that observes and warns. It never
# remediates. The staging agent decides what to do (throttle/pause its build
# workers); this script only delivers the warning + evidence.
#
# Design constraints (see ~/watchdog/README.md "Alerting staging on danger"):
#   - No agent, no session, no polling anywhere on the watchdog side. This
#     script runs, writes files, exits. Nothing on this machine reads a reply —
#     the watchdog has no inbox because it has no reader.
#   - De-bounced: at most one alert per COOLDOWN window, so a sustained squeeze
#     produces a handful of alerts, not hundreds. Alerts stay INFREQUENT.
#   - Two channels: a Hydra inbox message (staging's next-turn hook surfaces it)
#     plus an attention-marker (the urgent out-of-band channel already watched).
#   - The staging worktree is resolved dynamically: its name always begins with
#     "staging" but is not guaranteed to be "staging-gce".
#
# Args (all passed in by health-monitor so we don't re-collect):
#   $1 reason slug     e.g. "swap95-psi70"
#   $2 one-line human summary of what tripped (with the numbers)
#   $3 top-RSS process line (the leading offender), optional
#
# Exit 0 on send, on cooldown-suppression, or if no staging worktree is found
# (none of these is an error worth failing the health tick over).

set -u

WT_ROOT="/home/josh/projects/github/CategoricalData/hydra/worktrees"
ATTENTION_DIR="$HOME/.cache/claude-attention"
COOLDOWN_STAMP="/home/josh/watchdog/logs/.last-staging-alert"
COOLDOWN_SECS=900   # 15 min — one alert per window, no matter how long it squeezes

reason="${1:-unspecified}"
summary="${2:-memory pressure detected}"
offender="${3:-}"

now_epoch=$(date -u +%s)
ts_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
ts_file=$(date -u +'%Y-%m-%dT%H-%M-%SZ')   # colons→dashes for portable filenames

# --- resolve the staging worktree by glob (name starts with "staging") ---
# If several match, prefer one whose inbox already exists; else the first.
staging_dir=""
for d in "$WT_ROOT"/staging*/; do
  [ -d "$d" ] || continue
  if [ -d "${d}claude-hydra-messages/inbox" ]; then staging_dir="$d"; break; fi
  [ -z "$staging_dir" ] && staging_dir="$d"
done
if [ -z "$staging_dir" ]; then
  # No staging worktree on this machine right now. Still record an attention
  # marker so the danger is not lost, then exit cleanly.
  mkdir -p "$ATTENTION_DIR"
  {
    echo "watchdog: alpha memory pressure — freeze risk (${reason})"
    echo "$summary"
    [ -n "$offender" ] && echo "offender: $offender"
    echo "at ${ts_iso}; NO staging worktree found under ${WT_ROOT} — message not delivered"
  } > "$ATTENTION_DIR/watchdog-alpha-memory-pressure.txt"
  exit 0
fi
staging_inbox="${staging_dir}claude-hydra-messages/inbox"
staging_name=$(basename "$staging_dir")

# --- de-bounce: skip if we alerted within the cooldown window ---
if [ -f "$COOLDOWN_STAMP" ]; then
  last=$(cat "$COOLDOWN_STAMP" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now_epoch - last)) -lt "$COOLDOWN_SECS" ]; then
    exit 0   # already warned recently; stay quiet
  fi
fi

fname="${ts_file}-watchdog-alpha-memory-pressure.md"

# --- compose the message (advisory; staging decides the action) ---
msg_body=$(cat <<EOF
# ⚠ alpha memory pressure — freeze risk

**From:** watchdog (script-generated — there is no watchdog agent)
**To:** ${staging_name}
**Date:** ${ts_iso}
**Severity:** urgent — preventive action window

The \`alpha\` health-monitor tripped a danger threshold at ${ts_iso}. This
machine was heading toward the swap-exhaustion / memory-thrash livelock that has
hard-frozen it before (most recently 2026-07-08T20:50Z; see
\`~/watchdog/archive/\`). This is a **warning while there is still headroom to
act**, not a report of a freeze that already happened.

**What tripped:** ${summary}
EOF
)

if [ -n "$offender" ]; then
  msg_body="${msg_body}

**Leading resident-memory offender right now:**
\`\`\`
${offender}
\`\`\`"
fi

msg_body="${msg_body}

**Recommended preventive action (your call):** the confirmed cause of the prior
freeze was the Haskell build fleet (\`transform-haskell\` + parallel \`ghc\`)
exhausting the 16 GB swap on a 32 GB box, with no OOM kill — the box livelocked.
If build workers are the offender above, consider throttling build parallelism
or pausing a worker until pressure clears. The watchdog does not act on the
machine; this is advisory.

**No reply channel.** The watchdog is a set of scripts with no agent and no
inbox — nothing here reads a response. Act (or not) at your discretion; there
is nobody on the watchdog side to acknowledge. Evidence to check:
\`~/watchdog/logs/health.log\` (tail) and \`~/watchdog/archive/\`.

— watchdog/alert-staging.sh (reason=${reason})
"

# --- deliver: write directly to staging's inbox, then verify it landed ---
mkdir -p "$staging_inbox"
delivered=0
if printf '%s\n' "$msg_body" > "$staging_inbox/$fname" && [ -s "$staging_inbox/$fname" ]; then
  delivered=1
fi

# --- attention-marker: urgent out-of-band channel the user + staging watch ---
mkdir -p "$ATTENTION_DIR"
{
  echo "watchdog: alpha memory pressure — freeze risk (${reason})"
  echo "$summary"
  [ -n "$offender" ] && echo "offender: $offender"
  echo "at ${ts_iso}; message → ${staging_name} inbox (delivered=${delivered})"
  echo "detail: ~/watchdog/logs/health.log tail + ~/watchdog/archive/"
} > "$ATTENTION_DIR/watchdog-alpha-memory-pressure.txt"

# --- record cooldown stamp only once we've actually alerted ---
printf '%s\n' "$now_epoch" > "$COOLDOWN_STAMP"

exit 0
