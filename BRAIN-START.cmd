@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0brain\brain-control.ps1" -Action start
pause

