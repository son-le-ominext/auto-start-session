<#
start-session.ps1 -- open a Claude Code session on a schedule (Windows).

Runs a single headless `claude -p` request so that a Claude session (and the
rolling usage window that comes with it) is active at a predictable time of
day instead of whenever you first sit down at the machine.

Invoked by the "Claude Auto Start" scheduled task, but safe to run by hand:

    powershell -ExecutionPolicy Bypass -File .\start-session.ps1
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Defaults. Do not edit these -- copy config.example.ps1 to config.local.ps1
# and override there, so your settings survive a `git pull`.
# ---------------------------------------------------------------------------

# Path to the claude CLI. Empty means: resolve `claude` from PATH, then try the
# native-installer and npm locations.
$ClaudeBin = ''

# Directory the session runs in. Claude picks up the CLAUDE.md and settings of
# whatever directory it starts in, so keep this somewhere small and boring.
$WorkDir = $ScriptDir

# The request. Keep it cheap -- the point is to open the session, not to think.
$Prompt = 'Reply with exactly: session started'

# Empty means "whatever your configured default model is".
$Model = ''

# Extra arguments passed straight through to `claude`, e.g.
# $ExtraArgs = @('--allowed-tools', 'Read,Grep')
$ExtraArgs = @()

# Give up on a single attempt after this many seconds.
$TimeoutSecs = 240

# Retries, in case the machine has only just woken and the network is not up.
$MaxAttempts = 5
$RetryDelaySecs = 60

# Wait up to this long for the network to come back before the first attempt.
$NetworkWaitSecs = 180

$DataRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local/share' }
$LogDir = Join-Path (Join-Path $DataRoot 'claude-auto-start') 'logs'
$LogMaxBytes = 1MB

# ---------------------------------------------------------------------------

$LocalConfig = Join-Path $ScriptDir 'config.local.ps1'
if (Test-Path -LiteralPath $LocalConfig) { . $LocalConfig }

$LogFile = Join-Path $LogDir 'session.log'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Rotate-Log {
    if (-not (Test-Path -LiteralPath $LogFile)) { return }
    if ((Get-Item -LiteralPath $LogFile).Length -gt $LogMaxBytes) {
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
    }
}

function Resolve-Claude {
    if ($ClaudeBin -and (Test-Path -LiteralPath $ClaudeBin)) { return $ClaudeBin }
    # -CommandType Application skips npm's claude.ps1 shim, which Start-Process
    # could not launch; we want claude.exe or claude.cmd.
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidates = @()
    if ($env:USERPROFILE) { $candidates += Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
    if ($env:APPDATA)     { $candidates += Join-Path $env:APPDATA 'npm\claude.cmd' }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Wait-ForNetwork {
    $waited = 0
    while ($waited -lt $NetworkWaitSecs) {
        try {
            $null = Invoke-WebRequest -Uri 'https://api.anthropic.com/v1/models' `
                -Headers @{ 'x-api-key' = 'probe' } -UseBasicParsing -TimeoutSec 10
            return $true
        } catch {
            # Any HTTP status (a 401 included) means we reached Anthropic, which
            # is all we are checking for. Only a transport failure keeps waiting.
            $resp = $_.Exception.PSObject.Properties['Response']
            if ($resp -and $resp.Value) { return $true }
        }
        Start-Sleep -Seconds 10
        $waited += 10
    }
    Write-Log "WARN network still unreachable after ${NetworkWaitSecs}s; trying anyway"
    return $false
}

# Quote one argument the way the Windows C runtime parses a command line, so
# a prompt with spaces or quotes arrives at claude as a single argument.
function ConvertTo-CommandLineArg {
    param([string]$Arg)
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $escaped = $Arg -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# Windows has no `timeout` for arbitrary commands, so roll our own watchdog.
function Invoke-WithTimeout {
    param([string]$FilePath, [string[]]$Arguments, [int]$Secs, [string]$Cwd)
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    $inFile  = [IO.Path]::GetTempFileName()   # empty: claude must not wait on stdin
    try {
        $argLine = ($Arguments | ForEach-Object { ConvertTo-CommandLineArg $_ }) -join ' '
        $proc = Start-Process -FilePath $FilePath -ArgumentList $argLine -WorkingDirectory $Cwd `
            -NoNewWindow -PassThru -RedirectStandardInput $inFile `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $timedOut = $false
        if (-not $proc.WaitForExit($Secs * 1000)) {
            $timedOut = $true
            # claude.cmd spawns node, so kill the whole tree, not just the shell.
            try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
            $proc.WaitForExit()
        }
        $output = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) + ' ' +
                  [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        $code = if ($timedOut) { 124 } else { $proc.ExitCode }
        return [pscustomobject]@{ ExitCode = $code; Output = $output; TimedOut = $timedOut }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile, $inFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------

Rotate-Log

$claude = Resolve-Claude
if (-not $claude) {
    Write-Log "ERROR claude CLI not found (looked at '$ClaudeBin', PATH, %USERPROFILE%\.local\bin and %APPDATA%\npm)"
    exit 1
}
if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
    Write-Log "ERROR working directory does not exist: $WorkDir"
    exit 1
}

$claudeArgs = @('-p', $Prompt, '--output-format', 'text')
if ($Model) { $claudeArgs += @('--model', $Model) }
if ($ExtraArgs.Count -gt 0) { $claudeArgs += @($ExtraArgs) }

$modelLabel = if ($Model) { $Model } else { 'default' }
Write-Log "=== starting session (cwd=$WorkDir model=$modelLabel claude=$claude) ==="
$null = Wait-ForNetwork

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $result = Invoke-WithTimeout -FilePath $claude -Arguments $claudeArgs -Secs $TimeoutSecs -Cwd $WorkDir
    $response = ($result.Output -replace "`r", '' -replace "`n", ' ').Trim()
    if ($response.Length -gt 500) { $response = $response.Substring(0, 500) }

    if ($result.ExitCode -eq 0) {
        Write-Log "OK  attempt ${attempt}: $response"
        exit 0
    }

    $why = if ($result.TimedOut) { "timed out after ${TimeoutSecs}s" } else { "exit $($result.ExitCode)" }
    Write-Log "FAIL attempt $attempt/$MaxAttempts ($why): $response"
    if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $RetryDelaySecs }
}

Write-Log "ERROR gave up after $MaxAttempts attempts"
exit 1
