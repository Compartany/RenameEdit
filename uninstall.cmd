@echo off
setlocal

rem findstr, not "%VAR:--no-pause=%": an undefined value expands to "--no-pause=".
set "ATPAUSE=1"
set "ARGS=%*"
echo(%ARGS%| findstr /i /c:"--no-pause" >nul
if not errorlevel 1 set "ATPAUSE="

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\install.ps1" -Uninstall
set "CODE=%ERRORLEVEL%"

if not defined ATPAUSE exit /b %CODE%

echo.
pause
exit /b %CODE%
