#!/usr/bin/env bash
# staging-progress-watchdog.sh — detect a STALLED staging agent (not just a dead machine).
#
# The machine liveness heartbeat proves the box is alive; this proves staging is
# making PROGRESS. It fires only on the specific failure signature that cost ~10h
# on 2026-08-05: main has not advanced for a while AND there is landable work
# waiting (a queued build or an undelivered worker->staging handoff in the inbox).
# That distinguishes "legitimately quiet" (nothing to do) from "stalled with work".
#
# Machine-agnostic: pass the staging worktree via $1 (or STAGING_WT env). Runs as a
# loop (systemd service or `nohup ... &`); writes a status file staging keeps an eye
# on, and escalates to the user via the machine's alert channel when the stall
# threshold is crossed.
#
# Signals it emits (all to STATUS_FILE, one line each, plus alert on escalation):
#   OK           — main advancing or no work waiting (healthy)
#   STALL-WARN   — main static > WARN_MIN with work waiting (staging should self-check)
#   STALL-ALERT  — main static > ALERT_MIN with work waiting (escalate to user)
#
# See claude/external-alerts.md § "Staging-progress watchdog" for the protocol.

set -uo pipefail

STAGING_WT="${1:-${STAGING_WT:-}}"
[ -z "$STAGING_WT" ] && { echo "usage: $0 <staging-worktree-path>  (or set STAGING_WT)" >&2; exit 2; }
[ -d "$STAGING_WT/.git" ] || [ -f "$STAGING_WT/.git" ] || { echo "not a worktree: $STAGING_WT" >&2; exit 2; }

INBOX="$STAGING_WT/claude-hydra-messages/inbox"
SLOT_FILE="${SLOT_FILE:-$HOME/.hydra-build-slot}"
STATUS_FILE="${STATUS_FILE:-$HOME/watchdog/logs/staging-progress.status}"
ALERT_CMD="${ALERT_CMD:-$HOME/watchdog/bin/alert-staging.sh}"   # machine's escalation channel
WARN_MIN="${WARN_MIN:-90}"      # main static this long + work waiting -> staging should self-check
ALERT_MIN="${ALERT_MIN:-150}"   # main static this long + work waiting -> escalate to user
POLL_SEC="${POLL_SEC:-300}"

mkdir -p "$(dirname "$STATUS_FILE")"

last_main=""
main_since=$(date +%s)
alerted=0
stall_reads=0                  # consecutive stall readings (debounce)
STALL_CONFIRM="${STALL_CONFIRM:-2}"   # require this many consecutive stall polls before paging

# A heavy build actively running means STAGING IS WORKING — not lapsed. A genuine
# stall is main-static + work-waiting + NO active build. This exclusion prevents the
# false STALL-ALERT that pinged the user on 2026-08-05 while bug_613 was legitimately
# mid-build for hours.
is_build_active() {
  # any GHC/stack/gradle/cold-seed/update-json build process running right now.
  # NOTE: do NOT use `grep -q` here. Under `set -o pipefail`, `grep -q` short-circuits
  # on the first match and closes the pipe, sending SIGPIPE to the upstream `ps | grep -v`,
  # whose non-zero exit then becomes the pipeline's status — making this return FALSE even
  # on a match. This exact bug pinged the user with a false STALL-ALERT while feature_416 was
  # legitimately mid-build for 15+ min on 2026-08-05. Count matches into a var instead; no
  # early pipe close, so pipefail can't corrupt the result.
  local n
  n=$(ps -eo cmd 2>/dev/null | grep -vE 'grep|/bin/bash -c|tail ' \
    | grep -cE 'update-json-main|bootstrap-from-json|cold-seed-from-json|sync-haskell|GradleWorkerMain|ghc-[0-9]|stack .*(build|test)')
  [ "${n:-0}" -gt 0 ]
}

is_work_waiting() {
  # (a) an undelivered worker->staging handoff: an inbox *-to-staging-* / *-from-* file
  #     newer than the last main advance (i.e. arrived while staging was idle).
  # (b) a non-empty build-slot QUEUE (a worker is waiting for the slot / a land).
  local newest_handoff qcount
  newest_handoff=$(ls -t "$INBOX"/*to-staging* "$INBOX"/*from-* 2>/dev/null | head -1)
  if [ -n "$newest_handoff" ] && [ "$(stat -c %Y "$newest_handoff" 2>/dev/null || echo 0)" -gt "$main_since" ]; then
    echo "handoff:$(basename "$newest_handoff")"; return 0
  fi
  qcount=$(grep -ciE '^\s*\[#[0-9]|SLOT-REQ|land ' "$SLOT_FILE" 2>/dev/null || echo 0)
  [ "$qcount" -gt 0 ] && { echo "queue:$qcount"; return 0; }
  return 1
}

while true; do
  git -C "$STAGING_WT" fetch origin main -q 2>/dev/null
  m=$(git -C "$STAGING_WT" rev-parse --short origin/main 2>/dev/null || echo "?")
  now=$(date +%s)

  if [ "$m" != "$last_main" ]; then
    last_main="$m"; main_since="$now"; alerted=0
  fi
  static_min=$(( (now - main_since) / 60 ))

  work=$(is_work_waiting || true)
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  if is_build_active; then
    # Staging is actively building — genuinely working, NOT lapsed, regardless of
    # main-static time. Reset the alert latch AND the stall debounce so a real stall
    # AFTER the build still fires, but a momentary build-gap can't accumulate toward one.
    echo "$ts OK main=$m static=${static_min}m work=[${work:-none}] BUILD-ACTIVE (staging working, not a stall)" > "$STATUS_FILE"
    alerted=0; stall_reads=0
  elif [ -z "$work" ]; then
    echo "$ts OK main=$m static=${static_min}m (no work waiting)" > "$STATUS_FILE"
    stall_reads=0
  elif [ "$static_min" -ge "$ALERT_MIN" ]; then
    # Debounce: a single no-build reading is not enough — a build phase transition
    # (cold-seed -> sync, one exe finishing before the next) briefly shows no matching
    # process. Require STALL_CONFIRM consecutive stall polls before paging the user.
    stall_reads=$(( stall_reads + 1 ))
    if [ "$stall_reads" -lt "$STALL_CONFIRM" ]; then
      echo "$ts STALL-PENDING main=$m static=${static_min}m work=[$work] no-active-build read=$stall_reads/$STALL_CONFIRM (debouncing before page)" > "$STATUS_FILE"
    else
      echo "$ts STALL-ALERT main=$m static=${static_min}m work=[$work] no-active-build ${stall_reads}x — staging likely lapsed, escalating" > "$STATUS_FILE"
      if [ "$alerted" -eq 0 ]; then
        "$ALERT_CMD" "STAGING STALLED ${static_min}m: main $m not advancing, work waiting ($work), NO active build (${stall_reads} consecutive polls). Staging agent likely lapsed — check the session." 2>/dev/null || true
        alerted=1
      fi
    fi
  elif [ "$static_min" -ge "$WARN_MIN" ]; then
    stall_reads=$(( stall_reads + 1 ))
    echo "$ts STALL-WARN main=$m static=${static_min}m work=[$work] no-active-build — staging should self-check + re-drive" > "$STATUS_FILE"
  else
    echo "$ts OK main=$m static=${static_min}m work=[$work] (within threshold)" > "$STATUS_FILE"
  fi

  sleep "$POLL_SEC"
done
