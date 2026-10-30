#!/usr/bin/env bash
# quota-check.sh: should the fleet launch spare-quota work now? See docs/quota-pacing.md.
#
#   quota-check.sh [--target 90] [--limit TARGET] [--margin 3] [--fleets 1] [--ease-hours 1]
#                  [--burn-window 60] [--stale 15] [--json]
#                  [--watch SECONDS [--heartbeat SECONDS]]
#
# Reads $QUOTA_DIR/rate-limits.json (written by statusline.sh) and prints one
# verdict about EXTRA work (spare-quota passes, optional jobs), never about the
# work a fleet was asked to do:
#
#   go     the weekly use projected at the reset (current use + recent burn x
#          hours left) is below --target: launch one or two more workers.
#   hold   on pace or ahead, or not enough readings yet: launch nothing extra.
#   ease   use is within margin x fleets of --limit, or the reset is less than
#          --ease-hours away: launch nothing new; let running work finish.
#   stop   --limit is reached: STOP is written; launch nothing, wind down.
#
# --target is where to arrive at the reset (default 90, a good unattended
# overnight goal). --limit is the hard stop (default: the target). Without the
# flags, both come from the files QUOTA_DIR/target and QUOTA_DIR/limit when
# they exist, so a user who wakes to spare quota can raise them for every fleet
# on the machine at once: echo 95 > target; echo 97 > limit. The fleets adapt
# to the user's own load too, because the burn they see is the account's total.
# --fleets is the number of independent fleets (projects or machines) drawing
# on the same account: running work keeps burning after a fleet eases off, and
# N fleets keep N times as much burning, so the ease margin scales with it.
# The reset time comes from the reading (resets_at), never from a fixed clock.
#
# Readings are per account and identical on every machine. Every fleet sees
# the same total, including the other fleets' burn, and stop is a pure
# function of it, so fleets need no messages to stop together. Use the same
# --limit everywhere.
#
# Filters: a reading whose seven_day.resets_at is older than the window seen is
# skipped, and so is one below the highest use seen in the window (weekly use
# does not fall before the reset). Either way the reading probably came from
# another account's session. A later resets_at starts a new window: the state
# is reset and STOP is removed.
#
# --watch SECONDS re-checks every SECONDS and exits when the verdict changes,
# or after --heartbeat SECONDS (default 1800) even if it did not: a fleet that
# stays at `go` must keep launching, and an unchanged verdict would otherwise
# never wake it. Run it as a background job, so its exit wakes an idle
# coordinator, and re-arm it first thing on every wake.
#
# Exit status: 0 go, 10 hold, 11 ease, 12 stop, 3 no reading. Requires jq.

set -u
QUOTA_DIR="${QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage}"
TARGET=""; LIMIT=""; MARGIN=3; FLEETS=1; EASE_HOURS=1; BURN_WINDOW=60; STALE=15; JSON=false; WATCH=""; HEARTBEAT=1800
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --margin) MARGIN="$2"; shift 2 ;;
        --fleets) FLEETS="$2"; shift 2 ;;
        --ease-hours) EASE_HOURS="$2"; shift 2 ;;
        --burn-window) BURN_WINDOW="$2"; shift 2 ;;
        --stale) STALE="$2"; shift 2 ;;
        --json) JSON=true; shift ;;
        --watch) WATCH="$2"; shift 2 ;;
        --heartbeat) HEARTBEAT="$2"; shift 2 ;;
        -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "quota-check: unknown option $1" >&2; exit 2 ;;
    esac
done
# The account's target and limit, when not given: the files QUOTA_DIR/target
# and QUOTA_DIR/limit (one number each), so the user can raise them for every
# fleet at once (echo 95 > target), else 90 and the target.
num_file() { [ -f "$1" ] && tr -cd '0-9.' < "$1" | grep -E '^[0-9]+(\.[0-9]+)?$' || true; }
TARGET="${TARGET:-$(num_file "$QUOTA_DIR/target")}"; TARGET="${TARGET:-90}"
LIMIT="${LIMIT:-$(num_file "$QUOTA_DIR/limit")}"; LIMIT="${LIMIT:-$TARGET}"
F="$QUOTA_DIR/rate-limits.json"; STATE="$QUOTA_DIR/state.json"; STOP="$QUOTA_DIR/STOP"

check() {
    [ -f "$F" ] || { echo '{"verdict":"none","reason":"no reading yet: is statusline.sh installed, and is a session running?"}'; return; }
    local now; now="$(date +%s)"
    [ -f "$STATE" ] || echo '{}' > "$STATE"
    # One jq program: filter the reading, update the state, decide.
    local out
    out="$(jq -n --slurpfile r "$F" --slurpfile s "$STATE" \
        --argjson now "$now" --argjson target "$TARGET" --argjson limit "$LIMIT" --argjson margin "$MARGIN" \
        --argjson fleets "$FLEETS" --argjson easeh "$EASE_HOURS" \
        --argjson win "$BURN_WINDOW" --argjson stale "$STALE" '
      ($r[0]) as $r | ($s[0]) as $s
      | ($r.rate_limits.seven_day // null) as $w
      | ($limit - $margin * $fleets) as $ease
      | if $w == null or ($w.used_percentage // null) == null then
          {verdict: "hold", reason: "no weekly reading (the week may just have rolled over)", state: $s}
        else
          ($w.used_percentage) as $u | ($w.resets_at) as $ra
          | (if ($s.resetsAt // 0) < $ra then {resetsAt: $ra, max: 0, samples: [], newWindow: true} else $s end) as $st
          | if $ra < ($st.resetsAt) then {skip: "an older window (another account?)", st: $st}
            elif $u < ($st.max // 0) then {skip: "below the high of \($st.max) (another account?)", st: $st}
            else {st: ($st | .max = $u
                           | .samples = ([.samples[] | select(.[0] >= $now - 10800)] + [[$r.at, $u]]))} end
          | . as $f | $f.st as $st
          | ([$st.samples[] | select(.[0] >= $now - $win * 60)]) as $recent
          | (if ($recent | length) >= 2 and (($recent[-1][0] - $recent[0][0]) >= 900)
             then (($recent[-1][1] - $recent[0][1]) / (($recent[-1][0] - $recent[0][0]) / 3600))
             else null end) as $burn
          | ($st.max) as $used
          | (($ra - $now) / 3600) as $hleft
          | (if $burn == null then null else $used + $burn * ([$hleft, 0] | max) end) as $proj
          | {used: $used, target: $target, easeAt: $ease, limit: $limit, hoursLeft: ($hleft * 10 | floor / 10),
             burnPerHour: (if $burn == null then null else ($burn * 10 | floor / 10) end),
             projectedAtReset: (if $proj == null then null else ($proj * 10 | floor / 10) end),
             paceNeeded: (if $hleft > 0 then (($target - $used) / $hleft * 10 | floor / 10) else null end),
             stale: (($now - $r.at) > $stale * 60), skipped: ($f.skip // null),
             newWindow: ($st.newWindow // false), state: ($st | del(.newWindow))}
          | .verdict = (if $used >= $limit then "stop"
                        elif $used >= $ease or $hleft <= $easeh then "ease"
                        elif $proj == null then "hold"
                        elif $proj < $target then "go" else "hold" end)
          | .reason = ({stop: "limit reached", ease: "within the margin of the limit, or near the reset",
                        go: "projected below the target: room for extra work",
                        hold: (if $proj == null then "not enough readings for a burn rate yet" else "on pace or ahead" end)}[.verdict])
        end')" || { echo '{"verdict":"none","reason":"could not read the files"}'; return; }
    local tmp="$STATE.$$"
    printf '%s' "$out" | jq '.state' > "$tmp" && mv -f "$tmp" "$STATE"
    if [ "$(printf '%s' "$out" | jq -r '.newWindow // false')" = true ]; then rm -f "$STOP"; fi
    if [ "$(printf '%s' "$out" | jq -r '.verdict')" = stop ] && [ ! -f "$STOP" ]; then
        printf '%s weekly use %s%% >= limit %s%%: launch nothing; wind down\n' \
            "$(date '+%F %T')" "$(printf '%s' "$out" | jq -r '.used')" "$LIMIT" > "$STOP"
    fi
    printf '%s' "$out" | jq -c 'del(.state, .newWindow)'
}

report() {
    if $JSON; then printf '%s\n' "$1"; else
        printf '%s' "$1" | jq -r '"\(.verdict): \(.reason)" + (if .used != null then
            " | 7d \(.used)% target \(.target)% ease at \(.easeAt)% limit \(.limit)%, \(.hoursLeft) h left, burn \(.burnPerHour // "?")/h, projected \(.projectedAtReset // "?")%"
            + (if .stale then " [stale reading]" else "" end) + (if .skipped then " [skipped: \(.skipped)]" else "" end) else "" end)'
    fi
}

code() { case "$1" in go) echo 0 ;; hold) echo 10 ;; ease) echo 11 ;; stop) echo 12 ;; *) echo 3 ;; esac; }

r="$(check)"; v0="$(printf '%s' "$r" | jq -r .verdict)"
if [ -n "$WATCH" ]; then
    started="$(date +%s)"
    while :; do
        sleep "$WATCH"
        r="$(check)"; v="$(printf '%s' "$r" | jq -r .verdict)"
        [ "$v" != "$v0" ] && break
        [ $(( $(date +%s) - started )) -ge "$HEARTBEAT" ] && break
    done
    v0="$v"
fi
report "$r"
exit "$(code "$v0")"
