# ============================================================
# archpass2.ps1 - Context-Aware Second-Pass Analysis
#
# Re-analyzes source files with architecture context injected.
# Claude now knows:
# - Which subsystem this file belongs to
# - The architecture overview (how subsystems connect)
# - The cross-reference index (who calls whom)
# - The first-pass doc for this file
#
# Output: architecture/<path>.pass2.md (does NOT overwrite pass-1 docs)
#
# Prerequisites (run these first):
#   1. archgen.ps1       - per-file docs
#   2. archxref.ps1      - xref_index.md
#   3. arch_overview.ps1 - architecture.md
#
# Usage:
#   .\archpass2.ps1 [-TargetDir <dir>] [-Claude1] [-Clean] [-Jobs <n>]
#   .\archpass2.ps1 -Only "Engine/Source/Runtime/Renderer/Private/DeferredShadingRenderer.cpp,..."
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir = ".",
    [switch]$Claude1,
    [switch]$Clean,
    [string]$Only      = "",     # Comma-separated list of relative file paths
    [int]   $Jobs      = 0,
    [string]$EnvFile   = ".env",
    [int]   $Top       = 0,      # Only process top-N scoring files (0 = all)
    [switch]$ScoreOnly,           # Just print scores, don't run Pass 2
    [switch]$Delta,               # Opt v2#4: Delta-only mode - output only new insights, not full doc
    [switch]$Test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-EnvFile($path) {
    $vars = @{}
    if (Test-Path $path) {
        Get-Content $path | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^\s*#' -or $line -eq '') { return }
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                $val = $val -replace '\$HOME', $env:USERPROFILE
                $val = $val -replace '~', $env:USERPROFILE
                $vars[$key] = $val
            }
        }
    }
    return $vars
}

function Cfg($cfg, $key, $default = '') {
    if ($cfg.ContainsKey($key) -and $cfg[$key] -ne '') { return $cfg[$key] }
    return $default
}

function Get-SHA1($filePath) {
    $sha   = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ''
}

function Test-RateLimit($text) {
    $first3 = ($text -split "`n" | Select-Object -First 3) -join "`n"
    if ($first3 -match '^#') { return $false }
    if ($first3 -match '(^|[^0-9])429([^0-9]|$)') { return $true }
    if ($first3 -imatch 'rate.?limit|usage.?limit|too many requests') { return $true }
    if ($first3 -imatch '^error:.*(overloaded|quota)') { return $true }
    return $false
}

function Get-FenceLang($file, $def) {
    $ext = [System.IO.Path]::GetExtension($file).TrimStart('.').ToLower()
    switch ($ext) {
        { $_ -in 'c','h','inc' }                              { return 'c' }
        { $_ -in 'cpp','cc','cxx','hpp','hh','hxx','inl' }   { return 'cpp' }
        'cs'     { return 'csharp' }  'java' { return 'java' }
        'py'     { return 'python' }  'rs'   { return 'rust' }
        'lua'    { return 'lua' }
        { $_ -in 'gd','gdscript' } { return 'gdscript' }
        'swift'  { return 'swift' }
        { $_ -in 'm','mm' } { return 'objectivec' }
        { $_ -in 'shader','cginc','hlsl','glsl','compute' } { return 'hlsl' }
        'toml'   { return 'toml' }
        { $_ -in 'tscn','tres' } { return 'ini' }
        default  { return $def }
    }
}

# -- Testable functions ----------------------------------------

function Get-Pass2FileScore($rel, $lineCount, $incomingCount, $hasSerena) {
    $score = ($incomingCount * 3) + ($lineCount / 100.0)
    if ($hasSerena) { $score *= 0.5 }
    return $score
}

function Get-Pass2FileComplexity($lineCount, $refCount, $tieredModel, $defaultModel, $highModel) {
    if ($tieredModel -ne '1') { return $defaultModel }
    if ($lineCount -gt 1000 -or $refCount -gt 10) { return $highModel }
    return $defaultModel
}

# -- Unit Tests ------------------------------------------------

if ($Test) {
    $script:testsPassed = 0
    $script:testsFailed = 0
    $script:testErrors  = [System.Collections.Generic.List[string]]::new()

    function Assert-Equal($name, $expected, $actual) {
        if ($expected -eq $actual) { $script:testsPassed++ }
        else {
            $script:testsFailed++
            $script:testErrors.Add("FAIL: $name`n  expected: [$expected]`n  actual:   [$actual]")
        }
    }
    function Assert-True($name, $value) {
        if ($value) { $script:testsPassed++ }
        else {
            $script:testsFailed++
            $script:testErrors.Add("FAIL: $name`n  expected: True`n  actual:   [$value]")
        }
    }
    function Assert-False($name, $value) {
        if (-not $value) { $script:testsPassed++ }
        else {
            $script:testsFailed++
            $script:testErrors.Add("FAIL: $name`n  expected: False`n  actual:   [$value]")
        }
    }

    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host '  archpass2.ps1 - Unit Tests' -ForegroundColor Yellow
    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host ''

    $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "archpass2_tests_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $testDir | Out-Null

    try {

    # -- Test: Cfg ---------------------------------------------

    Write-Host 'Testing Cfg ...' -ForegroundColor Cyan

    $tc = @{ MODEL = 'haiku'; JOBS = '4'; EMPTY = '' }
    Assert-Equal 'Cfg: existing'       'haiku'   (Cfg $tc 'MODEL' 'sonnet')
    Assert-Equal 'Cfg: missing'        'sonnet'  (Cfg $tc 'MISSING' 'sonnet')
    Assert-Equal 'Cfg: empty default'  'default' (Cfg $tc 'EMPTY' 'default')
    Assert-Equal 'Cfg: no default'     ''        (Cfg $tc 'MISSING')

    # -- Test: Get-SHA1 ----------------------------------------

    Write-Host 'Testing Get-SHA1 ...' -ForegroundColor Cyan

    $sf = Join-Path $testDir 'sha.txt'
    'test content' | Set-Content $sf -NoNewline -Encoding UTF8
    $h1 = Get-SHA1 $sf
    Assert-True  'SHA1: 40 hex chars' ($h1 -match '^[0-9a-f]{40}$')
    $sf2 = Join-Path $testDir 'sha2.txt'
    'test content' | Set-Content $sf2 -NoNewline -Encoding UTF8
    Assert-Equal 'SHA1: deterministic' $h1 (Get-SHA1 $sf2)
    'different' | Set-Content $sf2 -NoNewline -Encoding UTF8
    Assert-True  'SHA1: different content' ($h1 -ne (Get-SHA1 $sf2))

    # -- Test: Test-RateLimit (archpass2 variant) --------------

    Write-Host 'Testing Test-RateLimit ...' -ForegroundColor Cyan

    Assert-True  'RL: 429'                    (Test-RateLimit "429`nToo many requests")
    Assert-True  'RL: rate limit'             (Test-RateLimit 'rate limit exceeded')
    Assert-True  'RL: usage limit'            (Test-RateLimit 'usage limit reached')
    Assert-True  'RL: too many requests'      (Test-RateLimit 'too many requests')
    Assert-True  'RL: overloaded'             (Test-RateLimit 'error: server overloaded')
    Assert-True  'RL: quota'                  (Test-RateLimit 'error: quota exceeded')
    Assert-False 'RL: markdown heading'       (Test-RateLimit "# Architecture`n## Subsystems")
    Assert-False 'RL: normal text'            (Test-RateLimit 'Normal analysis result.')
    Assert-False 'RL: empty'                  (Test-RateLimit '')

    # -- Test: Get-FenceLang -----------------------------------

    Write-Host 'Testing Get-FenceLang ...' -ForegroundColor Cyan

    Assert-Equal 'Fence: .c'     'c'          (Get-FenceLang 'foo.c' 'x')
    Assert-Equal 'Fence: .cpp'   'cpp'        (Get-FenceLang 'foo.cpp' 'x')
    Assert-Equal 'Fence: .cs'    'csharp'     (Get-FenceLang 'foo.cs' 'x')
    Assert-Equal 'Fence: .py'    'python'     (Get-FenceLang 'foo.py' 'x')
    Assert-Equal 'Fence: .rs'    'rust'       (Get-FenceLang 'foo.rs' 'x')
    Assert-Equal 'Fence: .hlsl'  'hlsl'       (Get-FenceLang 'foo.hlsl' 'x')
    Assert-Equal 'Fence: .gd'    'gdscript'   (Get-FenceLang 'foo.gd' 'x')
    Assert-Equal 'Fence: .toml'  'toml'       (Get-FenceLang 'foo.toml' 'x')
    Assert-Equal 'Fence: unknown' 'mydef'     (Get-FenceLang 'foo.xyz' 'mydef')

    # -- Test: Get-Pass2FileScore ------------------------------

    Write-Host 'Testing Get-Pass2FileScore ...' -ForegroundColor Cyan

    # score = (incoming * 3) + (lines / 100), halved if hasSerena
    Assert-Equal 'Score: 0 refs 0 lines'     0     (Get-Pass2FileScore 'x.cpp' 0 0 $false)
    Assert-Equal 'Score: 10 refs 500 lines'  35    (Get-Pass2FileScore 'x.cpp' 500 10 $false)
    Assert-Equal 'Score: 10 refs with Serena' 17.5 (Get-Pass2FileScore 'x.cpp' 500 10 $true)
    Assert-Equal 'Score: 1 ref 100 lines'    4     (Get-Pass2FileScore 'x.cpp' 100 1 $false)
    Assert-Equal 'Score: 0 refs 1000 lines'  10    (Get-Pass2FileScore 'x.cpp' 1000 0 $false)

    # Ranking: hub file (many refs) beats large file (many lines)
    $scoreHub = Get-Pass2FileScore 'hub.cpp' 200 20 $false
    $scoreBig = Get-Pass2FileScore 'big.cpp' 5000 0 $false
    Assert-True  'Score: hub beats big file' ($scoreHub -gt $scoreBig)

    # Serena discount halves score
    $scoreNoSerena = Get-Pass2FileScore 'x.cpp' 500 5 $false
    $scoreSerena   = Get-Pass2FileScore 'x.cpp' 500 5 $true
    Assert-Equal 'Score: Serena halves' ($scoreNoSerena / 2) $scoreSerena

    # -- Test: Get-Pass2FileComplexity -------------------------

    Write-Host 'Testing Get-Pass2FileComplexity ...' -ForegroundColor Cyan

    # Tiered disabled
    Assert-Equal 'Complexity: tiered off'            'haiku'  (Get-Pass2FileComplexity 5000 50 '0' 'haiku' 'sonnet')

    # Tiered enabled - high complexity
    Assert-Equal 'Complexity: >1000 lines'           'sonnet' (Get-Pass2FileComplexity 1001 0 '1' 'haiku' 'sonnet')
    Assert-Equal 'Complexity: >10 refs'              'sonnet' (Get-Pass2FileComplexity 100 11 '1' 'haiku' 'sonnet')
    Assert-Equal 'Complexity: both high'             'sonnet' (Get-Pass2FileComplexity 2000 20 '1' 'haiku' 'sonnet')

    # Tiered enabled - low/medium complexity
    Assert-Equal 'Complexity: small file few refs'   'haiku'  (Get-Pass2FileComplexity 500 5 '1' 'haiku' 'sonnet')
    Assert-Equal 'Complexity: at boundary 1000/10'   'haiku'  (Get-Pass2FileComplexity 1000 10 '1' 'haiku' 'sonnet')

    # -- Load worker functions for testing ---------------------

    Write-Host 'Loading archpass2_worker.ps1 functions ...' -ForegroundColor Cyan

    $workerPath = Join-Path $PSScriptRoot 'archpass2_worker.ps1'
    $workerLoaded = $false
    if (Test-Path $workerPath) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$null, [ref]$null)
        $funcDefs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        foreach ($fd in $funcDefs) {
            # Skip functions already defined in this script (same names)
            $fname = $fd.Name
            if ($fname -in @('Get-FenceLang','Test-RateLimit')) { continue }
            try { Invoke-Expression $fd.Extent.Text } catch {}
        }
        $workerLoaded = $true
    } else {
        Write-Host '  WARNING: archpass2_worker.ps1 not found, skipping worker tests' -ForegroundColor Yellow
    }

    # -- Test: Test-TooLong (worker) ---------------------------

    if ($workerLoaded) {
        Write-Host 'Testing Test-TooLong (worker) ...' -ForegroundColor Cyan

        Assert-True  'TooLong: prompt too long'      (Test-TooLong 'Error: prompt is too long')
        Assert-True  'TooLong: context length'       (Test-TooLong 'context length exceeded')
        Assert-True  'TooLong: maximum context'      (Test-TooLong 'maximum context reached')
        Assert-True  'TooLong: too many tokens'      (Test-TooLong 'too many tokens in prompt')
        Assert-False 'TooLong: normal'               (Test-TooLong '# Analysis doc')
        Assert-False 'TooLong: empty'                (Test-TooLong '')
    }

    # -- Test: Write-ErrorLog (worker) -------------------------

    if ($workerLoaded) {
        Write-Host 'Testing Write-ErrorLog (worker) ...' -ForegroundColor Cyan

        $errLogPath = Join-Path $testDir 'test_error.log'
        '' | Set-Content $errLogPath -Encoding UTF8
        Write-ErrorLog $errLogPath 'TEST_TYPE' 'src/test.cpp' 1 'stdout content' 'stderr content'
        $errContent = Get-Content $errLogPath -Raw
        Assert-True  'ErrorLog: has type'            ($errContent -match 'TEST_TYPE')
        Assert-True  'ErrorLog: has file'            ($errContent -match 'src/test\.cpp')
        Assert-True  'ErrorLog: has exit code'       ($errContent -match '1')
        Assert-True  'ErrorLog: has stdout'          ($errContent -match 'stdout content')
        Assert-True  'ErrorLog: has stderr'          ($errContent -match 'stderr content')
        Assert-True  'ErrorLog: has timestamp'       ($errContent -match '\d{4}-\d{2}-\d{2}')
        Assert-True  'ErrorLog: has divider'         ($errContent -match '={10,}')
    }

    # -- Test: Get-RateLimitResetTime (worker) -----------------

    if ($workerLoaded) {
        Write-Host 'Testing Get-RateLimitResetTime (worker) ...' -ForegroundColor Cyan

        $t1 = Get-RateLimitResetTime 'resets at 6pm (America/New_York)'
        Assert-True  'ResetTime: 6pm'              ($null -ne $t1)
        if ($t1) { Assert-Equal 'ResetTime: 6pm hour' 18 $t1.Hour }

        $t2 = Get-RateLimitResetTime 'resets at 2025-06-15T13:00:00Z'
        Assert-True  'ResetTime: ISO'              ($null -ne $t2)

        $t3 = Get-RateLimitResetTime '{"reset_at":1705320000}'
        Assert-True  'ResetTime: unix'             ($null -ne $t3)

        $t4 = Get-RateLimitResetTime 'random text'
        Assert-True  'ResetTime: no match null'    ($null -eq $t4)
    }

    # -- Test: Format-LocalTime (worker) -----------------------

    if ($workerLoaded) {
        Write-Host 'Testing Format-LocalTime (worker) ...' -ForegroundColor Cyan

        $dt = [datetime]::new(2025, 6, 15, 14, 30, 0)
        $fmt = Format-LocalTime $dt
        Assert-True  'FmtTime: has 2:30'           ($fmt -match '2:30')
        Assert-True  'FmtTime: has PM'             ($fmt -match '(?i)pm')
    }

    # -- Test: Build-Pass2Payload (worker) ---------------------

    if ($workerLoaded) {
        Write-Host 'Testing Build-Pass2Payload (worker) ...' -ForegroundColor Cyan

        # Set up variables the function reads from outer scope
        $promptFileP2 = Join-Path $testDir 'test_p2_prompt.txt'
        'Enrich the analysis.' | Set-Content $promptFileP2 -Encoding UTF8
        $stateDir = Join-Path $testDir 'state'
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

        $srcLines = @('void Init() {', '    Setup();', '}')
        $pass1 = '# src/init.cpp\n## File Purpose\nInitializes.'
        $archCtx = '## Major Subsystems\n- Core\n- Renderer'
        $xrefCtx = '| Init | src/init.cpp | 5: Setup Render |'

        # Stage 0: full context
        $p0 = Build-Pass2Payload 0 'src/init.cpp' 'cpp' $srcLines $pass1 $archCtx $xrefCtx
        Assert-True  'P2Payload s0: file path'       ($p0 -match 'src/init\.cpp')
        Assert-True  'P2Payload s0: source code'     ($p0 -match 'void Init')
        Assert-True  'P2Payload s0: fence'           ($p0 -match '```cpp')
        Assert-True  'P2Payload s0: pass1 doc'       ($p0 -match 'FIRST-PASS ANALYSIS')
        Assert-True  'P2Payload s0: arch context'    ($p0 -match 'ARCHITECTURE CONTEXT')
        Assert-True  'P2Payload s0: xref context'    ($p0 -match 'CROSS-REFERENCE CONTEXT')
        Assert-True  'P2Payload s0: schema'          ($p0 -match 'Enrich the analysis')

        # Stage 1: drop xref
        $p1 = Build-Pass2Payload 1 'src/init.cpp' 'cpp' $srcLines $pass1 $archCtx $xrefCtx
        Assert-True  'P2Payload s1: has arch'        ($p1 -match 'ARCHITECTURE CONTEXT')
        Assert-False 'P2Payload s1: no xref'         ($p1 -match 'CROSS-REFERENCE CONTEXT')

        # Stage 2: drop arch, truncate harder
        $p2 = Build-Pass2Payload 2 'src/init.cpp' 'cpp' $srcLines $pass1 $archCtx $xrefCtx
        Assert-False 'P2Payload s2: no arch'         ($p2 -match 'ARCHITECTURE CONTEXT')
        Assert-False 'P2Payload s2: no xref'         ($p2 -match 'CROSS-REFERENCE CONTEXT')
        Assert-True  'P2Payload s2: has pass1'       ($p2 -match 'FIRST-PASS ANALYSIS')

        # Stage 3: source only (minimal)
        $p3 = Build-Pass2Payload 3 'src/init.cpp' 'cpp' $srcLines $pass1 $archCtx $xrefCtx
        Assert-False 'P2Payload s3: no arch'         ($p3 -match 'ARCHITECTURE CONTEXT')
        Assert-False 'P2Payload s3: no xref'         ($p3 -match 'CROSS-REFERENCE CONTEXT')
        Assert-True  'P2Payload s3: has source'      ($p3 -match 'void Init')

        # Truncation at different stages
        $bigSrc = (1..600 | ForEach-Object { "int line$_ = $_;" })
        $p0big = Build-Pass2Payload 0 'src/big.cpp' 'cpp' $bigSrc $pass1 $archCtx $xrefCtx
        Assert-True  'P2Payload truncate s0: at 500' ($p0big -match 'truncated at 500/600')
        $p2big = Build-Pass2Payload 2 'src/big.cpp' 'cpp' $bigSrc $pass1 $archCtx $xrefCtx
        Assert-True  'P2Payload truncate s2: at 200' ($p2big -match 'truncated at 200/600')
        $p3big = Build-Pass2Payload 3 'src/big.cpp' 'cpp' $bigSrc $pass1 $archCtx $xrefCtx
        Assert-True  'P2Payload truncate s3: at 100' ($p3big -match 'truncated at 100/600')

        # Targeted context (when .pass2_context file exists)
        $tgtDir = Join-Path (Split-Path $stateDir -Parent) '.pass2_context'
        $tgtSubDir = Join-Path $tgtDir 'src'
        New-Item -ItemType Directory -Force -Path $tgtSubDir | Out-Null
        $tgtFile = Join-Path $tgtSubDir 'init.cpp.ctx.txt'
        'Targeted context for init.cpp' | Set-Content $tgtFile -Encoding UTF8

        $p0tgt = Build-Pass2Payload 0 'src/init.cpp' 'cpp' $srcLines $pass1 $archCtx $xrefCtx
        Assert-True  'P2Payload targeted: uses targeted ctx' ($p0tgt -match 'TARGETED ARCHITECTURE')
        Assert-True  'P2Payload targeted: has content'       ($p0tgt -match 'Targeted context for init')
        Assert-False 'P2Payload targeted: no global arch'    ($p0tgt -match 'ARCHITECTURE CONTEXT:')
        Assert-False 'P2Payload targeted: no global xref'    ($p0tgt -match 'CROSS-REFERENCE CONTEXT \(excerpt\)')

        # Targeted context dropped at stage 2
        $p2tgt = Build-Pass2Payload 2 'src/init.cpp' 'cpp' $srcLines $pass1 $archCtx $xrefCtx
        Assert-False 'P2Payload targeted s2: no targeted'    ($p2tgt -match 'TARGETED')
    }

    } finally {
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -- Results -----------------------------------------------

    Write-Host ''
    Write-Host '--------------------------------------------' -ForegroundColor Yellow
    if ($script:testsFailed -eq 0) {
        Write-Host "ALL $($script:testsPassed) TESTS PASSED" -ForegroundColor Green
    } else {
        Write-Host "$($script:testsPassed) passed, $($script:testsFailed) FAILED" -ForegroundColor Red
        Write-Host ''
        foreach ($err in $script:testErrors) {
            Write-Host $err -ForegroundColor Red
        }
    }
    Write-Host '--------------------------------------------' -ForegroundColor Yellow
    exit $script:testsFailed
}

# -- Load config -----------------------------------------------

$cfg = Read-EnvFile $EnvFile

$repoRoot = (Get-Location).Path
try {
    $gitRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitRoot) { $repoRoot = $gitRoot.Trim() }
} catch {}

$archDir  = Join-Path $repoRoot 'architecture'
$stateDir = Join-Path $archDir  '.pass2_state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$defaultModel  = Cfg $cfg 'CLAUDE_MODEL'         'sonnet'
$model         = $defaultModel
$tieredModel   = Cfg $cfg 'TIERED_MODEL'        '1'
$highModel     = Cfg $cfg 'HIGH_COMPLEXITY_MODEL' 'sonnet'
$maxTurns      = Cfg $cfg 'CLAUDE_MAX_TURNS'     '1'
$outputFmt     = Cfg $cfg 'CLAUDE_OUTPUT_FORMAT' 'text'
$jobCount      = if ($Jobs -gt 0) { $Jobs } else { [int](Cfg $cfg 'JOBS' '2') }
$maxRetries    = [int](Cfg $cfg 'MAX_RETRIES' '2')
$retryDelay    = [int](Cfg $cfg 'RETRY_DELAY' '5')
$includeRx     = Cfg $cfg 'INCLUDE_EXT_REGEX' '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc|cs|java|py|rs|lua|gd|m|mm|swift)$'
$excludeRx     = Cfg $cfg 'EXCLUDE_DIRS_REGEX' '[/\\](\.git|architecture|build|out|dist|obj|bin)([/\\]|$)'
$extraExclude  = Cfg $cfg 'EXTRA_EXCLUDE_REGEX' ''
$defaultFence  = Cfg $cfg 'DEFAULT_FENCE' 'c'
$codebaseDesc  = Cfg $cfg 'CODEBASE_DESC' 'game engine / game codebase'
$detectDataBlob   = Cfg $cfg 'DETECT_DATA_BLOB' '1'
$dataBlobMinLines = [int](Cfg $cfg 'DATA_BLOB_MIN_LINES' '2000')
$dataBlobFrac     = [double](Cfg $cfg 'DATA_BLOB_FRACTION' '0.6')

# -- Local LLM backend (LLMConfig) -----------------------------
. (Join-Path $PSScriptRoot 'llm_core.ps1')
$llmBackend   = Get-LLMBackend -Cfg $cfg
$llmEndpoint  = ''
$llmModel     = ''
$llmTemp      = [double](Cfg $cfg 'LLM_TEMPERATURE' '0.1')
$llmMaxTokens = [int](Cfg $cfg 'LLM_MAX_TOKENS' '1000')
$llmTimeout   = [int](Cfg $cfg 'LLM_TIMEOUT' '900')
$llmNumCtx    = [int](Cfg $cfg 'LLM_NUM_CTX' '0')
$llmThink     = ((Cfg $cfg 'LLM_THINK' 'false').Trim().ToLower() -eq 'true')
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

$cfgDirKey    = if ($Claude1) { 'CLAUDE1_CONFIG_DIR' } else { 'CLAUDE2_CONFIG_DIR' }
$claudeCfgDir = Cfg $cfg $cfgDirKey ''
if ($llmBackend -eq 'claude') {
    if (-not $claudeCfgDir) { Write-Host "Missing $cfgDirKey in $EnvFile" -ForegroundColor Red; exit 2 }
    if (-not (Test-Path $claudeCfgDir)) { Write-Host "Claude config dir not found: $claudeCfgDir" -ForegroundColor Red; exit 2 }
}

# Degrade fallback (local backends only): escalate a degrading file to this claude model with
# the full payload instead of emitting a truncated doc, then continue locally. Empty = disabled.
$degradeFallbackModel = Cfg $cfg 'DEGRADE_FALLBACK_MODEL' ''
if ($llmBackend -eq 'claude') {
    $degradeFallbackModel = ''
} elseif ($degradeFallbackModel -ne '') {
    if (-not $claudeCfgDir -or -not (Test-Path $claudeCfgDir)) {
        Write-Host "DEGRADE_FALLBACK_MODEL='$degradeFallbackModel' set but $cfgDirKey missing/invalid -- disabling claude fallback" -ForegroundColor Yellow
        $degradeFallbackModel = ''
    } else {
        Write-Host "Degrade fallback:  local failures escalate to claude '$degradeFallbackModel'" -ForegroundColor Cyan
    }
}

$account = if ($Claude1) { 'claude1' } else { 'claude2' }

# Check prerequisites - look for subsystem-prefixed files first, then fall back to root files
$outPrefix    = if ($TargetDir -ne '.' -and $TargetDir -ne '') { (Split-Path $TargetDir -Leaf) + ' ' } else { '' }
$archOverview = if ($outPrefix -ne '' -and (Test-Path (Join-Path $archDir ($outPrefix + 'architecture.md')))) {
    Join-Path $archDir ($outPrefix + 'architecture.md')
} else { Join-Path $archDir 'architecture.md' }
$xrefIndex    = if ($outPrefix -ne '' -and (Test-Path (Join-Path $archDir ($outPrefix.TrimEnd() + '_xref_index.md')))) {
    Join-Path $archDir ($outPrefix.TrimEnd() + '_xref_index.md')
} elseif ($outPrefix -ne '' -and (Test-Path (Join-Path $archDir ($outPrefix + 'xref_index.md')))) {
    Join-Path $archDir ($outPrefix + 'xref_index.md')
} else { Join-Path $archDir 'xref_index.md' }

$missing = @()
if (-not (Test-Path $archOverview)) { $missing += "  - ${outPrefix}architecture.md (run arch_overview.ps1)" }
if (-not (Test-Path $xrefIndex))    { $missing += "  - ${outPrefix}xref_index.md or ${outPrefix}_xref_index.md (run archxref.ps1)" }
if ($missing.Count -gt 0) {
    Write-Host "Missing prerequisite files:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 2
}

# State files
$hashDbPath    = Join-Path $stateDir 'hashes.tsv'
$dataBlobLedger = Join-Path $stateDir 'datablob.tsv'   # files stubbed by the data-blob detector (Pass 2)
$errorLog      = Join-Path $stateDir 'last_claude_error.log'
$fatalFlag     = Join-Path $stateDir 'fatal.flag'
$fatalMsg      = Join-Path $stateDir 'fatal.msg'
$progressTxt   = Join-Path $stateDir 'progress.txt'
$rateLimitFile = Join-Path $stateDir 'ratelimit_resume.txt'

'' | Set-Content $errorLog -Encoding UTF8
Remove-Item $fatalFlag     -ErrorAction SilentlyContinue
Remove-Item $fatalMsg      -ErrorAction SilentlyContinue
Remove-Item $rateLimitFile -ErrorAction SilentlyContinue

# Pass-2 prompt (auto-generate if missing). Templates live in the toolkit llm_prompts/ dir.
$promptDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'llm_prompts'
# Opt v2#4: Delta mode uses a different prompt
if ($Delta) {
    $deltaPrompt = Join-Path $promptDir 'file_doc_prompt_pass2_delta.txt'
    if (Test-Path $deltaPrompt) {
        $promptFileP2 = $deltaPrompt
    } else {
        Write-Host "Warning: Delta prompt not found at $deltaPrompt, using standard pass-2 prompt" -ForegroundColor Yellow
        $promptFileP2 = Cfg $cfg 'PROMPT_FILE_P2' (Join-Path $promptDir 'file_doc_prompt_pass2.txt')
    }
} else {
    $promptFileP2 = Cfg $cfg 'PROMPT_FILE_P2' (Join-Path $promptDir 'file_doc_prompt_pass2.txt')
}
if (-not (Test-Path $promptFileP2)) {
    Write-Host "No pass-2 prompt found at: $promptFileP2 - generating default..." -ForegroundColor Yellow
    @'
You are doing a SECOND-PASS architectural analysis of a game engine source file.

You have: the first-pass analysis, the architecture overview, and the cross-reference index.
Your job is to ENRICH the analysis with cross-cutting insights impossible in the first pass.

Write deterministic markdown using this schema:

# <FILE PATH> - Enhanced Analysis

## Architectural Role
2-4 sentences explaining this file's role in the broader engine architecture.
Reference specific subsystems and data flows.

## Key Cross-References
### Incoming (who depends on this file)
- Which files/subsystems call functions defined here
- Which globals defined here are read elsewhere

### Outgoing (what this file depends on)
- Which subsystems this file calls into
- Which globals from other files it reads/writes

## Design Patterns & Rationale
- What design patterns are used (and why, if inferable)
- Why is the code structured this way?
- What tradeoffs were made?

## Data Flow Through This File
- What data enters (from where), how it's transformed, where it goes
- Key state transitions

## Learning Notes
- What would a developer studying this engine learn from this file?
- What's idiomatic to this engine/era that modern engines do differently?

## Potential Issues
- Only if clearly inferable from the code + context

Rules:
- Use the provided context to make specific cross-references
- Do NOT repeat the first-pass doc verbatim - add new insights
- Keep output under ~1500 tokens
'@ | Set-Content -Path $promptFileP2 -Encoding UTF8
    Write-Host "Wrote default prompt: $promptFileP2"
}

# -- Clean -----------------------------------------------------

if ($Clean) {
    Write-Host "CLEAN: removing pass-2 state and docs..." -ForegroundColor Yellow
    Get-ChildItem -Path $archDir -Recurse -Filter '*.pass2.md' -ErrorAction SilentlyContinue |
        Remove-Item -Force
    Remove-Item -Recurse -Force $stateDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}

'' | Set-Content $errorLog
Remove-Item $fatalFlag -ErrorAction SilentlyContinue
Remove-Item $fatalMsg  -ErrorAction SilentlyContinue
'' | Set-Content $progressTxt
if (-not (Test-Path $hashDbPath)) { '' | Set-Content $hashDbPath }

# -- Load hash DB ----------------------------------------------

$oldSha = @{}
if (Test-Path $hashDbPath) {
    Get-Content $hashDbPath | ForEach-Object {
        $parts = $_ -split "`t", 2
        if ($parts.Count -eq 2 -and $parts[1] -ne '') { $oldSha[$parts[1]] = $parts[0] }
    }
}

# -- Data-blob detector (mirror of archgen.ps1; keep the two in sync) ---------
# Large generated literal tables (LUTs / numeric arrays) have no architecture to
# document, exhaust the thinking model, and overflow the sonnet fallback. Stub
# them instead of re-failing in Pass 2.
function Test-DataBlobFile($fullPath, $minLines, $dataFrac) {
    $lines = @(Get-Content $fullPath -ErrorAction SilentlyContinue)
    if ($lines.Count -lt $minLines) { return $false }
    $code = 0; $data = 0
    foreach ($ln in $lines) {
        $t = $ln.Trim()
        if ($t -eq '' -or $t -match '^(//|/\*|\*|\*/|#)') { continue }   # blank / comment / preprocessor
        $code++
        if ($t -match '^[\s{}()]*((0[xX][0-9A-Fa-f]+|[+-]?[0-9][0-9.eEfFuUlL+-]*)[\s,;{}()]*)+$') { $data++ }
    }
    if ($code -eq 0) { return $false }
    return (($data / $code) -ge $dataFrac)
}

function Write-DataBlobStub($rel, $outPath) {
    $stub = "# $rel`n`n## File Purpose`nGenerated data table (lookup tables / precomputed numeric arrays). No architecture to document; skipped by the data-blob detector.`n`n## Core Responsibilities`n- Holds hardcoded numeric/hex literal data consumed elsewhere`n"
    $stub | Set-Content -Path $outPath -Encoding UTF8
}

# -- Collect files ---------------------------------------------

$scanRoot = if ($TargetDir -eq '.') { $repoRoot } else { Join-Path $repoRoot $TargetDir }

$onlyList = @()
if ($Only -ne '') { $onlyList = $Only -split ',' | ForEach-Object { $_.Trim() -replace '\\','/' } }

$files = Get-ChildItem -Path $scanRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($repoRoot.Length).TrimStart('\','/') -replace '\\','/'
        if ($rel -match '^architecture/' -or $rel -match '/architecture/') { return $false }
        if ($_.Name -match '\.ignore$') { return $false }
        if ($rel -imatch $excludeRx) { return $false }
        if ($extraExclude -ne '' -and $rel -imatch $extraExclude) { return $false }
        if (-not ($rel -imatch $includeRx)) { return $false }
        if ($onlyList.Count -gt 0 -and $rel -notin $onlyList) { return $false }
        return $true
    } | Sort-Object FullName |
    ForEach-Object { $_.FullName.Substring($repoRoot.Length).TrimStart('\','/') -replace '\\','/' }

$total = @($files).Count
if ($total -eq 0) {
    Write-Host "No matching source files found." -ForegroundColor Red; exit 1
}

$queue = [System.Collections.Generic.List[string]]::new()
$skipUnchanged = 0
$dataBlobN     = 0
foreach ($rel in $files) {
    $src = Join-Path $repoRoot ($rel -replace '/','\\')
    $out = Join-Path $archDir  (($rel -replace '/','\\') + '.pass2.md')
    $sha = Get-SHA1 $src
    if ((Test-Path $out) -and (-not $oldSha.ContainsKey($rel) -or $oldSha[$rel] -eq $sha)) {
        $skipUnchanged++
        continue
    }
    # Skip giant generated data tables (same detector as Pass 1) -- they exhaust the
    # thinking model and overflow the sonnet fallback; stub instead of re-failing.
    if ($detectDataBlob -eq '1' -and (Test-DataBlobFile $src $dataBlobMinLines $dataBlobFrac)) {
        $outDir = Split-Path $out -Parent
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        Write-DataBlobStub $rel $out
        [System.IO.File]::AppendAllText($hashDbPath, "$sha`t$rel`n")
        [System.IO.File]::AppendAllText($dataBlobLedger, "$rel`n")
        $dataBlobN++
        continue
    }
    $queue.Add($rel)
}

# -- Selective scoring: -Top N limits Pass 2 to highest-value files ------

$serenaContextDir = Join-Path $archDir '.serena_context'

# Load xref raw data (used for scoring and tiered model classification)
$xrefRaw = if (Test-Path $xrefIndex) { Get-Content $xrefIndex -Raw } else { '' }

if ($Top -gt 0 -and $Only -eq '' -and $queue.Count -gt $Top) {
    Write-Host "Scoring $($queue.Count) files for selective Pass 2 (top $Top)..." -ForegroundColor Cyan

    $scored = $queue | ForEach-Object {
        $rel = $_
        $srcPath = Join-Path $repoRoot ($rel -replace '/','\')
        $lineCount = @(Get-Content $srcPath -ErrorAction SilentlyContinue).Count

        # Count how many times this file appears as a callee in the xref index
        $incomingCount = ([regex]::Matches($xrefRaw, [regex]::Escape($rel))).Count

        # Check if this file has Serena LSP context (discount if already enriched in Pass 1)
        $hasSerena = Test-Path (Join-Path $serenaContextDir ($rel -replace '/','\') + '.serena_context.txt')

        $score = Get-Pass2FileScore $rel $lineCount $incomingCount $hasSerena

        [PSCustomObject]@{ Rel = $rel; Score = $score; Incoming = $incomingCount; Lines = $lineCount; HasSerena = $hasSerena }
    } | Sort-Object Score -Descending

    if ($ScoreOnly) {
        Write-Host ""
        Write-Host "Top $Top files by score:" -ForegroundColor Yellow
        $scored | Select-Object -First $Top | Format-Table -AutoSize Rel, Score, Incoming, Lines, HasSerena
        Write-Host "Full list: $($scored.Count) files scored."
        exit 0
    }

    $topFiles = $scored | Select-Object -First $Top | ForEach-Object { $_.Rel }
    $queue = [System.Collections.Generic.List[string]]::new()
    $topFiles | ForEach-Object { $queue.Add($_) }
    Write-Host "Selected top $Top files (scored by incoming refs, file size, Serena discount)." -ForegroundColor Cyan
}

$toDo = $queue.Count

# -- Print banner ----------------------------------------------

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  archpass2.ps1 - Second-Pass Analysis"     -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "Repo root:    $repoRoot"
Write-Host "Codebase:     $codebaseDesc"
if ($llmBackend -eq 'claude') {
    Write-Host "Account:      $account"
    Write-Host "Model:        $model"
} else {
    Write-Host "Backend:      $llmBackend"
    Write-Host "Model:        $llmModel"
}
Write-Host "Jobs:         $jobCount"
$modeStr = if ($Top -gt 0) { "SELECTIVE (top $Top)" } else { "ALL" }
if ($Delta) { $modeStr += " + DELTA" }
Write-Host "Mode:         $modeStr"
$blobNote = if ($dataBlobN -gt 0) { " + $dataBlobN data-blob" } else { '' }
Write-Host "Files:        $total (skipped: $skipUnchanged unchanged$blobNote, to process: $toDo)"
Write-Host "Prompt:       $promptFileP2"
Write-Host "Context:      $archOverview"
Write-Host "              $xrefIndex"
Write-Host ""

if ($toDo -eq 0) { Write-Host "Nothing to do." -ForegroundColor Green; exit 0 }

# Load context (truncated for context window safety)
$archContext = (Get-Content $archOverview | Select-Object -First 200) -join "`n"
$xrefContext = (Get-Content $xrefIndex   | Select-Object -First 300) -join "`n"
# Local backends: drop the global arch-overview + xref context to keep the Pass-2 prompt lean.
# The per-file targeted .pass2_context (small) is still injected. Online claude keeps both.
if ($llmBackend -ne 'claude') {
    if ($archContext -ne '' -or $xrefContext -ne '') {
        Write-Host "$llmBackend backend: dropping arch+xref context from Pass-2 prompt (minimizing local prompt)" -ForegroundColor Yellow
    }
    $archContext = ''
    $xrefContext = ''
}
if ($llmBackend -eq 'claude') {
    Write-Host "Loaded context: arch=$($archContext.Length) chars, xref=$($xrefContext.Length) chars"
} else {
    $p2ctxScope = if ($TargetDir -ne '.' -and $TargetDir -ne 'all') { Join-Path (Join-Path $archDir '.pass2_context') $TargetDir } else { Join-Path $archDir '.pass2_context' }
    $p2ctxN = if (Test-Path $p2ctxScope) { @(Get-ChildItem $p2ctxScope -Filter *.ctx.txt -Recurse -ErrorAction SilentlyContinue).Count } else { 0 }
    Write-Host "Loaded context: arch=0 chars, xref=0 chars (global dropped for local; per-file .pass2_context used by workers -- $p2ctxN files)"
}

# -- Counter file + worker script path ------------------------

$counterPath  = Join-Path $stateDir 'counter.json'
$workerScript = Join-Path $PSScriptRoot 'archpass2_worker.ps1'

if (-not (Test-Path $workerScript)) {
    Write-Host "ERROR: archpass2_worker.ps1 not found at: $workerScript" -ForegroundColor Red
    exit 2
}

@{ done = 0; fail = 0; skip = $skipUnchanged; retries = 0; haiku = 0; sonnet = 0 } |
    ConvertTo-Json -Compress | Set-Content $counterPath -Encoding UTF8
$modelCounts = @{ haiku = 0; sonnet = 0 }

$startTime = [datetime]::Now


# -- Progress helper with rate-limit status --------------------

function Read-Counter($path) {
    try { return (Get-Content $path -Raw -ErrorAction Stop) | ConvertFrom-Json } catch { return $null }
}

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

# -- Run with throttled parallelism ----------------------------

$running = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()

foreach ($rel in $queue) {
    if (Test-Path $fatalFlag) { break }

    while ($running.Count -ge $jobCount) {
        $finished = @($running | Where-Object { $_.State -ne 'Running' })
        foreach ($j in $finished) {
            Receive-Job $j -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $j
            $running.Remove($j) | Out-Null
        }
        if ($running.Count -ge $jobCount) {
            $c = Read-Counter $counterPath
            if ($c) {
                $elapsed = ([datetime]::Now - $startTime).TotalSeconds
                $rate    = if ($elapsed -gt 0 -and $c.done -gt 0) { [math]::Round($c.done / $elapsed, 2) } else { 0 }
                $remaining = [math]::Max(0, $toDo - $c.done)
                if ($rate -gt 0) {
                    $etaSec = [int]($remaining / $rate)
                    $etaH = [int][math]::Floor($etaSec / 3600)
                    $etaM = [int][math]::Floor(($etaSec % 3600) / 60)
                    $etaS = [int]($etaSec % 60)
                    $eta = if ($etaH -gt 0) { '{0}h{1:d2}m{2:d2}s' -f $etaH, $etaM, $etaS } else { '{0}m{1:d2}s' -f $etaM, $etaS }
                } else { $eta = '?' }
                $rlStatus = Get-RateLimitStatus $rateLimitFile
                if ($llmBackend -eq 'claude') {
                    $hPct = if ($modelCounts.haiku + $modelCounts.sonnet -gt 0) { [int][math]::Round(100 * $modelCounts.haiku / ($modelCounts.haiku + $modelCounts.sonnet)) } else { 0 }
                    $modelStatus = "haiku=${hPct}% sonnet=$((100 - $hPct))%"
                } else { $modelStatus = "model=$llmModel" }
                $line    = "PROGRESS: $($c.done)/$toDo  skip=$($c.skip)  fail=$($c.fail)  retries=$($c.retries)  rate=${rate}/s  eta=$eta  $modelStatus$rlStatus"
                Write-Host "`r$line    " -NoNewline
            }
            Start-Sleep -Milliseconds 500
        }
    }

    # Tiered model: auto-upgrade high-complexity files to sonnet
    $srcPath = Join-Path $repoRoot ($rel -replace '/','\')
    $lineCount = @(Get-Content $srcPath -ErrorAction SilentlyContinue).Count
    $fileName = Split-Path $rel -Leaf
    $refCount = if ($xrefRaw) { ([regex]::Matches($xrefRaw, [regex]::Escape($fileName))).Count } else { 0 }
    $fileModel = Get-Pass2FileComplexity $lineCount $refCount $tieredModel $defaultModel $highModel

    if ($fileModel -eq $highModel) { $modelCounts.sonnet++ } else { $modelCounts.haiku++ }

    $j = Start-Job -FilePath $workerScript -ArgumentList `
        $rel, $repoRoot, $archDir, $stateDir,
        $claudeCfgDir, $fileModel, $maxTurns, $outputFmt,
        $promptFileP2, $maxRetries, $retryDelay,
        $defaultFence, $hashDbPath, $counterPath,
        $fatalFlag, $fatalMsg, $errorLog, $rateLimitFile,
        $archContext, $xrefContext,
        $llmBackend, $llmEndpoint, $llmModel, $llmTemp, $llmMaxTokens, $llmTimeout, $llmNumCtx,
        $llmThink, $PSScriptRoot, $degradeFallbackModel
    $running.Add($j) | Out-Null
}

while ($running.Count -gt 0) {
    $finished = @($running | Where-Object { $_.State -ne 'Running' })
    foreach ($j in $finished) {
        Receive-Job $j -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $j
        $running.Remove($j) | Out-Null
    }
    if ($running.Count -gt 0) {
        $c = Read-Counter $counterPath
        if ($c) {
            $elapsed = ([datetime]::Now - $startTime).TotalSeconds
            $rate    = if ($elapsed -gt 0 -and $c.done -gt 0) { [math]::Round($c.done / $elapsed, 2) } else { 0 }
            $remaining = $toDo - $c.done
            $eta     = if ($rate -gt 0) { [math]::Round($remaining / $rate) } else { '?' }
            $rlStatus = Get-RateLimitStatus $rateLimitFile
            if ($llmBackend -eq 'claude') {
                $hPct = if ($modelCounts.haiku + $modelCounts.sonnet -gt 0) { [int][math]::Round(100 * $modelCounts.haiku / ($modelCounts.haiku + $modelCounts.sonnet)) } else { 0 }
                $modelStatus = "haiku=${hPct}% sonnet=$((100 - $hPct))%"
            } else { $modelStatus = "model=$llmModel" }
            $line    = "PROGRESS: $($c.done)/$toDo  skip=$($c.skip)  fail=$($c.fail)  retries=$($c.retries)  rate=${rate}/s  eta=${eta}s  $modelStatus$rlStatus"
            Write-Host "`r$line    " -NoNewline
        }
        Start-Sleep -Milliseconds 500
    }
}

Write-Host ""

if (Test-Path $fatalFlag) {
    $msg = if (Test-Path $fatalMsg) { Get-Content $fatalMsg -Raw } else { 'unknown error' }
    Write-Host ""
    Write-Host "FATAL: $msg" -ForegroundColor Red
    Write-Host "Error log: $errorLog" -ForegroundColor Red
    Write-Host "Re-run the same command to resume." -ForegroundColor Yellow
    exit 1
}

# Deduplicate hash DB
if (Test-Path $hashDbPath) {
    $seen = @{}; $lines = [System.Collections.Generic.List[string]]::new()
    $raw  = Get-Content $hashDbPath; [array]::Reverse($raw)
    foreach ($line in $raw) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2 -and -not $seen.ContainsKey($parts[1])) {
            $seen[$parts[1]] = $true; $lines.Add($line)
        }
    }
    $lines | Sort-Object | Set-Content $hashDbPath -Encoding UTF8
}

if ($dataBlobN -gt 0) {
    Write-Host "Data-blob detector: skipped $dataBlobN generated data-table file(s) (stubbed, not sent to the LLM). See $dataBlobLedger" -ForegroundColor Cyan
}
Write-Host "Done. Pass-2 docs: architecture/<path>.pass2.md" -ForegroundColor Green
