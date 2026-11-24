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
        HA_AGENTS_DIR=/agents HA_LIST_AGENTS="${LIST:-ask}" \
        HA_GUARDED="$( { [ "$2" = true ] || [ "$3" = true ]; } && echo true || echo false)" \
        ha_runner_prepare_worktree "$w" "${4:-staging}" 2>/dev/null
    printf '%s' "$w/.claude/settings.local.json"
}
HOOK_OK='[.hooks.PreToolUse[] | select(.matcher == "SendMessage|ListAgents") | .hooks[].command] == ["\"/agents/bin/claude-hooks/peer-scope.sh\""]'
NO_ASK='((.permissions.ask // []) | index("SendMessage")) == null'
NO_LIST_DENY='((.permissions.deny // []) | index("ListAgents")) == null'

f="$(prep open-public false false)"
check "public, open: peer-scope hook" "$f" "$HOOK_OK"
check "public, open: ListAgents left to the hook (asks)" "$f" "$NO_LIST_DENY"
check "public, open: no messaging guard" "$f" "(.isolatePeerMachines // false) == false and $NO_ASK"

f="$(LIST=deny prep open-public-deny false false)"
check "listAgents deny: ListAgents denied" "$f" '.permissions.deny | index("ListAgents")'

f="$(prep sens-public-staging false true staging)"
check "public staging, sensitive: cross-machine sends gated (no exemption)" "$f" '.isolatePeerMachines == true'
check "public staging, sensitive: same-machine sends not gated" "$f" "$NO_ASK"
check "public staging, sensitive: inbound key left to the launch flag" "$f" 'has("crossSessionInbound") | not'
check "public staging, sensitive: filesystem denies" "$f" '.permissions.deny | index("Read(~/.ssh/**)")'

f="$(prep open-private true false)"
check "private, open: same-project sends don't ask (hook scopes them)" "$f" "$NO_ASK and $HOOK_OK"
check "private, open: cross-machine sends gated" "$f" '.isolatePeerMachines == true'
check "private, open: no filesystem denies" "$f" '(.permissions.deny | index("Read(~/.ssh/**)")) == null'

# Migration: a worktree prepared by the earlier version (every send asks, ListAgents
# denied, an older peer-scope hook) is brought to the new shape; other hooks stay.
w="$(wt migrate)"; mkdir -p "$w/.claude"
printf '%s\n' '{"permissions":{"ask":["SendMessage"],"deny":["ListAgents","Edit(~/.ssh)"]},"hooks":{"PreToolUse":[{"matcher":"SendMessage|ListAgents","hooks":[{"type":"command","command":"python3 old/peer-scope.py"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"keep.sh"}]}]}}' > "$w/.claude/settings.local.json"
HA_PRIVATE=true HA_SENSITIVE=false HA_GUARDED=true HA_INBOUND=accept HA_AGENTS_DIR=/agents \
    ha_runner_prepare_worktree "$w" staging 2>/dev/null
f="$w/.claude/settings.local.json"
check "migration: old ask and ListAgents deny removed" "$f" "$NO_ASK and $NO_LIST_DENY"
check "migration: old peer-scope hook replaced, other hooks kept" "$f" \
    "$HOOK_OK and ([.hooks.PreToolUse[].hooks[].command] | index(\"keep.sh\")) and (.permissions.deny | index(\"Edit(~/.ssh)\"))"
HA_PRIVATE=true HA_SENSITIVE=false HA_GUARDED=true HA_INBOUND=accept HA_AGENTS_DIR=/agents \
    ha_runner_prepare_worktree "$w" staging 2>/dev/null
check "migration: idempotent (one peer-scope entry)" "$f" \
    '[.hooks.PreToolUse[] | select(.matcher == "SendMessage|ListAgents")] | length == 1'

w="$(wt guard)"
printf '{"agentsDir": "../../external/agents"}\n' > "$TMP/guard-config.json"
export HA_CONFIG_FILE="$TMP/guard-config.json"
HA_INBOUND=accept ha_runner_write_project_guard "$w"
git -C "$w" add .claude/settings.json
if ha_runner_check_project_guard "$w" >/dev/null; then echo "ok   checked-in guard verifies"; else echo "FAIL checked-in guard: $(ha_runner_check_project_guard "$w")"; fails=$((fails + 1)); fi
check "checked-in guard: hook (relative to the worktree), isolate, no ask, no inbound key" "$w/.claude/settings.json" \
    '([.hooks.PreToolUse[].hooks[].command] == ["\"$CLAUDE_PROJECT_DIR\"/../../external/agents/bin/claude-hooks/peer-scope.sh"]) and .isolatePeerMachines == true and ((.permissions.ask // []) | index("SendMessage")) == null and (has("crossSessionInbound") | not)'
printf '{"crossSessionInbound":"hold","isolatePeerMachines":true,"permissions":{"ask":["SendMessage"],"deny":["ListAgents"]}}\n' > "$w/.claude/settings.json"
ha_runner_check_project_guard "$w" | grep -q 'stale: permissions.ask' \
    && echo "ok   check reports the earlier guard's SendMessage ask as stale" || { echo "FAIL stale ask not reported"; fails=$((fails + 1)); }
HA_INBOUND=accept ha_runner_write_project_guard "$w"
check "rewriting an earlier guard drops its hold, ask and ListAgents deny, adds the hook" "$w/.claude/settings.json" \
    '(has("crossSessionInbound") | not) and ((.permissions.ask // []) | index("SendMessage")) == null and ((.permissions.deny // []) | index("ListAgents")) == null and ([.hooks.PreToolUse[].hooks[].command | select(test("peer-scope"))] | length == 1)'
HA_INBOUND=refuse ha_runner_write_project_guard "$w"
check "a stricter privateInbound is checked in" "$w/.claude/settings.json" '.crossSessionInbound == "refuse"'
printf '{"isolatePeerMachines":true}\n' > "$w/.claude/settings.json"
ha_runner_check_project_guard "$w" | grep -q 'peer-scope' \
    && echo "ok   check reports a missing peer-scope hook" || { echo "FAIL missing hook not reported"; fails=$((fails + 1)); }
unset HA_CONFIG_FILE

c="$(HA_GUARDED=true HA_INBOUND=accept ha_runner_launch_cmd s1 opus)"
[ "$c" = "claude-remote s1 -m opus -n s1 --settings '{\"crossSessionInbound\":\"accept\"}'" ] \
    && echo "ok   guarded launch accepts inbound at launch" || { echo "FAIL guarded launch: $c"; fails=$((fails + 1)); }
c="$(HA_GUARDED=false ha_runner_launch_cmd s1 opus --resume)"
[ "$c" = "claude-remote s1 -m opus -n s1 --continue" ] \
    && echo "ok   unguarded launch has no inbound flag" || { echo "FAIL unguarded launch: $c"; fails=$((fails + 1)); }

c="$(HA_GUARDED=false ha_runner_launch_cmd proj-staging-host1 opus --resume)"
[ "$c" = "claude-remote proj-staging-host1 -m opus -n proj-staging-host1 --settings '{\"crossSessionInbound\":\"accept\"}' --continue" ] \
    && echo "ok   unguarded staging launch still accepts inbound" || { echo "FAIL unguarded staging launch: $c"; fails=$((fails + 1)); }

echo; [ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $fails
