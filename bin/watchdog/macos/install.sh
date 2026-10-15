#!/bin/bash
# install.sh — render launchd.plist.template and (re)load the macOS watchdog.
#
# Usage: WATCHDOG_INBOX=<staging inbox dir> bin/watchdog/macos/install.sh
#
# Optional environment:
#   WATCHDOG_LABEL      launchd label      (default hydra-agents.watchdog)
#   WATCHDOG_STATE_DIR  log + state dir    (default ~/watchdog/logs)
#   WATCHDOG_INBOX      staging inbox dir  (default empty: attention marker only)
#
# The plist points at health-watchdog.sh in THIS checkout, so pulling the
# checkout updates the watchdog; re-run install.sh only to change settings.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${WATCHDOG_LABEL:-hydra-agents.watchdog}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/watchdog/logs}"
INBOX="${WATCHDOG_INBOX:-}"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -n "$INBOX" ] && [ ! -d "$INBOX" ]; then
    echo "install.sh: warning: WATCHDOG_INBOX=$INBOX does not exist yet; alerts will fall back to the attention marker" >&2
fi

mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"
sed -e "s#@LABEL@#$LABEL#g" \
    -e "s#@SCRIPT@#$HERE/health-watchdog.sh#g" \
    -e "s#@STATE_DIR@#$STATE_DIR#g" \
    -e "s#@INBOX@#$INBOX#g" \
    "$HERE/launchd.plist.template" > "$DEST"
plutil -lint "$DEST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"
echo "installed $DEST; log: $STATE_DIR/health.log"
