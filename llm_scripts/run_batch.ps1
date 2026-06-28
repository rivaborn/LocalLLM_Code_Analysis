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

function Get-EnvVal($key) {
    if (-not (Test-Path $EnvFile)) { return '' }
    foreach ($line in Get-Content $EnvFile) {
        $t = $line.Trim()
        if ($t -match '^\s*#' -or $t -eq '') { continue }
        if ($t -match ('^' + [regex]::Escape($key) + '\s*=\s*(.*)$')) { return $Matches[1].Trim().Trim('"').Trim("'") }
    }
    return ''
}

function Format-Hours($minutes) {
    if ($minutes -ge 60) { '{0:0.0}h' -f ($minutes / 60.0) } else { '{0}m' -f [int][math]::Round($minutes) }
}

# Same include/exclude filters the stages use -- drives the pre-run ETA estimate.
function Get-AnalyzableFileCount($Target) {
    $root = if ($Target -ne '.' -and $Target -ne 'all') { Join-Path $repoRoot $Target } else { $repoRoot }
    if (-not (Test-Path $root)) { return 0 }
    $incRx = Get-EnvVal 'INCLUDE_EXT_REGEX'; if (-not $incRx) { $incRx = '\.(cpp|h|hpp|cc|cxx|inl|cs)$' }
    $excRx = Get-EnvVal 'EXCLUDE_DIRS_REGEX'
    $n = 0
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            if ($f -notmatch $incRx) { continue }
            if ($excRx) { $rel = $f.Substring($repoRoot.Length).TrimStart('\','/') -replace '\\','/'; if ($rel -match $excRx) { continue } }
            $n++
        }
    } catch {}
    return $n
}

function Fmt([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1)       { '{0}h{1:d2}m{2:d2}s' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
    elseif ($ts.TotalMinutes -ge 1) { '{0}m{1:d2}s' -f $ts.Minutes, $ts.Seconds }
    else                            { '{0}s' -f [int]$ts.TotalSeconds }
}

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  run_batch.ps1 - $($Targets.Count) systems" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
foreach ($t in $Targets) { Write-Host "  - $t" }

# --- Pre-run ETA estimate (whole run + per subsystem) -------------
$r = Get-EnvVal 'ETA_MIN_PER_FILE'; $etaRate = if ($r) { [double]$r } else { 3.3 }
$etaRows  = @()
$totalMin = 0
foreach ($t in $Targets) {
    $n = Get-AnalyzableFileCount $t
    $m = $n * $etaRate
    $totalMin += $m
    $etaRows += [pscustomobject]@{ Name = (Split-Path $t -Leaf); Files = $n; Min = $m }
}
Write-Host ""
Write-Host "Estimated run (@ $etaRate min/file):" -ForegroundColor Yellow
foreach ($e in $etaRows) { Write-Host ("  {0,-26} {1,5} files  ~{2}" -f $e.Name, $e.Files, (Format-Hours $e.Min)) }
Write-Host ("  {0,-26} {1,5}        ~{2}  TOTAL" -f '', '', (Format-Hours $totalMin)) -ForegroundColor Yellow

$notifyUrl = Get-EnvVal 'NOTIFY_URL'
if ($notifyUrl) {
    $msg = "Batch starting: $($Targets.Count) systems, est ~$(Format-Hours $totalMin) total`n" +
           (($etaRows | ForEach-Object { "$($_.Name): ~$(Format-Hours $_.Min) ($($_.Files) files)" }) -join "`n")
    try { Invoke-RestMethod -Uri $notifyUrl -Method Post -Body $msg -Headers @{ Title = "batch starting ($($Targets.Count) systems)"; Tags = 'calendar' } -ContentType 'text/plain; charset=utf-8' -TimeoutSec 10 | Out-Null } catch {}
}

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
