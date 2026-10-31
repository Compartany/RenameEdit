@echo off
setlocal

set "NOPAUSE="
if /i "%~1"=="--no-pause" set "NOPAUSE=1"

set "ROOT=%~dp0"
set "DIST=%ROOT%dist"
set "STAGE=%DIST%\NameEdit"
set "ZIP=%DIST%\NameEdit.zip"

if exist "%STAGE%" rmdir /s /q "%STAGE%"
if exist "%ZIP%" del /q "%ZIP%"
mkdir "%STAGE%\src"

copy /y "%ROOT%install.cmd" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%uninstall.cmd" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%restore.cmd" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%README.md" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%README_CN.md" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%src\common.ps1" "%STAGE%\src\" >nul || goto :fail
copy /y "%ROOT%src\ne.ps1" "%STAGE%\src\" >nul || goto :fail
copy /y "%ROOT%src\install.ps1" "%STAGE%\src\" >nul || goto :fail
copy /y "%ROOT%src\restore.ps1" "%STAGE%\src\" >nul || goto :fail

powershell -NoProfile -Command "Compress-Archive -LiteralPath '%STAGE%' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 goto :fail

rmdir /s /q "%STAGE%"

echo.
echo Created:
echo   %ZIP%
echo.
if not defined NOPAUSE pause
exit /b 0

:fail
echo.
echo Package failed.
echo.
if not defined NOPAUSE pause
exit /b 1
