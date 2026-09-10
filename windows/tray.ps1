<#
tray.ps1 -- Claude Auto Start status icon for the Windows notification area.

The counterpart of the macOS menu bar app. It shows whether the scheduled
session ran, and lets you run it now, retime it, or read the log without
opening a terminal.

It owns no state: everything it shows is read from the scheduled task and the
session log that start-session.ps1 writes, so the tray and the command line
can never disagree.

    powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File .\tray.ps1
    powershell -ExecutionPolicy Bypass -File .\tray.ps1 -SelfTest
#>
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$TaskName     = 'Claude Auto Start'
$TrayTaskName = 'Claude Auto Start Tray'
# %LOCALAPPDATA% is always set on Windows. The fallback exists only so the
# -SelfTest path can be exercised on a non-Windows build machine.
$LocalAppData = $env:LOCALAPPDATA
if (-not $LocalAppData) { $LocalAppData = Join-Path $HOME '.local/share' }
$DataDir      = Join-Path $LocalAppData 'claude-auto-start'
$LogFile      = Join-Path (Join-Path $DataDir 'logs') 'session.log'
$InstallPs1   = Join-Path $ScriptDir 'install.ps1'
$UninstallPs1 = Join-Path $ScriptDir 'uninstall.ps1'

# ---------------------------------------------------------------------------
# Reading the state. Pure, so -SelfTest can exercise it anywhere.
# ---------------------------------------------------------------------------

function Get-RunStatus {
    $s = [pscustomobject]@{
        Kind        = 'never'      # ok | failed | working | never | notScheduled
        Title       = 'No runs yet'
        When        = $null
        Detail      = ''
        NeedsSignIn = $false
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        $s.Kind = 'notScheduled'
        $s.Title = 'Not scheduled'
        $s.Detail = 'The daily job is not registered on this account.'
        return $s
    }

    if (-not (Test-Path -LiteralPath $LogFile)) {
        $s.Detail = 'Nothing has been logged yet.'
        return $s
    }

    $lines = @(Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) {
        $s.Detail = 'Nothing has been logged yet.'
        return $s
    }

    # The CLI's own message, taken from the newest FAIL line.
    $reason = ''
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '^\S+ \S+\s+FAIL .*?\): (.+)$') { $reason = $Matches[1].Trim(); break }
    }

    # The most recent line representing an outcome wins.
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ($line -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s\s(.*)$') { continue }
        $when = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
        $rest = $Matches[2]

        if ($rest -like 'OK*') {
            $s.Kind = 'ok'; $s.Title = 'Last run succeeded'; $s.When = $when
            $s.Detail = ($rest -replace '^OK\s+attempt \d+:\s*', '').Trim()
            if (-not $s.Detail) { $s.Detail = 'Session opened.' }
            return $s
        }
        if ($rest -like 'ERROR*' -or $rest -like 'FAIL*') {
            if ($rest -like 'ERROR*') { $s.Kind = 'failed'; $s.Title = 'Last run failed' }
            else                      { $s.Kind = 'working'; $s.Title = 'Retrying' }
            $s.When = $when
            if ($reason) { $s.Detail = $reason } else { $s.Detail = $rest }
            $low = $s.Detail.ToLower()
            $s.NeedsSignIn = $low.Contains('authenticate') -or $low.Contains('oauth') -or $low.Contains('logged out')
            return $s
        }
        if ($rest -like '===*') {
            $s.Kind = 'working'; $s.Title = 'Running now'; $s.When = $when
            $s.Detail = 'Opening a session.'
            return $s
        }
    }
    return $s
}

function Get-ClaudeBin {
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidates = @()
    if ($env:USERPROFILE) { $candidates += Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
    if ($env:APPDATA)     { $candidates += Join-Path $env:APPDATA 'npm\claude.cmd' }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

# The authoritative answer, straight from the CLI. $null when it cannot be
# asked. The log only says what was true at the last run, and signing in does
# not write a log line, so without this the menu would keep asking you to sign
# in long after you had.
function Test-SignedIn {
    $bin = Get-ClaudeBin
    if (-not $bin) { return $null }
    try {
        $raw = & $bin auth status 2>&1 | Out-String
        $start = $raw.IndexOf('{')
        if ($start -lt 0) { return $null }
        return [bool](($raw.Substring($start) | ConvertFrom-Json).loggedIn)
    } catch { return $null }
}

function Get-ScheduledTimeText {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $t = $task.Triggers | Select-Object -First 1
    if ($t -and $t.StartBoundary) { return ([datetime]$t.StartBoundary).ToString('HH:mm') }
    return $null
}

# One icon per state, built once: recreating them on every refresh would leak
# GDI handles.
function New-StateIcons {
    if (-not ([System.Management.Automation.PSTypeName]'Win32Icon').Type) {
        Add-Type -Namespace '' -Name Win32Icon -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
'@
    }

    # Colours and glyphs for the fallback only. The shipped .ico files are
    # drawn from packaging/icon/make-icons.swift and carry every size Windows
    # asks for, so they are always preferred.
    $palette = @{
        ok           = [System.Drawing.Color]::FromArgb(46, 158, 99)
        failed       = [System.Drawing.Color]::FromArgb(216, 72, 63)
        working      = [System.Drawing.Color]::FromArgb(224, 138, 46)
        never        = [System.Drawing.Color]::FromArgb(116, 130, 154)
        notScheduled = [System.Drawing.Color]::FromArgb(116, 130, 154)
    }
    $glyph = @{ ok = [char]0x2713; failed = '!'; working = [char]0x2026; never = [char]0x2013; notScheduled = '?' }
    $iconDir = Join-Path $ScriptDir 'icons'

    $out = @{}
    foreach ($key in 'ok', 'failed', 'working', 'never', 'notScheduled') {
        $file = Join-Path $iconDir "$key.ico"
        if (Test-Path -LiteralPath $file) {
            try {
                $out[$key] = New-Object System.Drawing.Icon($file)
                continue
            } catch { }
        }

        # A missing or unreadable file must never take the icon away, so draw
        # a plain disc instead.
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

        $brush = New-Object System.Drawing.SolidBrush $palette[$key]
        $g.FillEllipse($brush, 1, 1, 30, 30)

        $font = New-Object System.Drawing.Font 'Segoe UI', 18, ([System.Drawing.FontStyle]::Bold),
            ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF 0, 0, 32, 32
        $g.DrawString([string]$glyph[$key], $font, [System.Drawing.Brushes]::White, $rect, $fmt)

        $handle = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($handle)
        $out[$key] = $icon.Clone()
        [void][Win32Icon]::DestroyIcon($handle)

        $brush.Dispose(); $font.Dispose(); $fmt.Dispose(); $g.Dispose(); $bmp.Dispose()
    }
    return $out
}

# ---------------------------------------------------------------------------
# Self test -- prove the icon and the parsing work without anyone looking.
# ---------------------------------------------------------------------------

if ($SelfTest) {
    Write-Host 'Claude Auto Start tray self test'
    Write-Host '--------------------------------'
    $ok = $true
    $onWindows = $env:OS -eq 'Windows_NT'
    $formsOk = $false
    try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing; $formsOk = $true } catch { }

    try {
        $st = Get-RunStatus
        Write-Host ("state:        {0}" -f $st.Title)
        Write-Host ("when:         {0}" -f $(if ($st.When) { $st.When } else { 'n/a' }))
        Write-Host ("detail:       {0}" -f $(if ($st.Detail) { $st.Detail } else { 'n/a' }))
        Write-Host ("needs signin: {0}" -f $st.NeedsSignIn)
        Write-Host ("schedule:     {0}" -f $(if (Get-ScheduledTimeText) { Get-ScheduledTimeText } else { 'not registered' }))
    } catch {
        Write-Host ("state:        unavailable ({0})" -f $_.Exception.Message.Split([char]10)[0])
        if ($onWindows) { $ok = $false }
    }

    $hasScripts = Test-Path -LiteralPath $InstallPs1
    if (-not $hasScripts) { $ok = $false }
    $bin = Get-ClaudeBin
    Write-Host ("claude cli:   {0}" -f $(if ($bin) { $bin } else { 'NOT FOUND' }))
    $signed = Test-SignedIn
    Write-Host ("signed in:    {0}" -f $(if ($null -eq $signed) { 'could not ask' } elseif ($signed) { 'yes' } else { 'no' }))
    Write-Host ("scripts:      {0}" -f $(if ($hasScripts) { 'present' } else { 'MISSING install.ps1' }))
    Write-Host ("WinForms:     {0}" -f $(if ($formsOk) { 'available' } else { 'not available' }))
    if (-not $formsOk -and $onWindows) { $ok = $false }

    if ($formsOk) {
        try {
            $icons = New-StateIcons
            foreach ($k in 'ok', 'failed', 'working', 'never', 'notScheduled') {
                $drawn = $null -ne $icons[$k]
                if (-not $drawn) { $ok = $false }
                Write-Host ("  icon {0,-13} {1}" -f $k, $(if ($drawn) { 'drawn' } else { 'FAILED' }))
            }
        } catch {
            $ok = $false
            Write-Host ("  icons:      FAILED ({0})" -f $_.Exception.Message)
        }
    }

    Write-Host '--------------------------------'
    if (-not $onWindows) {
        Write-Host 'PARTIAL - scheduler and tray UI can only be checked on Windows'
        exit 0
    }
    Write-Host $(if ($ok) { 'PASS' } else { 'FAIL' })
    exit $(if ($ok) { 0 } else { 1 })
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

# One icon, always. A second copy exits rather than crowding the tray.
$createdMutex = $false
$script:instanceLock = New-Object System.Threading.Mutex($true, 'Local\ClaudeAutoStartTray', [ref]$createdMutex)
if (-not $createdMutex) { exit 0 }

# Hide the console window this script was started from, so no black box lingers.
if (-not ([System.Management.Automation.PSTypeName]'Win32Console').Type) {
    Add-Type -Namespace '' -Name Win32Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
}
$console = [Win32Console]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [void][Win32Console]::ShowWindow($console, 0) }

$Icons = New-StateIcons

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

$script:lastKind = ''

function Add-Label([string]$Text) {
    $i = $menu.Items.Add($Text)
    $i.Enabled = $false
    return $i
}
function Add-Action([string]$Text, [scriptblock]$OnClick) {
    $i = $menu.Items.Add($Text)
    $i.Add_Click($OnClick)
    return $i
}

function Invoke-Scheduled([string]$Verb) {
    switch ($Verb) {
        'run' { Start-ScheduledTask -TaskName $TaskName }
    }
}

function Show-SignIn {
    # A .cmd the user can watch, rather than a hidden process doing auth.
    # It re-runs the job afterwards, because signing in writes no log line and
    # the icon would otherwise stay red until the next morning.
    $bin = Get-ClaudeBin
    if (-not $bin) { $bin = 'claude' }
    $cmd = Join-Path $env:TEMP 'claude-sign-in.cmd'
    @(
        '@echo off'
        'echo Signing in to Claude Code. Finish in the browser window that opens.'
        'echo.'
        ('"{0}" auth login' -f $bin)
        'if errorlevel 1 goto done'
        'echo.'
        'echo Signed in. Opening a session so the tray catches up...'
        ('schtasks /run /tn "{0}" >nul 2>&1' -f $TaskName)
        ':done'
        'echo.'
        'pause'
    ) | Set-Content -LiteralPath $cmd -Encoding ASCII
    Start-Process -FilePath $cmd
}

function Set-RunTime {
    $current = Get-ScheduledTimeText
    if (-not $current) { $current = '07:00' }
    $answer = [Microsoft.VisualBasic.Interaction]::InputBox(
        "When should the Claude session open each day?`r`n" +
        "If the PC is asleep then, it runs as soon as it wakes.",
        'Daily run time', $current)
    if (-not $answer) { return }
    $answer = $answer.Trim()
    if ($answer -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Enter it as HH:MM, for example 06:30.', 'That is not a time',
            'OK', 'Warning')
        return
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 $answer | Out-Null
    Update-Tray
}

function Remove-Schedule {
    $reply = [System.Windows.Forms.MessageBox]::Show(
        "The session will no longer open on its own. The log is kept, and you can schedule it again from this menu.",
        'Remove the daily run?', 'OKCancel', 'Warning')
    if ($reply -ne 'OK') { return }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UninstallPs1 | Out-Null
    Update-Tray
}

function Test-TrayAtLogon {
    return [bool](Get-ScheduledTask -TaskName $TrayTaskName -ErrorAction SilentlyContinue)
}

function Set-TrayAtLogon([bool]$On) {
    if ($On) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -WorkingDirectory $ScriptDir `
            -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f (Join-Path $ScriptDir 'tray.ps1'))
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
        $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TrayTaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force `
            -Description 'Shows the Claude Auto Start status icon in the notification area.' | Out-Null
    } else {
        Unregister-ScheduledTask -TaskName $TrayTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Build-Menu {
    $st = Get-RunStatus
    $menu.Items.Clear()

    $head = Add-Label $st.Title
    $head.Font = New-Object System.Drawing.Font $head.Font, ([System.Drawing.FontStyle]::Bold)
    if ($st.When) { [void](Add-Label $st.When.ToString('ddd d MMM, HH:mm')) }
    if ($st.Detail) {
        $text = $st.Detail
        if ($text.Length -gt 60) { $text = $text.Substring(0, 57) + '...' }
        [void](Add-Label $text)
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    if ($st.NeedsSignIn) {
        if ((Test-SignedIn) -eq $true) {
            # Signed in since that run. Nothing is wrong any more; the log is
            # simply older than the sign in.
            [void](Add-Label 'You are signed in now. Run it once to clear this.')
        } else {
            [void](Add-Action 'Sign in to Claude...' { Show-SignIn })
            [void](Add-Label 'Runs keep failing until you sign in.')
        }
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    if ($st.Kind -eq 'notScheduled') {
        [void](Add-Action 'Schedule Daily Run...' { Set-RunTime })
    } else {
        [void](Add-Action 'Run Now' { Invoke-Scheduled 'run'; Start-Sleep -Milliseconds 1500; Update-Tray })
    }
    [void](Add-Action 'Open Log' {
        if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe $LogFile }
        else { Start-Process explorer.exe (Split-Path -Parent $LogFile) }
    })

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $time = Get-ScheduledTimeText
    if ($time) { [void](Add-Label "Scheduled daily at $time") }
    else       { [void](Add-Label 'No schedule registered') }

    if ($st.Kind -ne 'notScheduled') {
        [void](Add-Action 'Change Time...' { Set-RunTime })
        [void](Add-Action 'Remove Schedule...' { Remove-Schedule })
    }

    $logon = Add-Action 'Start at Logon' {
        Set-TrayAtLogon (-not (Test-TrayAtLogon))
    }
    $logon.Checked = Test-TrayAtLogon

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-Action 'Quit' {
        $notify.Visible = $false
        $notify.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
}

function Update-Tray {
    $st = Get-RunStatus
    $notify.Icon = $Icons[$st.Kind]
    $tip = "Claude Auto Start - " + $st.Title.ToLower()
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }   # Windows caps the tooltip
    $notify.Text = $tip

    # Say something the first time a run goes bad while the icon is up.
    if ($st.Kind -eq 'failed' -and $script:lastKind -ne 'failed') {
        $notify.BalloonTipTitle = 'Claude Auto Start'
        $notify.BalloonTipText = if ($st.NeedsSignIn) {
            'The daily run failed: you are signed out of Claude Code.'
        } else {
            'The daily run failed. Open the log for details.'
        }
        $notify.ShowBalloonTip(8000)
    }
    $script:lastKind = $st.Kind
}

$menu.Add_Opening({ Build-Menu })
$notify.Add_DoubleClick({
    if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe $LogFile }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-Tray })
$timer.Start()

Update-Tray
Build-Menu
[System.Windows.Forms.Application]::Run()
