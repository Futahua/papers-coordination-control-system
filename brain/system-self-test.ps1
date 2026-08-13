param([switch]$Json)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$LogRoot = Split-Path -Parent $Root
$TaskName = 'PapersCliBrainTick'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
  $results.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Detail = $Detail })
}

foreach ($name in @('budget.json', 'wave.json', 'watcher.json', 'controller-state.json')) {
  $path = Join-Path $Root $name
  try {
    Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json | Out-Null
    Add-Check "JSON $name" $true 'valid'
  } catch { Add-Check "JSON $name" $false $_.Exception.Message }
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Add-Check 'scheduler exists and enabled' ($null -ne $task -and $task.State -ne 'Disabled') $(if ($task) { [string]$task.State } else { 'missing' })
if ($task) {
  Add-Check 'scheduler overlap policy' ($task.Settings.MultipleInstances -eq 'IgnoreNew') ([string]$task.Settings.MultipleInstances)
  Add-Check 'scheduler battery-safe' (-not $task.Settings.DisallowStartIfOnBatteries -and -not $task.Settings.StopIfGoingOnBatteries) ('no-start={0}; stop={1}' -f $task.Settings.DisallowStartIfOnBatteries, $task.Settings.StopIfGoingOnBatteries)
  Add-Check 'scheduler runtime limit' ($task.Settings.ExecutionTimeLimit -eq 'PT15M') ([string]$task.Settings.ExecutionTimeLimit)
  $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
  Add-Check 'scheduler last result' ($null -ne $info -and ($info.LastTaskResult -eq 0 -or $task.State -eq 'Running')) $(if ($info) { [string]$info.LastTaskResult } else { 'unknown' })
}

$watcher = Get-Content -LiteralPath (Join-Path $Root 'watcher.json') -Raw -Encoding utf8 | ConvertFrom-Json
$heartbeatAge = [double]::PositiveInfinity
try { $heartbeatAge = ([datetimeoffset]::Now - [datetimeoffset]::Parse([string]$watcher.heartbeatAt)).TotalSeconds } catch {}
$lockPath = Join-Path $Root 'brain-run.lock'
$busy = Test-Path -LiteralPath $lockPath
Add-Check 'watcher evidence' ($heartbeatAge -lt 240 -or $busy) ('heartbeat={0:N0}s; busy={1}' -f $heartbeatAge, $busy)
if ($busy) {
  $lockAge = ((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalMinutes
  Add-Check 'active lock age' ($lockAge -lt 15) ('{0:N1}m' -f $lockAge)
}

$wave = Get-Content -LiteralPath (Join-Path $Root 'wave.json') -Raw -Encoding utf8 | ConvertFrom-Json
$controllerText = Get-Content -LiteralPath (Join-Path $Root 'brain-control.ps1') -Raw -Encoding utf8
if ($controllerText -notmatch "'DISPATCH_READY'") {
  throw 'Controller readiness states omit DISPATCH_READY; completed reports can be stranded.'
}
if (-not ($controllerText.Contains("State -eq 'REPORT READY'") -and $controllerText.Contains('return $true'))) {
  throw 'Controller still globally blocks completed-report review behind running workers.'
}
if ($controllerText -notmatch 'Select-Object Worker, Key, State, Report, Bytes') {
  throw 'Event fingerprint is not restricted to stable worker decision fields.'
}
if ($controllerText -notmatch '\$retryIncompleteAttempt = \$false') {
  throw 'Controller can automatically retry an unchanged claimed event.'
}
if ($controllerText -notmatch 'Assert-BrainOutputSafety') {
  throw 'Mechanical eye-check rollback gate is missing.'
}
if ($controllerText -match "'exec', '--ephemeral'") {
  throw 'CLI BRAIN still creates ephemeral sessions.'
}
if ($controllerText -notmatch "'exec', 'resume'" -or $controllerText -notmatch 'brainSession\.sessionId') {
  throw 'CLI BRAIN does not resume its durable session id.'
}
if ($controllerText -notmatch "(?s)'exec', 'resume'.{0,300}--dangerously-bypass-approvals-and-sandbox") {
  throw 'Resumed CLI BRAIN turns lack write/dispatch authority.'
}
if ($controllerText -notmatch 'FileMode\]::CreateNew') { throw 'BRAIN lock acquisition is not atomic.' }
if ($controllerText -notmatch 'turnCompleted.*completedOutput') { throw 'BRAIN completion does not require both current JSON completion and current output.' }
if ($controllerText -notmatch 'lastCompletedFingerprint = \$attemptFingerprint') {
  throw 'Controller can swallow a worker report written during an active BRAIN turn.'
}
if ($controllerText -notmatch 'Get-WorkerAssistEvents' -or $controllerText -notmatch 'Mark-WorkerAssistEventsHandled') {
  throw 'Technical-lead assistance events are not detected and persisted.'
}
if ($controllerText -notmatch 'NO_MATERIAL_ACTIVITY' -or $controllerText -notmatch 'LONG_RUNNING_WITHOUT_REPORT') {
  throw 'Worker inactivity escalation thresholds are missing.'
}
foreach ($leadHintPart in @('LEAD HINT:', 'mechanism=', 'first=', 'avoid=', 'proof=', 'stop=', 'TASK:')) {
  if (-not $controllerText.Contains($leadHintPart)) { throw "Dispatch does not enforce lead-hint field $leadHintPart" }
}
if ($controllerText -notmatch '\$reasoningEffort = if' -or $controllerText -notmatch "'medium'" -or $controllerText -notmatch "'low'") {
  throw 'BRAIN reasoning is not dynamically routed between routine and intervention turns.'
}
if ($controllerText -notmatch '\$contract = Get-Content -LiteralPath \$InstructionsPath' -or $controllerText -notmatch 'Status: READY.*executable authority') {
  throw 'A corrected BRAIN contract cannot retry an incomplete claimed request or requires generic manager direction.'
}
$workerRunText = Get-Content -LiteralPath (Join-Path $Root 'worker-run.ps1') -Raw -Encoding utf8
$workerHubText = Get-Content -LiteralPath (Join-Path $LogRoot 'worker-hub.ps1') -Raw -Encoding utf8
if ($workerRunText -notmatch 'three materially distinct failed hypotheses' -or $workerRunText -notmatch 'send the CLI BRAIN.*help') {
  throw 'Dispatched workers lack the bounded hypothesis/help escalation contract.'
}
if ($workerRunText -notmatch 'Before reading product source or invoking any tool' -or $workerRunText -notmatch 'Treat the mechanism as a prioritized hypothesis') {
  throw 'Workers do not consume the BRAIN lead hint before beginning work.'
}
if ($workerHubText -notmatch 'three materially distinct failed hypotheses' -or $workerHubText -notmatch 'Do not silently loop') {
  throw 'Woken workers lack the bounded hypothesis/help escalation contract.'
}
$sessionPath = Join-Path $Root 'brain-session.json'
if (Test-Path -LiteralPath $sessionPath) {
  try {
    $session = Get-Content -LiteralPath $sessionPath -Raw -Encoding utf8 | ConvertFrom-Json
    $validId = [guid]::Empty
    Add-Check 'persistent Terra session' ([guid]::TryParse([string]$session.sessionId, [ref]$validId) -and $session.model -eq 'gpt-5.6-terra' -and [int]$session.turnCount -ge 1) ('id={0}; model={1}; turns={2}' -f $session.sessionId, $session.model, $session.turnCount)
  } catch { Add-Check 'persistent Terra session' $false $_.Exception.Message }
}
$truthPath = Join-Path $Root 'current-truth.md'
$eyeGatePath = Join-Path $Root 'eye-check-gate.json'
Add-Check 'manager continuity truth exists' (Test-Path -LiteralPath $truthPath -PathType Leaf) $truthPath
try {
  $eyeGate = Get-Content -LiteralPath $eyeGatePath -Raw -Encoding utf8 | ConvertFrom-Json
  Add-Check 'eye-check gate is explicit' ($null -ne $eyeGate.eligible -and $eyeGate.authority -eq 'mechanical-evidence-or-desktop-manager') ('eligible={0}; authority={1}' -f $eyeGate.eligible, $eyeGate.authority)
} catch { Add-Check 'eye-check gate is explicit' $false $_.Exception.Message }
if ($controllerText -notmatch 'uninterruptedSoakMinutes' -or $controllerText -notmatch 'evidenceReceipts') {
  throw 'Eye-check candidate lacks mechanical soak/evidence validation.'
}
$bridge = 'D:\Letters\MatTroiSeConMoc\Papers\Backpack projects\As you Go\BRAIN-WORKER.txt'
$tail = if (Test-Path -LiteralPath $bridge) { (Get-Content -LiteralPath $bridge -Tail 120 -Encoding utf8) -join "`n" } else { '' }
$waveId = [string]$wave.waveId
$waveNumber = [regex]::Match($waveId, '^\d+').Value
$waveEvidence = if ($waveNumber) { "(?m)^.*$([regex]::Escape($waveNumber)).*$" } else { [regex]::Escape($waveId) }
Add-Check 'current wave authoritative handoff' ($tail -match $waveEvidence -and $tail -match 'AUTHORITATIVE EOF') $waveId

$failed = @($results | Where-Object { -not $_.Passed })
if ($Json) {
  [pscustomobject]@{ ok = $failed.Count -eq 0; checkedAt = [datetimeoffset]::Now.ToString('o'); checks = $results } | ConvertTo-Json -Depth 5
} else {
  $results | Format-Table -AutoSize
  Write-Host ''
  Write-Host $(if ($failed.Count -eq 0) { 'SYSTEM SELF-CHECK: PASS' } else { "SYSTEM SELF-CHECK: FAIL ($($failed.Count))" })
}
if ($failed.Count -gt 0) { exit 1 }
