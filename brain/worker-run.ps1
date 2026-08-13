param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('winter', 'gazelle', 'roketpuncha', 'ning')]
  [string]$Worker
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LogRoot = Split-Path -Parent $Root
$Registry = Get-Content -LiteralPath (Join-Path $LogRoot 'worker-registry.json') -Raw | ConvertFrom-Json
$Wave = Get-Content -LiteralPath (Join-Path $Root 'wave.json') -Raw | ConvertFrom-Json
$Bridge = 'D:\Letters\MatTroiSeConMoc\Papers\Backpack projects\As you Go\BRAIN-WORKER.txt'
$SessionId = [string]$Registry.$Worker.sessionId
$Lane = $Wave.workers.$Worker

if ($Lane.active -ne $true) { throw "$Worker lane is not active." }
if ([string]$Lane.status -in @('LANE_COMPLETE', 'COMPLETE', 'STOPPED')) { throw "$Worker lane is already complete; refusing duplicate dispatch." }
if ([string]::IsNullOrWhiteSpace($SessionId)) { throw "$Worker session ID is missing." }

$prompt = @"
You are $($Registry.$Worker.displayName), one of four OpenCode workers coordinated by the Account B CLI BRAIN.
Read the latest authoritative EOF assignment for your name in $Bridge.
Wave assignment summary: $($Lane.assignment)
Required compact report: $(Join-Path $LogRoot ([string]$Lane.report))
Before reading product source or invoking any tool, parse the assignment's LEAD HINT and state in one concise sentence how its `mechanism`, `first`, `avoid`, `proof`, and `stop` fields shape your opening move. Then begin with `first`. Treat the mechanism as a prioritized hypothesis, not an assumed fact. If any lead-hint field is absent, stop and send BRAIN a blocker instead of improvising a broad investigation.
Work only inside that bounded lane. Use inexpensive subagents only for concrete independent subtasks. Do not broaden authority. Produce the compact report and STOP.
Maintain a short hypothesis ledger while diagnosing. After three materially distinct failed hypotheses, or after 12 minutes without new concrete evidence, stop exploratory retries and send the CLI BRAIN a `help` ping containing: the three attempts, the last literal evidence, your current best mechanism, and the smallest discriminating decision/test needed. Continue only safe work that does not repeat those attempts. Long declared soaks instead emit a concise progress ping at least every 20 minutes with elapsed duration and current cleanup/resource state.
If you are blocked, need a coordination decision, detect a lane conflict, or cannot complete the required report, immediately notify the CLI BRAIN by running:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$LogRoot\worker-hub.ps1" -Action send -From $Worker -To brain -Kind blocker -Message "<concise blocker plus evidence and the decision needed>"
Do not merely leave the problem in a document or transcript. Continue safe in-lane work if possible after sending the ping.
"@

& opencode run --session $SessionId --dir 'D:\' $prompt
if ($LASTEXITCODE -ne 0) { throw "OpenCode exited with code $LASTEXITCODE." }
