@echo off
setlocal

set "NOPAUSE="
if /i "%~1"=="--no-pause" set "NOPAUSE=1"

set "ROOT=%~dp0"
set "DIST=%ROOT%dist"
set "STAGE=%DIST%\RenameEdit"
set "VERSION="
set /p VERSION=<"%ROOT%version.txt"

rem The archive name and the release tag both come from version.txt, so a
rem missing or malformed file stops the run instead of producing a stray name.
if not defined VERSION goto :badversion
echo(%VERSION%| findstr /r /c:"^v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul
if errorlevel 1 goto :badversion

set "ZIP=%DIST%\RenameEdit-%VERSION%.zip"

if exist "%STAGE%" rmdir /s /q "%STAGE%"
if exist "%ZIP%" del /q "%ZIP%"
mkdir "%STAGE%\src"

copy /y "%ROOT%install.cmd" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%uninstall.cmd" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%restore.cmd" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%README.md" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%README_CN.md" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%version.txt" "%STAGE%\" >nul || goto :fail
copy /y "%ROOT%src\common.ps1" "%STAGE%\src\" >nul || goto :fail
copy /y "%ROOT%src\re.ps1" "%STAGE%\src\" >nul || goto :fail
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

:badversion
echo.
echo version.txt is missing or does not look like v1.0.0.
echo.
if not defined NOPAUSE pause
exit /b 1

:fail
echo.
echo Package failed.
echo.
if not defined NOPAUSE pause
exit /b 1
