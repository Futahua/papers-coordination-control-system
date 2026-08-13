@echo off
title Papers Worker Coordination Dashboard
chcp 65001 >nul
rem Local read-only browser dashboard (worker-status + worker-live-feed combined).
rem Binds 127.0.0.1:8765 only. Worker data is never modified.
rem The two existing CMD tools (worker-status.cmd / worker-live-feed.cmd) are untouched.
rem Stop: close the "Papers Dashboard Server" window (Ctrl+C) or use the dashboard's
rem "shutdown" link (/api/shutdown).
set "PY=D:\Letters\MatTroiSeConMoc\HermesAI\.hermes\hermes-agent\venv\Scripts\python.exe"
start "Papers Dashboard Server" "%PY%" -u "%~dp0dashboard\dashboard_server.py"
timeout /t 1 /nobreak >nul
start "" "http://127.0.0.1:8765"
echo Dashboard launched: http://127.0.0.1:8765
echo Close the "Papers Dashboard Server" window to stop it. Worker sessions are not stopped.
