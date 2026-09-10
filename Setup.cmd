@echo off
rem ===========================================================================
rem  Double-click this to install OpenTAKServer.
rem
rem  Most people should use "OTS Manager.cmd" instead - it is the same thing
rem  with buttons. This runs the same setup in a console window for anyone who
rem  prefers to watch the text scroll past.
rem
rem  Do NOT run setup.ps1 directly from a downloaded folder: Windows marks
rem  downloaded files as untrusted and PowerShell refuses them. This wrapper
rem  clears that mark first, which is the whole reason it exists.
rem ===========================================================================
setlocal
cd /d "%~dp0"

if not exist "setup.ps1" (
    echo Could not find setup.ps1 next to this file.
    echo Keep this file in the same folder as the rest of the download.
    pause
    exit /b 1
)

echo Clearing the "downloaded from the internet" mark...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*

echo.
pause
endlocal
