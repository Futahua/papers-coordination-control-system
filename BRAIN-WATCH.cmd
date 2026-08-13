@echo off
title Account B CLI BRAIN Watcher
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0brain\brain-control.ps1" -Action watch
echo.
echo Watcher closed. Workers were not stopped.
pause
