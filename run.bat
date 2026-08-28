@echo off
title Diskman - Live Activity Terminal
cd /d "%~dp0"
echo =====================================================================
echo   DISKMAN - C: DRIVE STORAGE CLEANER ^& JUNK PURGER
echo   Real-time activity and deletion logs will stream live below.
echo =====================================================================
echo.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\app.ps1"
echo.
echo =====================================================================
echo   Diskman session ended. Press any key to close this terminal.
echo =====================================================================
pause >nul
