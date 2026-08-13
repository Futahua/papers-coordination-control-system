param(
  [ValidateSet('menu', 'status', 'refresh', 'send', 'inbox', 'ack', 'wake')]
  [string]$Action = 'menu',
  [string]$From,
  [string]$To,
  [ValidateSet('info', 'blocker', 'evidence-request', 'handoff', 'conflict', 'help')]
  [string]$Kind = 'info',
  [string]$Message,
  [string]$Id
)

$ErrorActionPreference = 'Stop'
$RegistryPath = Join-Path $PSScriptRoot 'worker-registry.json'
$WavePath = Join-Path $PSScriptRoot 'brain\wave.json'
$MailboxPath = Join-Path $PSScriptRoot 'worker-mailbox.jsonl'
$BridgePath = "D:\Letters\MatTroiSeConMoc\Papers\Backpack projects\As you Go\BRAIN-WORKER.txt"
$UpdaterPath = 'D:\Programs\evTEMP\opencode\dbcopy\update_reasoning_logs.py'
$PythonPath = 'D:\Letters\MatTroiSeConMoc\HermesAI\.hermes\hermes-agent\venv\Scripts\python.exe'

function Get-Registry {
  return Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
}

function Resolve-Worker([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Worker name is required.' }
  $key = $Name.Trim().ToLowerInvariant()
  $registry = Get-Registry
  $property = $registry.PSObject.Properties | Where-Object { $_.Name -eq $key } | Select-Object -First 1
  if ($null -eq $property) { throw "Unknown worker '$Name'. Use BRAIN, Winter, Gazelle, RoketPuncha, or Ning." }
  return [pscustomobject]@{ Key = $key; Value = $property.Value }
}

function Add-MailEvent($Event) {
  $line = ($Event | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine
  $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
  $stream = [System.IO.File]::Open($MailboxPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $stream.Lock(0, [long]::MaxValue)
    [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    try { $stream.Unlock(0, [long]::MaxValue) } catch {}
    $stream.Dispose()
  }
}

function Get-MailEvents {
  if (-not (Test-Path -LiteralPath $MailboxPath)) { return @() }
  $events = @()
  foreach ($line in Get-Content -LiteralPath $MailboxPath) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $events += ($line | ConvertFrom-Json) } catch { Write-Warning "Ignored malformed mailbox line: $line" }
  }
  return $events
}

function Get-PendingPings([string]$Recipient) {
  $events = @(Get-MailEvents)
  $acked = @{}
  foreach ($event in $events) {
    if ($event.event -eq 'ack') { $acked[[string]$event.pingId] = $true }
  }
  $pings = @($events | Where-Object {
    $_.event -eq 'ping' -and -not $acked.ContainsKey([string]$_.id)
  })
  if (-not [string]::IsNullOrWhiteSpace($Recipient)) {
    $key = (Resolve-Worker $Recipient).Key
    $pings = @($pings | Where-Object { ([string]$_.to).ToLowerInvariant() -in @($key, 'all') })
  }
  return $pings
}

function Refresh-Logs {
  if (-not (Test-Path -LiteralPath $UpdaterPath)) { throw "Updater not found: $UpdaterPath" }
  if (-not (Test-Path -LiteralPath $PythonPath)) { throw "Python runtime not found: $PythonPath" }
  Push-Location (Split-Path -Parent $UpdaterPath)
  try { & $PythonPath $UpdaterPath } finally { Pop-Location }
  Write-Host ''
  Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.log' -File |
    Sort-Object Name |
    Select-Object Name, Length, LastWriteTime |
    Format-Table -AutoSize
}

function Show-WorkerStatus {
  $registry = Get-Registry
  $wave = if (Test-Path -LiteralPath $WavePath) {
    Get-Content -LiteralPath $WavePath -Raw -Encoding utf8 | ConvertFrom-Json
  } else { $null }
  $processes = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'opencode.exe' })
  $rows = @()
  foreach ($property in $registry.PSObject.Properties) {
    if ($property.Name -eq 'brain') { continue }
    $worker = $property.Value
    $laneProperty = if ($null -ne $wave -and $null -ne $wave.workers) {
      $wave.workers.PSObject.Properties | Where-Object { $_.Name -eq $property.Name } | Select-Object -First 1
    } else { $null }
    $lane = if ($null -ne $laneProperty) { $laneProperty.Value } else { $null }
    $inWave = $null -ne $lane -and $lane.active -eq $true
    $active = @($processes | Where-Object { $_.CommandLine -like "*$($worker.sessionId)*" }).Count -gt 0
    $currentReport = if ($inWave) { [string]$lane.report } else { $null }
    $reportPath = if ([string]::IsNullOrWhiteSpace($currentReport)) { $null } else { Join-Path $PSScriptRoot $currentReport }
    $reportBytes = if ($null -ne $reportPath -and (Test-Path -LiteralPath $reportPath)) { (Get-Item -LiteralPath $reportPath).Length } else { 0 }
    $activity = @()
    $dispatchDir = Join-Path $PSScriptRoot "workers\$($property.Name)\dispatch"
    if (Test-Path -LiteralPath $dispatchDir) { $activity += @(Get-ChildItem -LiteralPath $dispatchDir -File -ErrorAction SilentlyContinue) }
    if ($null -ne $reportPath -and (Test-Path -LiteralPath $reportPath)) { $activity += Get-Item -LiteralPath $reportPath }
    $latestActivity = $activity | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $idleMinutes = if ($null -ne $latestActivity) { ((Get-Date) - $latestActivity.LastWriteTime).TotalMinutes } else { $null }
    $stalled = $inWave -and $active -and $reportBytes -eq 0 -and $null -ne $idleMinutes -and $idleMinutes -ge 30
    $state = if (-not $inWave) { 'STANDBY' } elseif ($stalled) { 'STALLED - BRAIN REVIEW' } elseif ($active -and $reportBytes -gt 0) { 'WORKING (draft written)' } elseif ($active) { 'WORKING' } elseif ($reportBytes -gt 0) { 'REPORT READY' } else { 'NEEDS ATTENTION' }
    $logPath = if ([string]::IsNullOrWhiteSpace([string]$worker.log)) { $null } else { Join-Path $PSScriptRoot $worker.log }
    $logUpdated = if ($null -ne $logPath -and (Test-Path -LiteralPath $logPath)) { (Get-Item -LiteralPath $logPath).LastWriteTime } else { $null }
    $rows += [pscustomobject]@{
      Worker = $worker.displayName
      State = $state
      Report = $currentReport
      Bytes = $reportBytes
      LogUpdated = $logUpdated
      InWave = $inWave
    }
  }
  $rows | Select-Object Worker, State, Report, Bytes, LogUpdated | Format-Table -AutoSize
  $waveRows = @($rows | Where-Object { $_.InWave })
  $ready = @($waveRows | Where-Object { $_.State -eq 'REPORT READY' }).Count
  Write-Host "Wave checkpoint: $ready/$($waveRows.Count) reports ready."
  if ($waveRows.Count -gt 0 -and $ready -eq $waveRows.Count) {
    Write-Host 'Next: BRAIN reviews all reports and continues correction waves until the complete agenda is resolved.'
  } else {
    Write-Host 'Creator action: none. Let workers finish; do not type into their sessions.'
  }
  Write-Host 'Creator eye test is reserved until exhaustive implementation of every recorded problem.'
}

function Send-Ping([string]$Sender, [string]$Recipient, [string]$PingKind, [string]$Text) {
  $senderInfo = Resolve-Worker $Sender
  $recipientInfo = if ($Recipient.Trim().ToLowerInvariant() -eq 'all') { $null } else { Resolve-Worker $Recipient }
  $recipientKey = if ($null -eq $recipientInfo) { 'all' } else { $recipientInfo.Key }
  if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Ping message cannot be empty.' }
  if ([System.Text.Encoding]::UTF8.GetByteCount($Text) -gt 2000) { throw 'Ping message exceeds 2000 UTF-8 bytes.' }
  $pingId = [guid]::NewGuid().ToString('N')
  Add-MailEvent ([ordered]@{
    event = 'ping'; id = $pingId; at = [DateTimeOffset]::Now.ToString('o')
    from = $senderInfo.Key; to = $recipientKey; kind = $PingKind; message = $Text.Trim()
  })
  Write-Host "Queued ping $pingId from $($senderInfo.Value.displayName) to $recipientKey."
  Write-Host 'This is passive until the recipient checks the mailbox or the user chooses Wake.'
}

function Show-Inbox([string]$Worker) {
  $pings = @(Get-PendingPings $Worker)
  if ($pings.Count -eq 0) { Write-Host 'No pending pings.'; return }
  $pings | Select-Object at, id, from, to, kind, message | Format-Table -Wrap -AutoSize
}

function Acknowledge-Ping([string]$Worker, [string]$PingId) {
  $workerInfo = Resolve-Worker $Worker
  $match = @(Get-PendingPings $Worker | Where-Object { $_.id -eq $PingId })
  if ($match.Count -eq 0) { throw "Pending ping '$PingId' was not found for $Worker." }
  Add-MailEvent ([ordered]@{
    event = 'ack'; pingId = $PingId; by = $workerInfo.Key; at = [DateTimeOffset]::Now.ToString('o')
  })
  Write-Host "Acknowledged $PingId as $($workerInfo.Value.displayName)."
}

function Wake-Worker([string]$Worker) {
  $workerInfo = Resolve-Worker $Worker
  if ([string]::IsNullOrWhiteSpace([string]$workerInfo.Value.sessionId)) {
    throw "$($workerInfo.Value.displayName) has no OpenCode session ID and must be notified manually."
  }
  $pings = @(Get-PendingPings $Worker)
  if ($pings.Count -eq 0) { throw "No pending pings for $($workerInfo.Value.displayName)." }
  Write-Host "This continues OpenCode session $($workerInfo.Value.sessionId)."
  $confirm = Read-Host "Confirm $($workerInfo.Value.displayName) is STOPPED/IDLE and may be woken (type WAKE)"
  if ($confirm -ne 'WAKE') { Write-Host 'Wake cancelled.'; return }

  $lines = @()
  foreach ($ping in $pings) {
    $lines += "[$($ping.kind)] from $($ping.from), id=$($ping.id): $($ping.message)"
  }
  $prompt = @"
You are $($workerInfo.Value.displayName). You have coordination ping(s):
$($lines -join [Environment]::NewLine)

Read the latest authoritative status and assignments in:
$BridgePath
Do not edit product files unless the latest BRAIN assignment explicitly grants a non-overlapping lane. Respond with concise evidence.
Keep a short hypothesis ledger while diagnosing. After three materially distinct failed hypotheses, or after 12 minutes without new concrete evidence, send BRAIN one help ping containing the attempts, literal evidence, best current mechanism, and the smallest discriminating next test. During an authorized long soak, send concise progress evidence at least every 20 minutes. Do not silently loop.
Before stopping, acknowledge handled ping IDs by running:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\worker-hub.ps1" -Action ack -From $($workerInfo.Value.displayName) -Id <id>
"@
  & opencode run --session $workerInfo.Value.sessionId --dir 'D:\' $prompt
  if ($LASTEXITCODE -ne 0) { throw "OpenCode wake failed with exit code $LASTEXITCODE." }
  foreach ($ping in $pings) {
    Add-MailEvent ([ordered]@{
      event = 'delivery'; pingId = $ping.id; to = $workerInfo.Key; at = [DateTimeOffset]::Now.ToString('o')
    })
  }
}

function Run-Menu {
  while ($true) {
    Write-Host ''
    Write-Host 'Worker Coordination Hub'
    Write-Host '1. Show worker status / checkpoint'
    Write-Host '2. Refresh all automatic logs'
    Write-Host '3. Send a passive ping'
    Write-Host '4. Show pending pings'
    Write-Host '5. Wake a stopped OpenCode worker'
    Write-Host '6. Acknowledge a ping'
    Write-Host 'Q. Quit'
    $choice = (Read-Host 'Choose').Trim().ToUpperInvariant()
    try {
      switch ($choice) {
        '1' { Show-WorkerStatus }
        '2' { Refresh-Logs }
        '3' {
          $sender = Read-Host 'From (BRAIN/Winter/Gazelle/RoketPuncha/Ning)'
          $recipient = Read-Host 'To (worker name or all)'
          $pingKind = Read-Host 'Kind (info/blocker/evidence-request/handoff/conflict/help)'
          $text = Read-Host 'Short message'
          Send-Ping $sender $recipient $pingKind $text
        }
        '4' { Show-Inbox (Read-Host 'Inbox for worker (blank = all)') }
        '5' { Wake-Worker (Read-Host 'Stopped worker to wake') }
        '6' {
          $worker = Read-Host 'Acknowledging worker'
          $pingId = Read-Host 'Ping id'
          Acknowledge-Ping $worker $pingId
        }
        'Q' { return }
        default { Write-Warning 'Unknown choice.' }
      }
    } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
  }
}

switch ($Action) {
  'status' { Show-WorkerStatus }
  'refresh' { Refresh-Logs }
  'send' { Send-Ping $From $To $Kind $Message }
  'inbox' { Show-Inbox $To }
  'ack' { Acknowledge-Ping $From $Id }
  'wake' { Wake-Worker $To }
  default { Run-Menu }
}
