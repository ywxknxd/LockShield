@echo off
rem ============================================================
rem  Toggle the shield password on / off.
rem
rem  ON  (default) : double-click lock-shield.bat -> screen goes
rem                  black, coming back asks for the password.
rem  OFF           : double-click lock-shield.bat -> only turns
rem                  the display off, no password needed.
rem                  (The password itself is kept, just ignored.)
rem
rem  Run this bat again to switch back. Current state is printed.
rem ============================================================
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0lock-shield.ps1" -Toggle
set RC=%errorlevel%
echo.
if not "%RC%"=="0" (
    echo [failed, exit code %RC%]
)
pause
endlocal
