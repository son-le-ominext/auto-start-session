# Copy this file to config.local.ps1, edit, then re-run install.ps1 to deploy it.
# Every value is optional -- anything you leave out keeps the default from
# start-session.ps1.
#
#   Copy-Item config.example.ps1 config.local.ps1
#   powershell -ExecutionPolicy Bypass -File .\install.ps1

# Path to the claude CLI. Leave empty to resolve it from PATH, then from the
# native installer (%USERPROFILE%\.local\bin\claude.exe) and npm
# (%APPDATA%\npm\claude.cmd) locations.
# $ClaudeBin = ''

# Directory the scheduled session runs in. Claude loads the CLAUDE.md and
# .claude settings of this directory, so a big project here means a bigger,
# slower first request. Defaults to the deploy directory.
# $WorkDir = "$env:LOCALAPPDATA\claude-auto-start"

# The request sent on schedule. The default just opens the session cheaply.
# $Prompt = 'Reply with exactly: session started'

# Want it to actually do something? Give it a real prompt and the tools it
# needs. In headless mode any tool NOT in --allowed-tools is denied rather than
# prompting you, so list everything the task requires.
# $Prompt = "Summarise yesterday's commits in five bullets."
# $ExtraArgs = @('--allowed-tools', 'Read,Grep,Glob,Bash(git log:*)')

# Pin a model, e.g. claude-haiku-4-5-20251001 to keep the wake-up call cheap.
# $Model = ''

# Timing and resilience.
# $TimeoutSecs = 240
# $MaxAttempts = 5
# $RetryDelaySecs = 60
# $NetworkWaitSecs = 180

# $LogDir = "$env:LOCALAPPDATA\claude-auto-start\logs"
