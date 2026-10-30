#!/usr/bin/env bash
# test-quota.sh: synthetic checks of statusline.sh and quota-check.sh (no real
# quota is read: everything runs in a temporary QUOTA_DIR). Exit 0 iff all pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export QUOTA_DIR; QUOTA_DIR="$(mktemp -d)"
trap 'rm -rf "$QUOTA_DIR"' EXIT
fails=0
now() { date +%s; }
reading() {  # reading AT USED RESETS_AT [five_hour_used]
    printf '{"at":%s,"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}\n' \
        "$1" "${4:-10}" "$(( $3 - 3600 ))" "$2" "$3" > "$QUOTA_DIR/rate-limits.json"
}
expect() {  # expect NAME WANT_VERDICT [args...]
    local name="$1" want="$2"; shift 2
    local got; got="$("$HERE/quota-check.sh" --json "$@" | jq -r .verdict)"
    if [ "$got" = "$want" ]; then echo "ok   $name ($got)"; else echo "FAIL $name: want $want, got $got"; fails=$((fails + 1)); fi
}

T=$(now); RESET=$(( T + 10 * 3600 ))
"$HERE/quota-check.sh" > /dev/null; [ $? -eq 3 ] && echo "ok   no reading: exit 3" || { echo "FAIL no reading"; fails=$((fails + 1)); }

# the status line records the reading
echo "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":60,\"resets_at\":$RESET}}}" | "$HERE/statusline.sh" | grep -q '7d:60%' \
    && echo "ok   statusline prints and records" || { echo "FAIL statusline"; fails=$((fails + 1)); }

reading $(( T - 1800 )) 60 $RESET
expect "one reading: no burn yet" hold
reading "$T" 61 $RESET                        # 2 points/h; 61 + 2 x 10 h = 81 < 90
expect "projected under the target" go
reading "$T" 58 $RESET                        # another account, same reset
r="$("$HERE/quota-check.sh" --json)"
[ "$(printf '%s' "$r" | jq -r .skipped)" != null ] && [ "$(printf '%s' "$r" | jq -r .used)" = 61 ] \
    && echo "ok   a lower reading is skipped" || { echo "FAIL lower reading: $r"; fails=$((fails + 1)); }
expect "two fleets ease earlier: ease at 90 - 2 x 3 = 84" go --fleets 2
reading "$T" 85 $RESET
expect "two fleets: ease at 84" ease --fleets 2
expect "one fleet: 85 is under the ease point 87, but the burn overshoots" hold
reading "$T" 88 $RESET
expect "within the margin of the limit" ease
expect "a raised target and limit: room again" hold --target 95 --limit 97
echo 95 > "$QUOTA_DIR/target"; echo 97 > "$QUOTA_DIR/limit"
r="$("$HERE/quota-check.sh" --json)"
[ "$(printf '%s' "$r" | jq -r '.target, .limit' | tr '\n' ' ')" = "95 97 " ] \
    && echo "ok   the target and limit files apply to every fleet" || { echo "FAIL files: $r"; fails=$((fails + 1)); }
rm -f "$QUOTA_DIR/target" "$QUOTA_DIR/limit"
reading "$T" 90 $RESET
expect "the limit" stop
[ -f "$QUOTA_DIR/STOP" ] && echo "ok   STOP written" || { echo "FAIL STOP not written"; fails=$((fails + 1)); }
reading "$T" 2 $(( RESET + 7 * 86400 ))     # the week rolled over
expect "new window" hold
[ ! -f "$QUOTA_DIR/STOP" ] && echo "ok   STOP removed in the new window" || { echo "FAIL STOP kept"; fails=$((fails + 1)); }
reading "$T" 50 $(( T + 1800 ))             # an older window: another account
r="$("$HERE/quota-check.sh" --json)"
[ "$(printf '%s' "$r" | jq -r .skipped)" != null ] && echo "ok   an older window is skipped" || { echo "FAIL older window: $r"; fails=$((fails + 1)); }
printf '{"at":%s,"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":%s}}}\n' "$T" "$(( T + 3600 ))" > "$QUOTA_DIR/rate-limits.json"
expect "no weekly reading after the rollover" hold
rm -f "$QUOTA_DIR/state.json"; reading $(( T - 1800 )) 70 $(( T + 1800 )); "$HERE/quota-check.sh" > /dev/null; reading "$T" 71 $(( T + 1800 ))
expect "half an hour before the reset" ease

echo; [ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $fails
