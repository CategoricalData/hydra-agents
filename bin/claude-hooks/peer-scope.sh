#!/usr/bin/env bash
# PreToolUse hook (matcher "SendMessage|ListAgents"): scope cross-session messaging
# and discovery by project (docs/cross-worktree-messages.md § Project isolation).
#
#   SendMessage to one of this project's own sessions  -> allow (no prompt)
#   SendMessage to any other recipient                 -> ask the human
#   ListAgents (lists every session on the account)    -> ask (listAgents: "ask",
#                                                         the default) or deny
#
# "This project's own sessions" are computed, never discovered: the session name
# (bin/lib-config.sh ha_session_name_for) of every worktree of the project
# (`git worktree list`), by its folder and by its branch (recovery names a session
# after its folder, spawn after its branch; they are usually the same), plus the
# configured stagingPeers. A project
# learns about another project's agents only when it is told, and a send to one
# needs the human's approval; it isn't blocked.
#
# Also allowed without a prompt: an in-session subagent addressed by its agent id
# ("a" followed by 16 hex digits). SendMessage is also how a session continues its
# own subagents, which are not sessions of any project.
#
# An ask rule for SendMessage in any settings file outranks this hook's "allow"
# (Claude Code permissions docs), so the runner adapter and project-guard remove the
# old "every send asks" rule. Output: the PreToolUse JSON decision on stdout; any
# failure to load the config falls back to "ask".

set -uo pipefail

decide() {
    jq -cn --arg d "$1" --arg r "$2" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
    exit 0
}

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)"
case "$tool" in
    SendMessage|ListAgents) ;;
    *) exit 0 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/lib-config.sh"
# No network from a hook: if the config doesn't declare visibility, don't ask gh
# (visibility doesn't affect scoping; the cache just stops ha_load_config's lookup).
start="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cfg="$(ha_find_config "$start" 2>/dev/null || true)"
[ -n "$cfg" ] && export HA_VISIBILITY_CACHE="$cfg=private"
if ! ha_load_config >/dev/null 2>&1; then
    decide ask "No hydra-agents config found, so the recipient's project can't be checked."
fi

if [ "$tool" = ListAgents ]; then
    if [ "${HA_LIST_AGENTS:-ask}" = deny ]; then
        decide deny "Listing sessions is denied in this project (listAgents: deny)."
    fi
    decide ask "Listing sessions shows every project on the account; discovery outside this project needs the human's approval."
fi

to="$(jq -r '.tool_input.to // .tool_input.recipient // .tool_input.target // empty' <<<"$input" 2>/dev/null)"
[ -n "$to" ] || decide ask "SendMessage with no recognizable recipient field."

if [[ "$to" =~ ^a[0-9a-f]{16}$ ]]; then
    decide allow "$to is an in-session subagent."
fi

for peer in ${HA_STAGING_PEERS:-}; do
    [ "$to" = "$peer" ] && decide allow "$to is one of this project's staging peers."
done

# Every worktree of this project, by folder and by branch, from one git call.
names="$(git -C "$HA_PROJECT_ROOT" worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { sub(/^worktree /, ""); n = split($0, a, "/"); print a[n] }
    /^branch refs\/heads\// { sub(/^branch refs\/heads\//, ""); print }' | sort -u)"

if [ "${HA_OPAQUE_NAMES:-false}" != true ]; then
    # Readable names: strip the prefix (and a standardized branch's machine suffix)
    # and look the rest up, without hashing anything.
    case "$to" in "$HA_SESSION_PREFIX"*) ;; *) names="" ;; esac
    want="${to#"$HA_SESSION_PREFIX"}"
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        if [ "$want" = "$n" ] || { ha_is_standardized_branch "$n" && [ "$want" = "$n-$HA_MACHINE" ]; }; then
            [ "$to" = "$(ha_session_name_for "$n")" ] && decide allow "$to is this project's session for $n."
        fi
    done <<<"$names"
else
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ "$to" = "$(ha_session_name_for "$n")" ] && decide allow "$to is this project's session for $n."
    done <<<"$names"
fi

decide ask "$to is not a session of this project: a send outside the project needs the human's approval."
