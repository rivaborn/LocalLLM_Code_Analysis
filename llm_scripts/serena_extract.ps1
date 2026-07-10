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
    [string]$LangProfile = "",
    [int]   $Jobs       = 2,
    [int]   $Workers    = 0,
    [switch]$Force,
    [switch]$SkipRefs,
    [switch]$Compress,
    [double]$MinFreeRAM = 6.0,
    [double]$RAMPerWorker = 0,
    [string]$EnvFile    = ".env",
    [string]$ServerPath = "",
    [string]$ClangdPath = "",
    [switch]$Test
)
# -RAMPerWorker 0 / -ServerPath '' mean "use the language profile's value".
# -ClangdPath is a deprecated alias for -ServerPath.

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

# Presets + language profiles live in the shared module (single source of
# truth, also consumed by archgen.ps1 and friends). This script uses the
# extraction-side fields: LspInclude / LspExclude.
. (Join-Path $PSScriptRoot 'preset_core.ps1')

function Build-PyArgs(
    $extractScript, $repoRoot, $targetDir, $profileName, $serverPath,
    $jobs, $workers, $minFreeRAM, $ramPerWorker,
    $includeRx, $excludeRx, $force, $skipRefs, $compress
) {
    $pyArgs = @(
        $extractScript,
        "--repo-root", $repoRoot,
        "--target-dir", $targetDir,
        "--profile", $profileName,
        "--jobs", $jobs,
        "--workers", $workers,
        "--min-free-ram", $minFreeRAM
    )

    # Only override the profile's defaults when a value was actually given —
    # always passing e.g. --server-path clangd would break non-cpp profiles.
    if ($serverPath -ne '')   { $pyArgs += @("--server-path", $serverPath) }
    if ($ramPerWorker -gt 0)  { $pyArgs += @("--ram-per-worker", $ramPerWorker) }
    if ($includeRx -ne '')    { $pyArgs += @("--include-rx", $includeRx) }
    if ($excludeRx -ne '')    { $pyArgs += @("--exclude-rx", $excludeRx) }

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

        # unreal preset (extraction fields: LspInclude / LspExclude)
        $p = Get-Preset 'unreal'
        Assert-True ('Engine/Source/Runtime/Core/Private/Foo.cpp' -match $p.LspInclude) 'Get-Preset unreal: .cpp matches lsp include'
        Assert-True ('Engine/Source/Runtime/Core/Public/Bar.h' -match $p.LspInclude) 'Get-Preset unreal: .h matches lsp include'
        Assert-False ('Engine/Source/Programs/Foo.cs' -match $p.LspInclude) 'Get-Preset unreal: .cs does NOT match lsp include'
        Assert-True ('Engine/Source/Programs/Foo.cs' -match $p.Include) 'Get-Preset unreal: .cs DOES match doc-gen include'
        Assert-True ('Engine/Source/ThirdParty/Lib/foo.cpp' -match $p.LspExclude) 'Get-Preset unreal: ThirdParty matches exclude'
        Assert-True ('Engine/Intermediate/Build/foo.cpp' -match $p.LspExclude) 'Get-Preset unreal: Intermediate matches exclude'
        Assert-True ('repo/.git/config' -match $p.LspExclude) 'Get-Preset unreal: .git matches exclude'
        Assert-True ('Engine/Source/Runtime/Core/Foo.inl' -match $p.LspInclude) 'Get-Preset unreal: .inl matches lsp include'
        Assert-Equal $p.Profile 'cpp' 'Get-Preset unreal: profile is cpp'

        # ue5 alias
        $p5 = Get-Preset 'ue5'
        Assert-Equal $p5.LspInclude $p.LspInclude 'Get-Preset: ue5 alias equals unreal lsp include'
        Assert-Equal $p5.LspExclude $p.LspExclude 'Get-Preset: ue5 alias equals unreal lsp exclude'

        # quake preset
        $pq = Get-Preset 'quake'
        Assert-True ('src/main.c' -match $pq.LspInclude) 'Get-Preset quake: .c matches lsp include'
        Assert-True ('src/header.h' -match $pq.LspInclude) 'Get-Preset quake: .h matches lsp include'
        Assert-False ('script.py' -match $pq.LspInclude) 'Get-Preset quake: .py does NOT match lsp include'

        # empty preset (default)
        $pe = Get-Preset ''
        Assert-True ('foo.cpp' -match $pe.LspInclude) 'Get-Preset empty: .cpp matches lsp include'
        Assert-True ('foo.c' -match $pe.LspInclude) 'Get-Preset empty: .c matches lsp include'
        Assert-True ('repo/.git/HEAD' -match $pe.LspExclude) 'Get-Preset empty: .git matches exclude'
        Assert-False ('foo.py' -match $pe.LspInclude) 'Get-Preset empty: .py does NOT match lsp include (clangd cannot parse it)'

        # koreader / lua presets route to the lua profile
        $pk = Get-Preset 'koreader'
        Assert-True ('frontend/ui/uimanager.lua' -match $pk.LspInclude) 'Get-Preset koreader: .lua matches lsp include'
        Assert-True ('base/thirdparty/foo.lua' -match $pk.LspExclude) 'Get-Preset koreader: base/ matches exclude'
        Assert-True ('spec/unit/foo_spec.lua' -match $pk.LspExclude) 'Get-Preset koreader: spec/ matches exclude'
        Assert-Equal $pk.Profile 'lua' 'Get-Preset koreader: profile is lua'

        # language profiles load and resolve
        $profCpp = Get-LangProfile 'cpp'
        Assert-Equal $profCpp.server.languageId 'cpp' 'Get-LangProfile cpp: languageId'
        Assert-Equal $profCpp.server.cleanup 'pch' 'Get-LangProfile cpp: pch cleanup'
        $profLua = Get-LangProfile 'lua'
        Assert-Equal $profLua.server.languageId 'lua' 'Get-LangProfile lua: languageId'
        Assert-Equal $profLua.extraction.depSectionTitle 'Direct Require Dependencies' 'Get-LangProfile lua: dep section title'
        Assert-Equal (Resolve-ProfileName $pk '') 'lua' 'Resolve-ProfileName: preset profile wins'
        Assert-Equal (Resolve-ProfileName $pe 'go') 'go' 'Resolve-ProfileName: env fallback when preset has no profile'
        Assert-Equal (Resolve-ProfileName $pe '') 'cpp' 'Resolve-ProfileName: cpp default'

        # exclude patterns match common dirs
        foreach ($dir in @('ThirdParty', 'Intermediate', '.git', 'architecture', 'Binaries')) {
            Assert-True ("Engine/$dir/foo.cpp" -match $p.LspExclude) "Get-Preset unreal: exclude matches $dir"
        }

        # --------------------------------------------------
        # Build-PyArgs tests
        # --------------------------------------------------
        Write-Host "--- Build-PyArgs ---" -ForegroundColor Yellow

        # base args always present
        $args1 = Build-PyArgs 'extract.py' 'C:/repo' '.' 'cpp' 'clangd' 2 0 6.0 5.0 '\.cpp$' '\.git' $false $false $false
        Assert-True ($args1 -contains 'extract.py') 'Build-PyArgs: contains script path'
        Assert-True ($args1 -contains '--repo-root') 'Build-PyArgs: contains --repo-root'
        Assert-True ($args1 -contains 'C:/repo') 'Build-PyArgs: contains repo root value'
        Assert-True ($args1 -contains '--profile') 'Build-PyArgs: contains --profile'
        Assert-True ($args1 -contains 'cpp') 'Build-PyArgs: contains profile value'
        Assert-True ($args1 -contains '--jobs') 'Build-PyArgs: contains --jobs'
        Assert-True ($args1 -contains '--server-path') 'Build-PyArgs: --server-path when given'
        Assert-True ($args1 -contains '--ram-per-worker') 'Build-PyArgs: --ram-per-worker when > 0'
        Assert-True ($args1 -contains '--include-rx') 'Build-PyArgs: contains --include-rx'
        Assert-False ($args1 -contains '--force') 'Build-PyArgs: no --force when false'
        Assert-False ($args1 -contains '--skip-refs') 'Build-PyArgs: no --skip-refs when false'
        Assert-False ($args1 -contains '--compress') 'Build-PyArgs: no --compress when false'

        # profile defaults win when overrides are unset
        $args1b = Build-PyArgs 'extract.py' 'C:/repo' '.' 'lua' '' 2 0 6.0 0 '' '' $false $false $false
        Assert-False ($args1b -contains '--server-path') 'Build-PyArgs: no --server-path when empty (profile default)'
        Assert-False ($args1b -contains '--ram-per-worker') 'Build-PyArgs: no --ram-per-worker when 0 (profile default)'
        Assert-False ($args1b -contains '--include-rx') 'Build-PyArgs: no --include-rx when empty (profile default)'
        Assert-False ($args1b -contains '--exclude-rx') 'Build-PyArgs: no --exclude-rx when empty (profile default)'
        Assert-True ($args1b -contains 'lua') 'Build-PyArgs: lua profile forwarded'

        # conditional flags
        $args2 = Build-PyArgs 'extract.py' 'C:/repo' '.' 'cpp' 'clangd' 2 0 6.0 5.0 '\.cpp$' '\.git' $true $true $true
        Assert-True ($args2 -contains '--force') 'Build-PyArgs: --force when true'
        Assert-True ($args2 -contains '--skip-refs') 'Build-PyArgs: --skip-refs when true'
        Assert-True ($args2 -contains '--compress') 'Build-PyArgs: --compress when true'

        # individual flags
        $args3 = Build-PyArgs 'extract.py' 'C:/repo' '.' 'cpp' 'clangd' 2 0 6.0 5.0 '\.cpp$' '\.git' $true $false $false
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

# Profile precedence: -LangProfile > preset's Profile > .env PROFILE > cpp.
$profileName = if ($LangProfile -ne '') { $LangProfile } else { Resolve-ProfileName $presetData (Cfg 'PROFILE' '') }
$langProfile = Get-LangProfile $profileName

# Regex precedence: .env override > named preset > the profile's own
# defaults (passed as '' so Build-PyArgs omits the flag and the Python
# side falls back to the profile).
$presetInclude = if ($presetName -ne '') { $presetData.LspInclude } else { '' }
$presetExclude = if ($presetName -ne '') { $presetData.LspExclude } else { '' }
$includeRx  = Cfg 'INCLUDE_EXT_REGEX'  $presetInclude
$excludeRx  = Cfg 'EXCLUDE_DIRS_REGEX' $presetExclude

$serverPath = if ($ServerPath -ne '') { $ServerPath } else { $ClangdPath }

$repoRoot = (Get-Location).Path
try {
    $g = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $g) { $repoRoot = $g.Trim() }
} catch {}

# -- Verify prerequisites (per language profile) -------------------

$prereqs = @()
if ($null -ne $langProfile.server.prereqs) { $prereqs = @($langProfile.server.prereqs) }
foreach ($pr in $prereqs) {
    $target = Join-Path $repoRoot $pr.path
    if (-not (Test-Path $target)) {
        if ("$($pr.severity)" -eq 'error') {
            Write-Err "Missing: $($pr.path) at $repoRoot"
            Write-Err "  $($pr.hint)"
            exit 2
        }
        Write-Host "Warning: $($pr.path) not found at $repoRoot" -ForegroundColor Yellow
        Write-Host "  $($pr.hint)" -ForegroundColor Yellow
    }
}

$extractScript = Join-Path $PSScriptRoot 'serena_extract.py'
if (-not (Test-Path $extractScript)) {
    Write-Err "Missing: serena_extract.py in $PSScriptRoot"
    exit 2
}

# -- Banner ----------------------------------------------------

$serverDisplay = if ($serverPath -ne '') { $serverPath } else { @($langProfile.server.command)[0] }
Write-Host '============================================' -ForegroundColor Yellow
Write-Host '  serena_extract.ps1 - LSP Context Extract' -ForegroundColor Yellow
Write-Host '============================================' -ForegroundColor Yellow
Write-Host "Repo root:   $repoRoot"
Write-Host "Target:      $TargetDir"
Write-Host "Profile:     $profileName"
Write-Host "Server:      $serverDisplay (-j=$Jobs)"
Write-Host "Include:     $(if ($includeRx -ne '') { $includeRx } else { $langProfile.extraction.includeRegex + ' (profile default)' })"
Write-Host "Exclude:     $(if ($excludeRx -ne '') { $excludeRx } else { $langProfile.extraction.excludeRegex + ' (profile default)' })"
if ($presetName) { Write-Host "Preset:      $presetName" }
Write-Host ''

# -- Run Python extraction script --------------------------------

$pyArgs = Build-PyArgs $extractScript $repoRoot $TargetDir $profileName $serverPath `
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
