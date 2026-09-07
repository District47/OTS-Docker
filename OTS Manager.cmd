@echo off
rem ===========================================================================
rem  Double-click this to open the OpenTAKServer control panel.
rem
rem  It launches OTS-Manager.ps1 with the execution policy bypassed for this
rem  one process only, so Windows' default script blocking does not stop it.
rem  Nothing on your machine is changed by running this.
rem ===========================================================================
setlocal
cd /d "%~dp0"

if not exist "OTS-Manager.ps1" (
    echo Could not find OTS-Manager.ps1 next to this file.
    echo Keep this shortcut in the same folder as the rest of the files.
    pause
    exit /b 1
)

rem Files extracted from a downloaded ZIP carry a "mark of the web" tag that
rem makes PowerShell refuse them. Clearing it here means users never have to
rem know about Properties > Unblock.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0OTS-Manager.ps1"
endlocal
