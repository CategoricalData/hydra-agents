#!/usr/bin/env bash
# Spawn a worktree + tmux session + agent for a specific GitHub issue.
#
# Per-project configuration comes from the consuming project's hydra-agents.json
# (see config/examples/hydra-agents.json and bin/lib-config.sh): the issue-tracker
# URL base, the agent-context guide filename, and the default spawn model. The
# script errors if no hydra-agents.json is found for the current project.
#
# Usage:
#   COORDINATOR=<coord-worktree> bin/spawn-issue-worktree.sh <issue-number> <slug> [<issue-title>] [--force-respawn]
# Example:
#   COORDINATOR=staging bin/spawn-issue-worktree.sh 425 clojure_json_decode "Clojure host's JSON decoder rejects kernel JSON"
#   COORDINATOR=release_508 TYPE=task PARENT=508 \
#     bin/spawn-issue-worktree.sh 557 worker_hierarchy "Establish a principled agent + issue hierarchy"
#
# $COORDINATOR names the worktree whose inbox the new agent will address —
# the entity that owns the ready-to-stage / question-answering relationship.
# It varies per machine and per epoch (which session is currently coordinating);
# there is no sensible hardcoded default, so the operator must set it.
#
# $TYPE selects the branch prefix so the branch name carries the issue type,
# mirroring the issue tree (see docs/agent-hierarchy.md). One of
# bug|feature|task|release; default bug. The branch, worktree, and tmux session
# are all named ${TYPE}_${NUM}_${SLUG}.
#
# $PARENT is the parent issue number this agent's issue is a child of. It is
# recorded in the seeded briefing so the agent/coordinator relationship is
# derivable from the issue parent (every non-release issue should declare one;
# see the mandatory-parent rule in docs/agent-hierarchy.md). Optional but
# strongly recommended for non-release agents; omit for a release_* root.
#
# $SPAWN_MODEL overrides the config's default model. The per-class model policy
# lives in docs/agent-hierarchy.md.
#
# Refuses to spawn if worktrees/closed/ already contains a plan-doc for this
# issue (a prior agent addressed it). Override with --force-respawn.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-config.sh"
ha_load_config   # errors out (exit 4/5) with guidance if no hydra-agents.json

if [ -z "${COORDINATOR:-}" ]; then
    echo "error: \$COORDINATOR must be set (name the coordinator worktree, e.g. COORDINATOR=staging)" >&2
    echo "       See the file header for context — coordinator identity varies per machine and per epoch." >&2
    exit 2
fi

if [ $# -lt 2 ]; then
    echo "usage: COORDINATOR=<coord-worktree> [TYPE=bug|feature|task|release] [PARENT=<n>] [SPAWN_MODEL=<m>] \\" >&2
    echo "       $0 <issue-number> <slug> [<title>] [--force-respawn]" >&2
    exit 2
fi

NUM="$1"
SLUG="$2"
TITLE="${3:-(issue title not given — fetch with: gh issue view $NUM)}"

# Config-derived, with env override for the model.
GUIDE="$HA_AGENT_GUIDE"                       # e.g. CLAUDE.md
ISSUE_URL="${HA_ISSUE_URL_BASE%/}/${NUM}"     # issue-tracker URL for this issue
SPAWN_MODEL="${SPAWN_MODEL:-$HA_SPAWN_MODEL}"

# Issue type drives the branch prefix so the branch name mirrors the issue tree.
TYPE="${TYPE:-bug}"
case "$TYPE" in
    bug|feature|task|release) ;;
    *)
        echo "error: TYPE must be one of bug|feature|task|release (got '$TYPE')" >&2
        exit 2
        ;;
esac

PARENT="${PARENT:-}"

# Mandatory-parent gate: every non-release issue must declare a parent, so the
# agent tree mirrors the GitHub issue tree (see docs/agent-hierarchy.md §
# Mandatory parent). release_* roots are the only parentless issues.
if [ "$TYPE" != "release" ] && [ -z "$PARENT" ]; then
    echo "error: PARENT is required for TYPE=$TYPE (only TYPE=release may omit it)." >&2
    echo "       Pass PARENT=<issue-number> — the issue this one is a child of." >&2
    echo "       If this issue genuinely has no parent, it is a release root: use TYPE=release." >&2
    exit 2
fi

# Build the parent paragraph as a PLAIN variable, never as an inline
# ${PARENT:+...} brace-expansion inside the heredoc: an apostrophe inside a
# ${var:+...} alternate value in a heredoc breaks bash's brace-scan at RUNTIME,
# which `bash -n` cannot catch. Assembling it here keeps the heredoc a simple
# variable interpolation.
if [ -n "$PARENT" ]; then
    PARENT_PARAGRAPH="**Parent issue:** #${PARENT} — your coordinator (${COORDINATOR}) manages this
agent as part of the #${PARENT} subtree. Any issue you file must itself declare a
parent (see the mandatory-parent rule in agents/docs/agent-hierarchy.md)."
else
    PARENT_PARAGRAPH="**Parent issue:** (none given) — if this is not a release root, ask your
coordinator (${COORDINATOR}) which issue this is a child of. Every non-release
issue must declare a parent (agents/docs/agent-hierarchy.md)."
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WORKTREES_DIR="$(cd "$ROOT/.." && pwd)"
BRANCH="${TYPE}_${NUM}_${SLUG}"
WT="$WORKTREES_DIR/$BRANCH"

if [ -e "$WT" ]; then
    echo "error: $WT already exists" >&2
    exit 1
fi

# Don't re-spawn an agent for an issue we've already closed.
CLOSED_DIR="$WORKTREES_DIR/closed"
if [ -d "$CLOSED_DIR" ]; then
    PRIOR=$(ls "$CLOSED_DIR" 2>/dev/null | grep -E "^(bug|feature|task|release)_${NUM}_" || true)
    if [ -n "$PRIOR" ]; then
        echo "error: issue #${NUM} already has an archived plan-doc in worktrees/closed/:" >&2
        echo "$PRIOR" | sed 's/^/  /' >&2
        echo "" >&2
        echo "If this issue is still open, the prior agent likely landed a partial fix" >&2
        echo "and the issue needs a status comment or close action, not a new agent." >&2
        echo "Check with: gh issue view ${NUM}" >&2
        echo "" >&2
        echo "To override and re-spawn anyway, pass --force-respawn as the 4th argument." >&2
        if [ "${4:-}" != "--force-respawn" ]; then
            exit 1
        fi
        echo "(--force-respawn given; proceeding)" >&2
    fi
fi

echo "Creating worktree $WT (branch $BRANCH off origin/main)..."
git worktree add -b "$BRANCH" "$WT" origin/main

# Any abort from here must undo BOTH the worktree and the branch that
# `git worktree add -b` created. A single ERR/EXIT trap cleans up until we
# clear it on success (just before tmux spawn).
cleanup_partial_spawn() {
    local st=$?
    [ "$st" -eq 0 ] && return 0
    echo "spawn aborted (exit $st); cleaning up partial worktree + branch..." >&2
    git worktree remove --force "$WT" 2>/dev/null || true
    git branch -D "$BRANCH" 2>/dev/null || true
}
trap cleanup_partial_spawn EXIT

echo "Seeding .claude/settings.json (hooks + permissions)..."
mkdir -p "$WT/.claude"
# Hooks live in the hydra-agents checkout (agents/bin/claude-hooks/). Verify the
# referenced hook scripts exist and are executable *before* launching — a missing
# hook fails silently at the first Stop/Notification/UserPromptSubmit event.
HOOKS_DIR="$HA_AGENTS_DIR/bin/claude-hooks"
for hook in inbox-hook.sh notification-hook.sh stop-hook.sh proposals-hook.sh decisions-hook.sh autonomy-hook.sh; do
    if [ ! -x "$HOOKS_DIR/$hook" ]; then
        echo "error: hook script missing or not executable: $HOOKS_DIR/$hook" >&2
        echo "       The spawned agent's hooks would fail silently. Ensure the hydra-agents" >&2
        echo "       checkout ($HA_AGENTS_DIR) is present and its bin/claude-hooks/*.sh are +x." >&2
        exit 1
    fi
done
cp "$HOOKS_DIR/template-settings.json" "$WT/.claude/settings.json"

# Sandbox permission bypass (see docs/sandbox-permissions.md). The template
# deliberately does NOT carry defaultMode: bypassPermissions — that would leak
# bypass to every machine that clones the repo. Inject it here ONLY when this
# machine declares itself a sandbox via the ~/.hydra-sandbox marker. Done with
# jq (no Python dependency).
if [ -f "$HOME/.hydra-sandbox" ]; then
    echo "Sandbox marker present — enabling permission bypass for this agent..."
    _tmp="$WT/.claude/settings.json.tmp.$$"
    if jq '.permissions = (.permissions // {}) | .permissions.defaultMode = "bypassPermissions"' \
            "$WT/.claude/settings.json" > "$_tmp" && mv -f "$_tmp" "$WT/.claude/settings.json"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        echo "error: failed to inject bypassPermissions into settings.json" >&2
        exit 1
    fi
fi

echo "Seeding claude-hydra-messages/inbox/ with briefing..."
mkdir -p "$WT/claude-hydra-messages/inbox/archive"
mkdir -p "$WT/claude-hydra-messages/outbox/archive"
# Issue-proposal queue (see docs/agent-hierarchy.md).
mkdir -p "$WT/claude-hydra-messages/proposals/pending"
mkdir -p "$WT/claude-hydra-messages/proposals/forwarded"
mkdir -p "$WT/claude-hydra-messages/proposals/approved"
mkdir -p "$WT/claude-hydra-messages/proposals/declined"
# Design-decision queue (see docs/agent-hierarchy.md § Design decisions).
mkdir -p "$WT/claude-hydra-messages/decisions/pending"
mkdir -p "$WT/claude-hydra-messages/decisions/forwarded"
mkdir -p "$WT/claude-hydra-messages/decisions/answered"
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
cat > "$WT/claude-hydra-messages/inbox/${TS}-coordinator-assignment.md" <<EOF
# Assignment: GitHub issue #${NUM}

**From:** coordinator (${COORDINATOR})
**Date:** $(date -u +%Y-%m-%d)
**Issue:** ${ISSUE_URL}
**Title:** ${TITLE}
**Type:** ${TYPE}
${PARENT_PARAGRAPH}

## What

Read the GitHub issue (\`gh issue view ${NUM}\`) for the full problem statement and
context. This branch is dedicated to investigating and addressing it.

## How to work

1. Run the ${GUIDE} startup procedure (you should be doing that anyway).
2. Read the issue body via \`gh issue view ${NUM}\`. Investigate the symptom
   and propose a root cause.
3. Write your plan to \`${BRANCH}-plan.md\` at the worktree root.
4. Iterate: commit small, push often, draft a PR when ready for review.

### Scoped reading (keep your context lean)

Your startup reading is scoped to your role (see
agents/docs/agent-hierarchy.md § Context minimization). As an issue agent you
need: the ${GUIDE} startup checklist, this briefing, the new-issue proposal
lifecycle + dependency test in agents/docs/agent-hierarchy.md, and the project
references relevant to YOUR issue. You do NOT need the staging promotion-loop
internals (agents/docs/branch-flow.md) or the coordinator lifecycle
(agents/docs/coordinator-workflow.md) unless/until your issue takes on children.
Read what your job needs, and no more.

## Coordination

- The inbox hook (\`agents/bin/claude-hooks/inbox-hook.sh\`, wired via
  \`.claude/settings.json\`) auto-surfaces new messages in this directory on
  each prompt. You don't need to remember to poll.
- The coordinator monitors \`~/.cache/claude-attention/\` for blocked
  sessions. If you hit a permission prompt and pause, the coordinator
  sees a marker file with your worktree name and can act.

### IMPORTANT: never call AskUserQuestion. Use the coordinator inbox instead.

The human is supervising N parallel sub-sessions and cannot watch each pane.
**Your settings.json denies the \`AskUserQuestion\` tool by default** — calling
it will fail. This is intentional: every multiple-choice prompt blocks your
turn while the human has to cycle through every pane to answer.

The same principle applies to any other form of pause-and-wait-for-the-user:
don't end your turn with "Should I do X or Y?" expecting the human to answer.
Instead, route the question through the coordinator:

1. Write a message to the coordinator's inbox at
   \`../${COORDINATOR}/claude-hydra-messages/inbox/\`
   (filename format per agents/docs/cross-worktree-messages.md). Include enough
   context for the coordinator to answer on the user's behalf.
2. Then either (a) **make a best-guess choice, document it in the plan-doc,
   and continue working** while waiting for the coordinator's reply, or
   (b) if the question is truly blocking, end your turn with a brief
   "blocked — waiting on coordinator's answer" status.
3. **Default to (a).** The coordinator can redirect you later if the choice
   was wrong; if it was right, you've saved a round-trip.

Permission prompts (tool-use approvals) are different — those are handled at
the harness level by the human; you do not need to message the coordinator
about them.

## Scope guard

This branch is for issue #${NUM} **only**. Out-of-scope discoveries should
go in the plan-doc's "Findings" section for future filing, not this PR.

Good luck. Ping back when you've got a plan or hit a blocker.
EOF

# Worktree is fully provisioned; a failure from here should NOT tear it down.
trap - EXIT

echo "Starting tmux session '${BRANCH}'..."
tmux new-session -d -s "${BRANCH}" -c "$WT"
tmux set-window-option -t "${BRANCH}" automatic-rename off
tmux set-window-option -t "${BRANCH}" allow-rename off
tmux rename-window   -t "${BRANCH}" "${BRANCH}"
tmux select-pane     -t "${BRANCH}" -T "${BRANCH}"

tmux send-keys -t "${BRANCH}" "claude-remote -b -m ${SPAWN_MODEL}" Enter

# Give the agent TUI time to spin up before sending the trigger prompt, then
# send a follow-up Enter — paste-detection occasionally eats the first.
sleep 8
tmux send-keys -t "${BRANCH}" "Please complete the ${GUIDE} startup procedure and address any pending inbox messages." Enter
sleep 3
tmux send-keys -t "${BRANCH}" Enter

echo ""
echo "============================================================"
echo "Spawned ${BRANCH}:"
echo "  worktree: $WT"
echo "  branch:   $BRANCH"
echo "  tmux:     tmux attach -t ${BRANCH}"
echo ""
echo "Watch attention markers from coordinator:"
echo "  ls -la ~/.cache/claude-attention/"
echo "============================================================"
