#!/usr/bin/env bash
# lib-config.sh — resolve a consuming project's hydra-agents.json config.
#
# Sourced by the harness scripts (spawn-issue-worktree.sh, scan-orphan-issues.sh)
# to read per-project configuration. Each consuming project checks in a
# `hydra-agents.json` at its project root (see config/examples/hydra-agents.json).
# Because the config is a file at the project root — not an environment variable —
# two different projects on the same machine each get their own values
# unambiguously, keyed to whichever project tree the caller is operating in.
#
# Requires `jq` (the harness deliberately avoids a Python dependency).
#
# Usage:
#   . "$(dirname "$0")/lib-config.sh"
#   ha_load_config          # errors out if no hydra-agents.json is found
#   echo "$HA_ISSUE_URL_BASE" "$HA_SPAWN_MODEL" ...
#
# Exports, on success:
#   HA_PROJECT_ROOT   absolute path to the project root (dir holding hydra-agents.json)
#   HA_CONFIG_FILE    absolute path to the resolved hydra-agents.json
#   HA_AGENTS_DIR     absolute path to the hydra-agents checkout (from agentsDir)
#   HA_AGENTS_VERSION pinned hydra-agents version/sha (agentsVersion; "unpinned" if unset)
#   HA_ISSUE_URL_BASE issue-tracker URL base (issueUrlBase)
#   HA_ISSUE_REPO     "owner/repo" for gh (issueRepo)
#   HA_AGENT_GUIDE    the agent-context filename, e.g. CLAUDE.md (agentGuide)
#   HA_SPAWN_MODEL    default spawn model tier (spawnModel)

# Walk up from $1 (or $PWD) to find the nearest hydra-agents.json. Prints its
# absolute path, or nothing if none found before the filesystem root.
ha_find_config() {
    local dir="${1:-$PWD}"
    dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if [ -f "$dir/hydra-agents.json" ]; then
            printf '%s\n' "$dir/hydra-agents.json"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    [ -f "/hydra-agents.json" ] && { printf '%s\n' "/hydra-agents.json"; return 0; }
    return 1
}

ha_load_config() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "error: jq is required to read hydra-agents.json (the harness avoids a Python dependency)." >&2
        return 3
    fi

    # A worktree resolves its project root via CLAUDE_PROJECT_DIR / git; the
    # config lives at (or above) that root. Start the search from there.
    local start="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    HA_CONFIG_FILE="$(ha_find_config "$start" || true)"
    if [ -z "${HA_CONFIG_FILE:-}" ]; then
        echo "error: no hydra-agents.json found in $start or any parent directory." >&2
        echo "       This project needs a hydra-agents.json at its root to use the harness scripts." >&2
        echo "       Copy the reference and edit it:" >&2
        echo "         cp <agents-checkout>/config/examples/hydra-agents.json <project-root>/hydra-agents.json" >&2
        return 4
    fi
    HA_PROJECT_ROOT="$(cd "$(dirname "$HA_CONFIG_FILE")" && pwd)"

    # Read a required string field; error if missing/null/empty.
    local _v
    _req() {
        _v="$(jq -re --arg k "$1" '.[$k] // empty' "$HA_CONFIG_FILE" 2>/dev/null || true)"
        if [ -z "$_v" ]; then
            echo "error: hydra-agents.json is missing required field \"$1\" ($HA_CONFIG_FILE)." >&2
            return 5
        fi
        printf '%s' "$_v"
    }
    # Read an optional string field with a default.
    _opt() { jq -re --arg k "$1" --arg d "$2" '.[$k] // $d' "$HA_CONFIG_FILE" 2>/dev/null || printf '%s' "$2"; }

    HA_ISSUE_URL_BASE="$(_req issueUrlBase)" || return 5
    HA_ISSUE_REPO="$(_req issueRepo)"        || return 5
    HA_AGENT_GUIDE="$(_opt agentGuide CLAUDE.md)"
    HA_SPAWN_MODEL="$(_opt spawnModel opusplan)"
    HA_AGENTS_VERSION="$(_opt agentsVersion unpinned)"

    # agentsDir is relative to the project root; resolve to absolute.
    local _adir; _adir="$(_opt agentsDir ./agents)"
    case "$_adir" in
        /*) HA_AGENTS_DIR="$_adir" ;;
        *)  HA_AGENTS_DIR="$HA_PROJECT_ROOT/${_adir#./}" ;;
    esac

    export HA_PROJECT_ROOT HA_CONFIG_FILE HA_AGENTS_DIR HA_AGENTS_VERSION \
           HA_ISSUE_URL_BASE HA_ISSUE_REPO HA_AGENT_GUIDE HA_SPAWN_MODEL
    return 0
}
