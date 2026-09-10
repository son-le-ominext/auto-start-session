#!/bin/bash
#
# uninstall.sh -- remove the launchd agent. Logs are left in place.

set -uo pipefail

LABEL="com.ominext.claude-auto-start"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "Unloaded $LABEL" \
	|| echo "$LABEL was not loaded"

if [ -f "$TARGET" ]; then
	rm -f "$TARGET"
	echo "Removed $TARGET"
fi

echo "Logs kept at $HOME/Library/Logs/claude-auto-start"
