# Copy this file to config.local.sh, edit, then re-run ./install.sh to deploy it.
# Every value is optional -- anything you leave out keeps the default from
# start-session.sh.
#
#   cp config.example.sh config.local.sh
#   ./install.sh

# Path to the claude CLI, if it is not the Homebrew one.
# CLAUDE_BIN="/opt/homebrew/bin/claude"

# Directory the scheduled session runs in. Claude loads the CLAUDE.md and
# .claude settings of this directory, so a big project here means a bigger,
# slower first request. Defaults to the deploy directory.
#
# IMPORTANT: macOS TCC blocks launchd agents from ~/Documents, ~/Desktop and
# ~/Downloads. Pointing WORKDIR at a project under those folders will fail with
# "Operation not permitted" unless you grant Full Disk Access to /bin/bash in
# System Settings > Privacy & Security. Prefer a path outside them.
# WORKDIR="$HOME/Library/Application Support/claude-auto-start"

# The request sent on schedule. The default just opens the session cheaply.
# PROMPT="Reply with exactly: session started"

# Want it to actually do something? Give it a real prompt and the tools it
# needs. In headless mode any tool NOT in --allowed-tools is denied rather than
# prompting you, so list everything the task requires.
# PROMPT="Summarise yesterday's commits in five bullets."
# EXTRA_ARGS=(--allowed-tools "Read,Grep,Glob,Bash(git log:*)")

# Pin a model, e.g. claude-haiku-4-5-20251001 to keep the wake-up call cheap.
# MODEL=""

# Timing and resilience.
# TIMEOUT_SECS=240
# MAX_ATTEMPTS=5
# RETRY_DELAY_SECS=60
# NETWORK_WAIT_SECS=180

# LOG_DIR="$HOME/Library/Logs/claude-auto-start"
