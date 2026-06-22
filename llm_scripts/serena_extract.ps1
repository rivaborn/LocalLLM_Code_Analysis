# ============================================================
# serena_extract.ps1 - LSP Context Extraction via clangd
#
# Extracts symbol overviews and cross-file references for each
# source file using clangd's LSP protocol directly.
# Zero Claude API calls. Zero tokens. Just local clangd queries.
#
# Output: architecture/.serena_context/<path>.serena_context.txt
#
# Prerequisites:
#   - compile_commands.json at repo root
#   - clangd installed (via VS2022 Clang components or LLVM)
#   - clangd background index built (.cache/clangd/index/)
#   - Python 3.12+ (via uv)
#
# Usage:
#   .\serena_extract.ps1 [-TargetDir <dir>] [-Preset <n>] [-Jobs <n>] [-Force]
#
# Examples:
#   .\serena_extract.ps1 -Preset unreal
#   .\serena_extract.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal
#   .\serena_extract.ps1 -Preset unreal -Force
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir  = ".",
    [string]$Preset     = "",
    [int]   $Jobs       = 2,
    [int]   $Workers    = 0,
    [switch]$Force,
    [switch]$SkipRefs,
    [switch]$Compress,
    [double]$MinFreeRAM = 6.0,
    [double]$RAMPerWorker = 5.0,
    [string]$EnvFile    = ".env",
    [string]$ClangdPath = "clangd",
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
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                $vars[$key] = $val
            }
        }
    }
    return $vars
}

function Cfg($key, $default = '') {
    if ($cfg.ContainsKey($key) -and $cfg[$key] -ne '') { return $cfg[$key] }
    return $default
}

function Get-Preset($name) {
    switch ($name.ToLower()) {
        { $_ -in @('quake','quake2','quake3','doom','idtech') } {
            return @{
                Include = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
                Exclude = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|x64|Win32|\.vs|\.vscode|baseq2|baseq3|base)([/\\]|$)'
            }
        }
        { $_ -in @('unreal','ue4','ue5') } {
            return @{
                Include = '\.(cpp|h|hpp|cc|cxx|inl)$'
                Exclude = '[/\\](\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|ThirdParty|GeneratedFiles|AutomationTool)([/\\]|$)'
            }
        }
        '' {
            return @{
                Include = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
                Exclude = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|\.vs)([/\\]|$)'
            }
        }
        default {
            Write-Err "Unknown preset: $name"
            exit 2
        }
    }
}

function Build-PyArgs(
    $extractScript, $repoRoot, $targetDir, $clangdPath,
    $jobs, $workers, $minFreeRAM, $ramPerWorker,
    $includeRx, $excludeRx, $force, $skipRefs, $compress
) {
    $pyArgs = @(
        $extractScript,
        "--repo-root", $repoRoot,
        "--target-dir", $targetDir,
        "--clangd-path", $clangdPath,
        "--jobs", $jobs,
        "--workers", $workers,
        "--min-free-ram", $minFreeRAM,
        "--ram-per-worker", $ramPerWorker,
        "--include-rx", $includeRx,
        "--exclude-rx", $excludeRx
    )

    if ($force)    { $pyArgs += "--force" }
    if ($skipRefs) { $pyArgs += "--skip-refs" }
    if ($compress) { $pyArgs += "--compress" }

    return $pyArgs
}

# ================================================================
# Test mode
# ================================================================

if ($Test) {
    $script:testsPassed = 0
    $script:testsFailed = 0

    function Assert-Equal($actual, $expected, $msg) {
        if ("$actual" -eq "$expected") {
            $script:testsPassed++
        } else {
            $script:testsFailed++
            Write-Err "FAIL: $msg"
            Write-Err "  Expected: $expected"
            Write-Err "  Actual:   $actual"
        }
    }
    function Assert-True($val, $msg) {
        if ($val) {
            $script:testsPassed++
        } else {
            $script:testsFailed++
            Write-Err "FAIL: $msg (expected true, got false)"
        }
    }
    function Assert-False($val, $msg) {
        if (-not $val) {
            $script:testsPassed++
        } else {
            $script:testsFailed++
            Write-Err "FAIL: $msg (expected false, got true)"
        }
    }

    $tmpDir = $null
    try {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "serena_test_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

        # --------------------------------------------------
        # Read-EnvFile tests
        # --------------------------------------------------
        Write-Host "--- Read-EnvFile ---" -ForegroundColor Yellow

        # basic parsing
        $envPath = Join-Path $tmpDir "test.env"
        Set-Content -Path $envPath -Value @(
            "KEY1=value1",
            "KEY2=value2",
            "  # comment line",
            "",
            'KEY3="quoted value"',
            "KEY4='single quoted'"
        )
        $vars = Read-EnvFile $envPath
        Assert-Equal $vars['KEY1'] 'value1' 'Read-EnvFile: basic key'
        Assert-Equal $vars['KEY2'] 'value2' 'Read-EnvFile: second key'
        Assert-Equal $vars['KEY3'] 'quoted value' 'Read-EnvFile: double-quoted value'
        Assert-Equal $vars['KEY4'] 'single quoted' 'Read-EnvFile: single-quoted value'
        Assert-Equal $vars.Count 4 'Read-EnvFile: correct count (comments/blanks skipped)'

        # missing file returns empty hashtable
        $vars2 = Read-EnvFile (Join-Path $tmpDir "nonexistent.env")
        Assert-Equal $vars2.Count 0 'Read-EnvFile: missing file returns empty hashtable'

        # --------------------------------------------------
        # Cfg tests
        # --------------------------------------------------
        Write-Host "--- Cfg ---" -ForegroundColor Yellow

        $cfg = @{ 'PRESENT' = 'hello'; 'EMPTY' = '' }
        Assert-Equal (Cfg 'PRESENT' 'default') 'hello' 'Cfg: existing key returns value'
        Assert-Equal (Cfg 'MISSING' 'default') 'default' 'Cfg: missing key returns default'
        Assert-Equal (Cfg 'EMPTY' 'default') 'default' 'Cfg: empty key returns default'
        Assert-Equal (Cfg 'MISSING') '' 'Cfg: missing key with no default returns empty string'

        # --------------------------------------------------
        # Get-Preset tests
        # --------------------------------------------------
        Write-Host "--- Get-Preset ---" -ForegroundColor Yellow

        # unreal preset
        $p = Get-Preset 'unreal'
        Assert-True ('Engine/Source/Runtime/Core/Private/Foo.cpp' -match $p.Include) 'Get-Preset unreal: .cpp matches include'
        Assert-True ('Engine/Source/Runtime/Core/Public/Bar.h' -match $p.Include) 'Get-Preset unreal: .h matches include'
        Assert-False ('Engine/Source/Programs/Foo.cs' -match $p.Include) 'Get-Preset unreal: .cs does NOT match include'
        Assert-True ('Engine/Source/ThirdParty/Lib/foo.cpp' -match $p.Exclude) 'Get-Preset unreal: ThirdParty matches exclude'
        Assert-True ('Engine/Intermediate/Build/foo.cpp' -match $p.Exclude) 'Get-Preset unreal: Intermediate matches exclude'
        Assert-True ('repo/.git/config' -match $p.Exclude) 'Get-Preset unreal: .git matches exclude'
        Assert-True ('Engine/Source/Runtime/Core/Foo.inl' -match $p.Include) 'Get-Preset unreal: .inl matches include'

        # ue5 alias
        $p5 = Get-Preset 'ue5'
        Assert-Equal $p5.Include $p.Include 'Get-Preset: ue5 alias equals unreal include'
        Assert-Equal $p5.Exclude $p.Exclude 'Get-Preset: ue5 alias equals unreal exclude'

        # quake preset
        $pq = Get-Preset 'quake'
        Assert-True ('src/main.c' -match $pq.Include) 'Get-Preset quake: .c matches include'
        Assert-True ('src/header.h' -match $pq.Include) 'Get-Preset quake: .h matches include'
        Assert-False ('script.py' -match $pq.Include) 'Get-Preset quake: .py does NOT match include'

        # empty preset (default)
        $pe = Get-Preset ''
        Assert-True ('foo.cpp' -match $pe.Include) 'Get-Preset empty: .cpp matches include'
        Assert-True ('foo.c' -match $pe.Include) 'Get-Preset empty: .c matches include'
        Assert-True ('repo/.git/HEAD' -match $pe.Exclude) 'Get-Preset empty: .git matches exclude'

        # exclude patterns match common dirs
        foreach ($dir in @('ThirdParty', 'Intermediate', '.git', 'architecture', 'Binaries')) {
            Assert-True ("Engine/$dir/foo.cpp" -match $p.Exclude) "Get-Preset unreal: exclude matches $dir"
        }

        # --------------------------------------------------
        # Build-PyArgs tests
        # --------------------------------------------------
        Write-Host "--- Build-PyArgs ---" -ForegroundColor Yellow

        # base args always present
        $args1 = Build-PyArgs 'extract.py' 'C:/repo' '.' 'clangd' 2 0 6.0 5.0 '\.cpp$' '\.git' $false $false $false
        Assert-True ($args1 -contains 'extract.py') 'Build-PyArgs: contains script path'
        Assert-True ($args1 -contains '--repo-root') 'Build-PyArgs: contains --repo-root'
        Assert-True ($args1 -contains 'C:/repo') 'Build-PyArgs: contains repo root value'
        Assert-True ($args1 -contains '--jobs') 'Build-PyArgs: contains --jobs'
        Assert-True ($args1 -contains '--include-rx') 'Build-PyArgs: contains --include-rx'
        Assert-False ($args1 -contains '--force') 'Build-PyArgs: no --force when false'
        Assert-False ($args1 -contains '--skip-refs') 'Build-PyArgs: no --skip-refs when false'
        Assert-False ($args1 -contains '--compress') 'Build-PyArgs: no --compress when false'

        # conditional flags
        $args2 = Build-PyArgs 'extract.py' 'C:/repo' '.' 'clangd' 2 0 6.0 5.0 '\.cpp$' '\.git' $true $true $true
        Assert-True ($args2 -contains '--force') 'Build-PyArgs: --force when true'
        Assert-True ($args2 -contains '--skip-refs') 'Build-PyArgs: --skip-refs when true'
        Assert-True ($args2 -contains '--compress') 'Build-PyArgs: --compress when true'

        # individual flags
        $args3 = Build-PyArgs 'extract.py' 'C:/repo' '.' 'clangd' 2 0 6.0 5.0 '\.cpp$' '\.git' $true $false $false
        Assert-True ($args3 -contains '--force') 'Build-PyArgs: only --force'
        Assert-False ($args3 -contains '--skip-refs') 'Build-PyArgs: no --skip-refs'
        Assert-False ($args3 -contains '--compress') 'Build-PyArgs: no --compress'

        # --------------------------------------------------
        # Prerequisite condition tests
        # --------------------------------------------------
        Write-Host "--- Prerequisite checks ---" -ForegroundColor Yellow

        # compile_commands.json missing
        $fakePath = Join-Path (Join-Path $tmpDir 'nonexistent') 'compile_commands.json'
        Assert-False (Test-Path $fakePath) 'Prereq: missing compile_commands.json detected'

        # compile_commands.json present
        $dbPath = Join-Path $tmpDir 'compile_commands.json'
        Set-Content -Path $dbPath -Value '[]'
        Assert-True (Test-Path $dbPath) 'Prereq: existing compile_commands.json detected'

        # index directory missing
        $fakeIdx = Join-Path (Join-Path (Join-Path $tmpDir '.cache') 'clangd') 'index'
        Assert-False (Test-Path $fakeIdx) 'Prereq: missing index dir detected'

        # index directory present
        New-Item -ItemType Directory -Path $fakeIdx -Force | Out-Null
        Assert-True (Test-Path $fakeIdx) 'Prereq: existing index dir detected'

        # extract script missing
        $fakeScript = Join-Path $tmpDir 'serena_extract.py'
        Assert-False (Test-Path $fakeScript) 'Prereq: missing extract script detected'

        # extract script present
        Set-Content -Path $fakeScript -Value '# stub'
        Assert-True (Test-Path $fakeScript) 'Prereq: existing extract script detected'

    } finally {
        if ($tmpDir -and (Test-Path $tmpDir)) {
            Remove-Item -Recurse -Force $tmpDir
        }
    }

    # -- Summary --
    Write-Host ''
    $total = $script:testsPassed + $script:testsFailed
    if ($script:testsFailed -eq 0) {
        Write-Host "All $total tests passed." -ForegroundColor Green
    } else {
        Write-Err "$($script:testsFailed) of $total tests FAILED."
    }
    exit $script:testsFailed
}

# -- Load config -----------------------------------------------

$cfg = Read-EnvFile $EnvFile
$presetName = if ($Preset -ne '') { $Preset } else { Cfg 'PRESET' '' }
$presetData = Get-Preset $presetName
$includeRx  = Cfg 'INCLUDE_EXT_REGEX'  $presetData.Include
$excludeRx  = Cfg 'EXCLUDE_DIRS_REGEX' $presetData.Exclude

$repoRoot = (Get-Location).Path
try {
    $g = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $g) { $repoRoot = $g.Trim() }
} catch {}

# -- Verify prerequisites ----------------------------------------

$compileDb = Join-Path $repoRoot 'compile_commands.json'
if (-not (Test-Path $compileDb)) {
    Write-Err "Missing: compile_commands.json at $repoRoot"
    Write-Err "Run: .\Engine\Build\BatchFiles\RunUBT.bat UnrealEditor Win64 Development -Mode=GenerateClangDatabase -engine -progress"
    exit 2
}

$indexDir = Join-Path $repoRoot '.cache\clangd\index'
if (-not (Test-Path $indexDir)) {
    Write-Err "No clangd index found at $indexDir"
    Write-Err "Start Serena/clangd and wait for background indexing to complete."
    exit 2
}

$extractScript = Join-Path $PSScriptRoot 'serena_extract.py'
if (-not (Test-Path $extractScript)) {
    Write-Err "Missing: serena_extract.py in $PSScriptRoot"
    exit 2
}

# -- Banner ----------------------------------------------------

Write-Host '============================================' -ForegroundColor Yellow
Write-Host '  serena_extract.ps1 - LSP Context Extract' -ForegroundColor Yellow
Write-Host '============================================' -ForegroundColor Yellow
Write-Host "Repo root:   $repoRoot"
Write-Host "Target:      $TargetDir"
Write-Host "clangd:      $ClangdPath (-j=$Jobs)"
Write-Host "Include:     $includeRx"
Write-Host "Exclude:     $excludeRx"
if ($presetName) { Write-Host "Preset:      $presetName" }
Write-Host ''

# -- Run Python extraction script --------------------------------

$pyArgs = Build-PyArgs $extractScript $repoRoot $TargetDir $ClangdPath `
    $Jobs $Workers $MinFreeRAM $RAMPerWorker `
    $includeRx $excludeRx $Force $SkipRefs $Compress

Write-Info "Running: uv run --python 3.12 $($pyArgs -join ' ')"
Write-Host ''

& uv run --python 3.12 @pyArgs

if ($LASTEXITCODE -ne 0) {
    Write-Err "serena_extract.py exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host "Done. Context files in: architecture/.serena_context/" -ForegroundColor Green
