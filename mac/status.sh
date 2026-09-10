#!/bin/bash
#
# status.sh -- is the agent registered, and what happened on the last run?

set -uo pipefail

LABEL="com.ominext.claude-auto-start"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DEPLOY_DIR="$HOME/Library/Application Support/claude-auto-start"
LOG_DIR="$HOME/Library/Logs/claude-auto-start"
DOMAIN="gui/$(id -u)"

echo "--- schedule ---"
if [ -f "$TARGET" ]; then
	/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval' "$TARGET" 2>/dev/null
else
	echo "not installed ($TARGET missing)"
fi

echo
echo "--- deployed script ---"
if [ -f "$DEPLOY_DIR/start-session.sh" ]; then
	ls -l "$DEPLOY_DIR/start-session.sh"
	[ -f "$DEPLOY_DIR/config.local.sh" ] && echo "config.local.sh: deployed" \
		|| echo "config.local.sh: none (using built-in defaults)"
else
	echo "not deployed -- run ./install.sh"
fi

echo
echo "--- launchd ---"
launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
	| grep -E '^[[:space:]]+(state|last exit code) = ' | head -2 \
	|| echo "not loaded in $DOMAIN"

echo
echo "--- last 15 log lines ---"
if [ -f "$LOG_DIR/session.log" ]; then
	tail -n 15 "$LOG_DIR/session.log"
else
	echo "no runs logged yet ($LOG_DIR/session.log)"
fi

if [ -s "$LOG_DIR/launchd.err.log" ]; then
	echo
	echo "--- launchd.err.log ---"
	tail -n 10 "$LOG_DIR/launchd.err.log"
fi
