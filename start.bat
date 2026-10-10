@echo off
REM One click for a fresh clone: builds the Windows installer if there isn't one yet, then runs it.
setlocal
cd /d "%~dp0"

if not exist "dist\WolfLeaderSetup-*.exe" (
    echo No installer in dist\ yet. Building it first, this takes a minute...
    set "WL_NOPAUSE=1"
    call "installer\windows\build.bat" || goto :fail
)

set "SETUP="
for /f "delims=" %%f in ('dir /b /o-d "dist\WolfLeaderSetup-*.exe" 2^>nul') do if not defined SETUP set "SETUP=%%f"
if not defined SETUP goto :fail

echo Starting %SETUP%...
start "" "%~dp0dist\%SETUP%"
exit /b 0

:fail
echo.
echo Could not build or find the installer. Scroll up for the error.
pause
exit /b 1
