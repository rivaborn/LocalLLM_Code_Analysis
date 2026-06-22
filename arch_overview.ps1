# ============================================================
# arch_overview.ps1 - Subsystem Architecture Overview Generator
#
# Modes:
#   Single-pass (default for small codebases):
#     Sends all diagram_data to Claude in one call.
#
#   Chunked (auto or -Chunked):
#     Two-tier approach for large codebases:
#       Tier 1: Per-subsystem overview for each directory.
#       Tier 2: Synthesizes a final overview from those.
#     Auto-triggered if diagram_data exceeds ChunkThreshold lines.
#
# Usage:
#   .\arch_overview.ps1 [-TargetDir <dir>] [-Chunked] [-Single] [-Claude1]
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir = "all",
    [switch]$Chunked,
    [switch]$Single,
    [switch]$Clean,
    [switch]$Claude1,
    [switch]$Full,          # Force full regeneration (no incremental)
    [string]$EnvFile   = ".env",
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

function Test-RateLimit($text) {
    if ($text -match '(?m)^#\s+\S') { return $false }
    if ($text -match '(?m)^\s*429\b')           { return $true }
    if ($text -match '"status"\s*:\s*429')       { return $true }
    if ($text -match '(?im)^error:.*\b(rate.?limit|usage.?limit|quota|overloaded)\b') { return $true }
    if ($text -match '(?im)^claude:\s*(rate.?limit|usage.?limit)')                    { return $true }
    if ($text -match '(?im)^\s*too many requests\s*$')                                { return $true }
    if ($text -match "(?im)^\s*you.ve hit your (usage |message |daily )?limit")       { return $true }
    return $false
}

function Test-TooLong($text) {
    if ($text -match '(?i)prompt is too long')               { return $true }
    if ($text -match '(?i)context.{0,20}(length|limit|window)') { return $true }
    if ($text -match '(?i)maximum context')                  { return $true }
    if ($text -match '(?i)too many tokens')                  { return $true }
    return $false
}

# ── Testable helper: extract diagram data from doc lines ─────

function Extract-DiagramSections($lines) {
    $sb = [System.Text.StringBuilder]::new()
    if (-not $lines) { return '' }
    $keep = $false
    foreach ($line in $lines) {
        if ($line -match '^# ') { $sb.AppendLine($line) | Out-Null; continue }
        if ($line -match '^## (File Purpose|Core Responsibilities|External Dependencies)') {
            $keep = $true; $sb.AppendLine($line) | Out-Null; continue
        }
        if ($line -match '^## ' -and $line -notmatch '^## (File Purpose|Core Responsibilities|External Dependencies)') {
            $keep = $false; continue
        }
        if ($keep) { $sb.AppendLine($line) | Out-Null }
    }
    return $sb.ToString()
}

# ── Testable helper: detect overview mode ─────────────────────

function Get-OverviewMode($chunkedFlag, $singleFlag, $diagramLines, $chunkThreshold) {
    if ($chunkedFlag) { return 'chunked' }
    if ($singleFlag)  { return 'single' }
    if ($diagramLines -gt $chunkThreshold) { return 'chunked' }
    return 'single'
}

# ── Testable helper: doc file filter ──────────────────────────

function Test-OverviewDocIncluded($name, $fullName) {
    if ($fullName -match '[/\\]\.(archgen|overview|pass2)_state[/\\]') { return $false }
    if ($name -match '^(architecture|diagram_data|xref_index|callgraph)') { return $false }
    if ($name -match '\.pass2\.md$') { return $false }
    return $true
}

# ── File helpers ──────────────────────────────────────────────

function Get-PerFileDocs($root) {
    return @(Get-ChildItem -Path $root -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { Test-OverviewDocIncluded $_.Name $_.FullName } | Sort-Object FullName)
}

function Build-DiagramData($root, $outPath) {
    $docs = @(Get-PerFileDocs $root)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($doc in $docs) {
        $lines = Get-Content $doc.FullName -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        $extracted = Extract-DiagramSections $lines
        if ($extracted) { $sb.Append($extracted) | Out-Null }
        $sb.AppendLine("") | Out-Null
    }
    $sb.ToString() | Set-Content -Path $outPath -Encoding UTF8
    return $docs.Count
}

# Recursively expand subsystem directories until each chunk is under threshold.
function Get-Subsystems($docRoot, $relPath, $threshold, $depth = 0) {
    $absPath = if ($relPath) { Join-Path $docRoot $relPath } else { $docRoot }
    $result  = [System.Collections.Generic.List[string]]::new()

    $tmpDiag = Join-Path $stateDir "tmp_diag_depth${depth}_$([System.IO.Path]::GetRandomFileName()).md"
    Build-DiagramData $absPath $tmpDiag | Out-Null
    $lineCount = @(Get-Content $tmpDiag -EA SilentlyContinue).Count
    Remove-Item $tmpDiag -EA SilentlyContinue

    if ($lineCount -le $threshold -or $depth -ge 4) {
        $label = if ($relPath) { $relPath } else { '.' }
        $result.Add($label)
        return $result
    }

    $children = @(Get-ChildItem -Path $absPath -Directory -EA SilentlyContinue |
        Where-Object { $_.Name -notmatch '^\.' } | Sort-Object Name)

    if ($children.Count -eq 0) {
        $label = if ($relPath) { $relPath } else { '.' }
        $result.Add($label)
        return $result
    }

    if ($children.Count -eq 1) {
        $childRel = if ($relPath) { "$relPath/$($children[0].Name)" } else { $children[0].Name }
        $expanded = Get-Subsystems $docRoot $childRel $threshold $depth
        foreach ($item in $expanded) { $result.Add($item) }
        return $result
    }

    foreach ($child in $children) {
        $childRel = if ($relPath) { "$relPath/$($child.Name)" } else { $child.Name }
        $expanded = Get-Subsystems $docRoot $childRel $threshold ($depth + 1)
        foreach ($item in $expanded) { $result.Add($item) }
    }
    return $result
}

# ── Prompt constructors ───────────────────────────────────────

function Get-SubsystemPrompt($desc, $content) {
    return @"
You are generating a subsystem-level overview for part of a $desc.
Write deterministic markdown.
Rules: Do NOT speculate. Keep section order exactly as specified. Use only provided input.
Infer the programming language(s) from file paths and contents.

Output schema (exact order):

# Subsystem Overview

## Purpose
1-3 sentences describing what this subsystem does.

## Key Files
| File | Role |

## Core Responsibilities
- 3-8 bullets

## Key Interfaces & Data Flow
- What this subsystem exposes to others
- What it consumes from other subsystems

## Runtime Role
- How this subsystem participates in init / frame / shutdown (if inferable)

## Notable Implementation Details
- (only if inferable)

BEGIN INPUT DOC INDEX
$content
END INPUT DOC INDEX
"@
}

function Get-SynthesisPrompt($desc, $overviews) {
    return @"
You are generating a top-level architecture overview for a $desc.
You are given per-subsystem overviews. Synthesize them into a unified architecture document.
Write deterministic markdown.
Rules: Do NOT speculate. Keep section order exactly as specified. Cross-reference subsystems.

Output schema (exact order):

# Architecture Overview

## Repository Shape
- (high-level repo layout inferred from subsystem paths)

## Major Subsystems
For each subsystem:
### <Subsystem Name>
- Purpose:
- Key directories / files:
- Key responsibilities:
- Key dependencies (other subsystems):

## Key Runtime Flows
### Initialization
### Per-frame / Main Loop
### Shutdown

## Data & Control Boundaries
- (important ownership boundaries, global state, resource lifetimes)

## Notable Risks / Hotspots
- (only if inferable)

BEGIN SUBSYSTEM OVERVIEWS
$overviews
END SUBSYSTEM OVERVIEWS
"@
}

function Get-SinglePassPrompt($desc, $content) {
    return @"
You are generating a subsystem-level architecture overview for a $desc.
Write deterministic markdown.
Rules: Do NOT speculate. Keep section order exactly as specified.
Infer the programming language(s) and engine type from file paths and contents.

Output schema (exact order):

# Architecture Overview

## Repository Shape
- (high-level repo layout inferred from file paths)

## Major Subsystems
For each subsystem:
### <Subsystem Name>
- Purpose:
- Key directories / files:
- Key responsibilities:
- Key dependencies (other subsystems):

## Key Runtime Flows
### Initialization
### Per-frame / Main Loop
### Shutdown

## Data & Control Boundaries
- (important ownership boundaries, global state, resource lifetimes)

## Notable Risks / Hotspots
- (only if inferable)

BEGIN INPUT DOC INDEX
$content
END INPUT DOC INDEX
"@
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
    Write-Host '  arch_overview.ps1 - Unit Tests' -ForegroundColor Yellow
    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host ''

    $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "arch_overview_tests_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $testDir | Out-Null

    try {

    # ── Test: Cfg ─────────────────────────────────────────────

    Write-Host 'Testing Cfg ...' -ForegroundColor Cyan

    $testCfg = @{ CLAUDE_MODEL = 'haiku'; JOBS = '8'; EMPTY_KEY = '' }
    Assert-Equal 'Cfg: existing key'              'haiku'   (Cfg $testCfg 'CLAUDE_MODEL' 'sonnet')
    Assert-Equal 'Cfg: missing key'               'sonnet'  (Cfg $testCfg 'MISSING' 'sonnet')
    Assert-Equal 'Cfg: empty value uses default'  'default' (Cfg $testCfg 'EMPTY_KEY' 'default')
    Assert-Equal 'Cfg: numeric value'             '8'       (Cfg $testCfg 'JOBS' '2')
    Assert-Equal 'Cfg: no default'                ''        (Cfg $testCfg 'MISSING')

    # ── Test: Test-RateLimit ──────────────────────────────────

    Write-Host 'Testing Test-RateLimit ...' -ForegroundColor Cyan

    # Positive cases
    Assert-True  'RateLimit: 429 code'                (Test-RateLimit "429`nToo many requests")
    Assert-True  'RateLimit: status 429 json'         (Test-RateLimit '"status": 429')
    Assert-True  'RateLimit: error rate limit'        (Test-RateLimit 'error: rate limit exceeded')
    Assert-True  'RateLimit: error usage limit'       (Test-RateLimit 'error: usage limit reached')
    Assert-True  'RateLimit: error quota'             (Test-RateLimit 'error: quota exceeded')
    Assert-True  'RateLimit: error overloaded'        (Test-RateLimit 'error: server overloaded')
    Assert-True  'RateLimit: claude usage limit'      (Test-RateLimit 'claude: usage limit')
    Assert-True  'RateLimit: too many requests'       (Test-RateLimit 'too many requests')
    Assert-True  'RateLimit: hit your limit'          (Test-RateLimit "You've hit your limit")
    Assert-True  'RateLimit: hit usage limit'         (Test-RateLimit "You've hit your usage limit")
    Assert-True  'RateLimit: hit message limit'       (Test-RateLimit "You've hit your message limit")
    Assert-True  'RateLimit: hit daily limit'         (Test-RateLimit "You've hit your daily limit")

    # Negative cases — markdown response starts with # heading
    Assert-False 'RateLimit: markdown heading'        (Test-RateLimit "# Architecture Overview`n`n## Repository Shape")
    Assert-False 'RateLimit: normal response'         (Test-RateLimit 'This is a normal analysis result.')
    Assert-False 'RateLimit: empty string'            (Test-RateLimit '')

    # ── Test: Test-TooLong ────────────────────────────────────

    Write-Host 'Testing Test-TooLong ...' -ForegroundColor Cyan

    Assert-True  'TooLong: prompt is too long'        (Test-TooLong 'Error: prompt is too long')
    Assert-True  'TooLong: context length'            (Test-TooLong 'Error: context length exceeded')
    Assert-True  'TooLong: context limit'             (Test-TooLong 'Exceeded the context limit')
    Assert-True  'TooLong: context window'            (Test-TooLong 'Exceeds the context window')
    Assert-True  'TooLong: maximum context'           (Test-TooLong 'Error: maximum context reached')
    Assert-True  'TooLong: too many tokens'           (Test-TooLong 'too many tokens in prompt')
    Assert-False 'TooLong: normal text'               (Test-TooLong 'This is a normal response.')
    Assert-False 'TooLong: empty'                     (Test-TooLong '')

    # ── Test: Test-OverviewDocIncluded ────────────────────────

    Write-Host 'Testing Test-OverviewDocIncluded ...' -ForegroundColor Cyan

    # Included
    Assert-True  'DocIncl: normal doc'                (Test-OverviewDocIncluded 'Actor.cpp.md' 'C:\arch\Actor.cpp.md')
    Assert-True  'DocIncl: deep path'                 (Test-OverviewDocIncluded 'Math.cpp.md' 'C:\arch\Core\Private\Math.cpp.md')

    # Excluded: meta files
    Assert-False 'DocIncl: architecture.md'           (Test-OverviewDocIncluded 'architecture.md' 'C:\arch\architecture.md')
    Assert-False 'DocIncl: architecture Core.md'      (Test-OverviewDocIncluded 'architecture Core.md' 'C:\arch\architecture Core.md')
    Assert-False 'DocIncl: xref_index.md'             (Test-OverviewDocIncluded 'xref_index.md' 'C:\arch\xref_index.md')
    Assert-False 'DocIncl: diagram_data.md'           (Test-OverviewDocIncluded 'diagram_data.md' 'C:\arch\diagram_data.md')
    Assert-False 'DocIncl: callgraph.md'              (Test-OverviewDocIncluded 'callgraph.md' 'C:\arch\callgraph.md')

    # Excluded: pass2 docs
    Assert-False 'DocIncl: pass2 doc'                 (Test-OverviewDocIncluded 'Actor.pass2.md' 'C:\arch\Actor.pass2.md')

    # Excluded: state directories
    Assert-False 'DocIncl: archgen_state'             (Test-OverviewDocIncluded 'data.md' 'C:\arch\.archgen_state\data.md')
    Assert-False 'DocIncl: overview_state'            (Test-OverviewDocIncluded 'data.md' 'C:\arch\.overview_state\data.md')
    Assert-False 'DocIncl: pass2_state'               (Test-OverviewDocIncluded 'data.md' 'C:\arch\.pass2_state\data.md')

    # ── Test: Extract-DiagramSections ─────────────────────────

    Write-Host 'Testing Extract-DiagramSections ...' -ForegroundColor Cyan

    $docFull = @(
        '# Engine/Source/Runtime/Core/Private/Math.cpp',
        '',
        '## File Purpose',
        'Math utility functions.',
        '',
        '## Core Responsibilities',
        '- Provides random number generation',
        '- Vector math operations',
        '',
        '## Key Types / Data Structures',
        '| Name | Kind | Purpose |',
        '| FMath | Class | Math utilities |',
        '',
        '## Key Functions / Methods',
        '### RandInit',
        '- Signature: void RandInit(int32)',
        '',
        '## Global / File-Static State',
        '| Name | Type | Scope | Purpose |',
        '| GRandState | int32 | Static | seed |',
        '',
        '## External Dependencies',
        '- `CoreMinimal.h` - core types',
        '- `UnrealMath.h` - math base',
        '',
        '## Control Flow',
        '- Init -> SetSeed -> ready'
    )

    $extracted = Extract-DiagramSections $docFull
    # Should include: # heading, File Purpose, Core Responsibilities, External Dependencies
    Assert-True  'Extract: has file path heading'     ($extracted -match 'Engine/Source/Runtime/Core/Private/Math\.cpp')
    Assert-True  'Extract: has File Purpose'          ($extracted -match '## File Purpose')
    Assert-True  'Extract: has purpose text'          ($extracted -match 'Math utility functions')
    Assert-True  'Extract: has Core Responsibilities' ($extracted -match '## Core Responsibilities')
    Assert-True  'Extract: has responsibility bullet' ($extracted -match 'random number generation')
    Assert-True  'Extract: has External Dependencies' ($extracted -match '## External Dependencies')
    Assert-True  'Extract: has dep content'           ($extracted -match 'CoreMinimal\.h')

    # Should NOT include: Key Types, Key Functions, Global State, Control Flow
    Assert-False 'Extract: no Key Types'              ($extracted -match '## Key Types')
    Assert-False 'Extract: no Key Functions'          ($extracted -match '## Key Functions')
    Assert-False 'Extract: no Global State'           ($extracted -match '## Global')
    Assert-False 'Extract: no Control Flow'           ($extracted -match '## Control Flow')
    Assert-False 'Extract: no FMath table row'        ($extracted -match 'FMath')
    Assert-False 'Extract: no RandInit'               ($extracted -match 'RandInit')
    Assert-False 'Extract: no GRandState'             ($extracted -match 'GRandState')

    # Empty/null input
    $extractEmpty = Extract-DiagramSections @()
    Assert-Equal 'Extract empty: returns empty'       '' $extractEmpty

    $extractNull = Extract-DiagramSections $null
    Assert-Equal 'Extract null: returns empty'        '' $extractNull

    # Minimal doc (only purpose)
    $docMinimal = @(
        '# src/tiny.cpp',
        '## File Purpose',
        'A tiny file.'
    )
    $extractMin = Extract-DiagramSections $docMinimal
    Assert-True  'Extract minimal: has heading'       ($extractMin -match 'src/tiny\.cpp')
    Assert-True  'Extract minimal: has purpose'       ($extractMin -match 'A tiny file')

    # Stub doc (no relevant sections)
    $docStub = @(
        '# src/stub.generated.h',
        '## File Purpose',
        'Auto-generated or trivial file.',
        '## Core Responsibilities',
        '- Boilerplate / generated code'
    )
    $extractStub = Extract-DiagramSections $docStub
    Assert-True  'Extract stub: has purpose'          ($extractStub -match 'Auto-generated')
    Assert-True  'Extract stub: has responsibilities' ($extractStub -match 'Boilerplate')

    # ── Test: Get-OverviewMode ────────────────────────────────

    Write-Host 'Testing Get-OverviewMode ...' -ForegroundColor Cyan

    Assert-Equal 'Mode: chunked flag overrides'   'chunked' (Get-OverviewMode $true $false 100 1500)
    Assert-Equal 'Mode: single flag overrides'    'single'  (Get-OverviewMode $false $true 9999 1500)
    Assert-Equal 'Mode: both flags, chunked wins' 'chunked' (Get-OverviewMode $true $true 100 1500)
    Assert-Equal 'Mode: auto small = single'      'single'  (Get-OverviewMode $false $false 500 1500)
    Assert-Equal 'Mode: auto at threshold'        'single'  (Get-OverviewMode $false $false 1500 1500)
    Assert-Equal 'Mode: auto above threshold'     'chunked' (Get-OverviewMode $false $false 1501 1500)
    Assert-Equal 'Mode: auto way above'           'chunked' (Get-OverviewMode $false $false 5000 1500)
    Assert-Equal 'Mode: auto 0 lines'             'single'  (Get-OverviewMode $false $false 0 1500)

    # ── Test: Get-SubsystemPrompt ─────────────────────────────

    Write-Host 'Testing Get-SubsystemPrompt ...' -ForegroundColor Cyan

    $subPrompt = Get-SubsystemPrompt 'Unreal Engine - Core subsystem' 'doc content here'
    Assert-True  'SubPrompt: has codebase desc'       ($subPrompt -match 'Unreal Engine - Core subsystem')
    Assert-True  'SubPrompt: has rules'               ($subPrompt -match 'Do NOT speculate')
    Assert-True  'SubPrompt: has schema sections'     ($subPrompt -match '## Purpose')
    Assert-True  'SubPrompt: has Key Files'           ($subPrompt -match '## Key Files')
    Assert-True  'SubPrompt: has Core Responsibilities' ($subPrompt -match '## Core Responsibilities')
    Assert-True  'SubPrompt: has Key Interfaces'      ($subPrompt -match '## Key Interfaces')
    Assert-True  'SubPrompt: has Runtime Role'        ($subPrompt -match '## Runtime Role')
    Assert-True  'SubPrompt: has BEGIN marker'        ($subPrompt -match 'BEGIN INPUT DOC INDEX')
    Assert-True  'SubPrompt: has END marker'          ($subPrompt -match 'END INPUT DOC INDEX')
    Assert-True  'SubPrompt: content injected'        ($subPrompt -match 'doc content here')

    # ── Test: Get-SynthesisPrompt ─────────────────────────────

    Write-Host 'Testing Get-SynthesisPrompt ...' -ForegroundColor Cyan

    $synPrompt = Get-SynthesisPrompt 'Unreal Engine' 'overviews here'
    Assert-True  'SynPrompt: has codebase desc'       ($synPrompt -match 'Unreal Engine')
    Assert-True  'SynPrompt: has cross-reference'     ($synPrompt -match 'Cross-reference subsystems')
    Assert-True  'SynPrompt: has Architecture Overview' ($synPrompt -match '# Architecture Overview')
    Assert-True  'SynPrompt: has Repository Shape'    ($synPrompt -match '## Repository Shape')
    Assert-True  'SynPrompt: has Major Subsystems'    ($synPrompt -match '## Major Subsystems')
    Assert-True  'SynPrompt: has Key Runtime Flows'   ($synPrompt -match '## Key Runtime Flows')
    Assert-True  'SynPrompt: has Initialization'      ($synPrompt -match '### Initialization')
    Assert-True  'SynPrompt: has Per-frame'           ($synPrompt -match '### Per-frame')
    Assert-True  'SynPrompt: has Shutdown'            ($synPrompt -match '### Shutdown')
    Assert-True  'SynPrompt: has Data Boundaries'     ($synPrompt -match '## Data & Control Boundaries')
    Assert-True  'SynPrompt: has Risks'               ($synPrompt -match '## Notable Risks')
    Assert-True  'SynPrompt: has BEGIN marker'        ($synPrompt -match 'BEGIN SUBSYSTEM OVERVIEWS')
    Assert-True  'SynPrompt: has END marker'          ($synPrompt -match 'END SUBSYSTEM OVERVIEWS')
    Assert-True  'SynPrompt: content injected'        ($synPrompt -match 'overviews here')

    # ── Test: Get-SinglePassPrompt ────────────────────────────

    Write-Host 'Testing Get-SinglePassPrompt ...' -ForegroundColor Cyan

    $spPrompt = Get-SinglePassPrompt 'Quake 2 engine' 'single pass content'
    Assert-True  'SinglePrompt: has desc'             ($spPrompt -match 'Quake 2 engine')
    Assert-True  'SinglePrompt: has Architecture title' ($spPrompt -match '# Architecture Overview')
    Assert-True  'SinglePrompt: has Repository Shape' ($spPrompt -match '## Repository Shape')
    Assert-True  'SinglePrompt: has Major Subsystems' ($spPrompt -match '## Major Subsystems')
    Assert-True  'SinglePrompt: has Runtime Flows'    ($spPrompt -match '## Key Runtime Flows')
    Assert-True  'SinglePrompt: has BEGIN marker'     ($spPrompt -match 'BEGIN INPUT DOC INDEX')
    Assert-True  'SinglePrompt: has END marker'       ($spPrompt -match 'END INPUT DOC INDEX')
    Assert-True  'SinglePrompt: content injected'     ($spPrompt -match 'single pass content')
    Assert-True  'SinglePrompt: infer language rule'  ($spPrompt -match 'Infer the programming language')

    # ── Test: Get-PerFileDocs (integration with temp files) ───

    Write-Host 'Testing Get-PerFileDocs ...' -ForegroundColor Cyan

    $docsDir = Join-Path $testDir 'docs'
    New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
    $stateSubDir = Join-Path $docsDir '.archgen_state'
    New-Item -ItemType Directory -Force -Path $stateSubDir | Out-Null

    # Create various doc files
    'content' | Set-Content (Join-Path $docsDir 'Actor.cpp.md') -Encoding UTF8
    'content' | Set-Content (Join-Path $docsDir 'World.h.md') -Encoding UTF8
    'content' | Set-Content (Join-Path $docsDir 'architecture.md') -Encoding UTF8
    'content' | Set-Content (Join-Path $docsDir 'xref_index.md') -Encoding UTF8
    'content' | Set-Content (Join-Path $docsDir 'callgraph.md') -Encoding UTF8
    'content' | Set-Content (Join-Path $docsDir 'diagram_data.md') -Encoding UTF8
    'content' | Set-Content (Join-Path $docsDir 'Actor.cpp.pass2.md') -Encoding UTF8
    'content' | Set-Content (Join-Path $stateSubDir 'hashes.md') -Encoding UTF8

    $result = @(Get-PerFileDocs $docsDir)
    Assert-Equal 'GetPerFileDocs: count'              2 $result.Count
    $names = @($result | ForEach-Object { $_.Name }) | Sort-Object
    Assert-True  'GetPerFileDocs: has Actor.cpp.md'   ($names -contains 'Actor.cpp.md')
    Assert-True  'GetPerFileDocs: has World.h.md'     ($names -contains 'World.h.md')

    # ── Test: Build-DiagramData (integration) ─────────────────

    Write-Host 'Testing Build-DiagramData ...' -ForegroundColor Cyan

    $diagDocsDir = Join-Path $testDir 'diag_docs'
    New-Item -ItemType Directory -Force -Path $diagDocsDir | Out-Null

    # Create a full doc
    @(
        '# src/init.cpp',
        '## File Purpose',
        'Initializes the engine.',
        '## Core Responsibilities',
        '- Sets up subsystems',
        '- Loads config',
        '## Key Functions / Methods',
        '### StartEngine',
        '- Purpose: start',
        '## External Dependencies',
        '- `Engine.h`'
    ) | Set-Content (Join-Path $diagDocsDir 'init.cpp.md') -Encoding UTF8

    @(
        '# src/render.cpp',
        '## File Purpose',
        'Renders frames.',
        '## Core Responsibilities',
        '- Draw calls',
        '## Key Types',
        '### RenderContext',
        '- A struct'
    ) | Set-Content (Join-Path $diagDocsDir 'render.cpp.md') -Encoding UTF8

    $diagOut = Join-Path $testDir 'diag_output.md'
    $diagCount = Build-DiagramData $diagDocsDir $diagOut
    Assert-Equal 'DiagramData: doc count'             2 $diagCount
    Assert-True  'DiagramData: output created'        (Test-Path $diagOut)

    $diagContent = Get-Content $diagOut -Raw
    Assert-True  'DiagramData: has init heading'      ($diagContent -match 'src/init\.cpp')
    Assert-True  'DiagramData: has init purpose'      ($diagContent -match 'Initializes the engine')
    Assert-True  'DiagramData: has init resp'         ($diagContent -match 'Sets up subsystems')
    Assert-True  'DiagramData: has init deps'         ($diagContent -match 'Engine\.h')
    Assert-True  'DiagramData: has render heading'    ($diagContent -match 'src/render\.cpp')
    Assert-True  'DiagramData: has render purpose'    ($diagContent -match 'Renders frames')
    # Should NOT have Key Functions or Key Types content
    Assert-False 'DiagramData: no Key Functions'      ($diagContent -match 'StartEngine')
    Assert-False 'DiagramData: no Key Types'          ($diagContent -match 'RenderContext')

    # ── Test: Get-Subsystems (integration with temp dirs) ─────

    Write-Host 'Testing Get-Subsystems ...' -ForegroundColor Cyan

    # Need $stateDir for Get-Subsystems' tmp file
    $script:stateDir = Join-Path $testDir 'state'
    New-Item -ItemType Directory -Force -Path $script:stateDir | Out-Null

    $subRoot = Join-Path $testDir 'subsystems'
    New-Item -ItemType Directory -Force -Path $subRoot | Out-Null

    # Create a small subsystem (under threshold)
    $subSmall = Join-Path $subRoot 'SmallSub'
    New-Item -ItemType Directory -Force -Path $subSmall | Out-Null
    @('# small/a.cpp', '## File Purpose', 'Small file A.') | Set-Content (Join-Path $subSmall 'a.cpp.md') -Encoding UTF8
    @('# small/b.cpp', '## File Purpose', 'Small file B.') | Set-Content (Join-Path $subSmall 'b.cpp.md') -Encoding UTF8

    # Create a large subsystem with children (would be over threshold)
    $subLarge = Join-Path $subRoot 'LargeSub'
    $subChild1 = Join-Path $subLarge 'Child1'
    $subChild2 = Join-Path $subLarge 'Child2'
    New-Item -ItemType Directory -Force -Path $subChild1 | Out-Null
    New-Item -ItemType Directory -Force -Path $subChild2 | Out-Null

    # Put enough content to exceed a low threshold (say 10 lines)
    $bigContent = @('# large/child1/big.cpp', '## File Purpose', 'Big file.', '## Core Responsibilities') +
        (1..20 | ForEach-Object { "- Responsibility $_" })
    $bigContent | Set-Content (Join-Path $subChild1 'big.cpp.md') -Encoding UTF8
    @('# large/child2/x.cpp', '## File Purpose', 'X file.') | Set-Content (Join-Path $subChild2 'x.cpp.md') -Encoding UTF8

    # Test with high threshold — everything fits in one chunk
    $resultHigh = @(Get-Subsystems $subRoot 'SmallSub' 1000)
    Assert-Equal 'Subsystems high threshold: 1 chunk' 1 $resultHigh.Count
    Assert-Equal 'Subsystems high threshold: is SmallSub' 'SmallSub' $resultHigh[0]

    # Test with low threshold — LargeSub should split into children
    $resultLow = @(Get-Subsystems $subRoot 'LargeSub' 5)
    Assert-True  'Subsystems low threshold: split into children' ($resultLow.Count -ge 2)

    # Single-child descend: create a deep single-child path
    $singleChild = Join-Path $subRoot 'SingleParent'
    $deepChild   = Join-Path $singleChild 'Deep'
    $leaf1 = Join-Path $deepChild 'LeafA'
    $leaf2 = Join-Path $deepChild 'LeafB'
    New-Item -ItemType Directory -Force -Path $leaf1 | Out-Null
    New-Item -ItemType Directory -Force -Path $leaf2 | Out-Null
    $bigContent2 = @('# deep/a/big.cpp', '## File Purpose', 'Big A.', '## Core Responsibilities') +
        (1..20 | ForEach-Object { "- Item $_" })
    $bigContent2 | Set-Content (Join-Path $leaf1 'a.cpp.md') -Encoding UTF8
    @('# deep/b/x.cpp', '## File Purpose', 'Small B.') | Set-Content (Join-Path $leaf2 'b.cpp.md') -Encoding UTF8

    $resultSingle = @(Get-Subsystems $subRoot 'SingleParent' 5)
    # Should descend through SingleParent/Deep to reach LeafA and LeafB
    Assert-True  'Subsystems single-child: descends past SingleParent' ($resultSingle.Count -ge 2)
    $hasLeaf = $resultSingle | Where-Object { $_ -match 'Leaf' }
    Assert-True  'Subsystems single-child: reaches leaf dirs' (@($hasLeaf).Count -gt 0)

    } finally {
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

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

$cfg = Read-EnvFile $EnvFile

$repoRoot = (Get-Location).Path
try {
    $gitRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitRoot) { $repoRoot = $gitRoot.Trim() }
} catch {}

$archDir   = Join-Path $repoRoot 'architecture'
$stateDir  = Join-Path $archDir '.overview_state'
New-Item -ItemType Directory -Force -Path $archDir  | Out-Null
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$model         = Cfg $cfg 'CLAUDE_MODEL'         'sonnet'
$tieredModel   = Cfg $cfg 'TIERED_MODEL'        '1'
$highModel     = Cfg $cfg 'HIGH_COMPLEXITY_MODEL' 'sonnet'
if ($tieredModel -eq '1') { $model = $highModel }
$modelCounts = @{ haiku = 0; sonnet = 0 }
$maxTurns      = Cfg $cfg 'CLAUDE_MAX_TURNS'     '1'
$outputFmt     = Cfg $cfg 'CLAUDE_OUTPUT_FORMAT' 'text'
$codebaseDesc  = Cfg $cfg 'CODEBASE_DESC'        'game engine / game codebase'
$chunkThreshold = [int](Cfg $cfg 'CHUNK_THRESHOLD' '1500')

# ── Local LLM backend (LLMConfig) ─────────────────────────────
. (Join-Path $PSScriptRoot 'llm_core.ps1')
$llmBackend   = Get-LLMBackend -Cfg $cfg
$llmEndpoint  = ''
$llmModel     = ''
$llmTemp      = [double](Cfg $cfg 'LLM_TEMPERATURE' '0.1')
# Synthesis needs a generous output budget; default well above the per-file LLM_MAX_TOKENS.
$llmMaxTokens = [int](Cfg $cfg 'LLM_OVERVIEW_MAX_TOKENS' (Cfg $cfg 'LLM_MAX_TOKENS' '8000'))
$llmTimeout   = [int](Cfg $cfg 'LLM_TIMEOUT' '900')
$llmNumCtx    = [int](Cfg $cfg 'LLM_NUM_CTX' '0')
$llmThink     = ((Cfg $cfg 'LLM_THINK' 'false').Trim().ToLower() -eq 'true')
if ($llmBackend -ne 'claude') {
    $llmEndpoint = Get-LLMEndpoint -Cfg $cfg -Backend $llmBackend
    $llmModel    = Get-LLMModel -Cfg $cfg
    Write-Host "LLM backend: $llmBackend ($llmEndpoint, model=$llmModel)" -ForegroundColor Green
}

$cfgDirKey    = if ($Claude1) { 'CLAUDE1_CONFIG_DIR' } else { 'CLAUDE2_CONFIG_DIR' }
$claudeCfgDir = Cfg $cfg $cfgDirKey ''
if ($llmBackend -eq 'claude') {
    if (-not $claudeCfgDir) { Write-Host "Missing $cfgDirKey in $EnvFile" -ForegroundColor Red; exit 2 }
    if (-not (Test-Path $claudeCfgDir)) { Write-Host "Claude config dir not found: $claudeCfgDir" -ForegroundColor Red; exit 2 }
}

$account = if ($Claude1) { 'claude1' } else { 'claude2' }

$errorLog = Join-Path $stateDir 'last_claude_error.log'
'' | Set-Content $errorLog

if ($Clean) {
    Write-Host "CLEAN: removing overview outputs..." -ForegroundColor Cyan
    Get-ChildItem -Path $archDir -Filter '*architecture.md' -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -Path $archDir -Filter '*diagram_data.md' -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -Path $archDir -Filter '*tier2_batch*.md' -ErrorAction SilentlyContinue | Remove-Item -Force
}

$docRoot   = if ($TargetDir -ne 'all' -and $TargetDir -ne '.') { Join-Path $archDir $TargetDir } else { $archDir }
$outPrefix = if ($TargetDir -ne 'all' -and $TargetDir -ne '.') { (Split-Path $TargetDir -Leaf) + ' ' } else { '' }
$outArch   = Join-Path $archDir ($outPrefix + 'architecture.md')
$outDiag   = Join-Path $archDir ($outPrefix + 'diagram_data.md')

# -- Helper: call Claude ---------------------------------------

function Invoke-Claude($prompt, $label) {
    # If the prompt itself is too long, truncate the content block and retry
    # up to $maxTruncStages times before giving up.
    $maxTruncStages = 3
    $truncStage     = 0
    $currentPrompt  = $prompt

    while ($true) {
        if ($llmBackend -eq 'claude') {
            $env:CLAUDE_CONFIG_DIR = $claudeCfgDir
            $stderrFile = [System.IO.Path]::GetTempFileName()
            try {
                $stdoutRaw = $currentPrompt | & claude -p `
                    --model $model `
                    --max-turns $maxTurns `
                    --output-format $outputFmt 2>$stderrFile
                $exitCode  = $LASTEXITCODE
                $stderrRaw = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -EA SilentlyContinue } else { '' }
            } catch {
                $stdoutRaw = ''
                $stderrRaw = $_.Exception.Message
                $exitCode  = 1
            } finally {
                Remove-Item $stderrFile -EA SilentlyContinue
            }
        } else {
            # Local LLM (vLLM gateway / Ollama) via LLMConfig. The system prompt is
            # embedded in $currentPrompt, so pass it all as the user message.
            try {
                $stdoutRaw = Invoke-LocalLLM -SystemPrompt '' -UserPrompt $currentPrompt `
                    -Backend $llmBackend -Endpoint $llmEndpoint -Model $llmModel `
                    -Temperature $llmTemp -MaxTokens $llmMaxTokens -Timeout $llmTimeout -NumCtx $llmNumCtx -Think $llmThink
                $exitCode  = 0
                $stderrRaw = ''
            } catch {
                $stdoutRaw = ''
                $stderrRaw = $_.Exception.Message
                $exitCode  = 1
            }
        }

        $stdoutText = if ($stdoutRaw -is [array]) { $stdoutRaw -join "`n" } else { [string]$stdoutRaw }
        $stderrText = if ($stderrRaw -is [array]) { $stderrRaw -join "`n" } else { [string]$stderrRaw }
        $respText   = ($stdoutText + "`n" + $stderrText).Trim()

        if ($exitCode -eq 0 -and -not (Test-RateLimit $respText)) {
            if ($model -match 'sonnet') { $script:modelCounts.sonnet++ } else { $script:modelCounts.haiku++ }
            return $stdoutText
        }

        if (Test-TooLong $respText) {
            $truncStage++
            if ($truncStage -gt $maxTruncStages) {
                $divider = '=' * 60
                [System.IO.File]::AppendAllText($errorLog,
                    "$divider`nTimestamp: $(Get-Date)`nContext: $label`nExit: $exitCode`nType: TOO_LONG (all truncation stages exhausted)`n$divider`n--- STDERR ---`n$stderrText`n--- STDOUT ---`n$stdoutText`n$divider`n`n")
                Write-Host "Claude call failed (prompt too long, all stages exhausted): $label" -ForegroundColor Red
                Write-Host "See: $errorLog" -ForegroundColor Red
                exit 1
            }
            # Truncate the content block - find the BEGIN...END markers and halve what's between them
            $keepFraction = 1.0 - ($truncStage * 0.3)   # stage1=70%, stage2=40%, stage3=10%
            $beginPat = 'BEGIN (INPUT DOC INDEX|SUBSYSTEM OVERVIEWS)'
            $endPat   = 'END (INPUT DOC INDEX|SUBSYSTEM OVERVIEWS)'
            if ($currentPrompt -match "(?s)($beginPat`n)(.*?)(`n$endPat)") {
                $header  = $currentPrompt.Substring(0, $currentPrompt.IndexOf($Matches[0]))
                $footer  = $currentPrompt.Substring($currentPrompt.IndexOf($Matches[0]) + $Matches[0].Length)
                $body    = $Matches[3]
                $lines   = $body -split "`n"
                $keep    = [math]::Max(50, [int]($lines.Count * $keepFraction))
                $trunced = ($lines | Select-Object -First $keep) -join "`n"
                $trunced += "`n`n... [TRUNCATED to $keep/$($lines.Count) lines for context length] ...`n"
                $currentPrompt = $header + $Matches[0].Substring(0, $Matches[0].IndexOf("`n") + 1) + $trunced + "`n" + ($endPat -replace '\(.*\)', ($Matches[4])) + $footer
                Write-Host "  [too-long] $label -- retrying with ~$([int]($keepFraction*100))% content (stage $truncStage)" -ForegroundColor DarkCyan
            } else {
                # Can't find markers to truncate — just fail
                break
            }
            continue
        }

        $divider = '=' * 60
        [System.IO.File]::AppendAllText($errorLog,
            "$divider`nTimestamp: $(Get-Date)`nContext: $label`nExit: $exitCode`n$divider`n--- STDERR ---`n$stderrText`n--- STDOUT ---`n$stdoutText`n$divider`n`n")
        Write-Host "Claude call failed for: $label (exit=$exitCode)" -ForegroundColor Red
        Write-Host "See: $errorLog" -ForegroundColor Red
        exit 1
    }
}

# -- Main ------------------------------------------------------

$docCount = @(Get-PerFileDocs $docRoot).Count
$diagramCount = Build-DiagramData $docRoot $outDiag
$diagramLines = @(Get-Content $outDiag).Count

# Auto-detect mode
$mode = ''
if ($Chunked) { $mode = 'chunked' }
elseif ($Single) { $mode = 'single' }
elseif ($diagramLines -gt $chunkThreshold) { $mode = 'chunked' }
else { $mode = 'single' }

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  arch_overview.ps1 - Architecture Overview" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "Codebase:       $codebaseDesc"
Write-Host "Account:        $account"
Write-Host "Model:          $model"
Write-Host "Target:         $TargetDir"
Write-Host "Mode:           $mode"
Write-Host "Doc root:       $docRoot"
Write-Host "Per-file docs:  $docCount"
Write-Host "Diagram lines:  $diagramLines (threshold: $chunkThreshold)"
Write-Host "Output:         $outArch"
Write-Host ""

if ($docCount -eq 0) {
    Write-Host "No per-file docs found. Run archgen.ps1 first." -ForegroundColor Red
    exit 1
}

# -- Single-pass -----------------------------------------------

if ($mode -eq 'single') {
    Write-Host "Running single-pass overview..."
    $content = Get-Content $outDiag -Raw
    $prompt  = Get-SinglePassPrompt $codebaseDesc $content
    $resp    = Invoke-Claude $prompt "single-pass overview"
    $resp | Set-Content -Path $outArch -Encoding UTF8
    Write-Host ""
    Write-Host "Wrote: $outDiag"
    Write-Host "Wrote: $outArch"
    Write-Host "Done." -ForegroundColor Green
    exit 0
}

# -- Chunked mode ----------------------------------------------

Write-Host "Running chunked two-tier overview..."
Write-Host ""

# Build the subsystem list using recursive expansion
$rawSubsystems = @(Get-ChildItem -Path $docRoot -Directory -EA SilentlyContinue |
    Where-Object { $_.Name -notmatch '^\.' } | Sort-Object Name | ForEach-Object { $_.Name })

if ($rawSubsystems.Count -eq 0) {
    Write-Host "No subsystem directories found, falling back to single-pass." -ForegroundColor Yellow
    $content = Get-Content $outDiag -Raw
    $prompt  = Get-SinglePassPrompt $codebaseDesc $content
    $resp    = Invoke-Claude $prompt "single-pass fallback"
    $resp | Set-Content -Path $outArch -Encoding UTF8
    Write-Host "Wrote: $outArch"
    Write-Host "Done (fallback)." -ForegroundColor Green
    exit 0
}

$subsystems = [System.Collections.Generic.List[string]]::new()
foreach ($raw in $rawSubsystems) {
    $expanded = Get-Subsystems $docRoot $raw $chunkThreshold
    foreach ($item in $expanded) { $subsystems.Add($item) }
}

Write-Host "Detected $($subsystems.Count) subsystem(s):"
foreach ($sub in $subsystems) {
    $subCount = @(Get-PerFileDocs (Join-Path $docRoot $sub)).Count
    Write-Host "  - $sub ($subCount files)"
}
Write-Host ""

# Tier 1
function Get-ModelStats {
    $mTotal = $script:modelCounts.haiku + $script:modelCounts.sonnet
    if ($mTotal -eq 0) { return '' }
    $hPct = [int][math]::Round(100 * $script:modelCounts.haiku / $mTotal)
    $sPct = 100 - $hPct
    return "  haiku=${hPct}% sonnet=${sPct}%"
}

$tier1Count  = 0
$tier1Skip   = 0

foreach ($sub in $subsystems) {
    $tier1Count++
    $subDocRoot = Join-Path $docRoot $sub
    $subDiag    = Join-Path $archDir "$sub diagram_data.md"
    $subArch    = Join-Path $archDir "$sub architecture.md"

    New-Item -ItemType Directory -Force -Path (Split-Path $subArch -Parent) | Out-Null

    # Opt v3#6: Incremental — skip if subsystem docs haven't changed
    if (-not $Full -and (Test-Path $subArch)) {
        $subDocs = @(Get-PerFileDocs $subDocRoot)
        $currentHash = ''
        if ($subDocs.Count -gt 0) {
            $sha = [System.Security.Cryptography.SHA1]::Create()
            $combined = ($subDocs | ForEach-Object { Get-Content $_.FullName -Raw }) -join ''
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
            $currentHash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        }
        $overviewHashDb = Join-Path $stateDir 'overview_hashes.tsv'
        $cachedHash = ''
        if (Test-Path $overviewHashDb) {
            $cachedHash = Get-Content $overviewHashDb -ErrorAction SilentlyContinue |
                Where-Object { $_ -match "^[^\t]+\t$([regex]::Escape($sub))$" } |
                ForEach-Object { ($_ -split "`t")[0] } | Select-Object -Last 1
        }
        if ($currentHash -eq $cachedHash -and $cachedHash -ne '') {
            Write-Host "[Tier 1: $tier1Count/$($subsystems.Count)] Unchanged, skipping: $sub$(Get-ModelStats)"
            $tier1Skip++
            continue
        }
        # Hash changed or new — record after generation
    }

    # Resume: skip if already done and not doing incremental check
    if ($Full -and (Test-Path $subArch)) {
        # Full mode regenerates everything — don't skip
    } elseif (-not $Full -and (Test-Path $subArch)) {
        # Already handled by incremental check above
    }

    Write-Host "[Tier 1: $tier1Count/$($subsystems.Count)] Analyzing subsystem: $sub$(Get-ModelStats)"
    Build-DiagramData $subDocRoot $subDiag | Out-Null
    $subLines = @(Get-Content $subDiag -ErrorAction SilentlyContinue).Count
    Write-Host "  diagram_data: $subLines lines"

    if ($subLines -eq 0) { Write-Host "  (empty - skipping)"; continue }

    $content = Get-Content $subDiag -Raw
    $prompt  = Get-SubsystemPrompt "$codebaseDesc - $sub subsystem" $content
    $resp    = Invoke-Claude $prompt "subsystem: $sub"
    $resp | Set-Content -Path $subArch -Encoding UTF8
    Write-Host "  Wrote: $subArch"

    # Opt v3#6: Record subsystem hash for incremental detection
    $overviewHashDb = Join-Path $stateDir 'overview_hashes.tsv'
    $subDocs = @(Get-PerFileDocs $subDocRoot)
    if ($subDocs.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $combined = ($subDocs | ForEach-Object { Get-Content $_.FullName -Raw }) -join ''
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
        $hashStr = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        [System.IO.File]::AppendAllText($overviewHashDb, "$hashStr`t$sub`n")
    }
}

if ($tier1Skip -gt 0) {
    Write-Host ""
    Write-Host "Tier 1: skipped $tier1Skip/$($subsystems.Count) already-complete subsystems." -ForegroundColor Cyan
}

# Tier 2 - batch synthesis
# Collect all tier-1 overviews that were written to disk
$tier1Files = @($subsystems | ForEach-Object {
    $p = Join-Path $archDir "$_ architecture.md"
    if (Test-Path $p) { $p }
})

Write-Host ""
Write-Host "[Tier 2] Synthesizing from $($tier1Files.Count) subsystem overviews...$(Get-ModelStats)"

# Measure total size and decide whether to batch
$allText    = $tier1Files | ForEach-Object { Get-Content $_ -Raw -ErrorAction SilentlyContinue }
$totalLines = @($allText | ForEach-Object { $_ -split "`n" }).Count

# Batch size: aim for ~1000 lines per batch to stay well under context limit
$batchLineTarget = 1000
$batches         = [System.Collections.Generic.List[string]]::new()
$batchFiles      = [System.Collections.Generic.List[string]]::new()
$currentBatch    = [System.Text.StringBuilder]::new()
$currentLines    = 0
$batchIndex      = 0

foreach ($file in $tier1Files) {
    $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    $sub   = [System.IO.Path]::GetFileNameWithoutExtension($file) -replace ' architecture$',''
    $entry = "`n--- SUBSYSTEM: $sub ---`n$content"
    $entryLines = @($entry -split "`n").Count

    if ($currentLines -gt 0 -and ($currentLines + $entryLines) -gt $batchLineTarget) {
        $batchIndex++
        $batches.Add($currentBatch.ToString())
        $batchFiles.Add((Join-Path $archDir "${outPrefix}tier2_batch${batchIndex}.md"))
        $currentBatch = [System.Text.StringBuilder]::new()
        $currentLines = 0
    }
    $currentBatch.AppendLine($entry) | Out-Null
    $currentLines += $entryLines
}
if ($currentBatch.Length -gt 0) {
    $batchIndex++
    $batches.Add($currentBatch.ToString())
    $batchFiles.Add((Join-Path $archDir "${outPrefix}tier2_batch${batchIndex}.md"))
}

Write-Host "  Total lines: $totalLines  |  Batches: $($batches.Count)"

if ($batches.Count -eq 1) {
    # Small enough for a single synthesis call
    if (Test-Path $outArch) {
        Write-Host "  Final overview already exists, skipping synthesis." -ForegroundColor Cyan
    } else {
        Write-Host "  Single synthesis call..."
        $prompt = Get-SynthesisPrompt $codebaseDesc $batches[0]
        $resp   = Invoke-Claude $prompt "final synthesis"
        $resp | Set-Content -Path $outArch -Encoding UTF8
    }
} else {
    # Multiple batches: synthesise each, then merge
    $batchSummaries = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $batches.Count; $i++) {
        $batchNum  = $i + 1
        $batchFile = $batchFiles[$i]

        if (Test-Path $batchFile) {
            Write-Host "  [Tier 2 batch $batchNum/$($batches.Count)] Skipping (exists): $batchFile" -ForegroundColor Cyan
            $resp = Get-Content $batchFile -Raw
        } else {
            Write-Host "  [Tier 2 batch $batchNum/$($batches.Count)] Synthesizing..."
            $prompt = Get-SynthesisPrompt "$codebaseDesc (batch $batchNum of $($batches.Count))" $batches[$i]
            $resp   = Invoke-Claude $prompt "tier2 batch $batchNum"
            $resp | Set-Content -Path $batchFile -Encoding UTF8
            Write-Host "    Wrote: $batchFile"
        }
        $batchSummaries.AppendLine("`n--- BATCH $batchNum ---`n$resp") | Out-Null
    }

    # Tier 3: merge batch summaries into final overview
    if (Test-Path $outArch) {
        Write-Host ""
        Write-Host "[Tier 3] Final overview already exists, skipping merge." -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "[Tier 3] Merging $($batches.Count) batch summaries into final overview...$(Get-ModelStats)"
        $mergePrompt = Get-SynthesisPrompt $codebaseDesc $batchSummaries.ToString()
        $resp        = Invoke-Claude $mergePrompt "tier3 final merge"
        $resp | Set-Content -Path $outArch -Encoding UTF8
    }
}

Write-Host ""
Write-Host "Wrote: $outDiag ($diagramLines lines)"
Write-Host "Wrote: $outArch"
Write-Host ""
Write-Host "Subsystem overviews:"
foreach ($sub in $subsystems) {
    $subArch = Join-Path $archDir "$sub architecture.md"
    if (Test-Path $subArch) { Write-Host "  - $subArch" }
}
$mTotal = $script:modelCounts.haiku + $script:modelCounts.sonnet
if ($mTotal -gt 0) {
    $hPct = [int][math]::Round(100 * $script:modelCounts.haiku / $mTotal)
    $sPct = 100 - $hPct
    Write-Host "Model usage:    $mTotal calls  haiku=${hPct}% sonnet=${sPct}%"
}
Write-Host ""
Write-Host "Done." -ForegroundColor Green
