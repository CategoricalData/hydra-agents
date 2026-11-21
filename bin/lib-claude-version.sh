#!/usr/bin/env bash
# lib-claude-version.sh — warn when the installed Claude Code predates native
# cross-session messaging.
#
# Since v2.1.224, Claude Code sessions can message each other directly
# (SendMessage, with ListAgents to find the recipient), and --name sets the
# address. The harness uses that as the doorbell for the file protocol and falls
# back to the tmux ping on older versions (hydra-agents#7,
# docs/cross-worktree-messages.md). Spawn and recovery call this so an old CLI is
# reported up front instead of discovered as an unreachable agent later. Native
# Windows needs v2.1.234; this check uses the Unix minimum.
#
# Usage:
#   . "$(dirname "$0")/lib-claude-version.sh"
#   ha_check_claude_version     # warns on stderr; never fails the caller

HA_MIN_CLAUDE_MESSAGING_VERSION="2.1.224"

# ha_version_ge <a> <b>: true if dotted version a >= b. Pure bash (no sort -V,
# which BSD/macOS sort lacks in older releases).
ha_version_ge() {
    local IFS=.
    local -a a=($1) b=($2)
    local i x y
    for i in 0 1 2; do
        x="${a[$i]:-0}"; y="${b[$i]:-0}"
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        x="${x:-0}"; y="${y:-0}"
        if [ "$x" -gt "$y" ]; then return 0; fi
        if [ "$x" -lt "$y" ]; then return 1; fi
    done
    return 0
}

# ha_check_claude_version: print a warning to stderr if `claude` is missing or
# older than HA_MIN_CLAUDE_MESSAGING_VERSION. Always returns 0: an old CLI still
# works with the tmux fallback, so this informs rather than blocks.
ha_check_claude_version() {
    local out ver
    if ! out="$(claude --version 2>/dev/null)"; then
        echo "warning: could not run 'claude --version'; cannot confirm native messaging support." >&2
        return 0
    fi
    ver="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "$ver" ]; then
        echo "warning: unrecognized 'claude --version' output: $out" >&2
        return 0
    fi
    if ! ha_version_ge "$ver" "$HA_MIN_CLAUDE_MESSAGING_VERSION"; then
        echo "warning: Claude Code $ver predates $HA_MIN_CLAUDE_MESSAGING_VERSION, so it has no" >&2
        echo "         cross-session messaging (SendMessage). Agents will be reachable only by" >&2
        echo "         the tmux ping. Upgrade with 'claude update' (docs/cross-worktree-messages.md)." >&2
    fi
    return 0
}
