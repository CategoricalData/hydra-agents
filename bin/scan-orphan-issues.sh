#!/usr/bin/env bash
# Orphan-issue scan: list open GitHub issues that have no parent and are not
# release roots. Read-only — it never files, closes, or re-parents anything.
#
# This is the backstop for the mandatory-parent rule (see
# docs/agent-hierarchy.md): every non-release issue should declare a parent,
# but humans occasionally file one without, and an agent might slip. Run this
# periodically as a staging non-issue duty (docs/branch-flow.md § Staging's
# non-issue duties), then surface the results to the user for parent assignment
# — draft-and-show; NEVER re-parent without explicit approval.
#
# The target repo comes from the project's hydra-agents.json (issueRepo), or the
# HYDRA_REPO env var as an override.
#
# Usage:
#   bin/scan-orphan-issues.sh
#
# A "release root" is legitimately parentless. Because `gh issue list` does not
# expose the issue-type field uniformly, this treats an issue as a release root
# if EITHER its title matches RELEASE_RE OR it carries the RELEASE_LABEL label.
# Adjust RELEASE_RE / RELEASE_LABEL below if your project's convention differs.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-config.sh"

# Repo: env override wins; otherwise from hydra-agents.json (issueRepo).
if [ -n "${HYDRA_REPO:-}" ]; then
    REPO="$HYDRA_REPO"
else
    ha_load_config   # errors out with guidance if no hydra-agents.json
    REPO="$HA_ISSUE_REPO"
fi

# Project-specific release-root heuristic. Override per project as needed.
RELEASE_RE="${RELEASE_RE:-^Hydra [0-9]+\.[0-9]+ release$}"
RELEASE_LABEL="${RELEASE_LABEL:-release}"

echo "Scanning open issues in $REPO for missing parents (release roots excluded)..."
echo ""

# Fetch the issue list up front so a fetch failure is caught explicitly, rather
# than feeding an empty stream into the loop and printing a false "none found".
if ! ISSUES=$(gh issue list --repo "$REPO" --state open --limit 300 \
        --json number,title,labels \
        --jq '.[] | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))"'); then
    echo "error: 'gh issue list' failed for $REPO — cannot scan for orphans." >&2
    echo "       Check 'gh auth status' and network; not reporting a result." >&2
    exit 1
fi

orphans=0
while IFS=$'\t' read -r num title labels; do
    [ -n "$num" ] || continue

    # Release roots are legitimately parentless — skip by title OR by label.
    if printf '%s' "$title" | grep -Eq "$RELEASE_RE"; then
        continue
    fi
    if printf '%s' ",$labels," | grep -qF ",$RELEASE_LABEL,"; then
        continue
    fi

    # A 404 from the parent endpoint means no parent is set. On 404 `gh api`
    # prints the error JSON to *stdout* (and exits non-zero), so key on a
    # successfully-parsed numeric parent, not on empty stdout.
    parent=$(gh api "repos/$REPO/issues/$num/parent" --jq '.number' 2>/dev/null || true)
    if ! printf '%s' "$parent" | grep -Eq '^[0-9]+$'; then
        printf '  #%-5s %s\n' "$num" "$title"
        orphans=$((orphans + 1))
    fi
done <<< "$ISSUES"

echo ""
if [ "$orphans" -eq 0 ]; then
    echo "No orphaned (parentless, non-release) open issues found."
else
    echo "$orphans orphaned issue(s) above need a parent."
    echo "Surface these to the user for parent assignment — do NOT re-parent"
    echo "without explicit approval (see docs/agent-hierarchy.md)."
fi
