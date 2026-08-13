@echo off
setlocal
set "BRAIN_ROOT=%~dp0"
set "BRAIN_LOG=%~dp0runs\watcher-supervisor.log"

:tick
echo [%DATE% %TIME%] watcher tick>> "%BRAIN_LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BRAIN_ROOT%brain-control.ps1" -Action tick >> "%BRAIN_LOG%" 2>&1
timeout /t 10 /nobreak >nul
goto tick
