#!/bin/bash
#
# start-session.sh -- open a Claude Code session on a schedule.
#
# Runs a single headless `claude -p` request so that a Claude session (and the
# rolling usage window that comes with it) is active at a predictable time of
# day instead of whenever you first sit down at the machine.
#
# Invoked by the launchd agent com.ominext.claude-auto-start, but safe to run
# by hand at any time.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults. Do not edit these -- copy config.example.sh to config.local.sh and
# override there, so your settings survive a `git pull`.
# ---------------------------------------------------------------------------

CLAUDE_BIN="/opt/homebrew/bin/claude"

# Directory the session runs in. Claude picks up the CLAUDE.md and settings of
# whatever directory it starts in, so keep this somewhere small and boring.
WORKDIR="$SCRIPT_DIR"

# The request. Keep it cheap -- the point is to open the session, not to think.
PROMPT="Reply with exactly: session started"

# Empty means "whatever your configured default model is".
MODEL=""

# Extra arguments passed straight through to `claude`, e.g.
# EXTRA_ARGS=(--allowed-tools "Read,Grep")
EXTRA_ARGS=()

# Give up on a single attempt after this many seconds.
TIMEOUT_SECS=240

# Retries, in case the machine has only just woken and the network is not up.
MAX_ATTEMPTS=5
RETRY_DELAY_SECS=60

# Wait up to this long for the network to come back before the first attempt.
NETWORK_WAIT_SECS=180

LOG_DIR="$HOME/Library/Logs/claude-auto-start"
LOG_MAX_BYTES=1048576

# ---------------------------------------------------------------------------

if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
	# shellcheck source=/dev/null
	. "$SCRIPT_DIR/config.local.sh"
fi

LOG_FILE="$LOG_DIR/session.log"
mkdir -p "$LOG_DIR"

log() {
	printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

rotate_log() {
	[ -f "$LOG_FILE" ] || return 0
	local size
	size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
	if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
		mv -f "$LOG_FILE" "$LOG_FILE.1"
	fi
}

# `timeout` is not on stock macOS, so roll our own watchdog.
run_with_timeout() {
	local secs="$1"
	shift
	"$@" &
	local pid=$!
	(
		sleep "$secs"
		kill -TERM "$pid" 2>/dev/null
		sleep 5
		kill -KILL "$pid" 2>/dev/null
	) >/dev/null 2>&1 &
	local watcher=$!
	wait "$pid"
	local rc=$?
	kill -KILL "$watcher" 2>/dev/null
	wait "$watcher" 2>/dev/null
	return $rc
}

wait_for_network() {
	local waited=0
	while [ "$waited" -lt "$NETWORK_WAIT_SECS" ]; do
		if curl -fsS --max-time 10 -o /dev/null "https://api.anthropic.com/v1/models" \
			-H "x-api-key: probe" 2>/dev/null; then
			return 0
		fi
		# A 401 also means we reached Anthropic, which is all we are checking for.
		local code
		code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
			"https://api.anthropic.com/v1/models" 2>/dev/null)
		if [ -n "$code" ] && [ "$code" != "000" ]; then
			return 0
		fi
		sleep 10
		waited=$((waited + 10))
	done
	log "WARN network still unreachable after ${NETWORK_WAIT_SECS}s; trying anyway"
	return 1
}

rotate_log

if [ ! -x "$CLAUDE_BIN" ]; then
	resolved="$(command -v claude 2>/dev/null || true)"
	if [ -n "$resolved" ]; then
		log "INFO $CLAUDE_BIN not executable; falling back to $resolved"
		CLAUDE_BIN="$resolved"
	else
		log "ERROR claude CLI not found (looked at $CLAUDE_BIN and \$PATH)"
		exit 1
	fi
fi

if [ ! -d "$WORKDIR" ]; then
	log "ERROR working directory does not exist: $WORKDIR"
	exit 1
fi

cd "$WORKDIR" || exit 1

args=(-p "$PROMPT" --output-format text)
[ -n "$MODEL" ] && args+=(--model "$MODEL")
[ "${#EXTRA_ARGS[@]}" -gt 0 ] && args+=("${EXTRA_ARGS[@]}")

log "=== starting session (cwd=$WORKDIR model=${MODEL:-default}) ==="
wait_for_network

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
	out_file="$(mktemp -t claude-auto-start)"

	run_with_timeout "$TIMEOUT_SECS" "$CLAUDE_BIN" "${args[@]}" \
		</dev/null >"$out_file" 2>&1
	rc=$?

	response="$(tr -d '\r' <"$out_file" | tr '\n' ' ' | cut -c1-500)"
	rm -f "$out_file"

	if [ "$rc" -eq 0 ]; then
		log "OK  attempt $attempt: $response"
		exit 0
	fi

	log "FAIL attempt $attempt/$MAX_ATTEMPTS (exit $rc): $response"
	attempt=$((attempt + 1))
	[ "$attempt" -le "$MAX_ATTEMPTS" ] && sleep "$RETRY_DELAY_SECS"
done

log "ERROR gave up after $MAX_ATTEMPTS attempts"
exit 1
