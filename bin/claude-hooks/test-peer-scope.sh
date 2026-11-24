#!/usr/bin/env bash
# test-peer-scope.sh: synthetic checks of the peer-scope hook (scoped messaging,
# docs/cross-worktree-messages.md § Project isolation). Builds a throwaway project
# with three worktrees (one whose folder and branch differ); no real settings or
# sessions are touched. Exit 0 iff all pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/peer-scope.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
host="$(hostname -s 2>/dev/null || echo unknown)"

# A project "acme/proj": main checkout plus worktrees staging, feature_1, and a
# folder "renamed" on branch docs_x.
git init -q -b main "$TMP/proj.git" && git -C "$TMP/proj.git" commit -q --allow-empty -m init
mkdir -p "$TMP/worktrees"
git -C "$TMP/proj.git" worktree add -q -b staging "$TMP/worktrees/staging"
git -C "$TMP/proj.git" worktree add -q -b feature_1 "$TMP/worktrees/feature_1"
git -C "$TMP/proj.git" worktree add -q -b docs_x "$TMP/worktrees/renamed"
for w in staging feature_1 renamed; do
    printf '{"issueRepo":"acme/proj","issueUrlBase":"https://example.invalid/","agentGuide":"CLAUDE.md","spawnModel":"opus","visibility":"private","stagingPeers":["proj-staging-otherhost"]}\n' \
        > "$TMP/worktrees/$w/hydra-agents.json"
done

run() {  # run TOOL TO [extra-config-jq]: print the decision, from feature_1
    local cfg="$TMP/worktrees/feature_1/hydra-agents.json"
    if [ -n "${3:-}" ]; then jq "$3" "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"; fi
    jq -cn --arg t "$1" --arg to "$2" '{tool_name: $t, tool_input: {to: $to, message: "x"}}' \
        | CLAUDE_PROJECT_DIR="$TMP/worktrees/feature_1" HA_VISIBILITY_CACHE= "$HOOK" \
        | jq -r '.hookSpecificOutput.permissionDecision // "none"' | grep . || echo none
}
expect() {  # expect NAME WANT GOT
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; fails=$((fails + 1)); fi
}

expect "own worktree by folder"                 allow "$(run SendMessage proj-feature_1)"
expect "own worktree, folder differs (folder)"  allow "$(run SendMessage proj-renamed)"
expect "own worktree, folder differs (branch)"  allow "$(run SendMessage proj-docs_x)"
expect "own staging (machine-qualified)"        allow "$(run SendMessage "proj-staging-$host")"
expect "own worktree with a [ref] suffix"        allow "$(run SendMessage "proj-feature_1 [38865b]")"
expect "own staging with a [ref] suffix"         allow "$(run SendMessage "proj-staging-$host [2c5f78]")"
expect "foreign name with a [ref] suffix"        ask   "$(run SendMessage "other-thing [abc123]")"
expect "listed staging peer"                    allow "$(run SendMessage proj-staging-otherhost)"
expect "in-session subagent id"                 allow "$(run SendMessage a0123456789abcdef)"
expect "another project's session asks"         ask   "$(run SendMessage other-staging-"$host")"
expect "same prefix, no such worktree asks"     ask   "$(run SendMessage proj-feature_999)"
expect "unqualified staging asks"               ask   "$(run SendMessage proj-staging)"
expect "ListAgents asks"                        ask   "$(run ListAgents '')"
expect "other tools: no decision"               none  "$(run Read '')"
out="$(jq -cn '{tool_name: "SendMessage", tool_input: {message: "x"}}' \
    | CLAUDE_PROJECT_DIR="$TMP/worktrees/feature_1" "$HOOK" | jq -r .hookSpecificOutput.permissionDecision)"
expect "no recipient field asks"                ask   "$out"
expect "listAgents deny"                        deny  "$(run ListAgents '' '.listAgents = "deny"')"

# Opaque names (opt-in): the p-<hash> names are allowed, readable ones are not.
run SendMessage x '.opaqueNames = true | .listAgents = "ask"' >/dev/null
opaque="$(cd "$TMP/worktrees/feature_1" && CLAUDE_PROJECT_DIR="$TMP/worktrees/feature_1" HA_VISIBILITY_CACHE= \
    "$HERE/../session-name" renamed)"
expect "opaque: computed name is p-<hash>"      p-    "${opaque:0:2}"
expect "opaque: own worktree allowed"           allow "$(run SendMessage "$opaque")"
expect "opaque: readable name asks"             ask   "$(run SendMessage proj-renamed)"
resolved="$(cd "$TMP/worktrees/feature_1" && CLAUDE_PROJECT_DIR="$TMP/worktrees/feature_1" "$HERE/../session-name" --resolve "$opaque")"
expect "opaque: --resolve gives the folder"     renamed "$resolved"

echo; [ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $fails
