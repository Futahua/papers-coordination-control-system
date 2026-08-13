@echo off
title Papers Workers + CLI BRAIN Live Feed
chcp 65001 >nul
"D:\Letters\MatTroiSeConMoc\HermesAI\.hermes\hermes-agent\venv\Scripts\python.exe" -u "%~dp0worker_live_feed.py"
echo.
echo Feed exited. Worker sessions were not stopped.
pause
