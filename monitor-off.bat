@echo off
rem ============================================================
rem  monitor-off.bat - turn the display off right now.
rem  Nothing sleeps, nothing stops. Move the mouse to come back.
rem
rem  Usage:
rem    monitor-off.bat                  turn off immediately
rem    monitor-off.bat -Delay 300       turn off in 5 minutes
rem    monitor-off.bat -Lock            turn off and lock the PC
rem ============================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor-off.ps1" %*
if errorlevel 1 (
    echo.
    echo [FAILED] exit code %errorlevel%
    pause
)
endlocal
