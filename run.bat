@echo off
title Diskman - Live Activity Terminal
cd /d "%~dp0"

:: Check for Administrator elevation
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo =====================================================================
    echo   DISKMAN - Requesting Administrator Privileges...
    echo =====================================================================
    echo.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -STA -ExecutionPolicy Bypass -File \"\"%~dp0src\app.ps1\"\"' -Verb RunAs"
    exit /b
)

echo =====================================================================
echo   DISKMAN - C: DRIVE STORAGE CLEANER ^& JUNK PURGER (Elevated Admin)
echo   Real-time activity and deletion logs will stream live below.
echo =====================================================================
echo.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\app.ps1"
echo.
echo =====================================================================
echo   Diskman session ended. Press any key to close this terminal.
echo =====================================================================
pause >nul
