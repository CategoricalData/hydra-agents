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

    # Fail loudly on malformed JSON, up front — otherwise a parse error would
    # masquerade as a "missing required field" (from _req) or silently fall back
    # to defaults for every optional field (from _opt).
    if ! jq empty "$HA_CONFIG_FILE" 2>/dev/null; then
        echo "error: hydra-agents.json is not valid JSON ($HA_CONFIG_FILE)." >&2
        echo "       Run 'jq . $HA_CONFIG_FILE' to see the parse error." >&2
        return 6
    fi

    # Read a required string field; error if missing/null/empty. `strings` guards
    # against a non-string value (number/object) being accepted as a garbage value.
    local _v
    _req() {
        _v="$(jq -re --arg k "$1" '.[$k] | strings // empty' "$HA_CONFIG_FILE" 2>/dev/null || true)"
        if [ -z "$_v" ]; then
            echo "error: hydra-agents.json is missing (or non-string/empty) required field \"$1\" ($HA_CONFIG_FILE)." >&2
            return 5
        fi
        printf '%s' "$_v"
    }
    # Read an optional string field with a default. Treats an ABSENT, null, or
    # EMPTY-STRING value as "use the default" — jq's `//` alone only defaults on
    # null/false, so an explicit "" would otherwise slip through as an empty value.
    _opt() {
        local _o
        _o="$(jq -re --arg k "$1" '.[$k] | strings // empty' "$HA_CONFIG_FILE" 2>/dev/null || true)"
        if [ -z "$_o" ]; then printf '%s' "$2"; else printf '%s' "$_o"; fi
    }

    HA_ISSUE_URL_BASE="$(_req issueUrlBase)" || return 5
    HA_ISSUE_REPO="$(_req issueRepo)"        || return 5
    HA_AGENT_GUIDE="$(_opt agentGuide CLAUDE.md)"
    HA_SPAWN_MODEL="$(_opt spawnModel opusplan)"
    HA_AGENTS_VERSION="$(_opt agentsVersion unpinned)"

    # Machine-global tmux-session/agent name prefix. Branches and worktrees are
    # per-repo, but tmux session names are per-MACHINE — so two projects on one
    # host collide on `staging` / `feature_NNN_*`. Qualify session names (not the
    # short branch/window/pane titles) with this prefix. Defaults to the repo
    # name from issueRepo (e.g. "acme/myproj" → "myproj-"); override with
    # sessionPrefix where the repo name is awkward. See hydra-agents#1.
    HA_SESSION_PREFIX="$(_opt sessionPrefix "${HA_ISSUE_REPO##*/}-")"

    # Standardized branch names (staging, etc.) exist on EVERY machine, so their
    # agent/session name collides across a multi-machine fleet even after the
    # per-project prefix above. Machine-qualify ONLY those (see the spawn script):
    # issue branches like feature_NNN_* are already unique, and a machine suffix
    # would just make them longer, hurting readability in the mobile agent picker.
    # This is the machine-qualification layer above hydra-agents#1's session prefix.
    # Space-separated set (jq-friendly, no array parsing); override via config.
    HA_STANDARDIZED_BRANCHES="$(_opt standardizedBranches "staging")"
    HA_MACHINE="$(hostname -s 2>/dev/null || echo unknown)"

    # Resolve the hydra-agents checkout. HYDRA_AGENTS_DIR (env) overrides for a
    # nonstandard layout; otherwise agentsDir from the config, relative to the
    # project root. Both resolve to an absolute path.
    local _adir
    if [ -n "${HYDRA_AGENTS_DIR:-}" ]; then
        _adir="$HYDRA_AGENTS_DIR"
    else
        _adir="$(_opt agentsDir ./agents)"
    fi
    case "$_adir" in
        /*) HA_AGENTS_DIR="$_adir" ;;
        *)  HA_AGENTS_DIR="$HA_PROJECT_ROOT/${_adir#./}" ;;
    esac

    export HA_PROJECT_ROOT HA_CONFIG_FILE HA_AGENTS_DIR HA_AGENTS_VERSION \
           HA_ISSUE_URL_BASE HA_ISSUE_REPO HA_AGENT_GUIDE HA_SPAWN_MODEL \
           HA_SESSION_PREFIX
    unset -f _req _opt   # don't leak these generic helper names into the caller's shell
    return 0
}
