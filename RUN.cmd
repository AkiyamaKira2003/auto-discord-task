@echo off
setlocal
title Audisk by Kiraa - Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
set "AUDISK_EXIT=%ERRORLEVEL%"
if not "%AUDISK_EXIT%"=="0" (
    echo.
    echo Audisk setup exited with code %AUDISK_EXIT%.
    pause
)
exit /b %AUDISK_EXIT%
