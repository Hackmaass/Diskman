@echo off
title Launching Diskman...
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\app.ps1"
