@echo off
setlocal EnableExtensions
title Claude Auto Start - Setup
REM ---------------------------------------------------------------------------
REM  Claude Auto Start __VERSION__ -- single-file installer for Windows.
REM
REM  Double-click to install with the default 07:00 schedule, or run from a
REM  terminal with options that are passed straight to install.ps1:
REM      ClaudeAutoStart-Setup.cmd 06:30
REM      ClaudeAutoStart-Setup.cmd -WakeToRun
REM
REM  The scripts are embedded below as a base64 zip. They are extracted to
REM  %LOCALAPPDATA%\claude-auto-start\src and install.ps1 is run from there.
REM  No administrator rights are needed.
REM ---------------------------------------------------------------------------
set "SELF=%~f0"
set "TARGET=%LOCALAPPDATA%\claude-auto-start\src"
echo.
echo  Claude Auto Start __VERSION__
echo  Extracting to %TARGET% ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$lines = [IO.File]::ReadAllLines($env:SELF);" ^
  "$start = [array]::IndexOf($lines, '::PAYLOAD-BEGIN') + 1;" ^
  "$end = [array]::IndexOf($lines, '::PAYLOAD-END');" ^
  "if ($start -lt 1 -or $end -lt $start) { throw 'installer payload is missing or damaged' };" ^
  "$b64 = -join ($lines[$start..($end - 1)] | ForEach-Object { $_.Substring(2) });" ^
  "$zip = Join-Path $env:TEMP 'claude-auto-start-payload.zip';" ^
  "[IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64));" ^
  "if (Test-Path -LiteralPath $env:TARGET) { Remove-Item -LiteralPath $env:TARGET -Recurse -Force };" ^
  "New-Item -ItemType Directory -Force -Path $env:TARGET | Out-Null;" ^
  "Expand-Archive -LiteralPath $zip -DestinationPath $env:TARGET -Force;" ^
  "Remove-Item -LiteralPath $zip -Force;" ^
  "& (Join-Path $env:TARGET 'install.ps1')" %*
if errorlevel 1 (
  echo.
  echo  Setup did not complete. The messages above say why.
  echo  You can retry by running: "%TARGET%\install.ps1"
) else (
  echo.
  echo  Done. Uninstall any time with: "%TARGET%\uninstall.ps1"
)
echo.
pause
exit /b
