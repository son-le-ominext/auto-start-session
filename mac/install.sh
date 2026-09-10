#!/bin/bash
#
# install.sh -- register the daily launchd agent for the current user.
#
# Usage:
#   ./install.sh            # 07:00 daily
#   ./install.sh 06:30      # any HH:MM you like
#
# Why the deploy step: macOS TCC blocks launchd agents from reading files under
# ~/Documents, ~/Desktop and ~/Downloads, so a job pointed straight at this repo
# dies with "Operation not permitted" (exit 126). We therefore copy the runtime
# files into ~/Library/Application Support, which is not protected. Re-run this
# script after editing start-session.sh or config.local.sh to sync the copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.ominext.claude-auto-start"
TEMPLATE="$SCRIPT_DIR/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DEPLOY_DIR="$HOME/Library/Application Support/claude-auto-start"
LOG_DIR="$HOME/Library/Logs/claude-auto-start"
DOMAIN="gui/$(id -u)"

TIME="${1:-07:00}"
if ! [[ "$TIME" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
	echo "error: time must be HH:MM (got '$TIME')" >&2
	exit 1
fi
HOUR=$((10#${BASH_REMATCH[1]}))
MINUTE=$((10#${BASH_REMATCH[2]}))
if [ "$HOUR" -gt 23 ] || [ "$MINUTE" -gt 59 ]; then
	echo "error: '$TIME' is not a valid time of day" >&2
	exit 1
fi

[ -f "$TEMPLATE" ] || { echo "error: missing $TEMPLATE" >&2; exit 1; }
[ -f "$SCRIPT_DIR/start-session.sh" ] || { echo "error: missing start-session.sh" >&2; exit 1; }

mkdir -p "$DEPLOY_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

install -m 755 "$SCRIPT_DIR/start-session.sh" "$DEPLOY_DIR/start-session.sh"
if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
	install -m 644 "$SCRIPT_DIR/config.local.sh" "$DEPLOY_DIR/config.local.sh"
	echo "Deployed config.local.sh"
else
	rm -f "$DEPLOY_DIR/config.local.sh"
fi

sed -e "s|__SCRIPT_PATH__|$DEPLOY_DIR/start-session.sh|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    -e "s|__HOUR__|$HOUR|g" \
    -e "s|__MINUTE__|$MINUTE|g" \
    "$TEMPLATE" > "$TARGET"

plutil -lint "$TARGET" >/dev/null

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$TARGET"
launchctl enable "$DOMAIN/$LABEL"

printf '\nInstalled %s\n' "$TARGET"
printf 'Schedule:  %02d:%02d local time, every day\n' "$HOUR" "$MINUTE"
printf 'Runs:      %s/start-session.sh\n' "$DEPLOY_DIR"
printf 'Log:       %s/session.log\n\n' "$LOG_DIR"
printf 'Test it now:  launchctl kickstart -k %s/%s\n' "$DOMAIN" "$LABEL"
printf 'Check state:  ./status.sh\n'
