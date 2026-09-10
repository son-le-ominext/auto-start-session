<#
uninstall.ps1 -- remove the scheduled task. The deployed copy and logs are kept.
#>

$ErrorActionPreference = 'Stop'

$TaskName  = 'Claude Auto Start'
$DeployDir = Join-Path $env:LOCALAPPDATA 'claude-auto-start'

foreach ($name in $TaskName, 'Claude Auto Start Tray') {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "Removed scheduled task '$name'"
    } else {
        Write-Host "'$name' was not registered"
    }
}

# The icon itself is a running process; ask it to go away too.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*tray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "Deployed copy and logs kept at $DeployDir"
