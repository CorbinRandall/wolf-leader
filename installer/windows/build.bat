@echo off
REM Builds dist\WolfLeaderSetup-<version>.exe from this repo.
REM   installer\windows\build.bat [version]
REM Version defaults to the newest git tag (v0.2.1 -> 0.2.1). Installs Inno Setup with winget if missing.
setlocal
cd /d "%~dp0"

set "VER=%~1"
if "%VER%"=="" for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "$t = git -C '%~dp0..\..' describe --tags --abbrev=0 2>$null; if ($t -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { '0.0.0' }"`) do set "VER=%%v"
if "%VER%"=="" set "VER=0.0.0"

echo Building the Wolf Leader installer, version %VER%...
call :findiscc
if not defined ISCC (
    echo Inno Setup not found. Installing it with winget...
    echo If nothing happens for a while, look for a Windows permission prompt behind this window.
    winget install -e --id JRSoftware.InnoSetup --silent --accept-package-agreements --accept-source-agreements
    call :findiscc
)
if not defined ISCC (
    echo.
    echo Could not find or install Inno Setup 6. Install it from https://jrsoftware.org/isdl.php
    echo and run this again.
    goto :err
)

"%ISCC%" /Qp /DAppVersion=%VER% "%~dp0WolfLeader.iss" || goto :err

echo.
echo Done: %~dp0..\..\dist\WolfLeaderSetup-%VER%.exe
if not defined WL_NOPAUSE pause
exit /b 0

:findiscc
set "ISCC="
for %%p in ("%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" "%ProgramFiles%\Inno Setup 6\ISCC.exe") do (
    if not defined ISCC if exist "%%~p" set "ISCC=%%~p"
)
if not defined ISCC for /f "delims=" %%p in ('where ISCC.exe 2^>nul') do if not defined ISCC set "ISCC=%%p"
exit /b 0

:err
echo.
echo Build failed. See the errors above.
if not defined WL_NOPAUSE pause
exit /b 1
