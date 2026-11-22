#!/usr/bin/env bash
# test-claude-code.sh: synthetic checks of the Claude Code adapter's isolation
# settings (docs/cross-worktree-messages.md § Project isolation). Everything runs
# in temporary git repos; no real settings are read or written. Exit 0 iff all pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
. "$HERE/claude-code.sh"
fails=0
check() {  # check NAME FILE JQ-EXPR
    if jq -e "$3" "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1: $3 on $(cat "$2" 2>/dev/null)"; fails=$((fails + 1)); fi
}
wt() {  # wt NAME: a fresh worktree-like git repo
    git init -q "$TMP/$1" && printf '%s' "$TMP/$1"
}
prep() {  # prep NAME PRIVATE SENSITIVE [branch]
    local w; w="$(wt "$1")"
    HA_PRIVATE="$2" HA_SENSITIVE="$3" HA_INBOUND=accept HA_STAGING_PEERS="peer-a peer-b" \
        HA_GUARDED="$( { [ "$2" = true ] || [ "$3" = true ]; } && echo true || echo false)" \
        ha_runner_prepare_worktree "$w" "${4:-staging}" 2>/dev/null
    printf '%s' "$w/.claude/settings.local.json"
}

f="$(prep open-public false false)"
check "public, open: ListAgents denied" "$f" '.permissions.deny | index("ListAgents")'
check "public, open: no messaging guard" "$f" '(.isolatePeerMachines // false) == false and (.permissions.ask // []) == []'

f="$(prep sens-public-staging false true staging)"
check "public staging, sensitive: cross-machine sends gated (no exemption)" "$f" '.isolatePeerMachines == true'
check "public staging, sensitive: same-machine sends not gated" "$f" '((.permissions.ask // []) | index("SendMessage")) == null'
check "public staging, sensitive: inbound key left to the launch flag" "$f" 'has("crossSessionInbound") | not'
check "public staging, sensitive: filesystem denies" "$f" '.permissions.deny | index("Read(~/.ssh/**)")'

f="$(prep open-private true false)"
check "private, open: every send asks" "$f" '.permissions.ask | index("SendMessage")'
check "private, open: cross-machine sends gated" "$f" '.isolatePeerMachines == true'
check "private, open: no filesystem denies" "$f" '(.permissions.deny | index("Read(~/.ssh/**)")) == null'

w="$(wt guard)"
HA_INBOUND=accept ha_runner_write_project_guard "$w"
git -C "$w" add .claude/settings.json
if ha_runner_check_project_guard "$w" >/dev/null; then echo "ok   checked-in guard verifies"; else echo "FAIL checked-in guard: $(ha_runner_check_project_guard "$w")"; fails=$((fails + 1)); fi
check "checked-in guard: ask, isolate, no inbound key" "$w/.claude/settings.json" \
    '(.permissions.ask | index("SendMessage")) and .isolatePeerMachines == true and (has("crossSessionInbound") | not)'
printf '{"crossSessionInbound":"hold","isolatePeerMachines":true,"permissions":{"deny":["ListAgents"]}}\n' > "$w/.claude/settings.json"
HA_INBOUND=accept ha_runner_write_project_guard "$w"
check "rewriting an old guard drops its hold and adds the ask" "$w/.claude/settings.json" \
    '(has("crossSessionInbound") | not) and (.permissions.ask | index("SendMessage"))'
HA_INBOUND=refuse ha_runner_write_project_guard "$w"
check "a stricter privateInbound is checked in" "$w/.claude/settings.json" '.crossSessionInbound == "refuse"'
printf '{"isolatePeerMachines":true,"permissions":{"deny":["ListAgents"]}}\n' > "$w/.claude/settings.json"
ha_runner_check_project_guard "$w" | grep -q 'SendMessage' \
    && echo "ok   check reports a missing SendMessage ask" || { echo "FAIL missing ask not reported"; fails=$((fails + 1)); }

c="$(HA_GUARDED=true HA_INBOUND=accept ha_runner_launch_cmd s1 opus)"
[ "$c" = "claude-remote s1 -m opus -n s1 --settings '{\"crossSessionInbound\":\"accept\"}'" ] \
    && echo "ok   guarded launch accepts inbound at launch" || { echo "FAIL guarded launch: $c"; fails=$((fails + 1)); }
c="$(HA_GUARDED=false ha_runner_launch_cmd s1 opus --resume)"
[ "$c" = "claude-remote s1 -m opus -n s1 --continue" ] \
    && echo "ok   unguarded launch has no inbound flag" || { echo "FAIL unguarded launch: $c"; fails=$((fails + 1)); }

echo; [ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $fails
