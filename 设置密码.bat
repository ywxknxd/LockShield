@echo off
rem ============================================================
rem  Set or change the shield password.
rem  (Filename is Chinese, content is pure ASCII on purpose:
rem   cmd reads .bat as GBK, Chinese text here would garble.)
rem ============================================================
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0lock-shield.ps1" -SetPassword
set RC=%errorlevel%
echo.
if "%RC%"=="0" (
    echo Password saved. Double-click the lock bat to use it.
) else (
    echo [failed, exit code %RC%]
)
pause
endlocal
