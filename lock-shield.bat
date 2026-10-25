@echo off
rem ============================================================
rem  lock-shield.bat - full-screen lock overlay + monitor off.
rem  Password is YOUR OWN, stored in shield.config.json.
rem
rem  Just double-click it:
rem    - first time  -> it walks you through setting a password
rem    - after that  -> it locks the screen immediately
rem
rem  To change the password later, use the "set password" bat
rem  (the one with the Chinese filename) in the same folder.
rem
rem  Optional command-line flags:
rem    -SetPassword     same as the set-password bat
rem    -Test            show the overlay without turning the display off
rem
rem  NOTE: this is a cosmetic shield, NOT real security.
rem        Ctrl+Alt+Del can kill it. Use Win+L for real locking.
rem ============================================================
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0lock-shield.ps1" %*
set RC=%errorlevel%
if not "%RC%"=="0" (
    echo.
    echo [exit code %RC%]
    pause
)
endlocal
