# ============================================================
# run_batch.ps1 - run the full pipeline across several targets back-to-back
#
# Thin wrapper over run_pipeline.ps1: runs each -TargetDir in turn, preserves
# each run's "Run Report.md" (run_pipeline overwrites it every run), and prints a
# summary. Per-section push notifications come from run_pipeline itself (set
# NOTIFY_URL in .env); each is prefixed with the subsystem name so a batch is
# distinguishable on the phone.
#
# A failed subsystem does NOT stop the batch -- run_pipeline exits 1 on a failed
# stage, which is captured here and the batch continues to the next target (the
# `& script.ps1; exit` does not terminate this wrapper). Collect + status updates
# remain manual, one subsystem at a time, after the batch.
#
# Usage:
#   .\llm_scripts\run_batch.ps1 -Preset unreal -Jobs 1 -Targets `
#     Engine/Source/Runtime/PhysicsCore, Engine/Source/Runtime/AudioMixer, Engine/Plugins/Online/OnlineSubsystem
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Targets,
    [string]$Preset  = "",
    [int]   $Jobs    = 1,
    [int]   $Top     = 0,
    [switch]$Claude1,
    [switch]$SkipSerena,
    [switch]$SkipPass2,
    [switch]$SkipLoad,
    [string]$EnvFile = ".env"
)

$toolkitDir = $PSScriptRoot
$repoRoot   = (Get-Location).Path
$archDir    = Join-Path $repoRoot 'architecture'
$pipeline   = Join-Path $toolkitDir 'run_pipeline.ps1'
if (-not (Test-Path $pipeline)) { Write-Host "run_pipeline.ps1 not found at $pipeline" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force -Path $archDir | Out-Null

function Fmt([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1)       { '{0}h{1:d2}m{2:d2}s' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
    elseif ($ts.TotalMinutes -ge 1) { '{0}m{1:d2}s' -f $ts.Minutes, $ts.Seconds }
    else                            { '{0}s' -f [int]$ts.TotalSeconds }
}

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  run_batch.ps1 - $($Targets.Count) systems" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
foreach ($t in $Targets) { Write-Host "  - $t" }

$batchStart = Get-Date
$results = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $Targets.Count; $i++) {
    $t    = $Targets[$i]
    $name = Split-Path $t -Leaf
    Write-Host ""
    Write-Host "############ BATCH $($i + 1)/$($Targets.Count): $name ############" -ForegroundColor Magenta
    $start = Get-Date

    $p = @{ TargetDir = $t; EnvFile = $EnvFile; Jobs = $Jobs }
    if ($Preset)     { $p.Preset = $Preset }
    if ($Top -gt 0)  { $p.Top = $Top }
    if ($Claude1)    { $p.Claude1 = $true }
    if ($SkipSerena) { $p.SkipSerena = $true }
    if ($SkipPass2)  { $p.SkipPass2 = $true }
    if ($SkipLoad)   { $p.SkipLoad = $true }

    & $pipeline @p
    $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $dur  = (Get-Date) - $start

    # run_pipeline overwrites architecture/Run Report.md each run -- preserve this one.
    $rpt = Join-Path $archDir 'Run Report.md'
    if (Test-Path $rpt) { Copy-Item $rpt (Join-Path $archDir "Run Report - $name.md") -Force }

    $results.Add([pscustomobject]@{ Name = $name; Ok = ($code -eq 0); Exit = $code; Duration = $dur })
}

$batchDur = (Get-Date) - $batchStart
Write-Host ""
Write-Host "==== BATCH SUMMARY ($(Fmt $batchDur)) ====" -ForegroundColor Cyan
foreach ($r in $results) {
    Write-Host ("  {0,-24} {1,-10} {2}" -f $r.Name, $(if ($r.Ok) { 'OK' } else { "FAIL($($r.Exit))" }), (Fmt $r.Duration)) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' })
}
$okN = @($results | Where-Object Ok).Count
Write-Host ""
Write-Host "$okN/$($results.Count) succeeded. Per-system reports saved as 'architecture/Run Report - <name>.md'." -ForegroundColor $(if ($okN -eq $results.Count) { 'Green' } else { 'Yellow' })
if ($okN -lt $results.Count) { exit 1 }
