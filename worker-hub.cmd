@echo off
title Papers Worker Coordination Hub
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0worker-hub.ps1"
if errorlevel 1 (
  echo.
  echo Worker hub exited with an error.
  pause
)
