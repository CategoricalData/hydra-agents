#!/usr/bin/env bash
# statusline.sh: a Claude Code status line that records the account's quota use.
#
# Claude Code passes the status-line command a JSON object on stdin whose
# `rate_limits` holds `five_hour` and `seven_day`, each with `used_percentage`
# and `resets_at` (epoch seconds). This script saves that object, with the
# time it was read, to $QUOTA_DIR/rate-limits.json (atomically) and prints
# "5h:NN% 7d:NN%". quota-check.sh reads the file. See docs/quota-pacing.md.
#
# Install (user level, opt-in), in the settings.json of the Claude config dir:
#   "statusLine": {"type": "command", "command": "<agents>/bin/quota/statusline.sh"}
# To keep an existing status line, set QUOTA_STATUSLINE_NEXT to its command:
# it gets the same stdin, and its output is printed before ours.
#
# QUOTA_DIR defaults to ${CLAUDE_CONFIG_DIR:-~/.claude}/usage, so each Claude
# account (config dir) on a machine records into its own directory.
# Requires jq.

QUOTA_DIR="${QUOTA_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage}"
input="$(cat)"
prefix=""
if [ -n "${QUOTA_STATUSLINE_NEXT:-}" ]; then
    prefix="$(printf '%s' "$input" | sh -c "$QUOTA_STATUSLINE_NEXT" 2>/dev/null | head -n 1)"
fi
rl="$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)"
ours=""
if [ -n "$rl" ] && [ "$rl" != "{}" ]; then
    mkdir -p "$QUOTA_DIR"
    tmp="$QUOTA_DIR/.rate-limits.json.$$"
    if printf '{"at":%s,"rate_limits":%s}\n' "$(date +%s)" "$rl" > "$tmp"; then
        mv -f "$tmp" "$QUOTA_DIR/rate-limits.json"
    else
        rm -f "$tmp"
    fi
    ours="$(printf '%s' "$rl" | jq -r '[(.five_hour.used_percentage // empty | "5h:\(floor)%"),
                                         (.seven_day.used_percentage // empty | "7d:\(floor)%")] | join(" ")')"
fi
printf '%s\n' "$(printf '%s %s' "$prefix" "$ours" | sed 's/^ *//; s/ *$//')"
