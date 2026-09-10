<#
install.ps1 -- register the daily scheduled task for the current user.

Usage:
    powershell -ExecutionPolicy Bypass -File .\install.ps1               # 07:00 daily
    powershell -ExecutionPolicy Bypass -File .\install.ps1 06:30         # any HH:MM
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -WakeToRun    # also wake the PC from sleep

No administrator rights are needed: the task is registered in your own account
and runs only while you are logged on, which is where Claude Code's credentials
live.

Why the deploy step: it mirrors the macOS version. The task runs a copy under
%LOCALAPPDATA%\claude-auto-start, so the repo can be moved, deleted, or live on
a synced drive without breaking the schedule. Re-run this script after editing
start-session.ps1 or config.local.ps1 to sync the copy.
#>
param(
    [Parameter(Position = 0)]
    [string]$Time = '07:00',
    [switch]$WakeToRun,
    # Install the daily job only, with no status icon in the notification area.
    [switch]$NoTray
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName  = 'Claude Auto Start'
$DeployDir = Join-Path $env:LOCALAPPDATA 'claude-auto-start'
$LogDir    = Join-Path $DeployDir 'logs'

if ($Time -notmatch '^(\d{1,2}):(\d{2})$') { throw "time must be HH:MM (got '$Time')" }
$Hour   = [int]$Matches[1]
$Minute = [int]$Matches[2]
if ($Hour -gt 23 -or $Minute -gt 59) { throw "'$Time' is not a valid time of day" }

$Source = Join-Path $ScriptDir 'start-session.ps1'
if (-not (Test-Path -LiteralPath $Source)) { throw "missing $Source" }
if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    throw 'the ScheduledTasks module is not available; this needs Windows 8 / Server 2012 or later'
}

New-Item -ItemType Directory -Force -Path $DeployDir, $LogDir | Out-Null

$Script = Join-Path $DeployDir 'start-session.ps1'
Copy-Item -LiteralPath $Source -Destination $Script -Force

# Everything the tray needs lives beside the worker, so the icon keeps working
# even if the folder it was installed from is deleted.
if ((Resolve-Path $ScriptDir).Path -ne (Resolve-Path $DeployDir).Path) {
    foreach ($name in 'tray.ps1', 'install.ps1', 'uninstall.ps1', 'status.ps1', 'config.example.ps1') {
        $from = Join-Path $ScriptDir $name
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination (Join-Path $DeployDir $name) -Force
        }
    }
    $iconsFrom = Join-Path $ScriptDir 'icons'
    if (Test-Path -LiteralPath $iconsFrom) {
        Copy-Item -LiteralPath $iconsFrom -Destination (Join-Path $DeployDir 'icons') -Recurse -Force
    }
}

$LocalConfig = Join-Path $ScriptDir 'config.local.ps1'
$DeployedConfig = Join-Path $DeployDir 'config.local.ps1'
if (Test-Path -LiteralPath $LocalConfig) {
    Copy-Item -LiteralPath $LocalConfig -Destination $DeployedConfig -Force
    Write-Host 'Deployed config.local.ps1'
} else {
    Remove-Item -LiteralPath $DeployedConfig -Force -ErrorAction SilentlyContinue
}

# Windows PowerShell 5.1 ships with every supported Windows, so the task does
# not depend on PowerShell 7 being installed or on its location.
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Action = New-ScheduledTaskAction -Execute $PsExe -WorkingDirectory $DeployDir `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""

$At = (Get-Date).Date.AddHours($Hour).AddMinutes($Minute)
$Trigger = New-ScheduledTaskTrigger -Daily -At $At

# StartWhenAvailable is the launchd-like part: if the PC was asleep or off at
# the scheduled time, the task runs as soon as it is back and you are logged on.
# The script's own worst case (network wait + 5 attempts) is under 30 minutes,
# so a 1 hour execution limit only catches a wedged process.
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun:$WakeToRun `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

# Interactive = "run only when the user is logged on", the counterpart of
# launchd's LimitLoadToSessionType=Aqua. No password is stored anywhere.
$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Settings $Settings -Principal $Principal -Force `
    -Description 'Opens a Claude Code session every morning (auto-start-session).' | Out-Null

# ---------------------------------------------------------------------------
# The status icon. Registered as its own logon task so it comes back with the
# desktop, and started now so the user sees something the moment setup ends.
# ---------------------------------------------------------------------------

$TrayTaskName = 'Claude Auto Start Tray'
$TrayScript = Join-Path $DeployDir 'tray.ps1'
$trayNote = 'not installed'

if (-not $NoTray -and (Test-Path -LiteralPath $TrayScript)) {
    $TrayAction = New-ScheduledTaskAction -Execute $PsExe -WorkingDirectory $DeployDir `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TrayScript`""
    $TrayTrigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    # No execution time limit: this one is meant to stay up all day.
    $TraySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TrayTaskName -Action $TrayAction -Trigger $TrayTrigger `
        -Settings $TraySettings -Principal $Principal -Force `
        -Description 'Shows the Claude Auto Start status icon in the notification area.' | Out-Null

    Start-ScheduledTask -TaskName $TrayTaskName -ErrorAction SilentlyContinue
    $trayNote = 'running now, and at every logon'
} elseif ($NoTray) {
    Unregister-ScheduledTask -TaskName $TrayTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $trayNote = 'skipped (-NoTray)'
}

$wake = if ($WakeToRun) { ' (wakes the PC)' } else { '' }
Write-Host ''
Write-Host "Installed scheduled task '$TaskName'"
Write-Host ('Schedule:  {0:D2}:{1:D2} local time, every day{2}' -f $Hour, $Minute, $wake)
Write-Host "Runs:      $Script"
Write-Host "Log:       $LogDir\session.log"
Write-Host "Status icon: $trayNote"
Write-Host ''
Write-Host "Test it now:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host 'Check state:  powershell -ExecutionPolicy Bypass -File .\status.ps1'
