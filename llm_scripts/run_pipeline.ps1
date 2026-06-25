# ============================================================
# run_pipeline.ps1 - End-to-end pipeline orchestrator
#
# Runs the full architecture-doc pipeline in order, writes a
# "Run Report.md", and STOPS after any stage that has failures
# (the stage is completed first, then its failed files + reasons
# are listed in the report, and the pipeline exits).
#
# On the ollama backend the pipeline talks to raw Ollama (:11434), which
# bypasses the LLMConfig gateway's GPU arbitration. A pre-flight step POSTs
# the model to the gateway's /api/load (:11430) so Ollama owns the GPU's VRAM
# before the run; best-effort (warns, does not abort). Skip with -SkipLoad.
#
# Stages (0b archgen_dirs is claude-only and auto-skipped on local):
#   0   serena_extract.ps1      LSP extraction (free)
#   0b  archgen_dirs.ps1        dir overviews (claude only)
#   1   archgen.ps1             Pass 1 per-file docs
#   2   archxref.ps1            cross-reference index (free)
#   3   archgraph.ps1           call graphs (free)
#   4   arch_overview.ps1       subsystem overview
#   4b  archpass2_context.ps1   targeted Pass 2 context (free)
#   5   archpass2.ps1           Pass 2 enrichment
#
# Per-file failure handling: archgen/archpass2 run in "continue on
# error" mode (env ARCH_CONTINUE_ON_ERROR) so a failing file is
# recorded to <state>/failures.tsv instead of aborting the stage.
#
# Usage:
#   .\llm_scripts\run_pipeline.ps1 -Preset unreal -TargetDir Engine/Source/Runtime/RHI -Jobs 1 -Top 40
#   .\llm_scripts\run_pipeline.ps1 -Preset unreal -TargetDir Engine/Source/Runtime/RHI -SkipSerena
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir  = ".",
    [string]$Preset     = "",
    [int]   $Jobs       = 0,
    [int]   $Top        = 0,
    [switch]$Claude1,
    [switch]$SkipSerena,
    [switch]$SkipPass2,
    [switch]$SkipLoad,
    [string]$EnvFile    = ".env",
    [string]$ReportPath = ""
)

$toolkitDir = $PSScriptRoot
$repoRoot   = (Get-Location).Path
$archDir    = Join-Path $repoRoot 'architecture'
New-Item -ItemType Directory -Force -Path $archDir | Out-Null
if (-not $ReportPath) { $ReportPath = Join-Path $archDir 'Run Report.md' }

# --- helpers ------------------------------------------------------

function Get-EnvVal($key) {
    if (-not (Test-Path $EnvFile)) { return '' }
    foreach ($line in Get-Content $EnvFile) {
        $t = $line.Trim()
        if ($t -match '^\s*#' -or $t -eq '') { continue }
        if ($t -match ('^' + [regex]::Escape($key) + '\s*=\s*(.*)$')) {
            $v = $Matches[1].Trim().Trim('"').Trim("'")
            return ($v -replace [regex]::Escape('$HOME'), $env:USERPROFILE)
        }
    }
    return ''
}

function Format-Duration([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1)        { '{0}h{1:d2}m{2:d2}s' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
    elseif ($ts.TotalMinutes -ge 1)  { '{0}m{1:d2}s' -f $ts.Minutes, $ts.Seconds }
    else                             { '{0}s' -f [int]$ts.TotalSeconds }
}

function Format-MdTable($headers, $rows) {
    $cols = $headers.Count
    $w = New-Object 'int[]' $cols
    for ($i = 0; $i -lt $cols; $i++) { $w[$i] = ([string]$headers[$i]).Length }
    foreach ($r in $rows) { for ($i = 0; $i -lt $cols; $i++) { $s = [string]$r[$i]; if ($s.Length -gt $w[$i]) { $w[$i] = $s.Length } } }
    $out = @()
    $hc = @(); for ($i = 0; $i -lt $cols; $i++) { $hc += ([string]$headers[$i]).PadRight($w[$i]) }
    $out += "| " + ($hc -join " | ") + " |"
    $sp = @(); for ($i = 0; $i -lt $cols; $i++) { $sp += ('-' * $w[$i]) }
    $out += "| " + ($sp -join " | ") + " |"
    foreach ($r in $rows) { $c = @(); for ($i = 0; $i -lt $cols; $i++) { $c += ([string]$r[$i]).PadRight($w[$i]) }; $out += "| " + ($c -join " | ") + " |" }
    ($out -join "`n")
}

$script:results  = @()
$script:runStart = Get-Date

function Write-RunReport($Overall) {
    $now      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $totalDur = (Get-Date) - $script:runStart

    $scanRoot = if ($TargetDir -ne '.' -and $TargetDir -ne 'all') { Join-Path $archDir $TargetDir } else { $archDir }
    $allMd = @(Get-ChildItem $scanRoot -Filter *.md -Recurse -ErrorAction SilentlyContinue)
    $pass2 = @($allMd | Where-Object { $_.Name -like '*.pass2.md' })
    $pass1 = $allMd.Count - $pass2.Count

    $o = @()
    $o += "# Run Report"
    $o += ""
    $o += "- **Generated:** $now"
    $o += "- **Codebase:** ``$repoRoot``"
    $o += "- **Target:** ``$TargetDir``"
    $o += "- **Backend / model:** $script:backend / $script:model"
    $o += "- **Jobs:** $(if ($Jobs -gt 0) { $Jobs } else { '(from .env)' })  |  **Pass 2 Top:** $(if ($Top -gt 0) { $Top } else { 'all' })"
    $o += "- **Overall:** $Overall"
    $o += "- **Total duration:** $(Format-Duration $totalDur)"
    $o += ""
    $o += "## Stages"
    $o += ""
    $rows = @()
    foreach ($r in $script:results) {
        $done = if ($r.Counts) { [string]$r.Counts.done } else { '-' }
        $fail = if ($r.Counts) { [string]$r.Counts.fail } else { [string]@($r.Fails).Count }
        $skip = if ($r.Counts) { [string]$r.Counts.skip } else { '-' }
        $rows += , @($r.Name, $r.Status, (Format-Duration $r.Duration), $done, $fail, $skip)
    }
    $o += (Format-MdTable @('Stage', 'Status', 'Duration', 'Done', 'Fail', 'Skip') $rows)

    $failedStages = @($script:results | Where-Object { $_.Status -eq 'FAILED' })
    if ($failedStages.Count -gt 0) {
        $o += ""
        $o += "## Failures"
        foreach ($r in $failedStages) {
            $o += ""
            $o += "### $($r.Name)"
            if (@($r.Fails).Count -gt 0) {
                $frows = @()
                foreach ($line in $r.Fails) {
                    $p = $line -split "`t", 3
                    $frows += , @($p[0], $(if ($p.Count -gt 1) { $p[1] } else { '' }), $(if ($p.Count -gt 2) { $p[2] } else { '' }))
                }
                $o += (Format-MdTable @('File', 'Type', 'Reason') $frows)
            } else {
                $o += "- Stage exited with code $($r.ExitCode)$(if ($r.Note) { " -- $($r.Note)" })."
                $o += "- See the stage's console output / state logs under ``architecture/``."
            }
        }
    }

    $o += ""
    $o += "## Outputs (under target scope)"
    $o += ""
    $o += "- Pass 1 docs: $pass1"
    $o += "- Pass 2 docs: $($pass2.Count)"
    $o += "- Output root: ``$scanRoot``"

    Set-Content -LiteralPath $ReportPath -Value ($o -join "`n") -Encoding UTF8
}

# $Params is a HASHTABLE (named-parameter splat). NOTE: splatting an ARRAY binds
# positionally in PowerShell, which mis-binds named params -- always use a hashtable.
function Invoke-Stage($Name, $ScriptName, $Params, $Kind, $StateDir) {
    $path = Join-Path $toolkitDir $ScriptName
    $argStr = (($Params.GetEnumerator() | ForEach-Object { if ($_.Value -is [bool] -and $_.Value) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value)" } }) -join ' ')
    Write-Host ""
    Write-Host "===== STAGE: $Name  ($ScriptName $argStr) =====" -ForegroundColor Cyan
    if (-not (Test-Path $path)) {
        $script:results += [pscustomobject]@{ Name = $Name; Status = 'FAILED'; Duration = [TimeSpan]::Zero; ExitCode = -1; Counts = $null; Fails = @(); Note = "script not found: $ScriptName" }
        Write-Host "STAGE FAILED: $Name -- script not found" -ForegroundColor Red
        Write-RunReport "FAILED at stage: $Name (script not found)"
        Write-Host "Run report: $ReportPath" -ForegroundColor Yellow
        exit 1
    }

    $failsFile = if ($Kind -eq 'perfile' -and $StateDir) { Join-Path $StateDir 'failures.tsv' } else { '' }
    if ($failsFile -and (Test-Path $failsFile)) { Remove-Item $failsFile -Force -ErrorAction SilentlyContinue }

    $start = Get-Date
    $global:LASTEXITCODE = 0
    $note = ''
    if ($Kind -eq 'perfile') { $env:ARCH_CONTINUE_ON_ERROR = '1' }
    try {
        & $path @Params
        $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } catch {
        $code = 1
        $note = $_.Exception.Message
    } finally {
        $env:ARCH_CONTINUE_ON_ERROR = $null
    }
    $dur = (Get-Date) - $start

    $fails = @()
    if ($failsFile -and (Test-Path $failsFile)) { $fails = @(Get-Content $failsFile -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' }) }
    $counts = $null
    if ($Kind -eq 'perfile' -and $StateDir) {
        $cp = Join-Path $StateDir 'counter.json'
        if (Test-Path $cp) { try { $counts = Get-Content $cp -Raw -ErrorAction Stop | ConvertFrom-Json } catch {} }
    }

    $isFail = ($fails.Count -gt 0) -or ($code -ne 0)
    $script:results += [pscustomobject]@{ Name = $Name; Status = $(if ($isFail) { 'FAILED' } else { 'OK' }); Duration = $dur; ExitCode = $code; Counts = $counts; Fails = $fails; Note = $note }

    if ($isFail) {
        Write-Host "STAGE FAILED: $Name (exit=$code, file-failures=$($fails.Count))" -ForegroundColor Red
        Write-RunReport "FAILED at stage: $Name"
        Write-Host "Run report: $ReportPath" -ForegroundColor Yellow
        exit 1
    }
    Write-Host ("STAGE OK: {0}  ({1})" -f $Name, (Format-Duration $dur)) -ForegroundColor Green
}

# --- resolve backend ----------------------------------------------

$script:backend = Get-EnvVal 'LLM_BACKEND'; if (-not $script:backend) { $script:backend = 'ollama' }
$script:model   = if ($script:backend -eq 'claude') { Get-EnvVal 'CLAUDE_MODEL' } else { Get-EnvVal 'LLM_DEFAULT_MODEL' }
if (-not $script:model) { $script:model = '(default)' }

# Pre-flight: arbitrate the GPU for Ollama. The ollama backend hits raw Ollama
# (:11434) directly, bypassing the gateway's GPU arbitration, so we POST the model
# to the gateway's /api/load (:11430) once before the run -- this evicts any other
# resident model (e.g. vLLM) and hands the card to Ollama. Best-effort: a failure
# warns but does not abort (Ollama still lazy-loads on first request, just without
# arbitration). vllm self-loads through the gateway already; claude needs no GPU.
function Invoke-ModelPreload($Model) {
    $gwHost = Get-EnvVal 'LLM_HOST';         if (-not $gwHost) { $gwHost = '192.168.1.40' }
    $gwPort = Get-EnvVal 'LLM_GATEWAY_PORT'; if (-not $gwPort) { $gwPort = '11430' }
    $uri  = "http://${gwHost}:${gwPort}/api/load"
    $body = @{ server = 'ollama'; model = $Model } | ConvertTo-Json -Compress
    Write-Host ""
    Write-Host "===== PRE-FLIGHT: load '$Model' on GPU via gateway ($uri) =====" -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600 | Out-Null
        Write-Host "Gateway load OK: '$Model' resident on Ollama (GPU arbitrated)." -ForegroundColor Green
    } catch {
        Write-Host "WARNING: gateway pre-load failed -- $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "         Continuing; Ollama will lazy-load on first request WITHOUT gateway" -ForegroundColor Yellow
        Write-Host "         arbitration, so the model may land partially on CPU. To load manually:" -ForegroundColor Yellow
        Write-Host "         POST $uri  {`"server`":`"ollama`",`"model`":`"$Model`"}" -ForegroundColor Yellow
    }
}

$archState = Join-Path $archDir '.archgen_state'
$pass2St   = Join-Path $archDir '.pass2_state'

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  run_pipeline.ps1 - full pipeline" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "Backend / model: $script:backend / $script:model"
Write-Host "Target:          $TargetDir"
Write-Host "Report:          $ReportPath"

if ($script:backend -eq 'ollama' -and -not $SkipLoad) { Invoke-ModelPreload $script:model }

# --- run stages in order (hashtable splat = named binding) ---------

if (-not $SkipSerena) {
    $p = @{ TargetDir = $TargetDir; EnvFile = $EnvFile; Workers = 2; Jobs = 2 }
    if ($Preset) { $p.Preset = $Preset }
    Invoke-Stage 'serena_extract (LSP)' 'serena_extract.ps1' $p 'free' ''
}
if ($script:backend -eq 'claude') {
    $p = @{ TargetDir = $TargetDir; EnvFile = $EnvFile }
    if ($Preset)  { $p.Preset = $Preset }
    if ($Claude1) { $p.Claude1 = $true }
    Invoke-Stage 'archgen_dirs (dir overviews)' 'archgen_dirs.ps1' $p 'free' ''
}

$p = @{ TargetDir = $TargetDir; EnvFile = $EnvFile }
if ($Preset)     { $p.Preset = $Preset }
if ($Jobs -gt 0) { $p.Jobs = $Jobs }
if ($Claude1)    { $p.Claude1 = $true }
Invoke-Stage 'archgen (Pass 1)' 'archgen.ps1' $p 'perfile' $archState

Invoke-Stage 'archxref'          'archxref.ps1'          @{ TargetDir = $TargetDir; EnvFile = $EnvFile } 'free' ''
Invoke-Stage 'archgraph'         'archgraph.ps1'         @{ TargetDir = $TargetDir; EnvFile = $EnvFile } 'free' ''

$p = @{ TargetDir = $TargetDir; EnvFile = $EnvFile }
if ($Claude1) { $p.Claude1 = $true }
Invoke-Stage 'arch_overview'     'arch_overview.ps1'     $p 'free' ''

Invoke-Stage 'archpass2_context' 'archpass2_context.ps1' @{ TargetDir = $TargetDir; EnvFile = $EnvFile } 'free' ''

if (-not $SkipPass2) {
    $p = @{ TargetDir = $TargetDir; EnvFile = $EnvFile }
    if ($Jobs -gt 0) { $p.Jobs = $Jobs }
    if ($Top -gt 0)  { $p.Top = $Top }
    if ($Claude1)    { $p.Claude1 = $true }
    Invoke-Stage 'archpass2 (Pass 2)' 'archpass2.ps1' $p 'perfile' $pass2St
}

Write-RunReport 'SUCCESS - all stages completed'
Write-Host ""
Write-Host "Pipeline complete. Run report: $ReportPath" -ForegroundColor Green
