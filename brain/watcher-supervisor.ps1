$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$WatcherPath = Join-Path $Root 'watcher.json'
$SupervisorPath = Join-Path $Root 'watcher-supervisor.json'
$Controller = Join-Path $Root 'brain-control.ps1'
$LogPath = Join-Path $Root 'runs\watcher-supervisor.log'
$LockPath = Join-Path $Root 'brain-run.lock'

function Write-State([string]$State, [string]$LastError = $null) {
  $value = [ordered]@{
    pid = $PID
    startedAt = (Get-Process -Id $PID).StartTime.ToString('o')
    heartbeatAt = [datetimeoffset]::Now.ToString('o')
    state = $State
    lastError = $LastError
  }
  $json = $value | ConvertTo-Json
  [System.IO.File]::WriteAllText($SupervisorPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($WatcherPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

while ($true) {
  try {
    if (Test-Path -LiteralPath $LockPath) {
      Write-State 'WORKING'
    } else {
      # Codex's Windows batch wrapper can exit its PowerShell host after a run.
      # Keep this supervisor alive by placing each deterministic tick in a
      # disposable child process; only a new fingerprint reaches Codex.
      $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Controller), '-Action', 'tick')
      Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory 'D:\' -WindowStyle Hidden | Out-Null
      Write-State 'TICK DISPATCHED'
    }
  } catch {
    "$(Get-Date -Format o) watcher tick error: $($_.Exception.Message)" | Add-Content -LiteralPath $LogPath -Encoding utf8
    Write-State 'ERROR' $_.Exception.Message
  }
  Start-Sleep -Seconds 10
}
