@echo off
title Papers Worker Status - LIVE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0worker_live_status.ps1" -IntervalSeconds 2
echo.
echo Live status closed. Worker sessions were not stopped.
pause
