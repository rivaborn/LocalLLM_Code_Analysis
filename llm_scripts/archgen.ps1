# ============================================================
# archgen.ps1 — File-Level Architecture Doc Generator
#
# Generates one .md doc per source file for any game engine codebase.
#
# Requires archgen_worker.ps1 in the same directory.
#
# Usage:
#   .\archgen.ps1 [-TargetDir <path>] [-Preset <n>] [-Claude1] [-Clean] [-NoHeaders] [-Jobs <n>]
#
# Examples:
#   .\archgen.ps1 -Preset unreal
#   .\archgen.ps1 -TargetDir Engine\Source\Runtime\Renderer -Preset unreal
#   .\archgen.ps1 -Preset quake -Jobs 4
#   .\archgen.ps1 -Clean
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir = ".",
    [string]$Preset    = "",
    [switch]$Claude1,
    [switch]$Clean,
    [switch]$NoHeaders,
    [int]   $Jobs      = 0,
    [string]$EnvFile   = ".env",
    [string]$ElideSource = "",
    [string]$NoBatch = "",
    [string]$NoPreamble = "",
    [string]$MaxTokens = "",
    [string]$JsonOutput = "",
    [string]$CompressLSP = "",
    [string]$Classify = "",
    [switch]$Test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Err($msg)  { Write-Host $msg -ForegroundColor Red }
function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }

function Read-EnvFile($path) {
    $vars = @{}
    if (Test-Path $path) {
        Get-Content $path | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^#' -or $line -eq '') { return }
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                $val = $val -replace [regex]::Escape('$HOME'), $env:USERPROFILE
                $val = $val -replace '^~', $env:USERPROFILE
                $vars[$key] = $val
            }
        }
    }
    return $vars
}

function Get-SHA1($filePath) {
    $sha   = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-Preset($name) {
    switch ($name.ToLower()) {
        { $_ -in @('quake','quake2','quake3','doom','idtech') } {
            return @{
                Include = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
                Exclude = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|x64|Win32|\.vs|\.vscode|baseq2|baseq3|base)([/\\]|$)'
                Desc    = 'C game engine codebase (id Software / Quake-family)'
                Fence   = 'c'
            }
        }
        { $_ -in @('unreal','ue4','ue5') } {
            return @{
                Include = '\.(cpp|h|hpp|cc|cxx|inl|cs)$'
                Exclude = '[/\\](\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|ThirdParty|GeneratedFiles|AutomationTool)([/\\]|$)'
                Desc    = 'Unreal Engine C++/C# source (Epic Games). Core, CoreUObject, Engine, Renderer, PhysicsCore/Chaos, AudioMixerCore, AIModule, GameplayAbilities (GAS), Slate/UMG, NetworkCore.'
                Fence   = 'cpp'
            }
        }
        'godot' {
            return @{
                Include = '\.(cpp|h|hpp|c|cc|gd|gdscript|tscn|tres|cs)$'
                Exclude = '[/\\](\.git|architecture|\.godot|\.import|build|export)([/\\]|$)'
                Desc    = 'Godot engine codebase (C++/GDScript/C#)'
                Fence   = 'cpp'
            }
        }
        'unity' {
            return @{
                Include = '\.(cs|shader|cginc|hlsl|compute|glsl|cpp|c|h)$'
                Exclude = '[/\\](\.git|architecture|Library|Temp|Obj|Build|Builds|Logs|UserSettings|\.vs)([/\\]|$)'
                Desc    = 'Unity game codebase (C#/shader)'
                Fence   = 'csharp'
            }
        }
        { $_ -in @('source','valve') } {
            return @{
                Include = '\.(cpp|h|hpp|c|cc|cxx|inl|inc|vpc|vgc)$'
                Exclude = '[/\\](\.git|architecture|build|out|obj|bin|Debug|Release|lib|thirdparty)([/\\]|$)'
                Desc    = 'Source Engine codebase (Valve / C++)'
                Fence   = 'cpp'
            }
        }
        'rust' {
            return @{
                Include = '\.(rs|toml)$'
                Exclude = '[/\\](\.git|architecture|target|\.cargo)([/\\]|$)'
                Desc    = 'Rust game engine codebase'
                Fence   = 'rust'
            }
        }
        '' {
            return @{
                Include = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc|cs|java|py|rs|lua|gd|gdscript|m|mm|swift)$'
                Exclude = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|\.vs|\.vscode|node_modules|\.godot|Library|Temp)([/\\]|$)'
                Desc    = 'game engine / game codebase'
                Fence   = 'c'
            }
        }
        default {
            Write-Err "Unknown preset: $name. Available: quake, doom, unreal, godot, unity, source, rust"
            exit 2
        }
    }
}

# ── Load config ───────────────────────────────────────────────

$cfg = Read-EnvFile $EnvFile

function Cfg($key, $default = '') {
    if ($cfg.ContainsKey($key) -and $cfg[$key] -ne '') { return $cfg[$key] }
    return $default
}

$presetName   = if ($Preset -ne '') { $Preset } else { Cfg 'PRESET' '' }
$presetData   = Get-Preset $presetName
$defaultModel = Cfg 'CLAUDE_MODEL'         'sonnet'
$model        = $defaultModel
$maxTurns     = Cfg 'CLAUDE_MAX_TURNS'     '1'
$outputFmt    = Cfg 'CLAUDE_OUTPUT_FORMAT' 'text'
$jobCount     = if ($Jobs -gt 0) { $Jobs } else { [int](Cfg 'JOBS' '2') }
$maxRetries   = [int](Cfg 'MAX_RETRIES'    '2')
$retryDelay   = [int](Cfg 'RETRY_DELAY'    '5')
$bundleHdrs   = if ($NoHeaders) { '0' } else { Cfg 'BUNDLE_HEADERS' '1' }
$maxBundled   = [int](Cfg 'MAX_BUNDLED_HEADERS' '5')
$maxFileLines = [int](Cfg 'MAX_FILE_LINES' '4000')
$includeRx    = Cfg 'INCLUDE_EXT_REGEX'   $presetData.Include
$excludeRx    = Cfg 'EXCLUDE_DIRS_REGEX'  $presetData.Exclude
$extraExclude = Cfg 'EXTRA_EXCLUDE_REGEX' ''
$codebaseDesc = Cfg 'CODEBASE_DESC'       $presetData.Desc
$defaultFence = Cfg 'DEFAULT_FENCE'       $presetData.Fence
$skipTrivial  = Cfg 'SKIP_TRIVIAL'       '1'
$tieredModel  = Cfg 'TIERED_MODEL'       '1'
$highModel    = Cfg 'HIGH_COMPLEXITY_MODEL' 'sonnet'
$bundleHdrDoc = Cfg 'BUNDLE_HEADER_DOCS' '0'
$batchTemplated = Cfg 'BATCH_TEMPLATED'  '0'
$minTrivialLines = [int](Cfg 'MIN_TRIVIAL_LINES' '20')
$batchSmallFiles = if ($NoBatch -ne '') { '0' } else { Cfg 'BATCH_SMALL_FILES' '1' }
$batchMaxLines   = [int](Cfg 'BATCH_MAX_LINES' '100')
$batchSize       = [int](Cfg 'BATCH_SIZE' '4')
$usePreamble     = if ($NoPreamble -ne '') { '0' } else { Cfg 'USE_PREAMBLE' '1' }
$elideSource     = if ($ElideSource -ne '') { '1' } else { Cfg 'ELIDE_SOURCE' '0' }
$patternCache    = Cfg 'PATTERN_CACHE' '0'
$useMaxTokens    = if ($MaxTokens -ne '') { '1' } else { Cfg 'USE_MAX_TOKENS' '0' }
$useJsonOutput   = if ($JsonOutput -ne '') { '1' } else { Cfg 'JSON_OUTPUT' '0' }
$useClassify     = if ($Classify -ne '') { '1' } else { Cfg 'CLASSIFY_FILES' '0' }

# ── Local LLM backend (LLMConfig) ─────────────────────────────
# vllm/ollama route doc-generation through the LLMConfig gateway; claude keeps
# the legacy `claude` CLI path. See llm_core.ps1 + the LLM_* keys in .env.
. (Join-Path $PSScriptRoot 'llm_core.ps1')
$llmBackend   = Get-LLMBackend -Cfg $cfg
$llmEndpoint  = ''
$llmModel     = ''
$llmTemp      = [double](Cfg 'LLM_TEMPERATURE' '0.1')
$llmMaxTokens = [int](Cfg 'LLM_MAX_TOKENS' '1000')
$llmTimeout   = [int](Cfg 'LLM_TIMEOUT' '900')
$llmNumCtx    = [int](Cfg 'LLM_NUM_CTX' '0')
$llmThink     = ((Cfg 'LLM_THINK' 'false').Trim().ToLower() -eq 'true')
if ($llmBackend -ne 'claude') {
    $llmEndpoint = Get-LLMEndpoint -Cfg $cfg -Backend $llmBackend
    $llmModel    = Get-LLMModel -Cfg $cfg
    Write-Host "LLM backend: $llmBackend ($llmEndpoint, model=$llmModel)" -ForegroundColor Green
}
# Ollama splits num_ctx across concurrent slots, overflowing large files and
# returning empty content. Force serial dispatch on the ollama backend.
if ($llmBackend -eq 'ollama' -and $jobCount -gt 1) {
    Write-Host "Ollama backend: forcing Jobs=1 (concurrent requests split num_ctx and drop large files)" -ForegroundColor Yellow
    $jobCount = 1
}
# Online claude handles large multi-file / multi-header prompts and the batch-response
# split; local LLM servers (ollama/vllm) do not. Batching corrupts their output (the
# delimiter-split is claude-only -> stub docs + concatenated blobs), and big prompts
# (file + many bundled headers) drive them to empty output. Keep local payloads lean:
# no file batching, no header bundling (rely on the file itself + injected LSP context).
if ($llmBackend -ne 'claude') {
    if ($batchSmallFiles -eq '1' -or $batchTemplated -eq '1') {
        Write-Host "$llmBackend backend: disabling file batching (response-split is claude-only)" -ForegroundColor Yellow
    }
    $batchSmallFiles = '0'
    $batchTemplated  = '0'
    if ($bundleHdrs -eq '1') {
        Write-Host "$llmBackend backend: disabling header bundling (large prompts overwhelm local models; using file + LSP context)" -ForegroundColor Yellow
    }
    $bundleHdrs = '0'
    # Minimize the local prompt further: drop the engine preamble (online claude keeps it).
    # Local Pass-1 prompt = file source + injected LSP context + compact schema.
    if ($usePreamble -eq '1') {
        Write-Host "$llmBackend backend: disabling engine preamble (minimizing local prompt)" -ForegroundColor Yellow
    }
    $usePreamble = '0'
}

$account      = if ($Claude1) { 'claude1' } else { 'claude2' }
$cfgDirKey    = if ($Claude1) { 'CLAUDE1_CONFIG_DIR' } else { 'CLAUDE2_CONFIG_DIR' }
$claudeCfgDir = Cfg $cfgDirKey ''
# A Claude config dir is only required when actually using the claude backend.
if ($llmBackend -eq 'claude') {
    if (-not $claudeCfgDir)             { Write-Err "Missing $cfgDirKey in $EnvFile"; exit 2 }
    if (-not (Test-Path $claudeCfgDir)) { Write-Err "Claude config dir not found: $claudeCfgDir"; exit 2 }
}

# ── Paths ─────────────────────────────────────────────────────

$repoRoot = (Get-Location).Path
try {
    $g = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $g) { $repoRoot = $g.Trim() }
} catch {}

$archDir  = Join-Path $repoRoot 'architecture'
$stateDir = Join-Path $archDir  '.archgen_state'
New-Item -ItemType Directory -Force -Path $archDir  | Out-Null
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$workerScript = Join-Path $PSScriptRoot 'archgen_worker.ps1'
if (-not (Test-Path $workerScript)) {
    Write-Err "Missing: $workerScript"
    Write-Err "archgen_worker.ps1 must be in the same folder as archgen.ps1"
    exit 2
}

$serenaContextDir = Join-Path $archDir '.serena_context'
$hasSerenaContext  = Test-Path $serenaContextDir

# Prompt templates live in the toolkit's llm_prompts/ dir (sibling of llm_scripts/).
$promptDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'llm_prompts'

# Auto-select LSP prompt if Serena context is available and no explicit PROMPT_FILE set
$defaultPrompt = if ($hasSerenaContext) { 'file_doc_prompt_lsp.txt' } else { 'file_doc_prompt.txt' }
$promptFile = Cfg 'PROMPT_FILE' (Join-Path $promptDir $defaultPrompt)
if (-not (Test-Path $promptFile)) {
    # Fall back to standard prompt if LSP prompt doesn't exist
    $promptFile = Join-Path $promptDir 'file_doc_prompt.txt'
}
if (-not (Test-Path $promptFile)) { Write-Err "Missing prompt file: $promptFile"; exit 2 }

# Local backends: prefer the compact schema to shrink the prompt (LSP context still injects
# separately into each payload). Online claude keeps the richer LSP/standard schema.
if ($llmBackend -ne 'claude') {
    $compactPrompt = Join-Path $promptDir 'file_doc_prompt_compact.txt'
    if (Test-Path $compactPrompt) { $promptFile = $compactPrompt }
}

# Opt v2#3: Minimal prompt for simple files
$minimalPromptFile = Join-Path $promptDir 'file_doc_prompt_minimal.txt'
if (-not (Test-Path $minimalPromptFile)) { $minimalPromptFile = '' }

# Opt v2#2: Engine knowledge preamble
$preambleContent = ''
if ($usePreamble -eq '1') {
    $preamblePath = Join-Path $promptDir 'ue_preamble.txt'
    if (Test-Path $preamblePath) {
        $preambleContent = Get-Content $preamblePath -Raw
    }
}

# Opt v2#6: Pattern cache directory
$patternCacheDir = Join-Path $stateDir 'pattern_cache'
if ($patternCache -eq '1') { New-Item -ItemType Directory -Force -Path $patternCacheDir | Out-Null }

$hashDbPath    = Join-Path $stateDir 'hashes.tsv'
$errorLog      = Join-Path $stateDir 'last_claude_error.log'
$fatalFlag     = Join-Path $stateDir 'fatal.flag'
$fatalMsg      = Join-Path $stateDir 'fatal.msg'
$progressTxt   = Join-Path $stateDir 'progress.txt'
$counterPath   = Join-Path $stateDir 'counter.json'
$rateLimitFile = Join-Path $stateDir 'ratelimit_resume.txt'

# ── Clean ─────────────────────────────────────────────────────

if ($Clean) {
    Write-Info "CLEAN: removing docs and state (preserving .serena_context, .dir_context, .dir_headers) ..."
    # Preserve expensive-to-regenerate directories
    $preserve = @('.serena_context', '.dir_context', '.dir_headers')
    # Remove everything except preserved dirs
    Get-ChildItem -Path $archDir -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notin $preserve
    } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $archDir  | Out-Null
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}

'' | Set-Content $errorLog  -Encoding UTF8
Remove-Item $fatalFlag     -ErrorAction SilentlyContinue
Remove-Item $fatalMsg      -ErrorAction SilentlyContinue
Remove-Item $rateLimitFile -ErrorAction SilentlyContinue
'' | Set-Content $progressTxt -Encoding UTF8
if (-not (Test-Path $hashDbPath)) { '' | Set-Content $hashDbPath -Encoding UTF8 }

# ── Hash DB ───────────────────────────────────────────────────

$oldSha = @{}
Get-Content $hashDbPath | ForEach-Object {
    $parts = $_ -split "`t", 2
    if ($parts.Count -eq 2 -and $parts[1] -ne '') { $oldSha[$parts[1]] = $parts[0] }
}

# ── Trivial file detection ────────────────────────────────────

$trivialPatterns = @(
    '\.generated\.h$',
    '\.gen\.cpp$',
    '^Module\.[A-Za-z0-9_]+\.cpp$',
    'Classes\.h$'
)

function Test-TrivialFile($rel, $fullPath, $minLines) {
    # Check filename patterns
    $leaf = Split-Path $rel -Leaf
    foreach ($pat in $trivialPatterns) {
        if ($leaf -match $pat) { return $true }
    }
    # Check line count
    $lines = @(Get-Content $fullPath -ErrorAction SilentlyContinue)
    if ($lines.Count -lt $minLines) { return $true }
    # Check if file is purely includes (no logic)
    $nonInclude = $lines | Where-Object {
        $_.Trim() -ne '' -and
        $_ -notmatch '^\s*(#\s*(include|pragma|ifndef|define|endif)|//|/\*|\*/)'
    }
    if (@($nonInclude).Count -le 2) { return $true }
    return $false
}

function Write-TrivialStub($rel, $outPath) {
    $stub = "# $rel`n`n## File Purpose`nAuto-generated or trivial file. No detailed analysis needed.`n`n## Core Responsibilities`n- Boilerplate / generated code`n"
    $stub | Set-Content -Path $outPath -Encoding UTF8
}

# ── Tiered model classification ──────────────────────────────

function Get-FileComplexity($rel, $repoRoot, $serenaContextDir) {
    $src = Join-Path $repoRoot ($rel -replace '/','\')
    $lineCount = @(Get-Content $src -ErrorAction SilentlyContinue).Count

    $symbolCount = 0
    $refCount    = 0
    if ($serenaContextDir -ne '' -and (Test-Path $serenaContextDir)) {
        $ctxPath = Join-Path $serenaContextDir (($rel -replace '/','\') + '.serena_context.txt')
        if (Test-Path $ctxPath) {
            $ctx = @(Get-Content $ctxPath -ErrorAction SilentlyContinue)
            $symbolCount = @($ctx | Where-Object { $_ -match '^- ' }).Count
            $refCount    = @($ctx | Where-Object { $_ -match '^\s+- ' }).Count
        }
    }

    if ($lineCount -lt 100 -and $symbolCount -le 2) { return 'low' }
    if ($lineCount -gt 1000 -or $refCount -gt 10)   { return 'high' }
    return 'medium'
}

function Get-OutputBudget($lineCount, $symbolCount) {
    if ($lineCount -lt 50)                           { return '~200 tokens' }
    if ($lineCount -lt 200 -and $symbolCount -le 5)  { return '~400 tokens' }
    if ($lineCount -lt 500)                          { return '~600 tokens' }
    if ($lineCount -lt 1500)                         { return '~1000 tokens' }
    return '~1200 tokens'
}

# ── Structural hashing for batch templates ───────────────────

function Get-StructuralHash($filePath) {
    $lines = @(Get-Content $filePath -First 20 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return 'empty' }
    $normalized = $lines | ForEach-Object {
        $_ -replace '\b[A-Z][A-Za-z0-9_]+\b', 'IDENT' `
           -replace '\b\d+\b', 'NUM' `
           -replace '"[^"]*"', 'STR'
    }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized -join "`n")
    return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ── Unit Tests ────────────────────────────────────────────────

if ($Test) {
    $script:testsPassed = 0
    $script:testsFailed = 0
    $script:testErrors  = [System.Collections.Generic.List[string]]::new()

    function Assert-Equal($name, $expected, $actual) {
        if ($expected -eq $actual) {
            $script:testsPassed++
        } else {
            $script:testsFailed++
            $script:testErrors.Add("FAIL: $name`n  expected: [$expected]`n  actual:   [$actual]")
        }
    }

    function Assert-True($name, $value) {
        if ($value) {
            $script:testsPassed++
        } else {
            $script:testsFailed++
            $script:testErrors.Add("FAIL: $name`n  expected: True`n  actual:   [$value]")
        }
    }

    function Assert-False($name, $value) {
        if (-not $value) {
            $script:testsPassed++
        } else {
            $script:testsFailed++
            $script:testErrors.Add("FAIL: $name`n  expected: False`n  actual:   [$value]")
        }
    }

    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host '  archgen.ps1 — Unit Tests' -ForegroundColor Yellow
    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host ''

    # --- Set up temp directory for file-based tests ---
    $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "archgen_tests_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $testDir | Out-Null

    try {

    # ── Test: Read-EnvFile ────────────────────────────────────

    Write-Host 'Testing Read-EnvFile ...' -ForegroundColor Cyan

    # Basic key=value parsing
    $envPath = Join-Path $testDir 'test.env'
    @(
        '# comment line',
        '',
        'CLAUDE_MODEL=haiku',
        'JOBS=8',
        'CODEBASE_DESC="Unreal Engine"',
        "SINGLE_QUOTED='hello world'",
        'SPACED_KEY = spaced_value',
        'HOME_VAR=$HOME/subdir',
        'TILDE_VAR=~/configs',
        'EMPTY_VAL='
    ) | Set-Content $envPath -Encoding UTF8

    $env = Read-EnvFile $envPath
    Assert-Equal 'Read-EnvFile: basic string'        'haiku'         $env['CLAUDE_MODEL']
    Assert-Equal 'Read-EnvFile: numeric string'      '8'             $env['JOBS']
    Assert-Equal 'Read-EnvFile: double-quoted'        'Unreal Engine' $env['CODEBASE_DESC']
    Assert-Equal 'Read-EnvFile: single-quoted'        'hello world'   $env['SINGLE_QUOTED']
    Assert-Equal 'Read-EnvFile: spaced key=value'     'spaced_value'  $env['SPACED_KEY']
    Assert-True  'Read-EnvFile: $HOME expanded'       ($env['HOME_VAR'] -match [regex]::Escape($env:USERPROFILE))
    Assert-True  'Read-EnvFile: ~ expanded'           ($env['TILDE_VAR'] -match [regex]::Escape($env:USERPROFILE))
    Assert-Equal 'Read-EnvFile: empty value'          ''              $env['EMPTY_VAL']
    Assert-False 'Read-EnvFile: comment not parsed'   ($env.ContainsKey('#'))
    Assert-Equal 'Read-EnvFile: key count'            8               $env.Count

    # Non-existent file returns empty hashtable
    $envEmpty = Read-EnvFile (Join-Path $testDir 'nonexistent.env')
    Assert-Equal 'Read-EnvFile: missing file returns empty' 0 $envEmpty.Count

    # ── Test: Get-SHA1 ────────────────────────────────────────

    Write-Host 'Testing Get-SHA1 ...' -ForegroundColor Cyan

    $sha1File = Join-Path $testDir 'sha1test.txt'
    'hello world' | Set-Content $sha1File -NoNewline -Encoding UTF8
    $hash1 = Get-SHA1 $sha1File
    Assert-Equal 'Get-SHA1: length is 40 hex chars' 40 $hash1.Length
    Assert-True  'Get-SHA1: only hex chars'         ($hash1 -match '^[0-9a-f]{40}$')

    # Same content = same hash
    $sha1File2 = Join-Path $testDir 'sha1test2.txt'
    'hello world' | Set-Content $sha1File2 -NoNewline -Encoding UTF8
    $hash2 = Get-SHA1 $sha1File2
    Assert-Equal 'Get-SHA1: same content same hash' $hash1 $hash2

    # Different content = different hash
    'hello world!' | Set-Content $sha1File2 -NoNewline -Encoding UTF8
    $hash3 = Get-SHA1 $sha1File2
    Assert-True  'Get-SHA1: different content different hash' ($hash1 -ne $hash3)

    # ── Test: Get-Preset ──────────────────────────────────────

    Write-Host 'Testing Get-Preset ...' -ForegroundColor Cyan

    # Unreal preset
    $p = Get-Preset 'unreal'
    Assert-True  'Get-Preset unreal: Include matches .cpp' ('.cpp' -match $p.Include)
    Assert-True  'Get-Preset unreal: Include matches .h'   ('.h'   -match $p.Include)
    Assert-True  'Get-Preset unreal: Include matches .cs'  ('.cs'  -match $p.Include)
    Assert-False 'Get-Preset unreal: Include rejects .py'  ('.py'  -match $p.Include)
    Assert-True  'Get-Preset unreal: Exclude matches ThirdParty' ('foo/ThirdParty/bar' -match $p.Exclude)
    Assert-True  'Get-Preset unreal: Exclude matches Intermediate' ('x/Intermediate/y' -match $p.Exclude)
    Assert-Equal 'Get-Preset unreal: Fence is cpp'         'cpp'   $p.Fence

    # Aliases
    $p2 = Get-Preset 'ue5'
    Assert-Equal 'Get-Preset ue5: same as unreal' $p.Include $p2.Include
    $p3 = Get-Preset 'ue4'
    Assert-Equal 'Get-Preset ue4: same as unreal' $p.Include $p3.Include

    # Quake preset
    $pq = Get-Preset 'quake'
    Assert-True  'Get-Preset quake: Include matches .c'  ('.c'  -match $pq.Include)
    Assert-True  'Get-Preset quake: Include matches .h'  ('.h'  -match $pq.Include)
    Assert-False 'Get-Preset quake: Include rejects .cs' ('.cs' -match $pq.Include)
    Assert-Equal 'Get-Preset quake: Fence is c'          'c'    $pq.Fence

    # Quake aliases
    foreach ($alias in @('quake2','quake3','doom','idtech')) {
        $pa = Get-Preset $alias
        Assert-Equal "Get-Preset $alias`: same as quake" $pq.Include $pa.Include
    }

    # Other presets exist and return valid data
    foreach ($name in @('godot','unity','rust')) {
        $px = Get-Preset $name
        Assert-True  "Get-Preset $name`: has Include" ($px.Include -ne '')
        Assert-True  "Get-Preset $name`: has Exclude" ($px.Exclude -ne '')
        Assert-True  "Get-Preset $name`: has Desc"    ($px.Desc    -ne '')
        Assert-True  "Get-Preset $name`: has Fence"   ($px.Fence   -ne '')
    }

    # Source/valve aliases
    $ps = Get-Preset 'source'
    $pv = Get-Preset 'valve'
    Assert-Equal 'Get-Preset valve: same as source' $ps.Include $pv.Include

    # Empty preset (fallback)
    $pe = Get-Preset ''
    Assert-True  'Get-Preset empty: Include matches .c'    ('.c'    -match $pe.Include)
    Assert-True  'Get-Preset empty: Include matches .py'   ('.py'   -match $pe.Include)
    Assert-True  'Get-Preset empty: Include matches .rs'   ('.rs'   -match $pe.Include)

    # ── Test: Get-OutputBudget ────────────────────────────────

    Write-Host 'Testing Get-OutputBudget ...' -ForegroundColor Cyan

    Assert-Equal 'Get-OutputBudget: tiny file'       '~200 tokens'  (Get-OutputBudget 20 1)
    Assert-Equal 'Get-OutputBudget: small file'      '~400 tokens'  (Get-OutputBudget 100 3)
    Assert-Equal 'Get-OutputBudget: medium file'     '~600 tokens'  (Get-OutputBudget 300 10)
    Assert-Equal 'Get-OutputBudget: large file'      '~1000 tokens' (Get-OutputBudget 1000 20)
    Assert-Equal 'Get-OutputBudget: very large file' '~1200 tokens' (Get-OutputBudget 5000 50)

    # Edge cases at boundaries
    Assert-Equal 'Get-OutputBudget: 49 lines'        '~200 tokens'  (Get-OutputBudget 49 0)
    Assert-Equal 'Get-OutputBudget: 50 lines 0 sym'  '~400 tokens'  (Get-OutputBudget 50 0)
    Assert-Equal 'Get-OutputBudget: 199 lines 5 sym' '~400 tokens'  (Get-OutputBudget 199 5)
    Assert-Equal 'Get-OutputBudget: 199 lines 6 sym' '~600 tokens'  (Get-OutputBudget 199 6)
    Assert-Equal 'Get-OutputBudget: 200 lines'       '~600 tokens'  (Get-OutputBudget 200 0)
    Assert-Equal 'Get-OutputBudget: 499 lines'       '~600 tokens'  (Get-OutputBudget 499 0)
    Assert-Equal 'Get-OutputBudget: 500 lines'       '~1000 tokens' (Get-OutputBudget 500 0)
    Assert-Equal 'Get-OutputBudget: 1499 lines'      '~1000 tokens' (Get-OutputBudget 1499 0)
    Assert-Equal 'Get-OutputBudget: 1500 lines'      '~1200 tokens' (Get-OutputBudget 1500 0)

    # ── Test: Test-TrivialFile ────────────────────────────────

    Write-Host 'Testing Test-TrivialFile ...' -ForegroundColor Cyan

    # Generated file patterns
    $trivTestDir = Join-Path $testDir 'trivial'
    New-Item -ItemType Directory -Force -Path $trivTestDir | Out-Null

    # .generated.h file (trivial by pattern)
    $genH = Join-Path $trivTestDir 'Actor.generated.h'
    @('// generated', '#pragma once', '#include "Actor.h"') + (1..30 | ForEach-Object { "void Func$_();" }) |
        Set-Content $genH -Encoding UTF8
    Assert-True  'Test-TrivialFile: .generated.h is trivial' (Test-TrivialFile 'src/Actor.generated.h' $genH 20)

    # .gen.cpp file (trivial by pattern)
    $genCpp = Join-Path $trivTestDir 'Module.Core.gen.cpp'
    @('// gen') + (1..30 | ForEach-Object { "int x$_ = $_;" }) | Set-Content $genCpp -Encoding UTF8
    Assert-True  'Test-TrivialFile: .gen.cpp is trivial' (Test-TrivialFile 'src/Module.Core.gen.cpp' $genCpp 20)

    # Module.*.cpp file (trivial by pattern)
    $modCpp = Join-Path $trivTestDir 'Module.AIGraph.cpp'
    @('// module stub') + (1..30 | ForEach-Object { "int y$_ = $_;" }) | Set-Content $modCpp -Encoding UTF8
    Assert-True  'Test-TrivialFile: Module.*.cpp is trivial' (Test-TrivialFile 'src/Module.AIGraph.cpp' $modCpp 20)

    # Short file (trivial by line count)
    $shortFile = Join-Path $trivTestDir 'tiny.cpp'
    @('#include "foo.h"', 'void f() {}') | Set-Content $shortFile -Encoding UTF8
    Assert-True  'Test-TrivialFile: <20 lines is trivial' (Test-TrivialFile 'src/tiny.cpp' $shortFile 20)

    # Include-only file (trivial by content)
    $incOnly = Join-Path $trivTestDir 'includes_only.h'
    @(
        '#pragma once',
        '#include "A.h"',
        '#include "B.h"',
        '#include "C.h"',
        '#include "D.h"',
        '// just includes',
        '#include "E.h"',
        '#include "F.h"',
        '#include "G.h"',
        '#include "H.h"',
        '#include "I.h"',
        '#include "J.h"',
        '#include "K.h"',
        '#include "L.h"',
        '#include "M.h"',
        '#include "N.h"',
        '#include "O.h"',
        '#include "P.h"',
        '#include "Q.h"',
        '#include "R.h"',
        '#include "S.h"'
    ) | Set-Content $incOnly -Encoding UTF8
    Assert-True  'Test-TrivialFile: include-only is trivial' (Test-TrivialFile 'src/includes_only.h' $incOnly 20)

    # Normal file (NOT trivial)
    $normalFile = Join-Path $trivTestDir 'normal.cpp'
    @(
        '#include "foo.h"',
        '',
        'class MyClass {',
        'public:',
        '    void DoWork();',
        '    int GetValue() const;',
        '};',
        '',
        'void MyClass::DoWork() {',
        '    int x = 42;',
        '    Process(x);',
        '    Finalize();',
        '}',
        '',
        'int MyClass::GetValue() const {',
        '    return m_value;',
        '}',
        '',
        'void Initialize() {',
        '    auto* obj = new MyClass();',
        '    obj->DoWork();',
        '    delete obj;',
        '}'
    ) | Set-Content $normalFile -Encoding UTF8
    Assert-False 'Test-TrivialFile: normal code is NOT trivial' (Test-TrivialFile 'src/normal.cpp' $normalFile 20)

    # ── Test: Write-TrivialStub ───────────────────────────────

    Write-Host 'Testing Write-TrivialStub ...' -ForegroundColor Cyan

    $stubPath = Join-Path $testDir 'stub_output.md'
    Write-TrivialStub 'Engine/Source/Runtime/Core/Test.generated.h' $stubPath
    Assert-True  'Write-TrivialStub: file created' (Test-Path $stubPath)
    $stubContent = Get-Content $stubPath -Raw
    Assert-True  'Write-TrivialStub: has file path heading' ($stubContent -match 'Engine/Source/Runtime/Core/Test\.generated\.h')
    Assert-True  'Write-TrivialStub: has Purpose section'   ($stubContent -match '## File Purpose')
    Assert-True  'Write-TrivialStub: mentions generated'    ($stubContent -match 'generated|trivial')

    # ── Test: Get-FileComplexity ──────────────────────────────

    Write-Host 'Testing Get-FileComplexity ...' -ForegroundColor Cyan

    $compDir = Join-Path $testDir 'complexity'
    $compSrcDir = Join-Path $compDir 'src'
    $compCtxDir = Join-Path $compDir 'ctx'
    New-Item -ItemType Directory -Force -Path $compSrcDir | Out-Null
    New-Item -ItemType Directory -Force -Path $compCtxDir | Out-Null

    # Low complexity: <100 lines, <=2 symbols
    # Get-FileComplexity looks for ctx at: $ctxDir\<rel>.serena_context.txt
    # so rel='src/low.cpp' => ctx at $ctxDir\src\low.cpp.serena_context.txt
    $lowFile = Join-Path $compSrcDir 'low.cpp'
    (1..50 | ForEach-Object { "int line$_ = $_;" }) | Set-Content $lowFile -Encoding UTF8
    $lowCtxDir2 = Join-Path $compCtxDir 'src'
    New-Item -ItemType Directory -Force -Path $lowCtxDir2 | Out-Null
    $lowCtx = Join-Path $lowCtxDir2 'low.cpp.serena_context.txt'
    @('- FuncA', '- FuncB') | Set-Content $lowCtx -Encoding UTF8
    Assert-Equal 'Get-FileComplexity: low' 'low' (Get-FileComplexity 'src/low.cpp' $compDir $compCtxDir)

    # High complexity: >1000 lines
    $highFile = Join-Path $compSrcDir 'high.cpp'
    (1..1100 | ForEach-Object { "void func$_() { }" }) | Set-Content $highFile -Encoding UTF8
    Assert-Equal 'Get-FileComplexity: high by lines' 'high' (Get-FileComplexity 'src/high.cpp' $compDir '')

    # High complexity: >10 incoming refs
    $highRefFile = Join-Path $compSrcDir 'highrefs.cpp'
    (1..200 | ForEach-Object { "int x$_ = $_;" }) | Set-Content $highRefFile -Encoding UTF8
    $highRefCtx = Join-Path $lowCtxDir2 'highrefs.cpp.serena_context.txt'
    $ctxLines = @('- MainFunc')
    $ctxLines += (1..15 | ForEach-Object { "  - ref$_.cpp:$_" })
    $ctxLines | Set-Content $highRefCtx -Encoding UTF8
    Assert-Equal 'Get-FileComplexity: high by refs' 'high' (Get-FileComplexity 'src/highrefs.cpp' $compDir $compCtxDir)

    # Medium complexity: in between
    $medFile = Join-Path $compSrcDir 'med.cpp'
    (1..300 | ForEach-Object { "void f$_() {}" }) | Set-Content $medFile -Encoding UTF8
    $medCtx = Join-Path $lowCtxDir2 'med.cpp.serena_context.txt'
    @('- FuncA', '- FuncB', '- FuncC', '  - ref1.cpp:10', '  - ref2.cpp:20') | Set-Content $medCtx -Encoding UTF8
    Assert-Equal 'Get-FileComplexity: medium' 'medium' (Get-FileComplexity 'src/med.cpp' $compDir $compCtxDir)

    # No serena context at all
    $noCtxFile = Join-Path $compSrcDir 'noctx.cpp'
    (1..300 | ForEach-Object { "int z$_ = $_;" }) | Set-Content $noCtxFile -Encoding UTF8
    Assert-Equal 'Get-FileComplexity: no ctx, 300 lines = medium' 'medium' (Get-FileComplexity 'src/noctx.cpp' $compDir '')

    # ── Test: Get-StructuralHash ──────────────────────────────

    Write-Host 'Testing Get-StructuralHash ...' -ForegroundColor Cyan

    # Same structure, different identifiers = same hash
    $structDir = Join-Path $testDir 'structural'
    New-Item -ItemType Directory -Force -Path $structDir | Out-Null

    $structA = Join-Path $structDir 'a.cpp'
    @('class MyClassA : public UObject {', 'public:', '    void DoStuff();', '};') | Set-Content $structA -Encoding UTF8
    $structB = Join-Path $structDir 'b.cpp'
    @('class MyClassB : public UObject {', 'public:', '    void DoStuff();', '};') | Set-Content $structB -Encoding UTF8
    $hashA = Get-StructuralHash $structA
    $hashB = Get-StructuralHash $structB
    Assert-Equal 'Get-StructuralHash: same structure same hash' $hashA $hashB
    Assert-True  'Get-StructuralHash: returns 40 hex chars' ($hashA -match '^[0-9a-f]{40}$')

    # Different structure = different hash
    $structC = Join-Path $structDir 'c.cpp'
    @('namespace Engine {', 'int globalVar = 42;', 'void Init() {}', '}') | Set-Content $structC -Encoding UTF8
    $hashC = Get-StructuralHash $structC
    Assert-True  'Get-StructuralHash: different structure different hash' ($hashA -ne $hashC)

    # Empty file
    $structEmpty = Join-Path $structDir 'empty.cpp'
    '' | Set-Content $structEmpty -NoNewline -Encoding UTF8
    $hashEmpty = Get-StructuralHash $structEmpty
    Assert-Equal 'Get-StructuralHash: empty file returns empty' 'empty' $hashEmpty

    # ── Load worker functions for testing ─────────────────────

    Write-Host 'Loading archgen_worker.ps1 functions ...' -ForegroundColor Cyan

    $workerPath = Join-Path $PSScriptRoot 'archgen_worker.ps1'
    if (Test-Path $workerPath) {
        # Parse AST, extract only function definitions, evaluate them
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$null, [ref]$null)
        $funcDefs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        foreach ($fd in $funcDefs) {
            try { Invoke-Expression $fd.Extent.Text } catch {}
        }
        $workerLoaded = $true
    } else {
        Write-Host '  WARNING: archgen_worker.ps1 not found, skipping worker tests' -ForegroundColor Yellow
        $workerLoaded = $false
    }

    # ── Test: Get-FenceLang (worker) ──────────────────────────

    if ($workerLoaded) {
        Write-Host 'Testing Get-FenceLang ...' -ForegroundColor Cyan

        # C family
        Assert-Equal 'Get-FenceLang: .c'       'c'          (Get-FenceLang 'foo.c' 'default')
        Assert-Equal 'Get-FenceLang: .h'       'c'          (Get-FenceLang 'bar.h' 'default')
        Assert-Equal 'Get-FenceLang: .inc'     'c'          (Get-FenceLang 'x.inc' 'default')

        # C++ family
        Assert-Equal 'Get-FenceLang: .cpp'     'cpp'        (Get-FenceLang 'main.cpp' 'default')
        Assert-Equal 'Get-FenceLang: .cc'      'cpp'        (Get-FenceLang 'lib.cc' 'default')
        Assert-Equal 'Get-FenceLang: .cxx'     'cpp'        (Get-FenceLang 'x.cxx' 'default')
        Assert-Equal 'Get-FenceLang: .hpp'     'cpp'        (Get-FenceLang 'x.hpp' 'default')
        Assert-Equal 'Get-FenceLang: .hh'      'cpp'        (Get-FenceLang 'x.hh' 'default')
        Assert-Equal 'Get-FenceLang: .hxx'     'cpp'        (Get-FenceLang 'x.hxx' 'default')
        Assert-Equal 'Get-FenceLang: .inl'     'cpp'        (Get-FenceLang 'x.inl' 'default')

        # Other languages
        Assert-Equal 'Get-FenceLang: .cs'      'csharp'     (Get-FenceLang 'x.cs' 'default')
        Assert-Equal 'Get-FenceLang: .java'    'java'       (Get-FenceLang 'x.java' 'default')
        Assert-Equal 'Get-FenceLang: .py'      'python'     (Get-FenceLang 'x.py' 'default')
        Assert-Equal 'Get-FenceLang: .rs'      'rust'       (Get-FenceLang 'x.rs' 'default')
        Assert-Equal 'Get-FenceLang: .lua'     'lua'        (Get-FenceLang 'x.lua' 'default')
        Assert-Equal 'Get-FenceLang: .gd'      'gdscript'   (Get-FenceLang 'x.gd' 'default')
        Assert-Equal 'Get-FenceLang: .gdscript' 'gdscript'  (Get-FenceLang 'x.gdscript' 'default')
        Assert-Equal 'Get-FenceLang: .swift'   'swift'      (Get-FenceLang 'x.swift' 'default')
        Assert-Equal 'Get-FenceLang: .m'       'objectivec' (Get-FenceLang 'x.m' 'default')
        Assert-Equal 'Get-FenceLang: .mm'      'objectivec' (Get-FenceLang 'x.mm' 'default')
        Assert-Equal 'Get-FenceLang: .shader'  'hlsl'       (Get-FenceLang 'x.shader' 'default')
        Assert-Equal 'Get-FenceLang: .hlsl'    'hlsl'       (Get-FenceLang 'x.hlsl' 'default')
        Assert-Equal 'Get-FenceLang: .cginc'   'hlsl'       (Get-FenceLang 'x.cginc' 'default')
        Assert-Equal 'Get-FenceLang: .glsl'    'hlsl'       (Get-FenceLang 'x.glsl' 'default')
        Assert-Equal 'Get-FenceLang: .compute' 'hlsl'       (Get-FenceLang 'x.compute' 'default')
        Assert-Equal 'Get-FenceLang: .toml'    'toml'       (Get-FenceLang 'x.toml' 'default')
        Assert-Equal 'Get-FenceLang: .tscn'    'ini'        (Get-FenceLang 'x.tscn' 'default')
        Assert-Equal 'Get-FenceLang: .tres'    'ini'        (Get-FenceLang 'x.tres' 'default')

        # Unknown extension falls back to default
        Assert-Equal 'Get-FenceLang: .xyz fallback' 'mydefault' (Get-FenceLang 'x.xyz' 'mydefault')
        Assert-Equal 'Get-FenceLang: .txt fallback' 'cpp'       (Get-FenceLang 'x.txt' 'cpp')

        # Path with directories
        Assert-Equal 'Get-FenceLang: path/to/file.cpp' 'cpp' (Get-FenceLang 'Engine/Source/Runtime/foo.cpp' 'c')
    }

    # ── Test: Test-RateLimit (worker) ─────────────────────────

    if ($workerLoaded) {
        Write-Host 'Testing Test-RateLimit ...' -ForegroundColor Cyan

        # Positive cases
        Assert-True  'Test-RateLimit: 429 code'          (Test-RateLimit 'Error: 429 Too Many Requests')
        Assert-True  'Test-RateLimit: rate limit text'    (Test-RateLimit 'You have exceeded your rate limit')
        Assert-True  'Test-RateLimit: usage limit text'   (Test-RateLimit "You've hit your usage limit")
        Assert-True  'Test-RateLimit: too many requests'  (Test-RateLimit 'Error: too many requests, please wait')
        Assert-True  'Test-RateLimit: hit your limit'     (Test-RateLimit "You've hit your limit for now")
        Assert-True  'Test-RateLimit: overloaded'         (Test-RateLimit 'error: server overloaded')
        Assert-True  'Test-RateLimit: quota'              (Test-RateLimit 'error: quota exceeded')

        # Negative cases
        Assert-False 'Test-RateLimit: normal response'    (Test-RateLimit '# Engine/Source/foo.cpp\n## File Purpose\nDoes stuff.')
        Assert-False 'Test-RateLimit: markdown heading'   (Test-RateLimit '# Actor.h')
        Assert-False 'Test-RateLimit: empty string'       (Test-RateLimit '')
        Assert-False 'Test-RateLimit: code with 429 var'  (Test-RateLimit '# foo.cpp\nint status = 200;')
    }

    # ── Test: Test-TooLong (worker) ───────────────────────────

    if ($workerLoaded) {
        Write-Host 'Testing Test-TooLong ...' -ForegroundColor Cyan

        # Positive cases
        Assert-True  'Test-TooLong: prompt is too long'       (Test-TooLong 'Error: prompt is too long')
        Assert-True  'Test-TooLong: context length exceeded'  (Test-TooLong 'Error: context length exceeded')
        Assert-True  'Test-TooLong: context limit reached'    (Test-TooLong 'The context limit has been reached')
        Assert-True  'Test-TooLong: context window'           (Test-TooLong 'Exceeds the context window')
        Assert-True  'Test-TooLong: maximum context'          (Test-TooLong 'Error: maximum context reached')
        Assert-True  'Test-TooLong: too many tokens'          (Test-TooLong 'Error: too many tokens in prompt')

        # Negative cases
        Assert-False 'Test-TooLong: normal response'          (Test-TooLong '# Analysis of foo.cpp')
        Assert-False 'Test-TooLong: empty string'             (Test-TooLong '')
        Assert-False 'Test-TooLong: unrelated error'          (Test-TooLong 'Error: network timeout')
    }

    # ── Test: Get-RateLimitResetTime (worker) ─────────────────

    if ($workerLoaded) {
        Write-Host 'Testing Get-RateLimitResetTime ...' -ForegroundColor Cyan

        # Pattern 1: bare 12-hour time
        $t1 = Get-RateLimitResetTime 'Your limit resets at 6pm (America/New_York)'
        Assert-True  'Get-RateLimitResetTime: 6pm returns datetime'     ($null -ne $t1)
        if ($t1) { Assert-Equal 'Get-RateLimitResetTime: 6pm hour' 18 $t1.Hour }

        $t2 = Get-RateLimitResetTime 'resets 6:30pm'
        Assert-True  'Get-RateLimitResetTime: 6:30pm returns datetime'  ($null -ne $t2)
        if ($t2) {
            Assert-Equal 'Get-RateLimitResetTime: 6:30pm hour' 18 $t2.Hour
            Assert-Equal 'Get-RateLimitResetTime: 6:30pm minute' 30 $t2.Minute
        }

        # Pattern 2: ISO 8601
        $t3 = Get-RateLimitResetTime 'resets at 2025-06-15T13:00:00Z'
        Assert-True  'Get-RateLimitResetTime: ISO returns datetime' ($null -ne $t3)

        # Pattern 4: Unix timestamp
        $t4 = Get-RateLimitResetTime '{"reset_at":1705320000}'
        Assert-True  'Get-RateLimitResetTime: unix ts returns datetime' ($null -ne $t4)

        # No match
        $t5 = Get-RateLimitResetTime 'some random error text'
        Assert-True  'Get-RateLimitResetTime: no match returns null' ($null -eq $t5)

        $t6 = Get-RateLimitResetTime ''
        Assert-True  'Get-RateLimitResetTime: empty returns null' ($null -eq $t6)
    }

    # ── Test: Format-LocalTime (worker) ───────────────────────

    if ($workerLoaded) {
        Write-Host 'Testing Format-LocalTime ...' -ForegroundColor Cyan

        $dt = [datetime]::new(2025, 6, 15, 14, 30, 0)
        $formatted = Format-LocalTime $dt
        Assert-True  'Format-LocalTime: contains 2:30'   ($formatted -match '2:30')
        Assert-True  'Format-LocalTime: contains PM'     ($formatted -match '(?i)pm')

        $dtMorning = [datetime]::new(2025, 1, 1, 9, 5, 0)
        $fmtMorning = Format-LocalTime $dtMorning
        Assert-True  'Format-LocalTime: morning contains AM' ($fmtMorning -match '(?i)am')
    }

    # ── Test: Build-Payload (worker) ──────────────────────────

    if ($workerLoaded) {
        Write-Host 'Testing Build-Payload ...' -ForegroundColor Cyan

        # Set up temp files for Build-Payload
        $bpDir = Join-Path $testDir 'buildpayload'
        $bpRepoRoot = Join-Path $bpDir 'repo'
        $bpArchDir  = Join-Path $bpDir 'arch'
        $bpSrcDir   = Join-Path $bpRepoRoot 'src'
        New-Item -ItemType Directory -Force -Path $bpSrcDir | Out-Null
        New-Item -ItemType Directory -Force -Path $bpArchDir | Out-Null

        # Create a source file
        $bpSrcFile = Join-Path $bpSrcDir 'test.cpp'
        @('#include "helper.h"', '', 'void DoWork() {', '    int x = 42;', '}') | Set-Content $bpSrcFile -Encoding UTF8
        $bpSrcLines = @(Get-Content $bpSrcFile)

        # Create a header for bundling
        $bpHdrFile = Join-Path $bpSrcDir 'helper.h'
        @('#pragma once', 'void DoWork();') | Set-Content $bpHdrFile -Encoding UTF8

        # Variables that Build-Payload references from outer scope
        $preambleContent = ''
        $elideSource = '0'
        $sharedHeaderDir = ''
        $dirContextDir = ''
        $promptFile = Join-Path $testDir 'test_prompt.txt'
        'Analyze this file.' | Set-Content $promptFile -Encoding UTF8

        # Stage 0: full content + headers
        $p0 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '1' 5 'cpp' '' '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload stage 0: contains file path'     ($p0 -match 'src/test.cpp')
        Assert-True  'Build-Payload stage 0: contains source code'   ($p0 -match 'void DoWork')
        Assert-True  'Build-Payload stage 0: contains fence'         ($p0 -match '```cpp')
        Assert-True  'Build-Payload stage 0: contains output budget' ($p0 -match '~600 tokens')
        Assert-True  'Build-Payload stage 0: contains schema'        ($p0 -match 'Analyze this file')
        Assert-True  'Build-Payload stage 0: bundles header'         ($p0 -match 'helper\.h')

        # Stage 1: no headers
        $p1 = Build-Payload 1 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '1' 5 'cpp' '' '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload stage 1: contains source'        ($p1 -match 'void DoWork')
        Assert-False 'Build-Payload stage 1: no bundled headers'     ($p1 -match 'BUNDLED HEADERS')

        # Stage 2: truncated, no headers
        $bigLines = (1..200 | ForEach-Object { "int line$_ = $_;" })
        $p2 = Build-Payload 2 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bigLines 100 `
                             '1' 5 'cpp' '' '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload stage 2: truncated'              ($p2 -match 'TRUNCATED')
        Assert-False 'Build-Payload stage 2: no bundled headers'     ($p2 -match 'BUNDLED HEADERS')

        # With LSP context
        $lspCtx = @"
## Symbol Overview
- DoWork (Function, lines 3-5)

## Trimmed Source (key sections only)
``````cpp
void DoWork() {
    int x = 42;
}
``````
"@
        $p3 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '0' 5 'cpp' $lspCtx '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload with LSP: injects context'       ($p3 -match 'LSP ANALYSIS CONTEXT')
        Assert-True  'Build-Payload with LSP: has symbol overview'   ($p3 -match 'Symbol Overview')

        # With preamble
        $preambleContent = 'UCLASS = reflection macro'
        $p4 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '0' 5 'cpp' '' '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload with preamble: has conventions'  ($p4 -match 'ENGINE CONVENTIONS')
        Assert-True  'Build-Payload with preamble: has content'      ($p4 -match 'UCLASS = reflection macro')
        $preambleContent = ''  # Reset

        # With source elision
        $elideSource = '1'
        $p5 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '0' 5 'cpp' $lspCtx '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload elide: source elided'            ($p5 -match 'Full source elided')
        Assert-False 'Build-Payload elide: no raw source'            ($p5 -match 'int line1 = 1')
        $elideSource = '0'  # Reset

        # LSP-trimmed source for oversized files
        $oversizedLines = (1..5000 | ForEach-Object { "int line$_ = $_;" })
        $p6 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $oversizedLines 4000 `
                             '0' 5 'cpp' $lspCtx '0' $bpArchDir '~1200 tokens'
        Assert-True  'Build-Payload LSP-trimmed: uses trimmed source' ($p6 -match 'LSP-TRIMMED')

        # With directory context
        $bpDirCtxDir = Join-Path $bpDir 'dir_context'
        $bpDirCtxSubDir = Join-Path $bpDirCtxDir 'src'
        New-Item -ItemType Directory -Force -Path $bpDirCtxSubDir | Out-Null
        $dirCtxFile = Join-Path $bpDirCtxDir 'src.dir.md'
        'This directory contains utility functions.' | Set-Content $dirCtxFile -Encoding UTF8
        $dirContextDir = $bpDirCtxDir
        $p7 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '0' 5 'cpp' '' '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload dir ctx: injects directory context' ($p7 -match 'DIRECTORY CONTEXT')
        Assert-True  'Build-Payload dir ctx: has dir content'           ($p7 -match 'utility functions')
        $dirContextDir = ''  # Reset

        # With shared headers
        $bpSharedDir = Join-Path $bpDir 'shared_headers'
        $bpSharedSrcDir = Join-Path $bpSharedDir 'src'
        New-Item -ItemType Directory -Force -Path $bpSharedSrcDir | Out-Null
        $sharedFile = Join-Path $bpSharedDir 'src.headers.txt'
        'Common includes: CoreMinimal.h, EngineTypes.h' | Set-Content $sharedFile -Encoding UTF8
        $sharedHeaderDir = $bpSharedDir
        $p8 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '0' 5 'cpp' '' '0' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload shared hdrs: loads shared headers'  ($p8 -match 'SHARED DIRECTORY HEADERS')
        Assert-True  'Build-Payload shared hdrs: has content'           ($p8 -match 'CoreMinimal')
        $sharedHeaderDir = ''  # Reset

        # Header doc bundling (BUNDLE_HEADER_DOCS=1)
        $hdrDocPath = Join-Path $bpArchDir 'src\helper.h.md'
        $hdrDocDir  = Split-Path $hdrDocPath -Parent
        New-Item -ItemType Directory -Force -Path $hdrDocDir | Out-Null
        '# helper.h\n## Purpose\nHelper utilities.' | Set-Content $hdrDocPath -Encoding UTF8
        $p9 = Build-Payload 0 'src/test.cpp' $bpSrcFile $bpRepoRoot 'cpp' $bpSrcLines 4000 `
                             '1' 5 'cpp' '' '1' $bpArchDir '~600 tokens'
        Assert-True  'Build-Payload hdr docs: bundles analyzed doc'     ($p9 -match 'analyzed doc')
    }

    # ── Test: Batch mode relList unwrap fix ───────────────────

    Write-Host 'Testing batch relList parsing ...' -ForegroundColor Cyan

    # Simulates the fix for the PowerShell 5.1 array unwrap bug
    # The fix: $relList = @(if ($isBatch) { $rel -split '\|' } else { $rel })

    # Single file (non-batch)
    $testRel1 = 'Engine/Source/Runtime/Core/Private/Math.cpp'
    $testIsBatch1 = $testRel1 -match '\|'
    $testRelList1 = @(if ($testIsBatch1) { $testRel1 -split '\|' } else { $testRel1 })
    Assert-Equal 'relList single: count=1'   1 $testRelList1.Count
    Assert-Equal 'relList single: full path' $testRel1 $testRelList1[0]

    # Batch (pipe-separated)
    $testRel2 = 'src/a.cpp|src/b.cpp|src/c.cpp'
    $testIsBatch2 = $testRel2 -match '\|'
    $testRelList2 = @(if ($testIsBatch2) { $testRel2 -split '\|' } else { $testRel2 })
    Assert-Equal 'relList batch: count=3'    3           $testRelList2.Count
    Assert-Equal 'relList batch: first'      'src/a.cpp' $testRelList2[0]
    Assert-Equal 'relList batch: second'     'src/b.cpp' $testRelList2[1]
    Assert-Equal 'relList batch: third'      'src/c.cpp' $testRelList2[2]

    # Verify the bug scenario: without outer @(), PowerShell 5.1 if/else
    # expression unwraps the @() inside the else branch, turning the single-element
    # array into a scalar string. Then [0] indexes the first character.
    # The FIX is wrapping the entire if/else in @():
    $fixedRelList = @(if ($false) { 'x' -split '\|' } else { $testRel1 })
    Assert-Equal 'relList fix-guard: [0] is full path' $testRel1 $fixedRelList[0]

    # ── Test: Batch response splitting ────────────────────────

    Write-Host 'Testing batch response splitting ...' -ForegroundColor Cyan

    $batchResp = @"
# src/a.cpp
## File Purpose
Does A stuff.
=== END FILE ===
# src/b.cpp
## File Purpose
Does B stuff.
=== END FILE ===
# src/c.cpp
## File Purpose
Does C stuff.
"@
    $splitDocs = $batchResp -split '=== END FILE ==='
    Assert-Equal 'Batch split: 3 docs'       3 $splitDocs.Count
    Assert-True  'Batch split: doc 1 has a'  ($splitDocs[0].Trim() -match 'src/a\.cpp')
    Assert-True  'Batch split: doc 2 has b'  ($splitDocs[1].Trim() -match 'src/b\.cpp')
    Assert-True  'Batch split: doc 3 has c'  ($splitDocs[2].Trim() -match 'src/c\.cpp')

    # ── Test: Cfg helper ──────────────────────────────────────

    Write-Host 'Testing Cfg helper ...' -ForegroundColor Cyan

    # Test with a known env file
    $cfgTestPath = Join-Path $testDir 'cfg_test.env'
    @('MODEL=haiku', 'EMPTY_KEY=', 'JOBS=4') | Set-Content $cfgTestPath -Encoding UTF8
    $savedCfg = $cfg
    $cfg = Read-EnvFile $cfgTestPath

    Assert-Equal 'Cfg: existing key'         'haiku' (Cfg 'MODEL' 'sonnet')
    Assert-Equal 'Cfg: missing key, default' 'sonnet' (Cfg 'MISSING_KEY' 'sonnet')
    Assert-Equal 'Cfg: empty value, default' 'fallback' (Cfg 'EMPTY_KEY' 'fallback')
    Assert-Equal 'Cfg: numeric value'        '4'     (Cfg 'JOBS' '2')

    $cfg = $savedCfg  # Restore

    # ── Test: Get-Preset exclude patterns ─────────────────────

    Write-Host 'Testing Get-Preset exclude patterns ...' -ForegroundColor Cyan

    $pu = Get-Preset 'unreal'
    # Should exclude common UE dirs
    Assert-True  'Exclude: Binaries'       ('Engine/Binaries/foo.cpp'     -match $pu.Exclude)
    Assert-True  'Exclude: ThirdParty'     ('Engine/ThirdParty/zlib/x.c' -match $pu.Exclude)
    Assert-True  'Exclude: Intermediate'   ('x/Intermediate/y.cpp'        -match $pu.Exclude)
    Assert-True  'Exclude: .git'           ('repo/.git/objects/foo'        -match $pu.Exclude)
    Assert-True  'Exclude: architecture'   ('repo/architecture/foo.md'    -match $pu.Exclude)
    # Should NOT exclude normal source paths
    Assert-False 'No exclude: Runtime'     ('Engine/Source/Runtime/Core/Private/Math.cpp' -match $pu.Exclude)
    Assert-False 'No exclude: Classes'     ('Engine/Source/Runtime/Engine/Classes/Actor.h' -match $pu.Exclude)

    # ── Test: Hash DB round-trip (integration) ────────────────

    Write-Host 'Testing hash DB round-trip ...' -ForegroundColor Cyan

    $testHashDb = Join-Path $testDir 'hashes.tsv'
    '' | Set-Content $testHashDb -Encoding UTF8

    # Write entries
    [System.IO.File]::AppendAllText($testHashDb, "abc123`tEngine/Source/foo.cpp`n")
    [System.IO.File]::AppendAllText($testHashDb, "def456`tEngine/Source/bar.cpp`n")

    # Read back
    $readBack = @{}
    Get-Content $testHashDb | ForEach-Object {
        $parts = $_ -split "`t", 2
        if ($parts.Count -eq 2 -and $parts[1] -ne '') { $readBack[$parts[1]] = $parts[0] }
    }
    Assert-Equal 'Hash DB: foo.cpp hash'  'abc123' $readBack['Engine/Source/foo.cpp']
    Assert-Equal 'Hash DB: bar.cpp hash'  'def456' $readBack['Engine/Source/bar.cpp']
    Assert-Equal 'Hash DB: entry count'   2        $readBack.Count

    # Dedup logic (same as end of archgen.ps1)
    [System.IO.File]::AppendAllText($testHashDb, "updated`tEngine/Source/foo.cpp`n")  # newer entry
    $seen = @{}
    $keep = [System.Collections.Generic.List[string]]::new()
    $raw  = @(Get-Content $testHashDb | Where-Object { $_.Trim() -ne '' })
    [array]::Reverse($raw)
    foreach ($line in $raw) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2 -and -not $seen.ContainsKey($parts[1])) {
            $seen[$parts[1]] = $true
            $keep.Add($line)
        }
    }
    Assert-Equal 'Hash DB dedup: keeps 2 unique entries'  2 $keep.Count
    $fooEntry = $keep | Where-Object { $_ -match 'foo\.cpp' }
    Assert-True  'Hash DB dedup: keeps newest foo entry' ($fooEntry -match 'updated')

    } finally {
        # ── Cleanup temp directory ────────────────────────────
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ── Results ───────────────────────────────────────────────

    Write-Host ''
    Write-Host '────────────────────────────────────────────' -ForegroundColor Yellow
    if ($script:testsFailed -eq 0) {
        Write-Host "ALL $($script:testsPassed) TESTS PASSED" -ForegroundColor Green
    } else {
        Write-Host "$($script:testsPassed) passed, $($script:testsFailed) FAILED" -ForegroundColor Red
        Write-Host ''
        foreach ($err in $script:testErrors) {
            Write-Host $err -ForegroundColor Red
        }
    }
    Write-Host '────────────────────────────────────────────' -ForegroundColor Yellow
    exit $script:testsFailed
}

# ── Collect files ─────────────────────────────────────────────

$scanRoot = if ($TargetDir -eq '.') { $repoRoot } else { Join-Path $repoRoot $TargetDir }
if (-not (Test-Path $scanRoot)) { Write-Err "Target directory not found: $scanRoot"; exit 1 }

$allFiles = Get-ChildItem -Path $scanRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        if ($rel -match '^architecture/' -or $rel -match '/architecture/') { return $false }
        if ($_.Name -match '\.ignore$') { return $false }
        if ($rel -match $excludeRx) { return $false }
        if ($extraExclude -ne '' -and $rel -match $extraExclude) { return $false }
        if ($rel -match $includeRx) { return $true }
        return $false
    } | Sort-Object FullName

$files = $allFiles | ForEach-Object {
    $_.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
}

$total = @($files).Count
if ($total -eq 0) { Write-Err "No matching source files found under '$scanRoot'"; exit 1 }

$queue         = [System.Collections.Generic.List[string]]::new()
$skipUnchanged = 0
$skipTrivialN  = 0
$skipBatched   = 0
$skipPatternCached = 0
$skipClassified = 0

foreach ($rel in $files) {
    $src = Join-Path $repoRoot ($rel -replace '/', '\')
    $out = Join-Path $archDir  (($rel -replace '/', '\') + '.md')
    $sha = Get-SHA1 $src

    if ($oldSha.ContainsKey($rel) -and $oldSha[$rel] -eq $sha -and (Test-Path $out)) {
        $skipUnchanged++
        continue
    }

    # Opt #1: Skip generated/trivial files — write stub doc instead
    if ($skipTrivial -eq '1' -and (Test-TrivialFile $rel $src $minTrivialLines)) {
        $outDir = Split-Path $out -Parent
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        Write-TrivialStub $rel $out
        # Record hash so we skip next run
        $hashStr = ($sha)
        [System.IO.File]::AppendAllText($hashDbPath, "$sha`t$rel`n")
        $skipTrivialN++
        continue
    }

    $queue.Add($rel)
}

# Opt #6: Batch templated files — analyze one representative per group
$batchedDocs = @{}
if ($batchTemplated -eq '1' -and $queue.Count -gt 0) {
    $groups = @{}
    foreach ($rel in $queue) {
        $src = Join-Path $repoRoot ($rel -replace '/','\')
        $hash = Get-StructuralHash $src
        if (-not $groups.ContainsKey($hash)) { $groups[$hash] = [System.Collections.Generic.List[string]]::new() }
        $groups[$hash].Add($rel)
    }
    $batchQueue = [System.Collections.Generic.List[string]]::new()
    foreach ($hash in $groups.Keys) {
        $members = $groups[$hash]
        if ($members.Count -ge 3) {
            # Keep only the first (representative); batch the rest later
            $batchQueue.Add($members[0])
            for ($i = 1; $i -lt $members.Count; $i++) {
                $batchedDocs[$members[$i]] = $members[0]  # maps file → representative
                $skipBatched++
            }
        } else {
            foreach ($m in $members) { $batchQueue.Add($m) }
        }
    }
    $queue = $batchQueue
}

# ── Opt v2#6: Pattern caching by base class ──────────────────

$patternDb = @{}  # baseClass → { count, templateDoc, templateRel }

if ($patternCache -eq '1' -and $hasSerenaContext -and $queue.Count -gt 0) {
    # Phase 1: Classify files by primary base class from LSP context
    $baseClassMap = @{}  # rel → baseClass
    foreach ($rel in $queue) {
        $ctxPath = Join-Path $serenaContextDir (($rel -replace '/','\') + '.serena_context.txt')
        if (Test-Path $ctxPath) {
            $ctxLines = Get-Content $ctxPath -ErrorAction SilentlyContinue
            # Look for "ClassName (Class, lines X-Y)" in symbol overview
            $classLine = $ctxLines | Where-Object { $_ -match '^\- \w+.*\(Class,' } | Select-Object -First 1
            if ($classLine -match '^\- (\w+)') {
                $className = $Matches[1]
                # Find base class from the source file
                $srcPath = Join-Path $repoRoot ($rel -replace '/','\')
                $srcHead = Get-Content $srcPath -First 30 -ErrorAction SilentlyContinue
                $inheritLine = $srcHead | Where-Object { $_ -match "class\s+$className\s*:\s*public\s+(\w+)" } | Select-Object -First 1
                if ($inheritLine -match "class\s+$className\s*:\s*public\s+(\w+)") {
                    $baseClass = $Matches[1]
                    $baseClassMap[$rel] = $baseClass
                }
            }
        }
    }

    # Phase 2: Group by base class, find groups with 3+ files under 200 lines
    $classGroups = @{}
    foreach ($rel in $baseClassMap.Keys) {
        $bc = $baseClassMap[$rel]
        if (-not $classGroups.ContainsKey($bc)) { $classGroups[$bc] = [System.Collections.Generic.List[string]]::new() }
        $classGroups[$bc].Add($rel)
    }

    # Phase 3: For groups with 3+ members, check if a template already exists
    $patternQueue = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $queue) {
        $bc = $baseClassMap[$rel]
        if ($bc -and $classGroups[$bc].Count -ge 3) {
            $templateFile = Join-Path $patternCacheDir "$bc.template.md"
            if (Test-Path $templateFile) {
                # Apply template: substitute class name and path
                $templateContent = Get-Content $templateFile -Raw
                $className = ''
                $srcHead = Get-Content (Join-Path $repoRoot ($rel -replace '/','\')) -First 30 -ErrorAction SilentlyContinue
                $classMatch = $srcHead | Where-Object { $_ -match "class\s+(\w+)\s*:\s*public\s+$bc" } | Select-Object -First 1
                if ($classMatch -match "class\s+(\w+)") { $className = $Matches[1] }

                if ($className) {
                    $doc = $templateContent -replace '\{PATH\}', $rel -replace '\{CLASS\}', $className -replace '\{BASE\}', $bc
                    $outPath = Join-Path $archDir (($rel -replace '/','\') + '.md')
                    $outDir  = Split-Path $outPath -Parent
                    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                    $doc | Set-Content -Path $outPath -Encoding UTF8
                    $sha = Get-SHA1 (Join-Path $repoRoot ($rel -replace '/','\'))
                    [System.IO.File]::AppendAllText($hashDbPath, "$sha`t$rel`n")
                    $skipPatternCached++
                    continue
                }
            }
        }
        $patternQueue.Add($rel)
    }

    if ($skipPatternCached -gt 0) {
        Write-Host "Pattern cache: $skipPatternCached files generated from templates" -ForegroundColor Cyan
    }
    $queue = $patternQueue
}

$toDo = $queue.Count

# ── Banner ────────────────────────────────────────────────────

Write-Host '============================================' -ForegroundColor Yellow
Write-Host '  archgen.ps1 — Architecture Doc Generator' -ForegroundColor Yellow
Write-Host '============================================' -ForegroundColor Yellow
Write-Host "Repo root:       $repoRoot"
Write-Host "Codebase:        $codebaseDesc"
if ($presetName) { Write-Host "Preset:          $presetName" }
Write-Host "Target:          $TargetDir"
Write-Host "Account:         $account  |  Model: $model  |  Jobs: $jobCount"
$hdrStatus   = if ($bundleHdrs -eq '1') { "ON (max $maxBundled)" } else { 'OFF' }
$linesStatus = if ($maxFileLines -gt 0) { "$maxFileLines lines max" } else { 'unlimited' }
Write-Host "Headers:         $hdrStatus  |  Max lines: $linesStatus"
$skipDetail = "unchanged=$skipUnchanged"
if ($skipTrivialN -gt 0)    { $skipDetail += "  trivial=$skipTrivialN" }
if ($skipBatched  -gt 0)    { $skipDetail += "  batched=$skipBatched" }
if ($skipPatternCached -gt 0) { $skipDetail += "  pattern=$skipPatternCached" }
if ($skipClassified -gt 0)   { $skipDetail += "  classified=$skipClassified" }
Write-Host "Files:           $total total  |  $skipDetail  |  process: $toDo"
Write-Host "Prompt:          $promptFile"
$lspStatus = if ($hasSerenaContext) { "YES (LSP context will be injected)" } else { "NO (run serena_extract.ps1 first)" }
Write-Host "Serena context:  $lspStatus"
$optStatus = @()
if ($usePreamble -eq '1' -and $preambleContent -ne '') { $optStatus += "preamble" }
if ($batchSmallFiles -eq '1') { $optStatus += "batch(<${batchMaxLines}L x$batchSize)" }
if ($elideSource -eq '1') { $optStatus += "elide-source" }
if ($patternCache -eq '1') { $optStatus += "pattern-cache" }
if ($useMaxTokens -eq '1') { $optStatus += "max-tokens" }
if ($useJsonOutput -eq '1') { $optStatus += "json-output" }
if ($useClassify -eq '1') { $optStatus += "classify" }
if ($optStatus.Count -gt 0) { Write-Host "Optimizations:   $($optStatus -join '  ')" }
Write-Host ''

if ($toDo -eq 0) {
    Write-Host 'Nothing to do. All docs are up to date.' -ForegroundColor Green
    exit 0
}

# ── Counter file ──────────────────────────────────────────────

@{ done = 0; fail = 0; skip = $skipUnchanged; total = $total; todo = $toDo; retries = 0 } |
    ConvertTo-Json | Set-Content $counterPath -Encoding UTF8
$script:modelCounts = @{ haiku = 0; sonnet = 0 }

$startTime = [datetime]::Now

# ── Rate-limit status helper ─────────────────────────────────

function Get-RateLimitStatus($rateLimitFile) {
    if (-not (Test-Path $rateLimitFile)) { return '' }
    try {
        $resumeAt = [datetime]::Parse((Get-Content $rateLimitFile -Raw -ErrorAction Stop).Trim())
        if ([datetime]::Now -lt $resumeAt) {
            $remaining = ($resumeAt - [datetime]::Now).TotalMinutes
            $ts = $resumeAt.ToString("h:mm tt")
            return "  [RATE LIMITED ~$([math]::Ceiling($remaining))m, until $ts]"
        }
    } catch {}
    return ''
}

# ── Progress helper ───────────────────────────────────────────

$script:lastProgressDone = -1
$script:progressBaseHash = 0

function Show-Progress {
    param($toDo, $startTime, $rateLimitFile)
    try {
        # Count lines in hashes.tsv — append-only, no locks needed
        $lineCount = 0
        $reader = [System.IO.StreamReader]::new($hashDbPath, [System.Text.Encoding]::UTF8, $true, 4096)
        while ($null -ne $reader.ReadLine()) { $lineCount++ }
        $reader.Close()

        $done = $lineCount - $script:progressBaseHash
        if ($done -lt 0) { $done = 0 }
        if ($done -gt $toDo) { $done = $toDo }

        if ($done -eq $script:lastProgressDone) { return }
        $script:lastProgressDone = $done

        $elapsed = ([datetime]::Now - $startTime).TotalSeconds
        $rate    = if ($elapsed -gt 0 -and $done -gt 0) { [math]::Round($done / $elapsed, 2) } else { 0 }
        $etaSec  = if ($rate -gt 0) { [math]::Round(($toDo - $done) / $rate) } else { 0 }
        if ($etaSec -gt 0) {
            $etaH = [int][math]::Floor($etaSec / 3600)
            $etaM = [int][math]::Floor(($etaSec % 3600) / 60)
            $etaS = [int]($etaSec % 60)
            $eta  = '{0}h{1:D2}m{2:D2}s' -f $etaH, $etaM, $etaS
        } else { $eta = '?' }
        # Read fail/retries from counter.json (best-effort, skip on contention)
        $fail = 0; $retries = 0
        try {
            $cRaw = [System.IO.File]::ReadAllText($counterPath)
            if ($cRaw -and $cRaw.Trim() -ne '') {
                $cObj = $cRaw | ConvertFrom-Json
                $fail    = [int]$cObj.fail
                $retries = [int]$cObj.retries
            }
        } catch {}

        $mTotal = $script:modelCounts.haiku + $script:modelCounts.sonnet
        $hPct = if ($mTotal -gt 0) { [int][math]::Round(100 * $script:modelCounts.haiku / $mTotal) } else { 0 }
        $sPct = 100 - $hPct
        $rlStatus = Get-RateLimitStatus $rateLimitFile
        $line = "PROGRESS: $done/$toDo  skip=$($script:progressSkip)  fail=$fail  retries=$retries  rate=${rate}/s  eta=$eta  haiku=${hPct}% sonnet=${sPct}%$rlStatus"
        [Console]::Write("`r" + $line.PadRight(100))
    } catch {
        # Debug: if progress fails, show why
        [Console]::Write("`r" + "PROGRESS ERROR: $($_.Exception.Message)".PadRight(100))
    }
}

# ── Opt v3#5: Pre-compute shared directory headers ───────────

$sharedHeaderDir = Join-Path $archDir '.dir_headers'
if ($bundleHdrs -eq '1' -and $queue.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path $sharedHeaderDir | Out-Null

    # Group queue files by directory
    $headerGroups = @{}
    foreach ($r in $queue) {
        $d = Split-Path $r -Parent
        if (-not $headerGroups.ContainsKey($d)) { $headerGroups[$d] = [System.Collections.Generic.List[string]]::new() }
        $headerGroups[$d].Add($r)
    }

    foreach ($d in $headerGroups.Keys) {
        $members = $headerGroups[$d]
        if ($members.Count -lt 3) { continue }  # Not worth sharing for <3 files
        $outFile = Join-Path $sharedHeaderDir (($d -replace '/','\') + '.headers.txt')
        if (Test-Path $outFile) { continue }  # Already computed

        # Find common includes across all files in this directory
        $allIncludes = @{}
        foreach ($r in $members) {
            $srcPath = Join-Path $repoRoot ($r -replace '/','\')
            $lines = Get-Content $srcPath -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            $fileIncs = @($lines | Where-Object { $_ -match '#\s*include\s+"([^"]+)"' } | ForEach-Object { if ($_ -match '"([^"]+)"') { $Matches[1] } })
            foreach ($inc in $fileIncs) {
                if (-not $allIncludes.ContainsKey($inc)) { $allIncludes[$inc] = 0 }
                $allIncludes[$inc]++
            }
        }

        # Common = included by 80%+ of files in the directory
        $threshold = [math]::Ceiling($members.Count * 0.8)
        $commonIncs = $allIncludes.Keys | Where-Object { $allIncludes[$_] -ge $threshold }

        if (@($commonIncs).Count -gt 0) {
            $outDir = Split-Path $outFile -Parent
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $headerContent = "Common includes for $d ($(@($commonIncs).Count) shared by 80%+ of $($members.Count) files):`n"
            foreach ($inc in $commonIncs | Sort-Object) {
                $headerContent += "- $inc`n"
            }
            $headerContent | Set-Content -Path $outFile -Encoding UTF8
        }
    }
}

# ── Opt v3#7: Two-phase classification (opt-in) ─────────────

if ($useClassify -eq '1' -and $queue.Count -gt 0) {
    Write-Host "Running classification phase..." -ForegroundColor Cyan
    $classifyPrompt = Join-Path $promptDir 'classify_prompt.txt'
    if (Test-Path $classifyPrompt) {
        $classifyQueue = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $queue) {
            $srcPath = Join-Path $repoRoot ($r -replace '/','\')
            $lc = @(Get-Content $srcPath -ErrorAction SilentlyContinue).Count
            $primarySym = ''
            if ($hasSerenaContext) {
                $ctxP = Join-Path $serenaContextDir (($r -replace '/','\') + '.serena_context.txt')
                if (Test-Path $ctxP) {
                    $symLine = Get-Content $ctxP -ErrorAction SilentlyContinue | Where-Object { $_ -match '^- \w+.*\(Class|Function' } | Select-Object -First 1
                    if ($symLine -match '^- (\w+)') { $primarySym = $Matches[1] }
                }
            }
            $classPayload = "PATH: $r | LINES: $lc | SYMBOL: $primarySym"
            try {
                if ($llmBackend -eq 'claude') {
                    $env:CLAUDE_CONFIG_DIR = $claudeCfgDir
                    $classResp = $classPayload | & claude -p --model haiku --max-turns 1 --max-tokens 30 --output-format text --append-system-prompt-file $classifyPrompt 2>&1
                    $classText = if ($classResp -is [array]) { $classResp -join '' } else { [string]$classResp }
                } else {
                    $classSys = Get-Content $classifyPrompt -Raw -Encoding UTF8
                    $classText = Invoke-LocalLLM -SystemPrompt $classSys -UserPrompt $classPayload `
                        -Backend $llmBackend -Endpoint $llmEndpoint -Model $llmModel `
                        -Temperature $llmTemp -MaxTokens 30 -Timeout $llmTimeout -NumCtx $llmNumCtx -Think $llmThink
                }
                if ($classText -match '^STUB:(.+)') {
                    $stubPurpose = $Matches[1].Trim()
                    $out = Join-Path $archDir (($r -replace '/','\') + '.md')
                    $outDir = Split-Path $out -Parent
                    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                    "# $r`n`n## File Purpose`n$stubPurpose`n" | Set-Content -Path $out -Encoding UTF8
                    $sha = Get-SHA1 $srcPath
                    [System.IO.File]::AppendAllText($hashDbPath, "$sha`t$r`n")
                    $skipClassified++
                    continue
                }
            } catch {}
            $classifyQueue.Add($r)
        }
        $queue = $classifyQueue
        if ($skipClassified -gt 0) {
            Write-Host "  Classified $skipClassified files as STUB" -ForegroundColor Cyan
        }
    }
}

# ── Opt v2#1: Split queue into batched small files + individual large files ──

$serenaArg = if ($hasSerenaContext) { $serenaContextDir } else { "" }

$dispatchQueue = [System.Collections.Generic.List[object]]::new()  # list of {Rels, IsBatch}

if ($batchSmallFiles -eq '1' -and $queue.Count -gt 0) {
    $smallQueue = [System.Collections.Generic.List[string]]::new()
    $largeQueue = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $queue) {
        $srcPath = Join-Path $repoRoot ($rel -replace '/','\')
        $lc = @(Get-Content $srcPath -ErrorAction SilentlyContinue).Count
        if ($lc -lt $batchMaxLines) { $smallQueue.Add($rel) }
        else { $largeQueue.Add($rel) }
    }
    # Build batches from small files
    for ($i = 0; $i -lt $smallQueue.Count; $i += $batchSize) {
        $end = [math]::Min($i + $batchSize - 1, $smallQueue.Count - 1)
        $batch = @($smallQueue[$i..$end])
        $dispatchQueue.Add([pscustomobject]@{ Rels = $batch; IsBatch = ($batch.Count -gt 1) })
    }
    # Add large files individually
    foreach ($rel in $largeQueue) {
        $dispatchQueue.Add([pscustomobject]@{ Rels = @($rel); IsBatch = $false })
    }
    $batchedSmallN = $smallQueue.Count
    $batchCount    = [math]::Ceiling($smallQueue.Count / $batchSize)
    Write-Host "Batching: $batchedSmallN small files into $batchCount batches + $($largeQueue.Count) individual files" -ForegroundColor Cyan
} else {
    foreach ($rel in $queue) {
        $dispatchQueue.Add([pscustomobject]@{ Rels = @($rel); IsBatch = $false })
    }
}

# ── Dispatch jobs ─────────────────────────────────────────────

Write-Host "Dispatching $($dispatchQueue.Count) jobs at parallelism=$jobCount ..." -ForegroundColor Green

# Snapshot hash DB line count so progress only tracks new entries from this run
$script:progressBaseHash = @(Get-Content $hashDbPath -ErrorAction SilentlyContinue).Count
$script:progressSkip     = $skipUnchanged

$running = [System.Collections.Generic.List[object]]::new()

foreach ($item in $dispatchQueue) {
    if (Test-Path $fatalFlag) { break }

    # Wait for a free slot
    while ($running.Count -ge $jobCount) {
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $running) {
            if ($r.Job.State -ne 'Running') {
                Receive-Job $r.Job -ErrorAction SilentlyContinue | Out-Null
                Remove-Job  $r.Job -ErrorAction SilentlyContinue
            } else {
                $next.Add($r)
            }
        }
        $running = $next
        if ($running.Count -ge $jobCount) { Start-Sleep -Milliseconds 300 }
        Show-Progress $toDo $startTime $rateLimitFile
    }

    $rels = $item.Rels
    $isBatch = $item.IsBatch
    $firstRel = $rels[0]

    # Opt #5: Tiered model — classify by first file (batch files are all small/simple)
    $fileModel = $defaultModel
    if ($tieredModel -eq '1' -and $hasSerenaContext -and -not $isBatch) {
        $complexity = Get-FileComplexity $firstRel $repoRoot $serenaContextDir
        $fileModel = switch ($complexity) {
            'high' { $highModel }
            default { $defaultModel }
        }
    }

    if ($fileModel -eq $highModel) { $script:modelCounts.sonnet++ } else { $script:modelCounts.haiku++ }

    # Opt #8: Adaptive output budget
    $srcPath = Join-Path $repoRoot ($firstRel -replace '/','\')
    $lc = @(Get-Content $srcPath -ErrorAction SilentlyContinue).Count
    $sc = 0
    if ($serenaArg -ne '') {
        $ctxP = Join-Path $serenaArg (($firstRel -replace '/','\') + '.serena_context.txt')
        if (Test-Path $ctxP) { $sc = @(Get-Content $ctxP -ErrorAction SilentlyContinue | Where-Object { $_ -match '^- ' }).Count }
    }
    $outputBudget = Get-OutputBudget $lc $sc

    # Opt v2#3: Select minimal prompt for simple files (non-batch)
    $filePrompt = $promptFile
    if (-not $isBatch -and $minimalPromptFile -ne '' -and $lc -lt 100 -and $sc -le 3) {
        $filePrompt = $minimalPromptFile
    }

    # Opt v3#1: Compute max-tokens cap from output budget
    $maxTokensArg = "0"
    if ($useMaxTokens -eq '1') {
        $maxTokensArg = switch -Wildcard ($outputBudget) {
            '*200*'  { '250'  }
            '*400*'  { '500'  }
            '*600*'  { '750'  }
            '*1000*' { '1200' }
            '*1200*' { '1500' }
            default  { '1500' }
        }
    }

    # Opt v3#2: Directory context dir (online claude only; local prompts stay lean)
    $dirContextDir = if ($llmBackend -eq 'claude') { Join-Path $archDir '.dir_context' } else { '' }

    # Serialize batch rel list as pipe-separated string
    $relArg = $rels -join '|'

    $j = Start-Job -FilePath $workerScript -ArgumentList `
        $relArg, $repoRoot, $archDir, $claudeCfgDir,
        $fileModel, $maxTurns, $outputFmt, $filePrompt,
        $maxRetries, $retryDelay, $defaultFence,
        $bundleHdrs, $maxBundled, $hashDbPath,
        $maxFileLines, $counterPath, $fatalFlag, $fatalMsg, $errorLog,
        $serenaArg, $bundleHdrDoc, $outputBudget, $preambleContent, $elideSource,
        $maxTokensArg, $dirContextDir, $sharedHeaderDir, $useJsonOutput,
        $llmBackend, $llmEndpoint, $llmModel, $llmTemp, $llmMaxTokens, $llmTimeout, $llmNumCtx,
        $llmThink, $PSScriptRoot

    $running.Add([pscustomobject]@{ Job = $j; Rel = $firstRel })
    Show-Progress $toDo $startTime $rateLimitFile
}

# Drain
while ($running.Count -gt 0) {
    $next = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $running) {
        if ($item.Job.State -ne 'Running') {
            Receive-Job $item.Job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job  $item.Job -ErrorAction SilentlyContinue
        } else {
            $next.Add($item)
        }
    }
    $running = $next
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 300 }
    Show-Progress $toDo $startTime $rateLimitFile
}

Write-Host ''

# ── Opt #6: Generate batch template docs from representative ──

if ($batchedDocs.Count -gt 0) {
    Write-Host "Generating $($batchedDocs.Count) batch-templated docs..." -ForegroundColor Cyan
    foreach ($batchedRel in $batchedDocs.Keys) {
        $repRel = $batchedDocs[$batchedRel]
        $repDoc = Join-Path $archDir (($repRel -replace '/','\') + '.md')
        $batchOut = Join-Path $archDir (($batchedRel -replace '/','\') + '.md')
        if (Test-Path $repDoc) {
            $docContent = Get-Content $repDoc -Raw
            # Replace the representative's path with the batched file's path
            $docContent = $docContent -replace [regex]::Escape($repRel), $batchedRel
            $batchOutDir = Split-Path $batchOut -Parent
            New-Item -ItemType Directory -Force -Path $batchOutDir | Out-Null
            $docContent | Set-Content -Path $batchOut -Encoding UTF8
            # Record hash
            $batchSrc = Join-Path $repoRoot ($batchedRel -replace '/','\')
            $sha = Get-SHA1 $batchSrc
            [System.IO.File]::AppendAllText($hashDbPath, "$sha`t$batchedRel`n")
        }
    }
}

# ── Opt v2#6: Save pattern cache templates from analyzed files ──

if ($patternCache -eq '1' -and $hasSerenaContext -and $patternDb.Count -eq 0) {
    # Build templates from newly analyzed files
    foreach ($rel in $queue) {
        $bc = $baseClassMap[$rel]
        if (-not $bc) { continue }
        if ($classGroups[$bc].Count -lt 3) { continue }
        $templateFile = Join-Path $patternCacheDir "$bc.template.md"
        if (Test-Path $templateFile) { continue }  # Already have template

        $docPath = Join-Path $archDir (($rel -replace '/','\') + '.md')
        if (Test-Path $docPath) {
            $doc = Get-Content $docPath -Raw
            # Extract class name for placeholder replacement
            $srcHead = Get-Content (Join-Path $repoRoot ($rel -replace '/','\')) -First 30 -ErrorAction SilentlyContinue
            $classMatch = $srcHead | Where-Object { $_ -match "class\s+(\w+)\s*:\s*public\s+$bc" } | Select-Object -First 1
            if ($classMatch -match "class\s+(\w+)") {
                $className = $Matches[1]
                $template = $doc -replace [regex]::Escape($rel), '{PATH}' -replace [regex]::Escape($className), '{CLASS}'
                $template | Set-Content -Path $templateFile -Encoding UTF8
            }
        }
    }
}

# ── Result ────────────────────────────────────────────────────

if (Test-Path $fatalFlag) {
    $msg = if (Test-Path $fatalMsg) { Get-Content $fatalMsg -Raw } else { 'unknown error' }
    Write-Host ''
    Write-Err  "FATAL: $($msg.Trim())"
    Write-Err  "Error log: $errorLog"
    Write-Host 'Re-run the same command to resume.' -ForegroundColor Yellow
    exit 1
}

# Deduplicate hash DB
if (Test-Path $hashDbPath) {
    $seen = @{}
    $keep = [System.Collections.Generic.List[string]]::new()
    $raw  = @(Get-Content $hashDbPath | Where-Object { $_.Trim() -ne '' })
    [array]::Reverse($raw)
    foreach ($line in $raw) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2 -and -not $seen.ContainsKey($parts[1])) {
            $seen[$parts[1]] = $true
            $keep.Add($line)
        }
    }
    ($keep | Sort-Object) -join "`n" | Set-Content $hashDbPath -Encoding UTF8
}

Write-Host "Done. Per-file docs are in: $archDir" -ForegroundColor Green
