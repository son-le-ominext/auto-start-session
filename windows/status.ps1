<#
status.ps1 -- is the task registered, and what happened on the last run?
#>

$ErrorActionPreference = 'Continue'

$TaskName  = 'Claude Auto Start'
$DeployDir = Join-Path $env:LOCALAPPDATA 'claude-auto-start'
$LogDir    = Join-Path $DeployDir 'logs'
$LogFile   = Join-Path $LogDir 'session.log'

function Describe-Result([uint32]$Code) {
    switch ($Code) {
        0          { 'ok' }
        1          { 'script reported failure -- see the log below' }
        267009     { 'currently running' }              # 0x41301
        267011     { 'has not run yet' }                # 0x41303
        267014     { 'terminated by the scheduler' }    # 0x41306
        2147750687 { 'skipped: user was not logged on' } # 0x800710E0
        default    { 'see the Task Scheduler history' }
    }
}

Write-Host '--- schedule ---'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $trigger = $task.Triggers | Select-Object -First 1
    if ($trigger -and $trigger.StartBoundary) {
        Write-Host ('daily at {0:HH:mm}' -f [datetime]$trigger.StartBoundary)
    }
    $info = $task | Get-ScheduledTaskInfo
    Write-Host "state:       $($task.State)"
    Write-Host "next run:    $($info.NextRunTime)"
    Write-Host "last run:    $($info.LastRunTime)"
    Write-Host ('last result: {0} ({1})' -f $info.LastTaskResult, (Describe-Result $info.LastTaskResult))
} else {
    Write-Host "not installed (no scheduled task named '$TaskName')"
}

Write-Host ''
Write-Host '--- deployed script ---'
$deployed = Join-Path $DeployDir 'start-session.ps1'
if (Test-Path -LiteralPath $deployed) {
    Get-Item -LiteralPath $deployed | Select-Object LastWriteTime, Length, FullName | Format-List | Out-String -Width 200 | Write-Host
    if (Test-Path -LiteralPath (Join-Path $DeployDir 'config.local.ps1')) {
        Write-Host 'config.local.ps1: deployed'
    } else {
        Write-Host 'config.local.ps1: none (using built-in defaults)'
    }
} else {
    Write-Host 'not deployed -- run install.ps1'
}

Write-Host ''
Write-Host '--- last 15 log lines ---'
if (Test-Path -LiteralPath $LogFile) {
    Get-Content -LiteralPath $LogFile -Tail 15
} else {
    Write-Host "no runs logged yet ($LogFile)"
}
