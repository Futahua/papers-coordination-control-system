param(
  [ValidateRange(1, 30)]
  [int]$IntervalSeconds = 2
)

$ErrorActionPreference = 'Continue'
$Hub = Join-Path $PSScriptRoot 'worker-hub.ps1'
$BrainRoot = Join-Path $PSScriptRoot 'brain'
$UsageRefresh = Join-Path $BrainRoot 'refresh-usage.ps1'
$BudgetPath = Join-Path $BrainRoot 'budget.json'
$WavePath = Join-Path $BrainRoot 'wave.json'
$CheckpointPath = Join-Path $BrainRoot 'brain-checkpoint.md'
$ControllerStatePath = Join-Path $BrainRoot 'controller-state.json'
$WatcherPath = Join-Path $BrainRoot 'watcher.json'
$BrainLockPath = Join-Path $BrainRoot 'brain-run.lock'
$RunsPath = Join-Path $BrainRoot 'runs'
$lastBody = $null
$lastLineCount = 0
$lastPingReason = $null
$nextUsageRefresh = [datetime]::MinValue

function Read-JsonSafe([string]$Path) {
  try {
    if (Test-Path -LiteralPath $Path) {
      return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
  } catch {}
  return $null
}

function Get-BrainPanel {
  $budget = Read-JsonSafe $BudgetPath
  $wave = Read-JsonSafe $WavePath
  $controller = Read-JsonSafe $ControllerStatePath
  $watcher = Read-JsonSafe $WatcherPath
  $checkpoint = if (Test-Path -LiteralPath $CheckpointPath) {
    Get-Content -LiteralPath $CheckpointPath -Raw -Encoding utf8
  } else { '' }

  $watcherAlive = $false
  if ($null -ne $watcher -and $null -ne $watcher.pid) {
    $watcherAlive = $null -ne (Get-Process -Id ([int]$watcher.pid) -ErrorAction SilentlyContinue)
  }
  if ($null -ne $watcher -and $watcher.scheduler -eq $true -and $null -ne $watcher.heartbeatAt) {
    try {
      $heartbeatAge = [datetimeoffset]::Now - [datetimeoffset]::Parse([string]$watcher.heartbeatAt)
      $watcherAlive = $heartbeatAge.TotalSeconds -lt 240
    } catch {}
  }
  $brainBusy = Test-Path -LiteralPath $BrainLockPath
  if ($brainBusy) { $watcherAlive = $true }
  $watcherDetail = if ($null -ne $watcher.state) { [string]$watcher.state } else { 'UNKNOWN' }
  $incompleteClaim = $false
  if ($null -ne $controller -and $null -eq $controller.lastCompletedFingerprint -and
      $null -ne $controller.lastAttemptFingerprint -and $null -ne $controller.lastAttemptAt) {
    try {
      # Do not call a newly-started or mechanically recoverable run an error.
      $incompleteClaim = (([datetimeoffset]::Now - [datetimeoffset]::Parse([string]$controller.lastAttemptAt)).TotalMinutes -ge 5)
    } catch {}
  }
  $brainState = if ($brainBusy) { "WORKING - Codex decision in progress ($watcherDetail)" }
    elseif ($incompleteClaim) { 'ERROR - last CLI BRAIN claim did not complete; Manager retry required' }
    elseif ($watcherAlive -and $watcherDetail -eq 'ERROR') { "ERROR - $($watcher.lastError)" }
    elseif ($watcherAlive -and $watcherDetail -eq 'INVOKING') { 'CLAIMING - decision event detected' }
    elseif ($watcherAlive) { 'WATCHING - waiting mechanically for an event' }
    else { 'STOPPED - completion events will not be handled' }

  $action = 'none'
  if ($checkpoint -match '(?im)^Creator action(?: needed)?:\s*(.+?)\s*$') {
    $action = $Matches[1].Trim().TrimEnd([char]0x00A0)
  }
  $needsDesktop = -not [string]::IsNullOrWhiteSpace($action) -and
    $action -match '^PING DESKTOP MANAGER NOW\b'
  $ping = if ($needsDesktop) {
    "*** PING DESKTOP MANAGER NOW ***`nReason: $action"
  } elseif (-not $watcherAlive) {
    'ATTENTION: CLI BRAIN watcher is stopped.'
  } else {
    'Desktop Manager: no conversation needed yet.'
  }

  $usage = 'Usage: UNSET'
  if ($null -ne $budget -and $null -ne $budget.remainingPercent -and $null -ne $budget.resetAt) {
    $now = [datetimeoffset]::Now
    $reset = [datetimeoffset]::Parse([string]$budget.resetAt)
    $days = [Math]::Max(1.0 / 24.0, ($reset - $now).TotalDays)
    $usable = [Math]::Max(0.0, [double]$budget.remainingPercent - [double]$budget.reservePercent)
    $pace = $usable / $days
    $observed = if ($null -ne $budget.observedAt) {
      [datetimeoffset]::Parse([string]$budget.observedAt)
    } else {
      [datetimeoffset]::Parse([string]$budget.updatedAt)
    }
    $age = $now - $observed
    $freshness = if ($age.TotalMinutes -ge 2) { 'TELEMETRY STALE - check Codex usage UI or /status' }
      else { 'live local session telemetry' }
    $stamp = Get-Date -Format 'yyyyMMdd'
    $runs = @(Get-ChildItem -LiteralPath $RunsPath -Filter "$stamp-*-gpt-5.6-*.log" -File -ErrorAction SilentlyContinue)
    $sol = @($runs | Where-Object { $_.Name -like '*gpt-5.6-sol*' }).Count
    $usage = ("Usage telemetry: {0:N1}% left | reserve {1:N1}% | safe pace {2:N1}%/day | reset {3:yyyy-MM-dd HH:mm}`n" +
      'Telemetry: {4} ({5:N0}m old) | controller runs today {6} (informational), Sol decisions {7}') -f 
      [double]$budget.remainingPercent, [double]$budget.reservePercent, $pace, $reset.LocalDateTime,
      $freshness, $age.TotalMinutes, $runs.Count, $sol
  }

  $lastDecision = if ($null -ne $controller -and $null -ne $controller.lastCompletedAt) {
    "Last CLI BRAIN completion: $($controller.lastCompletedAt) via $($controller.model)"
  } else { 'Last CLI BRAIN completion: none recorded' }
  $waveText = if ($null -ne $wave) { "Wave: $($wave.waveId) [$($wave.status)]" } else { 'Wave: unknown' }

  return [pscustomobject]@{
    Text = "$ping`n`nCLI BRAIN: $brainState`n$waveText`n$lastDecision`n$usage"
    PingReason = if ($needsDesktop) { $action } else { $null }
  }
}

try {
  [Console]::CursorVisible = $false
  while ($true) {
    try {
      if ((Get-Date) -ge $nextUsageRefresh) {
        try { & $UsageRefresh *> $null } catch {}
        $nextUsageRefresh = (Get-Date).AddSeconds(30)
      }
      $workers = (& $Hub -Action status 6>&1 | Out-String).TrimEnd()
      $brain = Get-BrainPanel
      $body = "$($brain.Text)`n`n$workers"
      if ($null -ne $brain.PingReason -and $brain.PingReason -ne $lastPingReason) {
        try {
          $notification = 'C:\Windows\Media\Windows Notify System Generic.wav'
          if (Test-Path -LiteralPath $notification) {
            [System.Media.SoundPlayer]::new($notification).Play()
          } else {
            [System.Media.SystemSounds]::Asterisk.Play()
          }
        } catch {}
      }
      $lastPingReason = $brain.PingReason
    } catch {
      $body = "Status refresh failed: $($_.Exception.Message)"
    }
    # Poll continuously but repaint only when state/report data changes. This
    # avoids the full-console Clear-Host flash that made the old dashboard blink.
    if ($body -ne $lastBody) {
      $header = "PAPERS WORKER STATUS - LIVE`nPolling every ${IntervalSeconds}s; redraws only on change. Ctrl+C closes status only.`n"
      $lines = @((($header + "`n" + $body) -split "`r?`n"))
      $width = [Math]::Max(20, [Console]::WindowWidth - 1)
      [Console]::SetCursorPosition(0, 0)
      $lineCount = [Math]::Max($lastLineCount, $lines.Count)
      for ($index = 0; $index -lt $lineCount; $index += 1) {
        $line = if ($index -lt $lines.Count) { [string]$lines[$index] } else { '' }
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
        [Console]::Write($line.PadRight($width))
        if ($index -lt $lineCount - 1) { [Console]::WriteLine() }
      }
      $lastBody = $body
      $lastLineCount = $lines.Count
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
} finally {
  try { [Console]::CursorVisible = $true } catch {}
}
