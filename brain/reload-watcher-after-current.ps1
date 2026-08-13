$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LockPath = Join-Path $Root 'brain-run.lock'
$Controller = Join-Path $Root 'brain-control.ps1'

while (Test-Path -LiteralPath $LockPath) {
  Start-Sleep -Seconds 2
}

& $Controller -Action stop
& $Controller -Action start
