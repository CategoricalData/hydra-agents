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
#   HA_STAGING_PEERS  space-separated session names of this project's staging
#                     sessions on other machines (stagingPeers; may be empty)
#   HA_LIST_AGENTS    "ask" (default) or "deny": what the peer-scope hook does with
#                     the account-wide session listing (listAgents)
#   HA_OPAQUE_NAMES   "true" only if opaqueNames is true: p-<hash> names instead of
#                     readable <prefix><branch> ones (default "false")
#   HA_VISIBILITY     "private" or "public": the repository's visibility, from
#                     `visibility`, else `gh repo view`, else "private" (fail closed)
#   HA_SENSITIVITY    "sensitive" or "open": this MACHINE's sensitivity, from
#                     machineSensitivity in hydra-agents.local.json or the env var
#                     HYDRA_AGENTS_MACHINE_SENSITIVITY; default "open" on a machine
#                     that declares itself a sandbox (~/.hydra-sandbox), else
#                     "sensitive" (fail closed)
#   HA_PRIVATE / HA_SENSITIVE / HA_GUARDED  "true"/"false"; guarded = private OR
#                     sensitive (docs/cross-worktree-messages.md § Project isolation)
#   HA_INBOUND        inbound policy for guarded sessions: privateInbound, "accept"
#                     (default), "hold" or "refuse"
#   HA_LOCAL_CONFIG_FILE absolute path to hydra-agents.local.json, or empty
#
# Machine-local overrides: hydra-agents.json is checked in and shared by every
# machine, so per-machine choices go in hydra-agents.local.json beside it (the
# consuming project gitignores it). Any optional string field set there wins over
# hydra-agents.json. machineSensitivity is read ONLY from there (or the env var):
# it describes the machine, so the shared file must not carry it.
#   HA_RUNNER         the agent runner adapter (runner; default claude-code), see
#                     bin/lib-runner.sh
#   HA_DOORBELLS      doorbell backends to try, in order (doorbells; default: the
#                     runner's own, then tmux; an explicit list is used exactly, and
#                     "none" rings nothing), see bin/lib-doorbell.sh
#
# Also defines ha_session_name_for <branch>: the session name for a branch.

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

    # Machine-local overrides (see the header). Validate up front, like the main file.
    HA_LOCAL_CONFIG_FILE=""
    if [ -f "$HA_PROJECT_ROOT/hydra-agents.local.json" ]; then
        HA_LOCAL_CONFIG_FILE="$HA_PROJECT_ROOT/hydra-agents.local.json"
        if ! jq empty "$HA_LOCAL_CONFIG_FILE" 2>/dev/null; then
            echo "error: hydra-agents.local.json is not valid JSON ($HA_LOCAL_CONFIG_FILE)." >&2
            echo "       Run 'jq . $HA_LOCAL_CONFIG_FILE' to see the parse error." >&2
            return 6
        fi
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
        local _o=""
        if [ -n "$HA_LOCAL_CONFIG_FILE" ]; then
            _o="$(jq -re --arg k "$1" '.[$k] | strings // empty' "$HA_LOCAL_CONFIG_FILE" 2>/dev/null || true)"
        fi
        [ -n "$_o" ] || _o="$(jq -re --arg k "$1" '.[$k] | strings // empty' "$HA_CONFIG_FILE" 2>/dev/null || true)"
        if [ -z "$_o" ]; then printf '%s' "$2"; else printf '%s' "$_o"; fi
    }
    # _optbool KEY DEFAULT: like _opt, but a JSON boolean counts too ("true"/"false").
    _optbool() {
        local _o="" _f
        for _f in "$HA_LOCAL_CONFIG_FILE" "$HA_CONFIG_FILE"; do
            [ -n "$_f" ] || continue
            _o="$(jq -r --arg k "$1" '.[$k] | if type == "boolean" then tostring elif type == "string" then . else empty end' "$_f" 2>/dev/null || true)"
            [ -n "$_o" ] && break
        done
        case "$_o" in true|false) printf '%s' "$_o" ;; *) printf '%s' "$2" ;; esac
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

    # Cross-machine staging roster: the exact session names (as other machines
    # resolve them) of this project's staging sessions elsewhere. Staging sends
    # off-machine ONLY to these, never to a name found by listing (hydra-agents#7,
    # docs/cross-worktree-messages.md § Project isolation). A JSON array, or a
    # space-separated string.
    HA_STAGING_PEERS="$(jq -r '.stagingPeers // empty | if type == "array" then join(" ") else . end' \
        "$HA_CONFIG_FILE" 2>/dev/null || true)"
    # Scoped messaging (docs/cross-worktree-messages.md § Project isolation): every
    # worktree routes SendMessage and ListAgents through bin/claude-hooks/peer-scope.sh.
    # A send to one of this project's own sessions goes through without a prompt; any
    # other recipient asks the human. listAgents: "ask" (default; the account-wide
    # listing shows other projects, so the human approves each one) or "deny".
    HA_LIST_AGENTS="$(_opt listAgents ask)"
    case "$HA_LIST_AGENTS" in
        ask|deny) ;;
        *) echo "error: listAgents must be \"ask\" or \"deny\" (got \"$HA_LIST_AGENTS\")." >&2; return 5 ;;
    esac
    # Opaque names (opt-in): "p-<hash>" session, tmux, Remote Control and terminal
    # names instead of "<prefix><branch>". Off by default: scoping, not renaming, is
    # what keeps projects apart, and readable names matter to the human.
    HA_OPAQUE_NAMES="$(_optbool opaqueNames false)"
    # Isolation inputs (docs/cross-worktree-messages.md § Project isolation):
    # the guard applies when the repo is private OR the machine is sensitive.
    HA_VISIBILITY="$(_opt visibility "")"
    if [ -z "$HA_VISIBILITY" ]; then
        # gh is a network call; cache it per config file for repeated loads
        # (recovery loads the config once per worktree).
        if [ -n "${HA_VISIBILITY_CACHE:-}" ] && [ "${HA_VISIBILITY_CACHE%%=*}" = "$HA_CONFIG_FILE" ]; then
            HA_VISIBILITY="${HA_VISIBILITY_CACHE#*=}"
        else
            HA_VISIBILITY="$(gh repo view "$HA_ISSUE_REPO" --json visibility -q .visibility 2>/dev/null \
                | tr '[:upper:]' '[:lower:]' || true)"
            case "$HA_VISIBILITY" in
                public) ;;
                private|internal) HA_VISIBILITY=private ;;
                *)
                    echo "note: could not determine the visibility of $HA_ISSUE_REPO (no \"visibility\" in" >&2
                    echo "      hydra-agents.json, and gh could not tell); treating it as private." >&2
                    HA_VISIBILITY=private
                    ;;
            esac
            HA_VISIBILITY_CACHE="$HA_CONFIG_FILE=$HA_VISIBILITY"
        fi
    fi
    case "$HA_VISIBILITY" in
        private|public) ;;
        *) echo "error: visibility must be \"private\" or \"public\" (got \"$HA_VISIBILITY\")." >&2; return 5 ;;
    esac

    if [ -n "${HYDRA_AGENTS_MACHINE_SENSITIVITY:-}" ]; then
        HA_SENSITIVITY="$HYDRA_AGENTS_MACHINE_SENSITIVITY"
    elif [ -n "$HA_LOCAL_CONFIG_FILE" ] \
            && HA_SENSITIVITY="$(jq -re '.machineSensitivity | strings' "$HA_LOCAL_CONFIG_FILE" 2>/dev/null)"; then
        :
    elif [ -f "$HOME/.hydra-sandbox" ]; then
        HA_SENSITIVITY=open
    else
        HA_SENSITIVITY=sensitive
    fi
    case "$HA_SENSITIVITY" in
        sensitive|open) ;;
        *) echo "error: machineSensitivity must be \"sensitive\" or \"open\" (got \"$HA_SENSITIVITY\")." >&2; return 5 ;;
    esac
    if jq -e 'has("machineSensitivity")' "$HA_CONFIG_FILE" >/dev/null 2>&1; then
        echo "warning: machineSensitivity in hydra-agents.json is ignored: it describes a machine, so it" >&2
        echo "         belongs in hydra-agents.local.json (or HYDRA_AGENTS_MACHINE_SENSITIVITY)." >&2
    fi

    HA_PRIVATE=false;   [ "$HA_VISIBILITY" = private ] && HA_PRIVATE=true
    HA_SENSITIVE=false; [ "$HA_SENSITIVITY" = sensitive ] && HA_SENSITIVE=true
    HA_GUARDED=false;   { [ "$HA_PRIVATE" = true ] || [ "$HA_SENSITIVE" = true ]; } && HA_GUARDED=true
    HA_INBOUND="$(_opt privateInbound accept)"
    # Sensitive machines: extra ~-relative paths to keep agents out of, and whether
    # to turn on the runner's Bash sandbox. Both are usually machine-local.
    # HYDRA_AGENTS_SENSITIVE_PATHS describes the whole machine, so it applies to every
    # worktree and project on it; sensitivePaths adds to it.
    HA_SENSITIVE_PATHS="${HYDRA_AGENTS_SENSITIVE_PATHS:-} $(_opt sensitivePaths "")"
    HA_SANDBOX_BASH="$(_opt sandboxBash false)"
    case "$HA_INBOUND" in
        accept|hold|refuse) ;;
        *) echo "error: privateInbound must be \"accept\", \"hold\" or \"refuse\" (got \"$HA_INBOUND\")." >&2; return 5 ;;
    esac

    # The agent runner (Claude Code today) is an adapter, so the harness can move to
    # another runner without touching the file protocol. Empty HA_DOORBELLS means
    # "the runner adapter's default", resolved by lib-doorbell.sh.
    HA_RUNNER="$(_opt runner claude-code)"
    HA_DOORBELLS="$(_opt doorbells "")"

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
           HA_SESSION_PREFIX HA_STAGING_PEERS HA_LIST_AGENTS HA_OPAQUE_NAMES \
           HA_LOCAL_CONFIG_FILE HA_VISIBILITY HA_VISIBILITY_CACHE HA_SENSITIVITY \
           HA_PRIVATE HA_SENSITIVE HA_GUARDED HA_INBOUND HA_SENSITIVE_PATHS HA_SANDBOX_BASH \
           HA_STANDARDIZED_BRANCHES HA_MACHINE HA_RUNNER HA_DOORBELLS
    unset -f _req _opt _optbool   # don't leak these generic helper names into the caller's shell
    return 0
}

# ha_session_name_for <branch>: the session name (tmux session, and the agent's
# messaging address) for a branch of this project. HA_SESSION_PREFIX + branch, plus
# "-<host>" for standardized branches (staging, ...), which exist on every machine.
# Spawn, recovery and the doorbell all use this, so a sender computes a recipient's
# name instead of discovering it.
#
# Names are readable by default. With "opaqueNames": true they are "p-" plus a short
# hash of the repository and that descriptive name (deterministic, so a sender still
# computes it). Isolation between projects comes from scoping sends and listings
# (bin/claude-hooks/peer-scope.sh), not from the names.
ha_session_name_for() {
    local _std _n="${HA_SESSION_PREFIX:-}$1"
    for _std in ${HA_STANDARDIZED_BRANCHES:-staging}; do
        if [ "$1" = "$_std" ]; then
            _n="$_n-${HA_MACHINE:-$(hostname -s 2>/dev/null || echo unknown)}"
            break
        fi
    done
    if [ "${HA_OPAQUE_NAMES:-false}" = true ]; then
        _n="p-$(ha_short_hash "${HA_ISSUE_REPO:-}/$_n")" || return 1
    fi
    printf '%s' "$_n"
}

# ha_short_hash <text>: first 10 hex digits of its SHA-256 (GNU or BSD tools).
ha_short_hash() {
    local _h
    if command -v sha256sum >/dev/null 2>&1; then
        _h="$(printf '%s' "$1" | sha256sum)"
    elif command -v shasum >/dev/null 2>&1; then
        _h="$(printf '%s' "$1" | shasum -a 256)"
    else
        echo "error: need sha256sum or shasum to compute a private session name" >&2
        return 1
    fi
    printf '%s' "${_h:0:10}"
}

# ha_is_standardized_branch <branch>: true if branch is in HA_STANDARDIZED_BRANCHES.
ha_is_standardized_branch() {
    local _std
    for _std in ${HA_STANDARDIZED_BRANCHES:-staging}; do
        [ "$1" = "$_std" ] && return 0
    done
    return 1
}
