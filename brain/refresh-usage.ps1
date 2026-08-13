param(
  [int]$TailBytes = 8388608
)

$ErrorActionPreference = 'Stop'
$BudgetPath = Join-Path $PSScriptRoot 'budget.json'
$BrainHome = 'D:\Programs\CodexBrainB'
$AuthPath = Join-Path $BrainHome 'auth.json'
$today = Get-Date
# Include yesterday so the midnight rollover cannot discard a still-current
# session and fall back to an arbitrarily old archive record.
$datePaths = @(0, 1 | ForEach-Object {
  $day = $today.AddDays(-$_)
  Join-Path (Join-Path $day.ToString('yyyy') $day.ToString('MM')) $day.ToString('dd')
})
# The dashboard is the Account B / persistent-Brain dashboard.  Never merge
# desktop Codex sessions here: an old desktop rate-limit event can overwrite
# the actual Brain account after an account change.
$activeDirs = @($datePaths | ForEach-Object {
  Join-Path 'D:\Programs\CodexBrainB\sessions' $_
})
$archiveDirs = @('D:\Programs\CodexBrainB\archived_sessions')

$files = @($activeDirs | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
  Get-ChildItem -LiteralPath $_ -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 4
})
if ($files.Count -eq 0) {
  $files = @($archiveDirs | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 4
  })
}

$telemetryRows = @()
foreach ($file in $files) {
  $stream = [System.IO.File]::Open(
    $file.FullName,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite
  )
  try {
    $count = [int][Math]::Min([long]$TailBytes, $stream.Length)
    if ($count -le 0) { continue }
    $null = $stream.Seek(-$count, [System.IO.SeekOrigin]::End)
    $buffer = New-Object byte[] $count
    $read = $stream.Read($buffer, 0, $count)
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
  } finally {
    $stream.Dispose()
  }

  $matches = [regex]::Matches(
    $text,
    '\{"timestamp":"([^"]+)"[^\r\n]*?"rate_limits":\{"limit_id":"codex".*?"used_percent":([0-9.]+).*?"resets_at":([0-9]+)'
  )
  if ($matches.Count -gt 0) {
    $match = $matches[$matches.Count - 1]
    $telemetryRows += [pscustomobject]@{
      EventAt = [datetimeoffset]::Parse([string]$match.Groups[1].Value)
      UsedPercent = [double]$match.Groups[2].Value
      ResetAt = [datetimeoffset]::FromUnixTimeSeconds([long]$match.Groups[3].Value).ToLocalTime()
      SourceFile = $file.FullName
    }
  }
}

$authChangedAt = if (Test-Path -LiteralPath $AuthPath) {
  [datetimeoffset](Get-Item -LiteralPath $AuthPath).LastWriteTimeUtc
} else {
  [datetimeoffset]::MinValue
}
# Authentication is an account boundary.  A rate-limit event written before
# the current private Brain credential was saved belongs to the previous
# account and must never be used as current usage.
$telemetryRows = @($telemetryRows | Where-Object { $_.EventAt -ge $authChangedAt })
$telemetry = $telemetryRows | Sort-Object EventAt -Descending | Select-Object -First 1
if ($null -eq $telemetry) { exit 2 }

$budget = Get-Content -LiteralPath $BudgetPath -Raw -Encoding utf8 | ConvertFrom-Json
$now = [datetimeoffset]::Now
$telemetryAge = $now - $telemetry.EventAt
# Never mutate displayed usage from stale evidence. The caller may continue
# showing the last credible value with an explicit STALE label.
if ($telemetryAge.TotalMinutes -gt 15) { exit 3 }
$remaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - $telemetry.UsedPercent))
$sameWindow = $false
try { $sameWindow = [Math]::Abs((([datetimeoffset]::Parse([string]$budget.resetAt)) - $telemetry.ResetAt).TotalMinutes) -lt 2 } catch {}
if ($sameWindow -and $remaining -gt ([double]$budget.remainingPercent + 0.1)) { exit 4 }
$changed = [Math]::Abs([double]$budget.remainingPercent - $remaining) -ge 0.05 -or
  ([datetimeoffset]::Parse([string]$budget.resetAt) -ne $telemetry.ResetAt)

$value = [ordered]@{
  updatedAt = if ($changed) { $now.ToString('o') } else { [string]$budget.updatedAt }
  observedAt = $telemetry.EventAt.ToString('o')
  source = 'codex-session-rate-limits'
  remainingPercent = $remaining
  usedPercent = $telemetry.UsedPercent
  resetAt = $telemetry.ResetAt.ToString('o')
  reservePercent = [double]$budget.reservePercent
  warningPercent = [double]$budget.warningPercent
  maxAutomaticRunsPerDay = [int]$budget.maxAutomaticRunsPerDay
  maxTerraRunsPerDay = [int]$budget.maxTerraRunsPerDay
  automaticRuns = [bool]$budget.automaticRuns
}

$json = $value | ConvertTo-Json -Depth 4
$temp = "$BudgetPath.refresh-$PID.tmp"
[System.IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temp -Destination $BudgetPath -Force

Write-Output ("{0:N1}% remaining; reset {1:o}" -f $remaining, $telemetry.ResetAt)
