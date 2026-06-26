# ============================================================
# archgen_dirs.ps1 - Directory-Level Architecture Context
#
# Generates a short architectural overview for each source directory,
# used by archgen_worker.ps1 to inject directory-level context into
# Pass 1 analysis. This gives every file architectural context in
# its first (and often only) analysis pass.
#
# Zero cost per file - one Claude call per directory.
# Output: architecture/.dir_context/<dir_path>.dir.md
#
# Usage:
#   .\archgen_dirs.ps1 [-TargetDir <dir>] [-Preset <n>] [-Claude1] [-Clean]
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir = ".",
    [string]$Preset    = "",
    [switch]$Claude1,
    [switch]$Clean,
    [string]$EnvFile   = ".env",
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
            if ($line -match '^\s*#' -or $line -eq '') { return }
            if ($line -match '^([^=]+)=(.*)$') {
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                $val = $val -replace [regex]::Escape('$HOME'), $env:USERPROFILE
                $val = $val -replace '^~', $env:USERPROFILE
                $vars[$Matches[1].Trim()] = $val
            }
        }
    }
    return $vars
}

function Cfg($key, $default = '') {
    if ($script:cfg.ContainsKey($key) -and $script:cfg[$key] -ne '') { return $script:cfg[$key] }
    return $default
}

function Group-FilesByDir($allFiles, $repoRoot) {
    $dirGroups = @{}
    foreach ($f in $allFiles) {
        $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\','/') -replace '\\','/'
        $dir = Split-Path $rel -Parent
        if (-not $dirGroups.ContainsKey($dir)) { $dirGroups[$dir] = [System.Collections.Generic.List[string]]::new() }
        $dirGroups[$dir].Add($rel)
    }
    return $dirGroups
}

function Build-FileSummary($rel, $repoRoot, $serenaDir) {
    $src = Join-Path $repoRoot ($rel -replace '/','\')
    $lineCount = @(Get-Content $src -ErrorAction SilentlyContinue).Count
    $leaf = Split-Path $rel -Leaf

    # Get primary symbol from LSP context if available
    $primarySymbol = ""
    $ctxPath = Join-Path $serenaDir (($rel -replace '/','\') + '.serena_context.txt')
    if (Test-Path $ctxPath) {
        $firstSymbol = Get-Content $ctxPath -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^- \w+.*\((Class|Struct|Enum|Function)' } |
            Select-Object -First 1
        if ($firstSymbol -match '^- (\w+)') { $primarySymbol = $Matches[1] }
    }

    $entry = "- $leaf ($lineCount lines)"
    if ($primarySymbol) { $entry += " - primary: $primarySymbol" }
    return $entry
}

function Build-DirPrompt($dir, $fileSummary, $fileCount) {
    return @"
Summarize the architectural role of this source directory in 3-5 sentences.
What subsystem does it belong to? What are its key responsibilities? What do files here typically do?

DIRECTORY: $dir
FILES ($fileCount):
$($fileSummary -join "`n")

Keep output under 300 tokens. Be specific about this directory's role.
"@
}

# ---- Test runner ----
if ($Test) {
    $script:testsPassed = 0
    $script:testsFailed = 0

    function Assert-Equal($expected, $actual, $msg) {
        if ($expected -eq $actual) {
            $script:testsPassed++
            Write-Host "  [PASS] $msg" -ForegroundColor Green
        } else {
            $script:testsFailed++
            Write-Host "  [FAIL] $msg" -ForegroundColor Red
            Write-Host "    Expected: $expected" -ForegroundColor Yellow
            Write-Host "    Actual:   $actual" -ForegroundColor Yellow
        }
    }

    function Assert-True($value, $msg) {
        Assert-Equal $true ([bool]$value) $msg
    }

    function Assert-False($value, $msg) {
        Assert-Equal $false ([bool]$value) $msg
    }

    $tmpDir = $null
    try {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "archgen_dirs_test_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

        # ========================================
        Write-Host "--- Read-EnvFile tests ---" -ForegroundColor Cyan
        # ========================================

        # Basic key=value
        $envPath = Join-Path $tmpDir 'test.env'
        @"
FOO=bar
NUM=42
"@ | Set-Content -Path $envPath -Encoding UTF8
        $result = Read-EnvFile $envPath
        Assert-Equal 'bar' $result['FOO'] 'Read-EnvFile: basic key=value'
        Assert-Equal '42' $result['NUM'] 'Read-EnvFile: numeric value'

        # Comments and blank lines
        @"
# This is a comment
FOO=bar

  # Indented comment
BAZ=qux
"@ | Set-Content -Path $envPath -Encoding UTF8
        $result = Read-EnvFile $envPath
        Assert-Equal 'bar' $result['FOO'] 'Read-EnvFile: value after comment'
        Assert-Equal 'qux' $result['BAZ'] 'Read-EnvFile: value after blank line'
        Assert-Equal 2 $result.Count 'Read-EnvFile: comments not included'

        # Quoted values
        @"
Q1="hello world"
Q2='single quoted'
"@ | Set-Content -Path $envPath -Encoding UTF8
        $result = Read-EnvFile $envPath
        Assert-Equal 'hello world' $result['Q1'] 'Read-EnvFile: double-quoted value'
        Assert-Equal 'single quoted' $result['Q2'] 'Read-EnvFile: single-quoted value'

        # $HOME expansion
        @"
DIR=`$HOME/stuff
TILDE=~/other
"@ | Set-Content -Path $envPath -Encoding UTF8
        $result = Read-EnvFile $envPath
        Assert-Equal "$($env:USERPROFILE)/stuff" $result['DIR'] 'Read-EnvFile: $HOME expansion'
        Assert-Equal "$($env:USERPROFILE)/other" $result['TILDE'] 'Read-EnvFile: tilde expansion'

        # Missing file
        $result = Read-EnvFile (Join-Path $tmpDir 'nonexistent.env')
        Assert-Equal 0 $result.Count 'Read-EnvFile: missing file returns empty hash'

        # ========================================
        Write-Host "--- Cfg tests ---" -ForegroundColor Cyan
        # ========================================

        $script:cfg = @{ 'KEY1' = 'val1'; 'EMPTY' = '' }
        Assert-Equal 'val1' (Cfg 'KEY1' 'default') 'Cfg: existing key returns value'
        Assert-Equal 'default' (Cfg 'MISSING' 'default') 'Cfg: missing key returns default'
        Assert-Equal 'fallback' (Cfg 'EMPTY' 'fallback') 'Cfg: empty value returns default'
        Assert-Equal '' (Cfg 'MISSING') 'Cfg: missing key with no default returns empty string'

        # ========================================
        Write-Host "--- Group-FilesByDir tests ---" -ForegroundColor Cyan
        # ========================================

        $fakeRoot = Join-Path $tmpDir 'repo'
        $dirA = Join-Path $fakeRoot 'src/a'
        $dirB = Join-Path $fakeRoot 'src/b'
        New-Item -ItemType Directory -Force -Path $dirA | Out-Null
        New-Item -ItemType Directory -Force -Path $dirB | Out-Null
        "x" | Set-Content (Join-Path $dirA 'f1.cpp')
        "y" | Set-Content (Join-Path $dirA 'f2.cpp')
        "z" | Set-Content (Join-Path $dirA 'f3.cpp')
        "w" | Set-Content (Join-Path $dirB 'only.cpp')

        $fakeFiles = Get-ChildItem -Path $fakeRoot -Recurse -File
        $groups = Group-FilesByDir $fakeFiles ($fakeRoot -replace '\\','/' -replace '/$','')

        # Normalize fakeRoot for comparison (the function uses $repoRoot.Length)
        # We need the path separators to match what the function produces
        $normRoot = $fakeRoot -replace '\\','/'
        $groups2 = @{}
        foreach ($f in $fakeFiles) {
            $rel = $f.FullName.Substring($normRoot.Length).TrimStart('\','/') -replace '\\','/'
            $dir = Split-Path $rel -Parent
            if (-not $groups2.ContainsKey($dir)) { $groups2[$dir] = [System.Collections.Generic.List[string]]::new() }
            $groups2[$dir].Add($rel)
        }

        Assert-Equal 2 $groups.Count 'Group-FilesByDir: two directories'
        # Check that src/a has 3 files
        $keyA = $groups.Keys | Where-Object { $_ -like '*src*a*' } | Select-Object -First 1
        $keyB = $groups.Keys | Where-Object { $_ -like '*src*b*' } | Select-Object -First 1
        Assert-True ($null -ne $keyA) 'Group-FilesByDir: src/a directory found'
        if ($keyA) {
            Assert-Equal 3 $groups[$keyA].Count 'Group-FilesByDir: src/a has 3 files'
        }
        if ($keyB) {
            Assert-Equal 1 $groups[$keyB].Count 'Group-FilesByDir: src/b has 1 file'
        }

        # Filter dirs with 2+ files
        $filteredDirs = @($groups.Keys | Where-Object { $groups[$_].Count -ge 2 })
        Assert-Equal 1 $filteredDirs.Count 'Group-FilesByDir: filter 2+ files excludes src/b'

        # ========================================
        Write-Host "--- Build-FileSummary tests ---" -ForegroundColor Cyan
        # ========================================

        $testRepo = Join-Path $tmpDir 'summaryrepo'
        $testSrcDir = Join-Path $testRepo 'src'
        $testSerena = Join-Path $tmpDir 'serena'
        New-Item -ItemType Directory -Force -Path $testSrcDir | Out-Null
        New-Item -ItemType Directory -Force -Path $testSerena | Out-Null

        # Create a 5-line source file
        @"
line1
line2
line3
line4
line5
"@ | Set-Content (Join-Path $testSrcDir 'MyClass.cpp')

        $entry = Build-FileSummary 'src/MyClass.cpp' $testRepo $testSerena
        Assert-True ($entry -match 'MyClass\.cpp') 'Build-FileSummary: contains filename'
        Assert-True ($entry -match '\d+ lines') 'Build-FileSummary: contains line count'
        Assert-False ($entry -match 'primary:') 'Build-FileSummary: no primary when no LSP'

        # With LSP context
        $ctxDir = Join-Path $testSerena 'src'
        New-Item -ItemType Directory -Force -Path $ctxDir | Out-Null
        @"
- FMyClass (Class) [1-50]
- DoThing (Function) [10-20]
"@ | Set-Content (Join-Path $ctxDir 'MyClass.cpp.serena_context.txt')

        $entry2 = Build-FileSummary 'src/MyClass.cpp' $testRepo $testSerena
        Assert-True ($entry2 -match 'primary: FMyClass') 'Build-FileSummary: extracts primary symbol from LSP'

        # ========================================
        Write-Host "--- Build-DirPrompt tests ---" -ForegroundColor Cyan
        # ========================================

        $summaryList = @('- Foo.cpp (100 lines)', '- Bar.h (50 lines) - primary: UBar')
        $prompt = Build-DirPrompt 'Engine/Source/Runtime/Core' $summaryList 2

        Assert-True ($prompt -match 'Engine/Source/Runtime/Core') 'Build-DirPrompt: contains directory path'
        Assert-True ($prompt -match 'Foo\.cpp') 'Build-DirPrompt: contains file entry'
        Assert-True ($prompt -match 'Bar\.h') 'Build-DirPrompt: contains second file entry'
        Assert-True ($prompt -match 'FILES \(2\)') 'Build-DirPrompt: contains file count'
        Assert-True ($prompt -match '300 tokens') 'Build-DirPrompt: contains token limit'
        Assert-True ($prompt -match 'architectural role') 'Build-DirPrompt: contains role instruction'

        # ========================================
        Write-Host '' -ForegroundColor Cyan
        Write-Host "--- Results ---" -ForegroundColor Cyan
        Write-Host "  Passed: $script:testsPassed" -ForegroundColor Green
        Write-Host "  Failed: $script:testsFailed" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })
    } finally {
        if ($tmpDir -and (Test-Path $tmpDir)) {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        }
    }
    exit $script:testsFailed
}

# ---- Main execution ----
$script:cfg = Read-EnvFile $EnvFile

$repoRoot = (Get-Location).Path
try {
    $g = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $g) { $repoRoot = $g.Trim() }
} catch {}

$archDir    = Join-Path $repoRoot 'architecture'
$dirCtxDir  = Join-Path $archDir '.dir_context'
$serenaDir  = Join-Path $archDir '.serena_context'

$model      = Cfg 'CLAUDE_MODEL' 'sonnet'
$tieredModel = Cfg 'TIERED_MODEL' '1'
$highModel  = Cfg 'HIGH_COMPLEXITY_MODEL' 'sonnet'
if ($tieredModel -eq '1') { $model = $highModel }
$maxTurns   = Cfg 'CLAUDE_MAX_TURNS' '1'
$outputFmt  = Cfg 'CLAUDE_OUTPUT_FORMAT' 'text'
$includeRx  = Cfg 'INCLUDE_EXT_REGEX' '\.(cpp|h|hpp|cc|cxx|inl|cs)$'
$excludeRx  = Cfg 'EXCLUDE_DIRS_REGEX' '[/\\](\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|ThirdParty|GeneratedFiles|AutomationTool)([/\\]|$)'

# -- Local LLM backend (LLMConfig) -----------------------------
. (Join-Path $PSScriptRoot 'llm_core.ps1')
$llmBackend   = Get-LLMBackend -Cfg $script:cfg
$llmEndpoint  = ''
$llmModel     = ''
$llmTemp      = [double](Cfg 'LLM_TEMPERATURE' '0.1')
$llmMaxTokens = [int](Cfg 'LLM_DIR_MAX_TOKENS' (Cfg 'LLM_MAX_TOKENS' '4000'))
$llmTimeout   = [int](Cfg 'LLM_TIMEOUT' '900')
$llmNumCtx    = [int](Cfg 'LLM_NUM_CTX' '0')
$llmThink     = ((Cfg 'LLM_THINK' 'false').Trim().ToLower() -eq 'true')
if ($llmBackend -ne 'claude') {
    $llmEndpoint = Get-LLMEndpoint -Cfg $script:cfg -Backend $llmBackend
    $llmModel    = Get-LLMModel -Cfg $script:cfg
    Write-Host "LLM backend: $llmBackend ($llmEndpoint, model=$llmModel)" -ForegroundColor Green
    Write-Host "NOTE: directory context is NOT used by the local Pass-1 prompt (it's claude-only). Running archgen_dirs on a local backend is optional / can be skipped." -ForegroundColor DarkYellow
}

$cfgDirKey    = if ($Claude1) { 'CLAUDE1_CONFIG_DIR' } else { 'CLAUDE2_CONFIG_DIR' }
$claudeCfgDir = Cfg $cfgDirKey ''
if ($llmBackend -eq 'claude' -and -not $claudeCfgDir) { Write-Err "Missing $cfgDirKey in $EnvFile"; exit 2 }

if ($Clean) {
    Remove-Item -Recurse -Force $dirCtxDir -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $dirCtxDir | Out-Null

# Collect source directories
$scanRoot = if ($TargetDir -eq '.') { $repoRoot } else { Join-Path $repoRoot $TargetDir }
$allFiles = Get-ChildItem -Path $scanRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = $_.FullName.Substring($repoRoot.Length).TrimStart('\','/') -replace '\\','/'
        if ($rel -match '^architecture/') { return $false }
        if ($rel -match $excludeRx) { return $false }
        if ($rel -match $includeRx) { return $true }
        return $false
    }

# Group by directory
$dirGroups = Group-FilesByDir $allFiles $repoRoot

# Filter to directories with 2+ files
$dirs = $dirGroups.Keys | Where-Object { $dirGroups[$_].Count -ge 2 } | Sort-Object

Write-Host '============================================' -ForegroundColor Yellow
Write-Host '  archgen_dirs.ps1 - Directory Context'      -ForegroundColor Yellow
Write-Host '============================================' -ForegroundColor Yellow
Write-Host "Repo root:   $repoRoot"
Write-Host "Directories: $($dirs.Count)"
if ($llmBackend -eq 'claude') { Write-Host "Model:       $model" } else { Write-Host "Model:       $llmModel" }
Write-Host ''

# Skip directories that already have context
$queue = [System.Collections.Generic.List[string]]::new()
foreach ($dir in $dirs) {
    $outFile = Join-Path $dirCtxDir (($dir -replace '/','\') + '.dir.md')
    if (-not $Clean -and (Test-Path $outFile)) { continue }
    $queue.Add($dir)
}

if ($queue.Count -eq 0) {
    Write-Host "Nothing to do. All directory contexts up to date." -ForegroundColor Green
    exit 0
}

Write-Host "Processing $($queue.Count) directories..." -ForegroundColor Green

$done = 0
foreach ($dir in $queue) {
    $files = $dirGroups[$dir]

    # Build a summary of files in this directory
    $fileSummary = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $files) {
        $fileSummary.Add((Build-FileSummary $rel $repoRoot $serenaDir))
    }

    $payload = Build-DirPrompt $dir $fileSummary $files.Count

    $outFile = Join-Path $dirCtxDir (($dir -replace '/','\') + '.dir.md')
    $outDir  = Split-Path $outFile -Parent
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    try {
        if ($llmBackend -eq 'claude') {
            $env:CLAUDE_CONFIG_DIR = $claudeCfgDir
            $resp = $payload | & claude -p --model $model --max-turns $maxTurns --output-format $outputFmt 2>&1
            $exitCode = $LASTEXITCODE
            $respText = if ($resp -is [array]) { $resp -join "`n" } else { [string]$resp }
        } else {
            $respText = Invoke-LocalLLM -SystemPrompt '' -UserPrompt $payload `
                -Backend $llmBackend -Endpoint $llmEndpoint -Model $llmModel `
                -Temperature $llmTemp -MaxTokens $llmMaxTokens -Timeout $llmTimeout -NumCtx $llmNumCtx -Think $llmThink
            $exitCode = 0
        }
        if ($exitCode -eq 0 -and $respText.Length -gt 0) {
            $respText | Set-Content -Path $outFile -Encoding UTF8
            $done++
        } else {
            Write-Host ""
            Write-Host "  [FAIL] $dir (exit=$exitCode): $($respText.Substring(0, [math]::Min(200, $respText.Length)))" -ForegroundColor Red
        }
    } catch {
        Write-Host ""
        Write-Host "  [ERROR] $dir : $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`r  PROGRESS: $done/$($queue.Count)  dir=$dir    " -NoNewline
}

Write-Host ''
Write-Host "Done. $done directory contexts in: $dirCtxDir" -ForegroundColor Green
