#!/usr/bin/env bash
# lib-identity.sh — what a worktree may show about itself outside the project.
#
# For a private project, its name, branch names and issue titles are confidential:
# the harness never emits them outside the project's own worktrees (hydra-agents#7,
# docs/cross-worktree-messages.md § Project isolation). This library is for the
# places that do reach outside — terminal and tmux titles, attention markers in a
# machine-wide directory — and is cheap enough for hooks: it reads the project's
# config files only (no gh, no network). A project counts as public only when its
# config says so ("visibility": "public", in hydra-agents.json or the machine-local
# hydra-agents.local.json); anything else is treated as private (fail closed).
#
# Usage:
#   . "<agents>/bin/lib-identity.sh"
#   ha_identity_load <worktree-root>      # sets HA_ID_* below; 1 if no harness config
#   ha_attention_dir <worktree-root>      # where this worktree's attention markers go
#   ha_display_name <worktree-root>       # a title safe to show outside the project
#
# HA_ID_PUBLIC "true"/"false"; HA_ID_CONFIG the config path ("" if none).

_HA_ID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ha_identity_load() {
    local root="$1" dir local_cfg vis
    HA_ID_CONFIG="" HA_ID_PUBLIC=false
    dir="$(cd "$root" 2>/dev/null && pwd)" || return 1
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        [ -f "$dir/hydra-agents.json" ] && { HA_ID_CONFIG="$dir/hydra-agents.json"; break; }
        dir="$(dirname "$dir")"
    done
    [ -n "$HA_ID_CONFIG" ] || return 1
    command -v jq >/dev/null 2>&1 || return 0   # can't read it: stay private
    local_cfg="$(dirname "$HA_ID_CONFIG")/hydra-agents.local.json"
    vis="$(jq -r '.visibility // empty' "$local_cfg" 2>/dev/null || true)"
    [ -n "$vis" ] || vis="$(jq -r '.visibility // empty' "$HA_ID_CONFIG" 2>/dev/null || true)"
    [ "$vis" = public ] && HA_ID_PUBLIC=true
    return 0
}

# ha_attention_dir <worktree-root>: ~/.cache/claude-attention for a public project
# (or a directory outside any harness project), else a project-local directory
# beside the worktrees: <worktrees>/.claude-attention. Markers are named after the
# worktree and carry its path, so a private project keeps them inside the project.
ha_attention_dir() {
    if ! ha_identity_load "$1" || [ "$HA_ID_PUBLIC" = true ]; then
        printf '%s' "$HOME/.cache/claude-attention"
    else
        printf '%s' "$(cd "$1/.." && pwd)/.claude-attention"
    fi
}

# ha_display_name <worktree-root>: the branch for a public project (or outside any
# harness project); for a private one, its opaque session name (p-<hash>, the
# same name spawn gives the tmux session and the agent).
ha_display_name() {
    local root="$1" branch
    branch="$(git -C "$root" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] || branch="$(basename "$root")"
    if ! ha_identity_load "$root" || [ "$HA_ID_PUBLIC" = true ]; then
        printf '%s' "$branch"
        return 0
    fi
    # Compute the opaque name with lib-config's rule, from the config fields alone.
    (
        . "$_HA_ID_DIR/lib-config.sh"
        HA_ISSUE_REPO="$(jq -r '.issueRepo // ""' "$HA_ID_CONFIG" 2>/dev/null)"
        HA_SESSION_PREFIX="$(jq -r '.sessionPrefix // empty' "$HA_ID_CONFIG" 2>/dev/null)"
        [ -n "$HA_SESSION_PREFIX" ] || HA_SESSION_PREFIX="${HA_ISSUE_REPO##*/}-"
        HA_STANDARDIZED_BRANCHES="$(jq -r '.standardizedBranches // "staging"' "$HA_ID_CONFIG" 2>/dev/null)"
        HA_MACHINE="$(hostname -s 2>/dev/null || echo unknown)"
        HA_PRIVATE=true
        ha_session_name_for "$branch"
    ) || printf 'agent'
}
