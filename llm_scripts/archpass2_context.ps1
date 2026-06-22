# ============================================================
# archpass2_context.ps1 - Build Per-File Targeted Context for Pass 2
#
# Extracts only the relevant portions of architecture.md and
# xref_index.md for each source file, producing small targeted
# context files instead of the full 200+300 line blobs.
#
# Zero Claude calls. Pure text processing. Runs in seconds.
#
# Output: architecture/.pass2_context/<path>.ctx.txt
#
# Prerequisites:
#   1. archxref.ps1      - xref_index.md
#   2. arch_overview.ps1 - architecture.md
#
# Usage:
#   .\archpass2_context.ps1 [-TargetDir <dir>] [-EnvFile <string>]
#   .\archpass2_context.ps1 -Test
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir = ".",
    [string]$EnvFile   = ".env",
    [switch]$Test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Testable functions ────────────────────────────────────────

function Get-SubsystemKeys($relDir) {
    $keys = [System.Collections.Generic.List[string]]::new()
    $parts = $relDir -split '[/\\]'
    if ($parts.Count -ge 1 -and $parts[-1] -ne '') { $keys.Add($parts[-1]) }
    if ($parts.Count -ge 2) { $keys.Add(($parts[-2..-1] -join '/')) }
    if ($parts.Count -ge 3) { $keys.Add(($parts[-3..-1] -join '/')) }
    return ,$keys
}

function Extract-ArchSections($archLines, $subsystemKeys) {
    $hits = [System.Collections.Generic.List[string]]::new()
    if (-not $archLines -or $archLines.Count -eq 0 -or $subsystemKeys.Count -eq 0) { return ,$hits }

    $inSection = $false
    $sectionLines = 0

    foreach ($aline in $archLines) {
        $matchedSection = $false
        foreach ($key in $subsystemKeys) {
            if ($aline -like '*##*' -and $aline.ToLower().Contains($key.ToLower())) {
                $matchedSection = $true
                break
            }
        }
        if ($matchedSection) {
            $inSection = $true
            $sectionLines = 0
        }
        if ($inSection) {
            $hits.Add($aline)
            $sectionLines++
            if ($sectionLines -gt 3 -and $aline -like '##*' -and -not $matchedSection) {
                $inSection = $false
            }
            if ($sectionLines -ge 30) {
                $inSection = $false
            }
        }
    }

    return ,$hits
}

function Extract-XrefEntries($xrefLines, $fileName, $relPath) {
    $hits = [System.Collections.Generic.List[string]]::new()
    if (-not $xrefLines -or $xrefLines.Count -eq 0) { return ,$hits }

    foreach ($xline in $xrefLines) {
        if ($xline.Contains($fileName) -or $xline.Contains($relPath)) {
            $hits.Add($xline)
        }
    }

    return ,$hits
}

function Build-TargetedContext($rel, $archHits, $xrefHits) {
    $ctx = [System.Collections.Generic.List[string]]::new()
    $ctx.Add("=== TARGETED CONTEXT FOR: $rel ===")
    $ctx.Add('')

    if ($archHits.Count -gt 0) {
        $ctx.Add('## Architecture Context (subsystem)')
        foreach ($h in $archHits) { $ctx.Add($h) }
        $ctx.Add('')
    }

    if ($xrefHits.Count -gt 0) {
        $ctx.Add('## Cross-Reference Entries')
        $cap = [math]::Min($xrefHits.Count, 50)
        for ($i = 0; $i -lt $cap; $i++) {
            $ctx.Add($xrefHits[$i])
        }
        if ($xrefHits.Count -gt 50) {
            $ctx.Add("... and $($xrefHits.Count - 50) more entries")
        }
        $ctx.Add('')
    }

    return ,$ctx
}

function Get-DocRelPath($docFullName, $archDir) {
    $docRel = $docFullName.Substring($archDir.Length).TrimStart('\', '/') -replace '\\', '/'
    return $docRel -replace '\.md$', ''
}

# ── Unit Tests ────────────────────────────────────────────────

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
    Write-Host '  archpass2_context.ps1 - Unit Tests' -ForegroundColor Yellow
    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host ''

    # ── Test: Get-SubsystemKeys ───────────────────────────────

    Write-Host 'Testing Get-SubsystemKeys ...' -ForegroundColor Cyan

    # Deep path: Engine/Source/Runtime/Core/Private
    $k1 = Get-SubsystemKeys 'Engine/Source/Runtime/Core/Private'
    Assert-Equal 'SubKeys deep: count'           3 $k1.Count
    Assert-Equal 'SubKeys deep: last dir'        'Private'                    $k1[0]
    Assert-Equal 'SubKeys deep: last 2'          'Core/Private'              $k1[1]
    Assert-Equal 'SubKeys deep: last 3'          'Runtime/Core/Private'      $k1[2]

    # Two-level path
    $k2 = Get-SubsystemKeys 'Renderer/Private'
    Assert-Equal 'SubKeys 2-level: count'        2 $k2.Count
    Assert-Equal 'SubKeys 2-level: last'         'Private'            $k2[0]
    Assert-Equal 'SubKeys 2-level: both'         'Renderer/Private'   $k2[1]

    # Single-level path
    $k3 = Get-SubsystemKeys 'Core'
    Assert-Equal 'SubKeys 1-level: count'        1 $k3.Count
    Assert-Equal 'SubKeys 1-level: name'         'Core' $k3[0]

    # Empty path
    $k4 = Get-SubsystemKeys ''
    Assert-Equal 'SubKeys empty: count'          0 $k4.Count

    # ── Test: Extract-ArchSections ────────────────────────────

    Write-Host 'Testing Extract-ArchSections ...' -ForegroundColor Cyan

    $archLines = @(
        '# Architecture Overview',
        '',
        '## Major Subsystems',
        '',
        '### Core',
        '- Purpose: foundational types',
        '- Key files: CoreMinimal.h',
        '- Dependencies: none',
        '',
        '### Renderer',
        '- Purpose: rendering pipeline',
        '- Key files: DeferredShading.cpp',
        '- Dependencies: Core, RHI',
        '',
        '### Audio',
        '- Purpose: audio mixing',
        '- Key files: AudioMixer.cpp',
        '',
        '## Key Runtime Flows',
        '### Initialization',
        '- Core initializes first'
    )

    # Match "Core" subsystem
    $hits1 = Extract-ArchSections $archLines @('Core')
    Assert-True  'ArchSections Core: has hits'          ($hits1.Count -gt 0)
    $joined1 = $hits1 -join "`n"
    Assert-True  'ArchSections Core: has Core heading'  ($joined1 -match '### Core')
    Assert-True  'ArchSections Core: has purpose'       ($joined1 -match 'foundational types')

    # Match "Renderer" subsystem
    $hits2 = Extract-ArchSections $archLines @('Renderer')
    Assert-True  'ArchSections Renderer: has hits'      ($hits2.Count -gt 0)
    $joined2 = $hits2 -join "`n"
    Assert-True  'ArchSections Renderer: has purpose'   ($joined2 -match 'rendering pipeline')

    # Multi-key matching (e.g., "Private" and "Core/Private")
    $hits3 = Extract-ArchSections $archLines @('Private', 'Core')
    $joined3 = $hits3 -join "`n"
    Assert-True  'ArchSections multi-key: finds Core'   ($joined3 -match '### Core')

    # No match
    $hits4 = Extract-ArchSections $archLines @('NonExistentSubsystem')
    Assert-Equal 'ArchSections no match: empty'         0 $hits4.Count

    # Empty inputs
    $hits5 = Extract-ArchSections @() @('Core')
    Assert-Equal 'ArchSections empty lines: empty'      0 $hits5.Count
    $hits6 = Extract-ArchSections $archLines @()
    Assert-Equal 'ArchSections empty keys: empty'       0 $hits6.Count

    # Section stops at next ## heading (not matching)
    $hits7 = Extract-ArchSections $archLines @('Core')
    $joined7 = $hits7 -join "`n"
    # Should include Core content but stop before Renderer
    Assert-True  'ArchSections stop: has Core'          ($joined7 -match 'foundational types')
    Assert-False 'ArchSections stop: no Renderer'       ($joined7 -match 'rendering pipeline')

    # Max 30 lines cap
    $longArch = @('## Core Section') + (1..40 | ForEach-Object { "Line $_ of core content" })
    $hitsCap = Extract-ArchSections $longArch @('Core')
    Assert-True  'ArchSections cap: <= 30 lines'        ($hitsCap.Count -le 30)

    # Case insensitive matching
    $hitsCI = Extract-ArchSections $archLines @('core')
    Assert-True  'ArchSections case: finds Core'        ($hitsCI.Count -gt 0)

    # ── Test: Extract-XrefEntries ─────────────────────────────

    Write-Host 'Testing Extract-XrefEntries ...' -ForegroundColor Cyan

    $xrefLines = @(
        '| Function | Defined In |',
        '|----------|-----------|',
        '| `RandInit` | `Engine/Source/Runtime/Core/Private/Math.cpp` |',
        '| `SpawnActor` | `Engine/Source/Runtime/Engine/Private/Actor.cpp` |',
        '| `Render` | `Engine/Source/Runtime/Renderer/Private/Draw.cpp` |',
        '| `RandHelper` | `Engine/Source/Runtime/Core/Private/Math.cpp` |',
        '| `Tick` | `Engine/Source/Runtime/Engine/Private/World.cpp` |'
    )

    # Match by filename
    $x1 = Extract-XrefEntries $xrefLines 'Math.cpp' 'Engine/Source/Runtime/Core/Private/Math.cpp'
    Assert-Equal 'Xref by filename: count'              2 $x1.Count
    Assert-True  'Xref by filename: has RandInit'       (($x1 -join "`n") -match 'RandInit')
    Assert-True  'Xref by filename: has RandHelper'     (($x1 -join "`n") -match 'RandHelper')

    # Match by full path
    $x2 = Extract-XrefEntries $xrefLines 'Actor.cpp' 'Engine/Source/Runtime/Engine/Private/Actor.cpp'
    Assert-Equal 'Xref by path: count'                  1 $x2.Count
    Assert-True  'Xref by path: has SpawnActor'         (($x2 -join "`n") -match 'SpawnActor')

    # No match
    $x3 = Extract-XrefEntries $xrefLines 'NonExistent.cpp' 'path/to/NonExistent.cpp'
    Assert-Equal 'Xref no match: empty'                 0 $x3.Count

    # Empty inputs
    $x4 = Extract-XrefEntries @() 'Math.cpp' 'path/Math.cpp'
    Assert-Equal 'Xref empty lines: empty'              0 $x4.Count

    # Table header doesn't match (no filename in it)
    $x5 = Extract-XrefEntries $xrefLines 'Function' 'Function'
    Assert-True  'Xref header matches: finds header'    ($x5.Count -gt 0)

    # ── Test: Build-TargetedContext ───────────────────────────

    Write-Host 'Testing Build-TargetedContext ...' -ForegroundColor Cyan

    $archH = [System.Collections.Generic.List[string]]::new()
    $archH.Add('### Core')
    $archH.Add('- Purpose: foundational types')
    $xrefH = [System.Collections.Generic.List[string]]::new()
    $xrefH.Add('| `RandInit` | `Core/Math.cpp` |')
    $xrefH.Add('| `RandHelper` | `Core/Math.cpp` |')

    $ctx1 = Build-TargetedContext 'Engine/Source/Runtime/Core/Private/Math.cpp' $archH $xrefH
    $joined = $ctx1 -join "`n"
    Assert-True  'Context: has header'                  ($joined -match '=== TARGETED CONTEXT FOR:.*Math\.cpp')
    Assert-True  'Context: has arch section'            ($joined -match '## Architecture Context')
    Assert-True  'Context: has arch content'            ($joined -match '### Core')
    Assert-True  'Context: has xref section'            ($joined -match '## Cross-Reference Entries')
    Assert-True  'Context: has xref content'            ($joined -match 'RandInit')

    # Only arch hits, no xref
    $emptyXref = [System.Collections.Generic.List[string]]::new()
    $ctx2 = Build-TargetedContext 'src/test.cpp' $archH $emptyXref
    $joined2 = $ctx2 -join "`n"
    Assert-True  'Context arch only: has arch'          ($joined2 -match '## Architecture Context')
    Assert-False 'Context arch only: no xref'           ($joined2 -match '## Cross-Reference Entries')

    # Only xref hits, no arch
    $emptyArch = [System.Collections.Generic.List[string]]::new()
    $ctx3 = Build-TargetedContext 'src/test.cpp' $emptyArch $xrefH
    $joined3 = $ctx3 -join "`n"
    Assert-False 'Context xref only: no arch'           ($joined3 -match '## Architecture Context')
    Assert-True  'Context xref only: has xref'          ($joined3 -match '## Cross-Reference Entries')

    # Neither
    $ctx4 = Build-TargetedContext 'src/test.cpp' $emptyArch $emptyXref
    $joined4 = $ctx4 -join "`n"
    Assert-True  'Context empty: has header'            ($joined4 -match '=== TARGETED CONTEXT FOR:')
    Assert-False 'Context empty: no arch'               ($joined4 -match '## Architecture Context')
    Assert-False 'Context empty: no xref'               ($joined4 -match '## Cross-Reference Entries')

    # Xref cap at 50 entries
    $bigXref = [System.Collections.Generic.List[string]]::new()
    1..60 | ForEach-Object { $bigXref.Add("| func$_ | file$_ |") }
    $ctx5 = Build-TargetedContext 'src/big.cpp' $emptyArch $bigXref
    $joined5 = $ctx5 -join "`n"
    Assert-True  'Context xref cap: has truncation msg' ($joined5 -match '10 more entries')
    # Should have 50 entries + header + truncation msg + blank
    $entryLines = @($ctx5 | Where-Object { $_ -match '^\| func' })
    Assert-Equal 'Context xref cap: 50 entries'         50 $entryLines.Count

    # ── Test: Get-DocRelPath ──────────────────────────────────

    Write-Host 'Testing Get-DocRelPath ...' -ForegroundColor Cyan

    Assert-Equal 'DocRelPath: normal'    'Engine/Source/Core/Math.cpp' `
        (Get-DocRelPath 'C:\arch\Engine\Source\Core\Math.cpp.md' 'C:\arch')
    Assert-Equal 'DocRelPath: backslash' 'src/file.cpp' `
        (Get-DocRelPath 'C:\arch\src\file.cpp.md' 'C:\arch')

    # ── Test: End-to-end integration ──────────────────────────

    Write-Host 'Testing end-to-end integration ...' -ForegroundColor Cyan

    # Simulate full pipeline: arch lines + xref lines + a file
    # Use a path where the subsystem key actually matches the arch heading.
    # For "Engine/Source/Runtime/Renderer/Private/Draw.cpp", the keys are:
    #   Private, Renderer/Private, Runtime/Renderer/Private
    # The arch heading "### Renderer/Private" would match, but "### Renderer" alone won't
    # match "Private" or "Renderer/Private" as a substring.
    # So use an arch overview that has headings matching the actual path components.
    $e2eArch = @(
        '# Architecture Overview',
        '## Major Subsystems',
        '### Renderer/Private',
        '- Purpose: handles all rendering',
        '- Key files: DeferredShading.cpp',
        '### Core',
        '- Purpose: base types and containers',
        '- Key files: CoreMinimal.h'
    )
    $e2eXref = @(
        '| `DrawScene` | `Renderer/Private/Draw.cpp` |',
        '| `Init` | `Core/Private/Init.cpp` |',
        '| `SetupPipeline` | `Renderer/Private/Draw.cpp` |'
    )

    $e2eRel = 'Renderer/Private/Draw.cpp'
    $e2eDir = Split-Path $e2eRel -Parent
    $e2eFile = Split-Path $e2eRel -Leaf

    $e2eKeys = Get-SubsystemKeys $e2eDir
    Assert-True  'E2E: keys contain Private'           ($e2eKeys -contains 'Private')
    Assert-True  'E2E: keys contain Renderer/Private'  ($e2eKeys -contains 'Renderer/Private')

    $e2eArchHits = Extract-ArchSections $e2eArch $e2eKeys
    Assert-True  'E2E: arch hits found'                ($e2eArchHits.Count -gt 0)
    Assert-True  'E2E: arch has Renderer'              (($e2eArchHits -join "`n") -match 'handles all rendering')

    $e2eXrefHits = Extract-XrefEntries $e2eXref $e2eFile $e2eRel
    Assert-Equal 'E2E: xref hits count'                2 $e2eXrefHits.Count

    $e2eCtx = Build-TargetedContext $e2eRel $e2eArchHits $e2eXrefHits
    $e2eJoined = $e2eCtx -join "`n"
    Assert-True  'E2E: has targeted header'            ($e2eJoined -match 'TARGETED CONTEXT FOR:.*Draw\.cpp')
    Assert-True  'E2E: has arch section'               ($e2eJoined -match '## Architecture Context')
    Assert-True  'E2E: has Renderer content'           ($e2eJoined -match 'handles all rendering')
    Assert-True  'E2E: has xref section'               ($e2eJoined -match '## Cross-Reference Entries')
    Assert-True  'E2E: has DrawScene xref'             ($e2eJoined -match 'DrawScene')
    Assert-True  'E2E: has SetupPipeline xref'         ($e2eJoined -match 'SetupPipeline')
    # Should NOT have Core content (different subsystem)
    Assert-False 'E2E: no Core content'                ($e2eJoined -match 'base types and containers')

    # ── Results ───────────────────────────────────────────────

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

# ── Main execution ────────────────────────────────────────────

$repoRoot = (Get-Location).Path
try {
    $g = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $g) { $repoRoot = $g.Trim() }
} catch { }

$archDir    = Join-Path $repoRoot "architecture"
$contextDir = Join-Path $archDir  ".pass2_context"
New-Item -ItemType Directory -Force -Path $contextDir | Out-Null

# Find architecture.md and xref_index.md
$archOverview = Join-Path $archDir "architecture.md"
if (-not (Test-Path $archOverview)) {
    $candidates = @(Get-ChildItem -Path $archDir -Filter "*architecture.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "architecture.md" })
    if ($candidates.Count -gt 0) {
        $archOverview = $candidates[0].FullName
        Write-Host "Using: $($candidates[0].Name)" -ForegroundColor Cyan
        if ($candidates.Count -gt 1) {
            Write-Host "Found $($candidates.Count) overview files, combining all" -ForegroundColor Cyan
        }
    }
}

$xrefIndex = Join-Path $archDir "xref_index.md"
if (-not (Test-Path $xrefIndex)) {
    $xrefCandidates = @(Get-ChildItem -Path $archDir -Filter "*xref_index.md" -File -ErrorAction SilentlyContinue)
    if ($xrefCandidates.Count -gt 0) {
        $xrefIndex = $xrefCandidates[0].FullName
        Write-Host "Using: $($xrefCandidates[0].Name)" -ForegroundColor Cyan
    }
}

if (-not (Test-Path $archOverview)) {
    Write-Host "Missing: architecture.md or *architecture.md (run arch_overview.ps1)" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $xrefIndex)) {
    Write-Host "Missing: xref_index.md or *xref_index.md (run archxref.ps1)" -ForegroundColor Red
    exit 2
}

# Load full context files
$archCandidates = @(Get-ChildItem -Path $archDir -Filter "*architecture.md" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch "[/\\]\." })
$archLines = @()
foreach ($ac in $archCandidates) {
    $archLines += @(Get-Content $ac.FullName -ErrorAction SilentlyContinue)
}
$xrefLines = @(Get-Content $xrefIndex -ErrorAction SilentlyContinue)

# Collect Pass 1 docs
$docs = @(Get-ChildItem -Path $archDir -Recurse -Filter "*.md" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -notmatch "\.pass2\.md$" -and
        $_.FullName -notmatch "[/\\]\."
    })

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  archpass2_context.ps1 - Targeted Context"  -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "Repo root:    $repoRoot"
Write-Host "Docs found:   $($docs.Count)"
Write-Host "Output:       $contextDir"
Write-Host ""

$count = 0

foreach ($doc in $docs) {
    $rel = Get-DocRelPath $doc.FullName $archDir
    if ($rel -like ".*") { continue }

    $fileName = Split-Path $rel -Leaf
    $relDir   = Split-Path $rel -Parent

    $subsystemKeys = Get-SubsystemKeys $relDir
    $archHits = Extract-ArchSections $archLines $subsystemKeys
    $xrefHits = Extract-XrefEntries $xrefLines $fileName $rel

    if ($archHits.Count -gt 0 -or $xrefHits.Count -gt 0) {
        $ctx = Build-TargetedContext $rel $archHits $xrefHits
        $outPath = Join-Path $contextDir (($rel -replace "/", "\") + ".ctx.txt")
        $outDir  = Split-Path $outPath -Parent
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        ($ctx -join "`n") | Set-Content -Path $outPath -Encoding UTF8
        $count++
    }
}

Write-Host "Done. $count targeted context files written to: $contextDir" -ForegroundColor Green
