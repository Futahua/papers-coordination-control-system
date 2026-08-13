param(
  [ValidateSet('login', 'budget', 'status', 'run', 'watch', 'tick', 'start', 'stop', 'dispatch')]
  [string]$Action = 'status',
  [ValidateSet('winter', 'gazelle', 'roketpuncha', 'ning')]
  [string]$Worker,
  [double]$RemainingPercent,
  [datetime]$ResetAt,
  [double]$ReservePercent = 20,
  [switch]$OverrideReserve
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LogRoot = Split-Path -Parent $Root
$Repo = 'D:\Letters\MatTroiSeConMoc\Papers\Backpack projects\As you Go'
$Bridge = Join-Path $Repo 'BRAIN-WORKER.txt'
$RegistryPath = Join-Path $LogRoot 'worker-registry.json'
$MailboxPath = Join-Path $LogRoot 'worker-mailbox.jsonl'
$BudgetPath = Join-Path $Root 'budget.json'
$WavePath = Join-Path $Root 'wave.json'
$RequestPath = Join-Path $Root 'manager-request.md'
$CheckpointPath = Join-Path $Root 'brain-checkpoint.md'
$InstructionsPath = Join-Path $Root 'brain-instructions.md'
$SnapshotPath = Join-Path $Root 'brain-input-snapshot.md'
$TruthPath = Join-Path $Root 'current-truth.md'
$EyeGatePath = Join-Path $Root 'eye-check-gate.json'
$EyeCandidatePath = Join-Path $Root 'eye-check-candidate.json'
$BrainLogs = Join-Path $Root 'runs'
$StatePath = Join-Path $Root 'controller-state.json'
$SessionPath = Join-Path $Root 'brain-session.json'
$WorkerRetryPath = Join-Path $Root 'worker-transient-retries.json'
$WorkerAssistPath = Join-Path $Root 'worker-assist-state.json'
$LockPath = Join-Path $Root 'brain-run.lock'
$WatcherPath = Join-Path $Root 'watcher.json'
$SupervisorPath = Join-Path $Root 'watcher-supervisor.json'
$SupervisorScript = Join-Path $Root 'watcher-supervisor.ps1'
$WatcherLoopScript = Join-Path $Root 'watcher-loop.cmd'
$WatcherTaskName = 'PapersCliBrainTick'
$BrainHome = 'D:\Programs\CodexBrainB'
$RefreshUsageScript = Join-Path $Root 'refresh-usage.ps1'
$BrainTemp = Join-Path $BrainHome 'tmp'
$CodexCommand = Join-Path $BrainHome 'runtime\node_modules\.bin\codex.cmd'

function Use-BrainHome {
  if (-not (Test-Path -LiteralPath $BrainHome)) {
    New-Item -ItemType Directory -Path $BrainHome -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $BrainTemp)) {
    New-Item -ItemType Directory -Path $BrainTemp -Force | Out-Null
  }
  $env:CODEX_HOME = $BrainHome
  $env:TEMP = $BrainTemp
  $env:TMP = $BrainTemp
  if (-not (Test-Path -LiteralPath $CodexCommand -PathType Leaf)) {
    throw "Private Account B Codex runtime is missing: $CodexCommand"
  }
}

function Read-Json([string]$Path) {
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-Utf8Json([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 12
  $directory = Split-Path -Parent $Path
  $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

function Get-BudgetState {
  $budget = Read-Json $BudgetPath
  if ($null -eq $budget.remainingPercent -or [string]::IsNullOrWhiteSpace([string]$budget.resetAt)) {
    return [pscustomobject]@{ Ready = $false; Budget = $budget; Days = $null; Pace = $null; Posture = 'UNSET' }
  }
  $reset = [datetimeoffset]::Parse([string]$budget.resetAt)
  $hours = [Math]::Max(1.0, ($reset - [datetimeoffset]::Now).TotalHours)
  $days = $hours / 24.0
  $usable = [Math]::Max(0.0, [double]$budget.remainingPercent - [double]$budget.reservePercent)
  $pace = $usable / $days
  $posture = if ([double]$budget.remainingPercent -le [double]$budget.reservePercent) {
    'RESERVE'
  } elseif ([double]$budget.remainingPercent -le [double]$budget.warningPercent) {
    'CONSERVE'
  } else {
    'NORMAL'
  }
  return [pscustomobject]@{ Ready = $true; Budget = $budget; Days = $days; Pace = $pace; Posture = $posture }
}

function Get-TodayRuns {
  if (-not (Test-Path -LiteralPath $BrainLogs)) { return @() }
  $prefix = Get-Date -Format 'yyyyMMdd-'
  return @(Get-ChildItem -LiteralPath $BrainLogs -File | Where-Object { $_.Name.StartsWith($prefix) })
}

function Get-WatcherProcess {
  if (-not (Test-Path -LiteralPath $WatcherPath)) { return $null }
  $watcher = Read-Json $WatcherPath
  if ($watcher.scheduler -eq $true) {
    # A heartbeat file is not a scheduler. Stop/start and failed task creation can
    # leave a fresh-looking watcher.json behind, so verify Windows owns the task.
    $scheduledTask = Get-ScheduledTask -TaskName $WatcherTaskName -ErrorAction SilentlyContinue
    if ($null -eq $scheduledTask -or [string]$scheduledTask.State -eq 'Disabled') { return $null }
    $heartbeat = [datetimeoffset]::Parse([string]$watcher.heartbeatAt)
    # A one-minute scheduled tick needs enough grace for launch jitter and a
    # skipped tick while IgnoreNew protects an active decision run.
    if (([datetimeoffset]::Now - $heartbeat).TotalSeconds -lt 240 -or (Test-Path -LiteralPath $LockPath)) {
      return [pscustomobject]@{ ProcessId = 0; Name = 'ScheduledTask'; CommandLine = $WatcherTaskName; CreationDate = $heartbeat }
    }
    return $null
  }
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$watcher.pid)" -ErrorAction SilentlyContinue
  if ($null -eq $process) { return $null }
  $isLegacyWatcher = $process.CommandLine -like '*brain-control.ps1*' -and $process.CommandLine -like '*-Action watch*'
  $isSupervisor = $process.CommandLine -like '*watcher-supervisor.ps1*'
  $isLoop = $process.CommandLine -like '*watcher-loop.cmd*'
  if ((-not $isLegacyWatcher -and -not $isSupervisor -and -not $isLoop) -or $process.Name -notin @('powershell.exe', 'cmd.exe')) { return $null }
  $actualStart = [datetimeoffset]$process.CreationDate
  $expectedStart = [datetimeoffset]::Parse([string]$watcher.startedAt)
  if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) { return $null }
  return $process
}

function Get-RequestStatus {
  $line = Get-Content -LiteralPath $RequestPath | Where-Object { $_ -match '^Status:\s*' } | Select-Object -First 1
  if ($null -eq $line) { return 'UNKNOWN' }
  return (($line -replace '^Status:\s*', '').Trim()).ToUpperInvariant()
}

function Get-RequestPriority {
  $line = Get-Content -LiteralPath $RequestPath | Where-Object { $_ -match '^Priority:\s*' } | Select-Object -First 1
  if ($null -eq $line) { return 'NORMAL' }
  return (($line -replace '^Priority:\s*', '').Trim()).ToUpperInvariant()
}

function Get-WorkerRows {
  $registry = Read-Json $RegistryPath
  $wave = Read-Json $WavePath
  $allProcesses = @(Get-CimInstance Win32_Process)
  $processes = @($allProcesses | Where-Object { $_.Name -eq 'opencode.exe' })
  $rows = @()
  foreach ($name in @('winter', 'gazelle', 'roketpuncha', 'ning')) {
    $registered = $registry.$name
    $lane = $wave.workers.$name
    $active = $lane.active -eq $true
    $sessionProcesses = @($processes | Where-Object { $_.CommandLine -like "*$($registered.sessionId)*" })
    $running = $sessionProcesses.Count -gt 0
    $relativeReport = [string]$lane.report
    $reportPath = if ([string]::IsNullOrWhiteSpace($relativeReport)) { $null } else { Join-Path $LogRoot $relativeReport }
    $bytes = if ($null -ne $reportPath -and (Test-Path -LiteralPath $reportPath)) { (Get-Item -LiteralPath $reportPath).Length } else { 0 }
    $activityFiles = @()
    $dispatchDir = Join-Path $LogRoot "workers\$name\dispatch"
    if (Test-Path -LiteralPath $dispatchDir) {
      $activityFiles += @(Get-ChildItem -LiteralPath $dispatchDir -File -ErrorAction SilentlyContinue)
    }
    if ($null -ne $reportPath -and (Test-Path -LiteralPath $reportPath)) { $activityFiles += Get-Item -LiteralPath $reportPath }
    $lastActivity = $activityFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $idleMinutes = if ($null -ne $lastActivity) { ((Get-Date) - $lastActivity.LastWriteTime).TotalMinutes } else { $null }
    # Silence is normal during long tests only when the worker owns a live child
    # workload. A lone provider process with no output and no descendants for 30
    # minutes is a real hung session, not a soak.
    $sessionPids = @($sessionProcesses | Select-Object -ExpandProperty ProcessId)
    $hasChildWork = @($allProcesses | Where-Object { $sessionPids -contains $_.ParentProcessId }).Count -gt 0
    $stalled = $active -and $running -and -not $hasChildWork -and $bytes -eq 0 -and $null -ne $idleMinutes -and $idleMinutes -ge 30
    $state = if (-not $active) { 'STANDBY' } elseif ($stalled) { 'STALLED' } elseif ($running) { 'WORKING' } elseif ($bytes -gt 0) { 'REPORT READY' } else { 'NEEDS ATTENTION' }
    $startedAt = if ($running) { @($sessionProcesses | Sort-Object CreationDate | Select-Object -First 1 | ForEach-Object { [datetimeoffset]$_.CreationDate })[0] } else { $null }
    $runningMinutes = if ($null -ne $startedAt) { ([datetimeoffset]::Now - $startedAt).TotalMinutes } else { $null }
    $rows += [pscustomobject]@{
      Worker = $registered.displayName
      Key = $name
      State = $state
      Report = $relativeReport
      Bytes = $bytes
      IdleMinutes = $idleMinutes
      RunningMinutes = $runningMinutes
      HasChildWork = $hasChildWork
      LastActivityAt = if ($null -ne $lastActivity) { $lastActivity.LastWriteTimeUtc.ToString('o') } else { $null }
    }
  }
  return $rows
}

function Get-TextHash([string]$Text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
  return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

function Get-WorkerAssistEvents {
  $wave = Read-Json $WavePath
  $handled = if (Test-Path -LiteralPath $WorkerAssistPath) { Read-Json $WorkerAssistPath } else { [pscustomobject]@{} }
  $events = @()
  foreach ($row in @(Get-WorkerRows)) {
    if ($row.State -ne 'WORKING') { continue }
    $lane = $wave.workers.($row.Key)
    $assignment = [string]$lane.assignment
    $declaredLongRun = $assignment -match '(?i)uninterrupted\s*>?=\s*120|two[- ]hour|2[- ]hour|\bsoak\b'
    $idleLimit = if ($declaredLongRun -and $row.HasChildWork) { 25.0 } else { 12.0 }
    $reason = $null
    if ($null -ne $row.IdleMinutes -and [double]$row.IdleMinutes -ge $idleLimit) {
      $reason = 'NO_MATERIAL_ACTIVITY'
    } elseif (-not $declaredLongRun -and $row.Bytes -eq 0 -and $null -ne $row.RunningMinutes -and [double]$row.RunningMinutes -ge 35) {
      $reason = 'LONG_RUNNING_WITHOUT_REPORT'
    }
    if ($null -eq $reason) { continue }

    $dispatchDir = Join-Path $LogRoot "workers\$($row.Key)\dispatch"
    $latestFiles = @(Get-ChildItem -LiteralPath $dispatchDir -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 2)
    $latest = $latestFiles | Select-Object -First 1
    $dispatchKey = if ($null -ne $latest) { ($latest.BaseName -replace '\.(out|err)$', '') } else { 'no-dispatch-log' }
    $activityKey = if ($row.LastActivityAt) { [string]$row.LastActivityAt } else { 'none' }
    $id = Get-TextHash ("$($row.Key)|$dispatchKey|$reason|$activityKey")
    if ($null -ne $handled.PSObject.Properties[$id]) { continue }
    $events += [pscustomobject]@{
      id = $id
      worker = $row.Key
      reason = $reason
      idleMinutes = if ($null -ne $row.IdleMinutes) { [Math]::Round([double]$row.IdleMinutes, 1) } else { $null }
      runningMinutes = if ($null -ne $row.RunningMinutes) { [Math]::Round([double]$row.RunningMinutes, 1) } else { $null }
      declaredLongRun = $declaredLongRun
      report = $row.Report
      dispatchFiles = @($latestFiles | ForEach-Object { $_.FullName })
    }
  }
  return $events
}

function Mark-WorkerAssistEventsHandled($Events) {
  if ($null -eq $Events -or @($Events).Count -eq 0) { return }
  $state = if (Test-Path -LiteralPath $WorkerAssistPath) { Read-Json $WorkerAssistPath } else { [pscustomobject]@{} }
  foreach ($event in @($Events)) {
    $state | Add-Member -NotePropertyName ([string]$event.id) -NotePropertyValue ([ordered]@{
      worker = [string]$event.worker
      reason = [string]$event.reason
      handledAt = [datetimeoffset]::Now.ToString('o')
    }) -Force
  }
  Write-Utf8Json $WorkerAssistPath $state
}

function Get-BrainAttentionEvents {
  if (-not (Test-Path -LiteralPath $MailboxPath)) { return @() }
  $wave = Read-Json $WavePath
  # Filesystem and ISO timestamps can differ by sub-second rounding. Include a
  # tiny boundary tolerance so a blocker emitted during wave creation is not lost.
  $waveStart = (Get-Item -LiteralPath $WavePath).LastWriteTime.AddSeconds(-2)
  $active = @($wave.workers.PSObject.Properties | Where-Object { $_.Value.active -eq $true } | ForEach-Object { $_.Name })
  $events = @()
  $acked = @{}
  foreach ($line in Get-Content -LiteralPath $MailboxPath -Encoding utf8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $event = $line | ConvertFrom-Json
      if ($event.event -eq 'ack') { $acked[[string]$event.pingId] = $true }
      $events += $event
    } catch {}
  }
  return @($events | Where-Object {
    if ($_.event -ne 'ping' -or $acked.ContainsKey([string]$_.id)) { return $false }
    if (([string]$_.to).ToLowerInvariant() -notin @('brain', 'all')) { return $false }
    if (([string]$_.from).ToLowerInvariant() -notin $active) { return $false }
    if (([string]$_.kind).ToLowerInvariant() -notin @('blocker', 'conflict', 'evidence-request', 'help')) { return $false }
    try { return ([datetimeoffset]::Parse([string]$_.at)).LocalDateTime -ge $waveStart } catch { return $false }
  } | Select-Object id, at, from, to, kind, message)
}

function Get-EventFingerprint {
  $wave = Get-Content -LiteralPath $WavePath -Raw
  $request = Get-Content -LiteralPath $RequestPath -Raw
  # Fingerprints represent decision state, never wall-clock passage. IdleMinutes
  # changes continuously even when no worker/process/report state changes and
  # previously caused one expensive BRAIN invocation per scheduler tick.
  $rows = Get-WorkerRows | Select-Object Worker, Key, State, Report, Bytes | ConvertTo-Json -Compress
  # A completed lane is normally marked inactive before its report is reviewed.
  # Include the exact current-wave report contents so that completion evidence is
  # a distinct, one-shot decision event even when no worker process remains.
  $waveObject = Read-Json $WavePath
  $reports = @()
  foreach ($property in @($waveObject.workers.PSObject.Properties)) {
    $relativeReport = [string]$property.Value.report
    if ([string]::IsNullOrWhiteSpace($relativeReport)) { continue }
    $reportPath = Join-Path $LogRoot $relativeReport
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { continue }
    $reports += [pscustomobject]@{
      worker = $property.Name
      report = $relativeReport
      content = Get-Content -LiteralPath $reportPath -Raw
    }
  }
  $reportEvidence = $reports | ConvertTo-Json -Compress -Depth 4
  $attention = Get-BrainAttentionEvents | ConvertTo-Json -Compress
  $assistance = Get-WorkerAssistEvents | Select-Object id, worker, reason | ConvertTo-Json -Compress
  $truth = if (Test-Path -LiteralPath $TruthPath) { Get-Content -LiteralPath $TruthPath -Raw } else { '' }
  $gate = if (Test-Path -LiteralPath $EyeGatePath) { Get-Content -LiteralPath $EyeGatePath -Raw } else { '' }
  # A changed operating contract is a legitimate retry boundary after an incomplete
  # BRAIN turn. It is not time-based polling: the stable instructions themselves
  # must change before the prior claimed event becomes eligible again.
  $contract = Get-Content -LiteralPath $InstructionsPath -Raw
  $text = $wave + "`n" + $request + "`n" + $rows + "`n" + $reportEvidence + "`n" + $attention + "`n" + $assistance + "`n" + $truth + "`n" + $gate + "`n" + $contract
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
  # Windows PowerShell 5 / .NET Framework does not expose Convert.ToHexString.
  return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

function New-BrainSnapshot {
  $budget = Get-Content -LiteralPath $BudgetPath -Raw
  $request = Get-Content -LiteralPath $RequestPath -Raw
  $waveText = Get-Content -LiteralPath $WavePath -Raw
  $registryText = Get-Content -LiteralPath $RegistryPath -Raw
  $wave = $waveText | ConvertFrom-Json
  $registry = $registryText | ConvertFrom-Json
  $workerRows = @(Get-WorkerRows)
  $attentionEvents = @(Get-BrainAttentionEvents)
  $assistEvents = @(Get-WorkerAssistEvents)
  $sections = [System.Collections.Generic.List[string]]::new()
  $sections.Add("# BRAIN input snapshot`nGenerated: $([datetimeoffset]::Now.ToString('o'))")
  if (Test-Path -LiteralPath $TruthPath) {
    $sections.Add("## Manager-owned current truth (authoritative; read fully; do not edit)`n$(Get-Content -LiteralPath $TruthPath -Raw)")
  }
  if (Test-Path -LiteralPath $EyeGatePath) {
    $sections.Add("## Mechanical eye-check gate (controller-owned; do not edit)`n~~~json`n$(Get-Content -LiteralPath $EyeGatePath -Raw)`n~~~")
  }
  $sections.Add("## Manager request`n$request")
  $sections.Add("## Budget`n~~~json`n$budget`n~~~")
  $sections.Add("## Wave`n~~~json`n$waveText`n~~~")
  $sections.Add("## Worker registry`n~~~json`n$registryText`n~~~")
  if ($attentionEvents.Count -gt 0) {
    $sections.Add("## Unacknowledged current-wave worker attention events`n~~~json`n$($attentionEvents | ConvertTo-Json -Depth 6)`n~~~")
  }
  if ($assistEvents.Count -gt 0) {
    $sections.Add("## Controller-detected worker assistance events`nThese are one-shot technical-lead reviews, not automatic restarts. Diagnose from the bounded evidence and send a concrete correction/help request in the same turn.`n~~~json`n$($assistEvents | ConvertTo-Json -Depth 6)`n~~~")
    foreach ($assist in $assistEvents) {
      foreach ($file in @($assist.dispatchFiles)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $tail = (Get-Content -LiteralPath $file -Tail 60 -Encoding utf8 -ErrorAction SilentlyContinue) -join "`n"
        if ($tail.Length -gt 7000) { $tail = $tail.Substring($tail.Length - 7000) }
        $sections.Add("## Assistance evidence: $($assist.worker) / $([IO.Path]::GetFileName($file))`n~~~text`n$tail`n~~~")
      }
    }
  }
  foreach ($name in @('winter', 'gazelle', 'roketpuncha', 'ning')) {
    $lane = $wave.workers.$name
    if ($lane.active -ne $true -or [string]::IsNullOrWhiteSpace([string]$lane.report)) { continue }
    $row = $workerRows | Where-Object { $_.Worker -eq $registry.$name.displayName } | Select-Object -First 1
    if ($null -ne $row -and $row.State -in @('NEEDS ATTENTION', 'STALLED')) {
      $dispatchDir = Join-Path $LogRoot "workers\$name\dispatch"
      $errorFile = Get-ChildItem -LiteralPath $dispatchDir -Filter '*.err.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($null -ne $errorFile) {
        $errorTail = (Get-Content -LiteralPath $errorFile.FullName -Tail 40 -Encoding utf8) -join "`n"
        if ($errorTail.Length -gt 4000) { $errorTail = $errorTail.Substring($errorTail.Length - 4000) }
        $sections.Add("## Attention evidence: $name`nSource: $($errorFile.Name)`n~~~text`n$errorTail`n~~~")
      }
    }
    $reportPath = Join-Path $LogRoot ([string]$lane.report)
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { continue }
    $report = Get-Content -LiteralPath $reportPath -Raw
    if ($report.Length -gt 12000) { $report = $report.Substring(0, 12000) + "`n[TRUNCATED BY CONTROLLER]" }
    $sections.Add("## Current compact report: $name`n$report")
  }
  [System.IO.File]::WriteAllText($SnapshotPath, ($sections -join "`n`n") + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Complete-ManagerRequest {
  $text = Get-Content -LiteralPath $RequestPath -Raw
  if ($text -notmatch '(?m)^Status:\s*READY\s*$') { return }
  $matcher = [regex]::new('(?m)^Status:\s*READY\s*$')
  $updated = $matcher.Replace($text, 'Status: DONE', 1)
  [System.IO.File]::WriteAllText($RequestPath, $updated, [System.Text.UTF8Encoding]::new($false))
}

function Get-BrainSession {
  if (-not (Test-Path -LiteralPath $SessionPath)) { return $null }
  try {
    $session = Read-Json $SessionPath
    if ([string]::IsNullOrWhiteSpace([string]$session.sessionId)) { return $null }
    return $session
  } catch { return $null }
}

function Acquire-BrainLock {
  try {
    $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([datetimeoffset]::Now.ToString('o'))
      $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
  } catch [System.IO.IOException] {
    throw "Another BRAIN run owns $LockPath"
  }
}

function Get-SessionIdFromRunLog([string]$RunLog) {
  foreach ($line in Get-Content -LiteralPath $RunLog -Encoding utf8 -ErrorAction SilentlyContinue) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $event = $line | ConvertFrom-Json
      if ([string]$event.type -eq 'thread.started' -and -not [string]::IsNullOrWhiteSpace([string]$event.thread_id)) {
        return [string]$event.thread_id
      }
    } catch {}
  }
  return $null
}

function Assert-BrainOutputSafety {
  if (-not (Test-Path -LiteralPath $EyeGatePath)) { return }
  $gate = Read-Json $EyeGatePath
  $checkpoint = if (Test-Path -LiteralPath $CheckpointPath) { Get-Content -LiteralPath $CheckpointPath -Raw } else { '' }
  $wave = Read-Json $WavePath
  $claimsEyeCheck = $checkpoint -match 'PING DESKTOP MANAGER NOW' -or [string]$wave.status -match 'MILESTONE|EYE.?CHECK'
  if ($claimsEyeCheck -and -not (Test-EyeCheckEligibility)) {
    throw 'BRAIN attempted a creator eye-check/milestone while the mechanical gate is closed.'
  }
}

function Test-EyeCheckEligibility {
  $gate = Read-Json $EyeGatePath
  if ($gate.eligible -eq $true) { return $true }
  if (-not (Test-Path -LiteralPath $EyeCandidatePath -PathType Leaf)) { return $false }
  try { $candidate = Read-Json $EyeCandidatePath } catch { return $false }
  if ($candidate.agendaStatus -ne 'RESOLVED' -or $candidate.productionPathVerified -ne $true) { return $false }
  if ([double]$candidate.uninterruptedSoakMinutes -lt 120 -or $candidate.uninterruptedSoak -ne $true) { return $false }
  if ([int]$candidate.nativeCycles -lt 1 -or [int]$candidate.knownContradictions -ne 0 -or $candidate.cleanupPassed -ne $true) { return $false }
  $receipts = @($candidate.evidenceReceipts)
  if ($receipts.Count -lt 2) { return $false }
  foreach ($relative in $receipts) {
    $path = if ([IO.Path]::IsPathRooted([string]$relative)) { [string]$relative } else { Join-Path $LogRoot ([string]$relative) }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  }
  return $true
}

function Repair-CompletedAttempt {
  # Persistent turns are finalized transactionally in Invoke-BrainOnce. Never
  # infer completion later from partial/stale logs because that bypasses session
  # capture and the mechanical eye-check gate.
  return $false
  <# Legacy recovery logic retained below for forensic reference only.
  if (Test-Path -LiteralPath $LockPath) { return $false }
  if (-not (Test-Path -LiteralPath $StatePath)) { return $false }
  $state = Read-Json $StatePath
  if ($null -ne $state.lastCompletedFingerprint -or -not $state.lastAttemptAt -or -not $state.model) { return $false }
  try { $attemptAt = [datetimeoffset]::Parse([string]$state.lastAttemptAt) } catch { return $false }
  $candidate = Get-ChildItem -LiteralPath $BrainLogs -Filter ("*-{0}.log" -f [string]$state.model) -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $attemptAt.LocalDateTime.AddSeconds(-2) } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -eq $candidate) { return $false }
  $tail = (Get-Content -LiteralPath $candidate.FullName -Tail 50 -ErrorAction SilentlyContinue) -join "`n"
  $turnCompleted = $tail -match '"type"\s*:\s*"turn\.completed"'
  if (-not $turnCompleted -and $tail -notmatch '(?m)^STOP\s*$') { return $false }
  Complete-ManagerRequest
  Write-Utf8Json $StatePath ([ordered]@{
    lastAttemptFingerprint = $state.lastAttemptFingerprint
    lastAttemptAt = $state.lastAttemptAt
    lastCompletedFingerprint = Get-EventFingerprint
    lastCompletedAt = [datetimeoffset]::Now.ToString('o')
    model = $state.model
    recoveredFromFinalOutput = $true
  })
  return $true
  #>
}

function Test-DecisionReady {
  if ((Get-RequestStatus) -eq 'READY') { return $true }
  $wave = Read-Json $WavePath
  # DISPATCH_READY is emitted by BRAIN for a fully defined wave whose worker
  # launches may already have been performed in the same cycle. Treat it as an
  # active coordination state so stopped workers with reports trigger review.
  if ([string]$wave.status -notin @('DISPATCH_READY', 'DISPATCHING', 'DISPATCHED', 'WORKING', 'NEEDS_ATTENTION')) { return $false }
  $active = @(Get-WorkerRows | Where-Object { $_.State -ne 'STANDBY' })
  # A worker switches itself inactive as it finishes.  Its current-wave report
  # is nevertheless decision-worthy; otherwise the BRAIN permanently misses the
  # completion and waits for an unrelated event.
  $completedLaneReports = @($wave.workers.PSObject.Properties | Where-Object {
    $relativeReport = [string]$_.Value.report
    -not [string]::IsNullOrWhiteSpace($relativeReport) -and
      (Test-Path -LiteralPath (Join-Path $LogRoot $relativeReport) -PathType Leaf)
  })
  if ($active.Count -eq 0 -and $completedLaneReports.Count -eq 0) { return $false }
  if (@(Get-WorkerAssistEvents).Count -gt 0) { return $true }
  if (@(Get-BrainAttentionEvents).Count -gt 0) { return $true }
  if (@($active | Where-Object { $_.State -in @('NEEDS ATTENTION', 'STALLED') }).Count -gt 0) { return $true }
  # Rolling coordination: one long implementation/soak must not strand another
  # worker's completed report. Review stopped report-ready lanes immediately;
  # drafts from live workers remain WORKING and do not wake the model.
  if (@($active | Where-Object { $_.State -eq 'REPORT READY' }).Count -gt 0) { return $true }
  return @($active | Where-Object { $_.State -eq 'WORKING' }).Count -eq 0
}

function Show-Status {
  Use-BrainHome
  $budgetState = Get-BudgetState
  Write-Host 'ACCOUNT B CLI BRAIN'
  & $CodexCommand login status 2>&1 | ForEach-Object { Write-Host $_ }
  Write-Host ''
  if ($budgetState.Ready) {
    Write-Host ('Budget: {0:N1}% remaining | reset in {1:N1} days | reserve {2:N1}% | safe pace {3:N1}%/day | {4}' -f [double]$budgetState.Budget.remainingPercent, $budgetState.Days, [double]$budgetState.Budget.reservePercent, $budgetState.Pace, $budgetState.Posture)
    $runs = @(Get-TodayRuns)
    Write-Host ('Runs today: {0} (informational; no fixed daily cap) | Sol decisions: {1}' -f $runs.Count, @($runs | Where-Object { $_.Name -like '*gpt-5.6-sol*' }).Count)
  } else {
    Write-Host 'Budget: UNSET - run BRAIN-BUDGET.cmd after checking Account B /status.'
  }
  Write-Host ('Manager request: {0}' -f (Get-RequestStatus))
  Write-Host ('Watcher: {0}' -f $(if ($null -ne (Get-WatcherProcess)) { 'RUNNING' } else { 'STOPPED' }))
  Write-Host ''
  $workerRows = @(Get-WorkerRows)
  $workerRows | Select-Object Worker, Key, State, Report, Bytes, IdleMinutes | Format-Table -AutoSize
  $assistanceDue = @(Get-WorkerAssistEvents)
  if ($assistanceDue.Count -gt 0) {
    Write-Host ''
    Write-Host 'BRAIN technical-lead assistance due:'
    $assistanceDue | Select-Object Worker, Reason, IdleMinutes, RunningMinutes | Format-Table -AutoSize
  }
  Write-Host ('Decision ready: {0}' -f (Test-DecisionReady))
  Write-Host ('Last checkpoint: {0}' -f $CheckpointPath)
}

function Set-Budget([Nullable[double]]$Remaining, [Nullable[datetime]]$Reset, [double]$Reserve) {
  $resolvedRemaining = if ($null -eq $Remaining) { [double](Read-Host 'Account B weekly remaining percentage (0-100)') } else { [double]$Remaining }
  $resolvedReset = if ($null -eq $Reset) { [datetime](Read-Host 'Reset date/time, for example 2026-08-18 09:00') } else { [datetime]$Reset }
  if ($resolvedRemaining -lt 0 -or $resolvedRemaining -gt 100) { throw 'Remaining percentage must be 0 through 100.' }
  $value = [ordered]@{
    updatedAt = [datetimeoffset]::Now.ToString('o')
    remainingPercent = $resolvedRemaining
    resetAt = ([datetimeoffset]$resolvedReset).ToString('o')
    reservePercent = $Reserve
    warningPercent = [Math]::Max($Reserve + 10, 35)
    maxAutomaticRunsPerDay = 6
    maxTerraRunsPerDay = 2
    automaticRuns = $true
  }
  Write-Utf8Json $BudgetPath $value
  Write-Host 'Budget runway updated.'
  Show-Status
}

function Invoke-BrainOnce {
  if (-not (Test-DecisionReady)) {
    Write-Host 'No new decision event. Codex was not invoked.'
    return
  }
  $budgetState = Get-BudgetState
  if (-not $budgetState.Ready) { throw 'Budget is unset. Run BRAIN-BUDGET.cmd first.' }
  if ($budgetState.Posture -eq 'RESERVE' -and -not $OverrideReserve) {
    throw 'Protected reserve reached. Automatic Codex run refused.'
  }
  $todayRuns = @(Get-TodayRuns)
  Use-BrainHome
  # Codex prints its successful login status on stderr. Windows PowerShell 5
  # promotes native stderr to an ErrorRecord under Stop, so probe with Continue
  # and judge authentication only by the native exit code.
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $CodexCommand login status *> $null
  $loginExitCode = $LASTEXITCODE
  $ErrorActionPreference = $savedPreference
  if ($loginExitCode -ne 0) { throw 'Account B is not authenticated. Run BRAIN-B-LOGIN.cmd.' }
  # Every model invocation is a decision-bearing BRAIN cycle. Routine routing
  # stays low-effort; technical-lead intervention gets medium effort. Waiting,
  # status, fingerprinting and dispatch remain deterministic and consume no model.
  $model = 'gpt-5.6-terra'
  $assistEventsAtStart = @(Get-WorkerAssistEvents)
  $attentionAtStart = @(Get-BrainAttentionEvents)
  $workerStatesAtStart = @(Get-WorkerRows)
  $managerRequestReady = (Get-RequestStatus) -eq 'READY'
  $needsIntervention = $managerRequestReady -or $assistEventsAtStart.Count -gt 0 -or
    @($attentionAtStart | Where-Object { ([string]$_.kind).ToLowerInvariant() -in @('blocker', 'conflict', 'help') }).Count -gt 0 -or
    @($workerStatesAtStart | Where-Object { $_.State -in @('STALLED', 'NEEDS ATTENTION') }).Count -gt 0
  $reasoningEffort = if ($needsIntervention) { 'medium' } else { 'low' }
  New-BrainSnapshot
  $brainSession = Get-BrainSession
  $prompt = @"
Read and obey: $InstructionsPath
Read this bounded input and no broader context unless it explicitly marks a DECISION and names the required files: $SnapshotPath

This is another turn in your persistent CLI BRAIN session. Reconcile the new snapshot with your retained coordination context; manager-owned current truth wins any contradiction. Perform exactly one bounded coordination cycle. This cycle is configured for $reasoningEffort reasoning. A `Status: READY` Manager request is executable authority: carry it out in this turn, or name a literal conflict with a cited authority that makes it impossible. Never replace it with a generic “manager direction needed.” If the evidence already shows its requested bounded work completed, reconcile that state, mark the request done, and continue with the smallest next unresolved agenda lane when safely authorized. Every newly dispatched assignment must begin with the mandatory five-field LEAD HINT from the instructions so the worker receives your best mechanism and first move before doing work. For a controller-detected assistance event, act as a technical lead: identify the most likely blocking mechanism from the bounded tail, send one concrete evidence-based correction or split one independent diagnosis lane, and require a compact report. Do not merely redispatch unchanged scope. Do not read the live feed or full reasoning logs. Do not wait or poll. Use model allowance conservatively. Write the checkpoint and exit.
"@
  try {
    $priorCheckpoint = if (Test-Path -LiteralPath $CheckpointPath) { Get-Content -LiteralPath $CheckpointPath -Raw } else { '' }
    $priorWave = Get-Content -LiteralPath $WavePath -Raw
    Acquire-BrainLock
    $attemptFingerprint = Get-EventFingerprint
    Write-Utf8Json $StatePath ([ordered]@{
      lastAttemptFingerprint = $attemptFingerprint
      lastAttemptAt = [datetimeoffset]::Now.ToString('o')
      lastCompletedFingerprint = $null
      model = $model
    })
    New-Item -ItemType Directory -Path $BrainLogs -Force | Out-Null
    $runLog = Join-Path $BrainLogs ("{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $model)
    $turnOutput = Join-Path $BrainLogs (".{0}-{1}.checkpoint.tmp" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
    if ($null -eq $brainSession) {
      $resumeSessionId = $null
      $codexArgs = @(
        'exec', '--json', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
        '-m', $model,
        '-c', ('model_reasoning_effort="{0}"' -f $reasoningEffort),
        '-C', $Root,
        '--add-dir', $Repo,
        '--add-dir', 'D:\Letters\MatTroiSeConMoc\PAPERS 3\Papers-3',
        '--add-dir', $LogRoot,
        '-s', 'danger-full-access',
        '-o', $turnOutput
      )
    } else {
      $resumeSessionId = [string]$brainSession.sessionId
      $codexArgs = @(
        'exec', 'resume', '--json', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
        '--dangerously-bypass-approvals-and-sandbox',
        '-m', $model,
        '-c', ('model_reasoning_effort="{0}"' -f $reasoningEffort),
        '-o', $turnOutput
      )
    }
    foreach ($feature in @(
      'apps', 'browser_use', 'browser_use_external', 'browser_use_full_cdp_access',
      'computer_use', 'goals', 'hooks', 'image_generation', 'in_app_browser',
      'memories', 'multi_agent', 'plugins', 'plugin_sharing', 'remote_plugin',
      'skill_search', 'tool_suggest', 'workspace_dependencies'
    )) {
      $codexArgs += @('--disable', $feature)
    }
    # Resume positional arguments must follow every option; otherwise later
    # --disable flags can be parsed as prompt text by some CLI versions.
    if ($null -ne $resumeSessionId) { $codexArgs += $resumeSessionId }
    $watchdog = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', 'D:\Programs\CodexBrainB\brain-run-watchdog.ps1',
      '-ControllerPid', $PID,
      '-RunLog', ('"{0}"' -f $runLog),
      '-LockPath', ('"{0}"' -f $LockPath)
    ) -WindowStyle Hidden -PassThru
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $CodexCommand @codexArgs $prompt *> $runLog
    $brainExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($null -ne $watchdog -and -not $watchdog.HasExited) { Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue }
    $runTail = (Get-Content -LiteralPath $runLog -Tail 80 -ErrorAction SilentlyContinue) -join "`n"
    $turnCompleted = $runTail -match '"type"\s*:\s*"turn\.completed"'
    $completedOutput = (Test-Path -LiteralPath $turnOutput) -and ((Get-Content -LiteralPath $turnOutput -Raw -ErrorAction SilentlyContinue) -match '(?m)^STOP\s*$')
    if ($brainExitCode -ne 0 -or -not $turnCompleted -or -not $completedOutput) { throw "Codex BRAIN did not produce a verified completed turn (exit=$brainExitCode; event=$turnCompleted; output=$completedOutput)." }
    [System.IO.File]::WriteAllText($CheckpointPath, (Get-Content -LiteralPath $turnOutput -Raw), [System.Text.UTF8Encoding]::new($false))
    $newSessionId = if ($null -eq $brainSession) { Get-SessionIdFromRunLog $runLog } else { [string]$brainSession.sessionId }
    if ([string]::IsNullOrWhiteSpace($newSessionId)) { throw 'Codex completed but did not expose a persistent session id.' }
    try {
      Assert-BrainOutputSafety
    } catch {
      [System.IO.File]::WriteAllText($CheckpointPath, $priorCheckpoint, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::WriteAllText($WavePath, $priorWave, [System.Text.UTF8Encoding]::new($false))
      if (Test-Path -LiteralPath $SessionPath) {
        Move-Item -LiteralPath $SessionPath -Destination ($SessionPath + '.rejected-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
      }
      throw
    }
    Write-Utf8Json $SessionPath ([ordered]@{
      sessionId = $newSessionId
      createdAt = if ($null -eq $brainSession) { [datetimeoffset]::Now.ToString('o') } else { [string]$brainSession.createdAt }
      updatedAt = [datetimeoffset]::Now.ToString('o')
      turnCount = if ($null -eq $brainSession) { 1 } else { ([int]$brainSession.turnCount + 1) }
      model = $model
      lastReasoningEffort = $reasoningEffort
    })
    Mark-WorkerAssistEventsHandled $assistEventsAtStart
    Complete-ManagerRequest
    Write-Utf8Json $StatePath ([ordered]@{
      lastAttemptFingerprint = $attemptFingerprint
      lastAttemptAt = [datetimeoffset]::Now.ToString('o')
      # Mark only the snapshot this turn actually reviewed. A worker can finish
      # while Terra is deciding; recording the post-turn fingerprint here would
      # falsely claim that new report and strand it in WATCHING.
      lastCompletedFingerprint = $attemptFingerprint
      lastCompletedAt = [datetimeoffset]::Now.ToString('o')
      model = $model
    })
    Get-Content -LiteralPath $CheckpointPath
  } finally {
    if ($turnOutput) { Remove-Item -LiteralPath $turnOutput -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
  }
}

function Dispatch-Worker {
  if ([string]::IsNullOrWhiteSpace($Worker)) { throw 'Worker is required for dispatch.' }
  $registry = Read-Json $RegistryPath
  $wave = Read-Json $WavePath
  $registered = $registry.$Worker
  $lane = $wave.workers.$Worker
  if ($lane.active -ne $true) { throw "$Worker has no active lane in wave.json." }
  if ([string]::IsNullOrWhiteSpace([string]$lane.assignment)) { throw "$Worker assignment is empty." }
  $assignmentText = [string]$lane.assignment
  foreach ($requiredHintPart in @('LEAD HINT:', 'mechanism=', 'first=', 'avoid=', 'proof=', 'stop=', 'TASK:')) {
    if (-not $assignmentText.Contains($requiredHintPart)) {
      throw "$Worker assignment lacks mandatory pre-work lead hint field '$requiredHintPart'; refusing to dispatch."
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$lane.report)) { throw "$Worker report path is empty." }
  $bridgeTail = (Get-Content -LiteralPath $Bridge -Tail 160 -Encoding utf8) -join "`n"
  $waveNumber = [regex]::Match([string]$wave.waveId, '^\d+').Value
  $reportName = [IO.Path]::GetFileName([string]$lane.report)
  if ([string]::IsNullOrWhiteSpace($waveNumber) -or $bridgeTail -notmatch [regex]::Escape($waveNumber) -or
      $bridgeTail -notmatch [regex]::Escape($reportName) -or $bridgeTail -notmatch 'AUTHORITATIVE EOF') {
    throw "Current wave handoff is not authoritative at BRAIN-WORKER EOF; refusing to dispatch $Worker."
  }
  $running = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'opencode.exe' -and $_.CommandLine -like "*$($registered.sessionId)*" })
  if ($running.Count -gt 0) { throw "$Worker session is already running." }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dispatchDir = Join-Path $LogRoot "workers\$Worker\dispatch"
  New-Item -ItemType Directory -Path $dispatchDir -Force | Out-Null
  $stdout = Join-Path $dispatchDir "$stamp.out.log"
  $stderr = Join-Path $dispatchDir "$stamp.err.log"
  $runner = Join-Path $Root 'worker-run.ps1'
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $runner), '-Worker', $Worker)
  Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory 'D:\' -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr | Out-Null
  Write-Host "Dispatched $($registered.displayName) headlessly."
}

function Watch-Events {
  Write-Host 'BRAIN watcher is live. Waiting is mechanical; Codex runs only on a new decision event.'
  while ($true) {
    try {
      $ready = Test-DecisionReady
      $fingerprint = if ($ready) { Get-EventFingerprint } else { $null }
      $previous = if (Test-Path -LiteralPath $StatePath) { (Read-Json $StatePath).lastAttemptFingerprint } else { $null }
      $watcherState = if ($ready -and $fingerprint -ne $previous) { 'INVOKING' }
        elseif ($ready) { 'EVENT ALREADY CLAIMED' }
        else { 'WATCHING' }
      Write-Utf8Json $WatcherPath ([ordered]@{
        pid = $PID
        startedAt = (Get-Process -Id $PID).StartTime.ToString('o')
        heartbeatAt = [datetimeoffset]::Now.ToString('o')
        state = $watcherState
        decisionReady = $ready
        eventFingerprint = $fingerprint
        lastAttemptFingerprint = $previous
      })
      if ($ready) {
        if ($fingerprint -ne $previous) { Invoke-BrainOnce }
      }
    } catch {
      Write-Warning $_
      Write-Utf8Json $WatcherPath ([ordered]@{
        pid = $PID
        startedAt = (Get-Process -Id $PID).StartTime.ToString('o')
        heartbeatAt = [datetimeoffset]::Now.ToString('o')
        state = 'ERROR'
        decisionReady = $null
        lastError = [string]$_
      })
    }
    Start-Sleep -Seconds 15
  }
}

function Invoke-WatcherTick {
  # Keep displayed account telemetry current even when no decision is due.
  if (Test-Path -LiteralPath $RefreshUsageScript) {
    try { & $RefreshUsageScript *> $null } catch {}
  }
  Repair-TransientWorkerFailures
  if (Test-Path -LiteralPath $LockPath) {
    $lockAgeMinutes = ((Get-Date) - (Get-Item -LiteralPath $LockPath).LastWriteTime).TotalMinutes
    if ($lockAgeMinutes -ge 5) {
      Remove-Item -LiteralPath $LockPath -Force
      Add-Content -LiteralPath (Join-Path $Root 'watcher-supervisor.log') -Value ("{0} cleared stale BRAIN lock ({1:N1} minutes old)" -f ([datetimeoffset]::Now.ToString('o')), $lockAgeMinutes)
    }
  }
  $recoveredCompletion = Repair-CompletedAttempt
  $state = if (Test-Path -LiteralPath $LockPath) { 'WORKING' } else { 'WATCHING' }
  Write-Utf8Json $WatcherPath ([ordered]@{ scheduler = $true; heartbeatAt = [datetimeoffset]::Now.ToString('o'); state = $state })
  if (Test-Path -LiteralPath $LockPath) { return }
  if ($recoveredCompletion) {
    Write-Utf8Json $WatcherPath ([ordered]@{ scheduler = $true; heartbeatAt = [datetimeoffset]::Now.ToString('o'); state = 'RECOVERED COMPLETED EVENT' })
  }
  if (-not (Test-DecisionReady)) { return }
  $fingerprint = Get-EventFingerprint
  $controllerState = if (Test-Path -LiteralPath $StatePath) { Read-Json $StatePath } else { $null }
  $previous = if ($null -ne $controllerState) { $controllerState.lastAttemptFingerprint } else { $null }
  $completed = if ($null -ne $controllerState) { $controllerState.lastCompletedFingerprint } else { $null }
  $attemptAt = if ($null -ne $controllerState -and $controllerState.lastAttemptAt) { [datetimeoffset]::Parse([string]$controllerState.lastAttemptAt) } else { [datetimeoffset]::MinValue }
  # Never spend model allowance twice on identical evidence. If a claimed run
  # dies, surface the incomplete claim and wait for a genuinely changed event or
  # an explicit Manager action; periodic retry previously produced garbage loops.
  $retryIncompleteAttempt = $false
  # Completion is recorded from the post-decision state, which can legitimately
  # differ from the pre-run attempt fingerprint (for example a dispatch changes
  # WORKING/report state). Never reinvoke for either already-known fingerprint.
  $newEvent = $fingerprint -ne $previous -and $fingerprint -ne $completed
  if ($newEvent -or $retryIncompleteAttempt) {
    Write-Utf8Json $WatcherPath ([ordered]@{ scheduler = $true; heartbeatAt = [datetimeoffset]::Now.ToString('o'); state = 'INVOKING'; eventFingerprint = $fingerprint })
    Invoke-BrainOnce
  }
  $finalState = if ($fingerprint -eq $completed -or $fingerprint -eq $previous) { 'EVENT ALREADY CLAIMED' } elseif ($retryIncompleteAttempt) { 'RETRIED INCOMPLETE EVENT' } else { 'EVENT CLAIMED' }
  Write-Utf8Json $WatcherPath ([ordered]@{ scheduler = $true; heartbeatAt = [datetimeoffset]::Now.ToString('o'); state = $finalState; eventFingerprint = $fingerprint })
}

function Repair-TransientWorkerFailures {
  $rows = @(Get-WorkerRows)
  $retryState = if (Test-Path -LiteralPath $WorkerRetryPath) { Read-Json $WorkerRetryPath } else { [pscustomobject]@{} }
  foreach ($row in $rows) {
    if ($row.State -ne 'NEEDS ATTENTION') { continue }
    $dispatchDir = Join-Path $LogRoot "workers\$($row.Key)\dispatch"
    $errorFile = Get-ChildItem -LiteralPath $dispatchDir -Filter '*.err.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $errorFile) { continue }
    $tail = (Get-Content -LiteralPath $errorFile.FullName -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
    if ($tail -notmatch 'service_unavailable_error|server_is_overloaded') { continue }
    $prior = $retryState.PSObject.Properties[$row.Key]
    $lastRetry = if ($null -ne $prior -and $prior.Value.lastRetryAt) { [datetimeoffset]::Parse([string]$prior.Value.lastRetryAt) } else { [datetimeoffset]::MinValue }
    if (([datetimeoffset]::Now - $lastRetry).TotalMinutes -lt 5) { continue }
    try {
      $script:Worker = [string]$row.Key
      Dispatch-Worker
      $retryState | Add-Member -NotePropertyName $row.Key -NotePropertyValue ([ordered]@{ lastRetryAt = [datetimeoffset]::Now.ToString('o'); reason = 'provider-overloaded'; dispatched = $true }) -Force
    } catch {
      $retryState | Add-Member -NotePropertyName $row.Key -NotePropertyValue ([ordered]@{ lastRetryAt = [datetimeoffset]::Now.ToString('o'); reason = 'provider-overloaded'; dispatched = $false; error = [string]$_ }) -Force
    }
  }
  Write-Utf8Json $WorkerRetryPath $retryState
}

function Start-Watcher {
  if ($null -ne (Get-WatcherProcess)) { Write-Host 'BRAIN watcher is already running.'; return }
  Remove-Item -LiteralPath $WatcherPath -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $BrainLogs -Force | Out-Null
  # Keep the scheduled command in an apostrophe-free path.  schtasks.exe
  # rewrites apostrophes in /TR values and otherwise corrupts this controller's
  # coordination-root path.
  $taskCommand = 'wscript.exe D:\Programs\CodexBrainB\brain-tick-hidden.vbs'
  & schtasks.exe /Create /TN $WatcherTaskName /TR $taskCommand /SC MINUTE /MO 1 /F *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Could not create the scheduled BRAIN watcher tick.' }
  $task = Get-ScheduledTask -TaskName $WatcherTaskName
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
  Set-ScheduledTask -TaskName $WatcherTaskName -Action $task.Actions -Trigger $task.Triggers -Settings $settings | Out-Null
  & schtasks.exe /Run /TN $WatcherTaskName *> $null
  Write-Utf8Json $WatcherPath ([ordered]@{ scheduler = $true; heartbeatAt = [datetimeoffset]::Now.ToString('o'); state = 'SCHEDULED TICK STARTING' })
  Write-Host 'BRAIN watcher scheduled tick started (one isolated check per minute).'
}

function Stop-Watcher {
  & schtasks.exe /End /TN $WatcherTaskName *> $null
  & schtasks.exe /Delete /TN $WatcherTaskName /F *> $null
  if (Test-Path -LiteralPath $SupervisorPath) {
    try {
      $supervisor = Read-Json $SupervisorPath
      $supervisorProcess = Get-Process -Id ([int]$supervisor.pid) -ErrorAction SilentlyContinue
      if ($null -ne $supervisorProcess) { Stop-Process -Id $supervisorProcess.Id }
    } catch {}
    Remove-Item -LiteralPath $SupervisorPath -Force -ErrorAction SilentlyContinue
  }
  $process = Get-WatcherProcess
  if ($null -eq $process) {
    Remove-Item -LiteralPath $WatcherPath -Force -ErrorAction SilentlyContinue
    Write-Host 'BRAIN watcher is not running.'
    return
  }
  if ($process.ProcessId -ne 0) { Stop-Process -Id $process.ProcessId }
  Remove-Item -LiteralPath $WatcherPath -Force -ErrorAction SilentlyContinue
  Write-Host 'BRAIN watcher stopped. Worker sessions were not stopped.'
}

switch ($Action) {
  'login' { Use-BrainHome; & $CodexCommand login --device-auth }
  'budget' {
    $remainingValue = if ($PSBoundParameters.ContainsKey('RemainingPercent')) { [Nullable[double]]$RemainingPercent } else { $null }
    $resetValue = if ($PSBoundParameters.ContainsKey('ResetAt')) { [Nullable[datetime]]$ResetAt } else { $null }
    Set-Budget $remainingValue $resetValue $ReservePercent
  }
  'status' { Show-Status }
  'run' { Invoke-BrainOnce }
  'watch' { Watch-Events }
  'tick' { Invoke-WatcherTick }
  'start' { Start-Watcher }
  'stop' { Stop-Watcher }
  'dispatch' { Dispatch-Worker }
}
