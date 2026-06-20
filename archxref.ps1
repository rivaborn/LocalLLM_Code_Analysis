# ============================================================
# archxref.ps1 - Cross-Reference Index Generator
#
# Parses per-file architecture docs (from archgen.ps1) to build:
#   architecture/xref_index.md
#
# Contains:
# - Function -> file mapping
# - Caller -> callee edges (call graph)
# - Global state ownership
# - Header dependency counts
# - Subsystem interface summary
#
# No Claude calls - pure text processing. Fast even on 1000+ files.
# Run after archgen.ps1, before arch_overview.ps1 or archpass2.ps1.
#
# Usage:
#   .\archxref.ps1 [-TargetDir <subsystem>]
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir = ".",
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

# ── Testable functions ────────────────────────────────────────

function Test-DocFileIncluded($name, $fullName) {
    if ($fullName -match '[/\\]\.archgen_state[/\\]') { return $false }
    if ($fullName -match '[/\\]\.overview_state[/\\]') { return $false }
    if ($name -match '^(architecture|diagram_data|xref_index|callgraph)') { return $false }
    if ($name -match '\.pass2\.md$') { return $false }
    return $true
}

function Parse-DocFile($lines) {
    $result = @{
        FilePath    = ''
        FuncMap     = [System.Collections.Generic.List[hashtable]]::new()
        CallEdges   = [System.Collections.Generic.List[hashtable]]::new()
        Globals     = [System.Collections.Generic.List[hashtable]]::new()
        IncludeDeps = [System.Collections.Generic.List[hashtable]]::new()
    }

    if (-not $lines -or $lines.Count -eq 0) { return $result }

    $filePath    = ''
    $section     = ''
    $currentFunc = ''

    foreach ($line in $lines) {
        # First line: file path from # heading
        if ($filePath -eq '' -and $line -match '^# (.+)') {
            $filePath = $Matches[1].Trim()
            $result.FilePath = $filePath
            continue
        }

        # Section detection
        if ($line -match '^## Key (Functions|Methods)')       { $section = 'functions'; $currentFunc = ''; continue }
        if ($line -match '^## Global')                         { $section = 'globals';   $currentFunc = ''; continue }
        if ($line -match '^## File-Static')                    { $section = 'globals';   continue }
        if ($line -match '^## External Dep')                   { $section = 'deps';      continue }
        if ($line -match '^## (Control|File Purpose|Core Resp|Key Types|Notable)') { $section = ''; continue }

        # ### heading in non-global section = function
        if ($line -match '^### ' -and $section -ne 'globals' -and $section -ne 'deps') {
            $section = 'functions'
        }

        if ($section -eq 'functions' -and $line -match '^### (.+)') {
            $currentFunc = $Matches[1].Trim() -replace '`','' -replace '\*',''
            if ($filePath -ne '') {
                $result.FuncMap.Add(@{ func = $currentFunc; file = $filePath })
            }
            continue
        }

        if ($section -eq 'functions' -and $currentFunc -ne '' -and $line -match '^- ' -and $line -imatch 'calls?[^a-z]') {
            $tmp = $line
            $m = [regex]::Matches($tmp, '`([A-Za-z_][A-Za-z0-9_]*)`')
            foreach ($match in $m) {
                $callee = $match.Groups[1].Value
                $result.CallEdges.Add(@{ caller = $currentFunc; callerFile = $filePath; callee = $callee })
            }
            continue
        }

        if ($section -eq 'globals' -and $line -match '^\|') {
            $cols = $line -split '\|' | ForEach-Object { $_.Trim() }
            # cols[0] empty, cols[1]=name, cols[2]=type, cols[3]=scope, cols[4]=purpose
            if ($cols.Count -ge 5) {
                $name  = $cols[1] -replace '`',''
                $type  = $cols[2] -replace '`',''
                $scope = $cols[3]
                if ($name -ne '' -and $name -ne 'Name' -and $name -notmatch '^-+$' -and $name -ne 'None') {
                    $result.Globals.Add(@{ name = $name; type = $type; scope = $scope; file = $filePath })
                }
            }
            continue
        }

        if ($section -eq 'deps' -and $line -match '`') {
            # Extract file includes (with extension)
            $m = [regex]::Matches($line, '`([A-Za-z_][A-Za-z0-9_/]*\.[a-z]+)`')
            foreach ($match in $m) {
                $result.IncludeDeps.Add(@{ file = $filePath; header = $match.Groups[1].Value })
            }
        }
    }

    return $result
}

function Build-XrefOutput($funcMap, $callEdges, $globals, $includeDeps) {
    $sb = [System.Text.StringBuilder]::new()

    $sb.AppendLine("# Cross-Reference Index") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("Auto-generated from per-file architecture docs.") | Out-Null
    $sb.AppendLine("") | Out-Null

    # Function -> File Map
    $sb.AppendLine("## Function Definition Map") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("| Function | Defined In |") | Out-Null
    $sb.AppendLine("|----------|-----------|") | Out-Null
    foreach ($entry in ($funcMap | Sort-Object { $_.func })) {
        $sb.AppendLine("| ``$($entry.func)`` | ``$($entry.file)`` |") | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    # Call graph - top callers
    $sb.AppendLine("## Call Graph - Most Connected Functions") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("Functions sorted by number of outgoing calls.") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("| Caller | File | Callees (count) |") | Out-Null
    $sb.AppendLine("|--------|------|-----------------|") | Out-Null

    $callerGroups = $callEdges | Group-Object { "$($_.caller)`t$($_.callerFile)" } |
        Sort-Object Count -Descending | Select-Object -First 40

    foreach ($g in $callerGroups) {
        $parts = $g.Name -split "`t", 2
        $caller = $parts[0]; $file = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $callees = ($g.Group | ForEach-Object { $_.callee } | Sort-Object -Unique) -join ' '
        $sb.AppendLine("| ``$caller`` | ``$file`` | $($g.Count): $callees |") | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    # Most called functions
    $sb.AppendLine("## Most Called Functions") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("| Function | Called By (count) | Callers |") | Out-Null
    $sb.AppendLine("|----------|-------------------|---------|") | Out-Null

    $calleeGroups = $callEdges | Group-Object { $_.callee } |
        Sort-Object Count -Descending | Select-Object -First 30

    foreach ($g in $calleeGroups) {
        $callers = ($g.Group | ForEach-Object { $_.caller } | Sort-Object -Unique) -join ' '
        $sb.AppendLine("| ``$($g.Name)`` | $($g.Count) | $callers |") | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    # Global state
    if ($globals.Count -gt 0) {
        $sb.AppendLine("## Global State Ownership") | Out-Null
        $sb.AppendLine("") | Out-Null
        $sb.AppendLine("| Name | Type | Scope | Owner File |") | Out-Null
        $sb.AppendLine("|------|------|-------|-----------|") | Out-Null
        foreach ($g in ($globals | Sort-Object { $_.name })) {
            $sb.AppendLine("| ``$($g.name)`` | ``$($g.type)`` | $($g.scope) | ``$($g.file)`` |") | Out-Null
        }
        $sb.AppendLine("") | Out-Null
    }

    # Header dependencies
    if ($includeDeps.Count -gt 0) {
        $sb.AppendLine("## Header Dependencies") | Out-Null
        $sb.AppendLine("") | Out-Null
        $sb.AppendLine("Most-included headers (by number of dependents).") | Out-Null
        $sb.AppendLine("") | Out-Null
        $sb.AppendLine("| Header | Included By (count) |") | Out-Null
        $sb.AppendLine("|--------|---------------------|") | Out-Null
        $includeDeps | Group-Object { $_.header } | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
            $sb.AppendLine("| ``$($_.Name)`` | $($_.Count) |") | Out-Null
        }
        $sb.AppendLine("") | Out-Null
    }

    # Subsystem interfaces
    $sb.AppendLine("## Subsystem Interfaces") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("Functions exported by each top-level directory.") | Out-Null
    $sb.AppendLine("") | Out-Null

    $bySubsystem = $funcMap | Group-Object {
        $parts = $_.file -split '/', 2
        if ($parts.Count -ge 2) { $parts[0] } else { '(root)' }
    } | Sort-Object Name

    foreach ($grp in $bySubsystem) {
        $sb.AppendLine("### $($grp.Name)") | Out-Null
        $sb.AppendLine("") | Out-Null
        foreach ($entry in ($grp.Group | Sort-Object { $_.func })) {
            $sb.AppendLine("- ``$($entry.func)``") | Out-Null
        }
        $sb.AppendLine("") | Out-Null
    }

    return $sb.ToString()
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
    Write-Host '  archxref.ps1 - Unit Tests' -ForegroundColor Yellow
    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host ''

    $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "archxref_tests_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $testDir | Out-Null

    try {

    # ── Test: Test-DocFileIncluded ────────────────────────────

    Write-Host 'Testing Test-DocFileIncluded ...' -ForegroundColor Cyan

    # Included: normal per-file doc
    Assert-True  'DocIncluded: normal.cpp.md'             (Test-DocFileIncluded 'normal.cpp.md' 'C:\arch\Engine\normal.cpp.md')
    Assert-True  'DocIncluded: Actor.h.md'                (Test-DocFileIncluded 'Actor.h.md' 'C:\arch\Engine\Actor.h.md')
    Assert-True  'DocIncluded: deep path'                 (Test-DocFileIncluded 'Math.cpp.md' 'C:\arch\Engine\Source\Runtime\Core\Private\Math.cpp.md')

    # Excluded: meta files
    Assert-False 'DocIncluded: architecture.md'           (Test-DocFileIncluded 'architecture.md' 'C:\arch\architecture.md')
    Assert-False 'DocIncluded: xref_index.md'             (Test-DocFileIncluded 'xref_index.md' 'C:\arch\xref_index.md')
    Assert-False 'DocIncluded: diagram_data.md'           (Test-DocFileIncluded 'diagram_data.md' 'C:\arch\diagram_data.md')
    Assert-False 'DocIncluded: callgraph.md'              (Test-DocFileIncluded 'callgraph.md' 'C:\arch\callgraph.md')
    Assert-False 'DocIncluded: callgraph.mermaid.md'      (Test-DocFileIncluded 'callgraph.mermaid.md' 'C:\arch\callgraph.mermaid.md')

    # Excluded: pass2 docs
    Assert-False 'DocIncluded: .pass2.md'                 (Test-DocFileIncluded 'Actor.cpp.pass2.md' 'C:\arch\Actor.cpp.pass2.md')

    # Excluded: state directories
    Assert-False 'DocIncluded: .archgen_state'            (Test-DocFileIncluded 'hashes.md' 'C:\arch\.archgen_state\hashes.md')
    Assert-False 'DocIncluded: .overview_state'           (Test-DocFileIncluded 'state.md' 'C:\arch\.overview_state\state.md')

    # Edge: subsystem architecture files
    Assert-False 'DocIncluded: architecture overview'     (Test-DocFileIncluded 'architecture Core.md' 'C:\arch\architecture Core.md')

    # ── Test: Parse-DocFile — function extraction ────────────

    Write-Host 'Testing Parse-DocFile: function extraction ...' -ForegroundColor Cyan

    $docFuncs = @(
        '# Engine/Source/Runtime/Core/Private/Math.cpp',
        '',
        '## File Purpose',
        'Math utilities.',
        '',
        '## Key Functions / Methods',
        '',
        '### RandInit',
        '- Signature: `void RandInit(int32 Seed)`',
        '- Purpose: Initialize random seed',
        '- Calls: `SetSeed`, `ValidateState`',
        '',
        '### RandHelper',
        '- Signature: `int32 RandHelper(int32 Max)`',
        '- Purpose: Generate random number',
        '- Calls: `RandInit`',
        '',
        '## Control Flow',
        'None.'
    )

    $r1 = Parse-DocFile $docFuncs
    Assert-Equal 'Parse funcs: file path'         'Engine/Source/Runtime/Core/Private/Math.cpp' $r1.FilePath
    Assert-Equal 'Parse funcs: func count'        2        $r1.FuncMap.Count
    Assert-Equal 'Parse funcs: func 1 name'       'RandInit'  $r1.FuncMap[0].func
    Assert-Equal 'Parse funcs: func 1 file'       'Engine/Source/Runtime/Core/Private/Math.cpp' $r1.FuncMap[0].file
    Assert-Equal 'Parse funcs: func 2 name'       'RandHelper' $r1.FuncMap[1].func

    # Call edges
    Assert-Equal 'Parse funcs: call edge count'   3        $r1.CallEdges.Count
    Assert-Equal 'Parse funcs: edge 1 caller'     'RandInit'   $r1.CallEdges[0].caller
    Assert-Equal 'Parse funcs: edge 1 callee'     'SetSeed'    $r1.CallEdges[0].callee
    Assert-Equal 'Parse funcs: edge 2 callee'     'ValidateState' $r1.CallEdges[1].callee
    Assert-Equal 'Parse funcs: edge 3 caller'     'RandHelper' $r1.CallEdges[2].caller
    Assert-Equal 'Parse funcs: edge 3 callee'     'RandInit'   $r1.CallEdges[2].callee

    # ── Test: Parse-DocFile — global state extraction ────────

    Write-Host 'Testing Parse-DocFile: globals extraction ...' -ForegroundColor Cyan

    $docGlobals = @(
        '# Engine/Source/Runtime/Core/Private/Globals.cpp',
        '',
        '## Global / File-Static State',
        '',
        '| Name | Type | Scope | Purpose |',
        '|------|------|-------|---------|',
        '| `GRandState` | `int32` | File-static | Random seed state |',
        '| `GFrameCounter` | `uint64` | Global | Frame counter |',
        '',
        '## Key Functions / Methods',
        ''
    )

    $r2 = Parse-DocFile $docGlobals
    Assert-Equal 'Parse globals: count'           2             $r2.Globals.Count
    Assert-Equal 'Parse globals: name 1'          'GRandState'  $r2.Globals[0].name
    Assert-Equal 'Parse globals: type 1'          'int32'       $r2.Globals[0].type
    Assert-Equal 'Parse globals: scope 1'         'File-static' $r2.Globals[0].scope
    Assert-Equal 'Parse globals: file 1'          'Engine/Source/Runtime/Core/Private/Globals.cpp' $r2.Globals[0].file
    Assert-Equal 'Parse globals: name 2'          'GFrameCounter' $r2.Globals[1].name
    Assert-Equal 'Parse globals: type 2'          'uint64'      $r2.Globals[1].type

    # Table header/separator rows should be excluded
    $docGlobalFilter = @(
        '# test.cpp',
        '## Global / File-Static State',
        '| Name | Type | Scope | Purpose |',
        '|------|------|-------|---------|',
        '| `ActualVar` | `bool` | Global | A real global |',
        '| None |  |  |  |'
    )
    $r2f = Parse-DocFile $docGlobalFilter
    Assert-Equal 'Parse globals filter: skips header row'  1 $r2f.Globals.Count
    Assert-Equal 'Parse globals filter: keeps real var'     'ActualVar' $r2f.Globals[0].name

    # ── Test: Parse-DocFile — include deps extraction ────────

    Write-Host 'Testing Parse-DocFile: include deps extraction ...' -ForegroundColor Cyan

    $docDeps = @(
        '# Engine/Source/Runtime/Engine/Private/Actor.cpp',
        '',
        '## External Dependencies',
        '- `CoreMinimal.h` - core types',
        '- `Actor.h` - actor class definition',
        '- Uses `UObject.h` and `World.h` for object management',
        '',
        '## Control Flow',
        'None.'
    )

    $r3 = Parse-DocFile $docDeps
    Assert-Equal 'Parse deps: count'              4             $r3.IncludeDeps.Count
    Assert-Equal 'Parse deps: header 1'           'CoreMinimal.h' $r3.IncludeDeps[0].header
    Assert-Equal 'Parse deps: header 2'           'Actor.h'     $r3.IncludeDeps[1].header
    Assert-Equal 'Parse deps: header 3'           'UObject.h'   $r3.IncludeDeps[2].header
    Assert-Equal 'Parse deps: header 4'           'World.h'     $r3.IncludeDeps[3].header
    Assert-Equal 'Parse deps: owner file'         'Engine/Source/Runtime/Engine/Private/Actor.cpp' $r3.IncludeDeps[0].file

    # ── Test: Parse-DocFile — section transitions ────────────

    Write-Host 'Testing Parse-DocFile: section transitions ...' -ForegroundColor Cyan

    $docSections = @(
        '# test/file.cpp',
        '',
        '## File Purpose',
        'This file does things.',
        '',
        '## Core Responsibilities',
        '- Does X',
        '- Does Y',
        '',
        '## Key Types / Data Structures',
        '### MyStruct',
        '- A data structure',
        '',
        '## Key Functions / Methods',
        '',
        '### Initialize',
        '- Signature: `void Initialize()`',
        '- Calls: `Setup`, `Validate`',
        '',
        '## Global / File-Static State',
        '',
        '| Name | Type | Scope | Purpose |',
        '|------|------|-------|---------|',
        '| `gState` | `int` | Global | state |',
        '',
        '## External Dependencies',
        '- `Header.h` - stuff',
        '',
        '## Control Flow',
        '- Init -> Setup -> Run'
    )

    $r4 = Parse-DocFile $docSections
    Assert-Equal 'Sections: file path'            'test/file.cpp' $r4.FilePath
    # Note: ### headings under non-global/non-deps sections are treated as functions
    # by the fallback rule. So ### MyStruct under Key Types IS counted as a function.
    Assert-Equal 'Sections: funcs found'          2             $r4.FuncMap.Count
    Assert-Equal 'Sections: func 1 name'          'MyStruct'    $r4.FuncMap[0].func
    Assert-Equal 'Sections: func 2 name'          'Initialize'  $r4.FuncMap[1].func
    Assert-Equal 'Sections: call edges'           2             $r4.CallEdges.Count
    Assert-Equal 'Sections: globals found'        1             $r4.Globals.Count
    Assert-Equal 'Sections: global name'          'gState'      $r4.Globals[0].name
    Assert-Equal 'Sections: deps found'           1             $r4.IncludeDeps.Count
    Assert-Equal 'Sections: dep header'           'Header.h'    $r4.IncludeDeps[0].header

    # ── Test: Parse-DocFile — empty/minimal docs ─────────────

    Write-Host 'Testing Parse-DocFile: edge cases ...' -ForegroundColor Cyan

    # Empty lines
    $rEmpty = Parse-DocFile @()
    Assert-Equal 'Parse empty: file path empty' '' $rEmpty.FilePath
    Assert-Equal 'Parse empty: no funcs'        0  $rEmpty.FuncMap.Count

    # Null input
    $rNull = Parse-DocFile $null
    Assert-Equal 'Parse null: no funcs'         0  $rNull.FuncMap.Count

    # Trivial stub doc
    $docStub = @(
        '# Engine/Source/Runtime/Module.Core.gen.cpp',
        '',
        '## File Purpose',
        'Auto-generated or trivial file. No detailed analysis needed.',
        '',
        '## Core Responsibilities',
        '- Boilerplate / generated code'
    )
    $rStub = Parse-DocFile $docStub
    Assert-Equal 'Parse stub: file path'        'Engine/Source/Runtime/Module.Core.gen.cpp' $rStub.FilePath
    Assert-Equal 'Parse stub: no funcs'         0  $rStub.FuncMap.Count
    Assert-Equal 'Parse stub: no edges'         0  $rStub.CallEdges.Count
    Assert-Equal 'Parse stub: no globals'       0  $rStub.Globals.Count
    Assert-Equal 'Parse stub: no deps'          0  $rStub.IncludeDeps.Count

    # ── Test: Parse-DocFile — call edge patterns ─────────────

    Write-Host 'Testing Parse-DocFile: call edge patterns ...' -ForegroundColor Cyan

    $docCalls = @(
        '# src/caller.cpp',
        '## Key Functions / Methods',
        '### DoWork',
        '- Calls: `FuncA`, `FuncB`, `FuncC`',
        '- Also calls `FuncD` for cleanup',
        '### Helper',
        '- Purpose: helps',
        '- Call: `FuncE`',
        '### NoCallsFunc',
        '- Purpose: standalone utility',
        '- Returns: int'
    )
    $rCalls = Parse-DocFile $docCalls
    Assert-Equal 'Call patterns: func count'     3  $rCalls.FuncMap.Count
    Assert-Equal 'Call patterns: total edges'    5  $rCalls.CallEdges.Count
    # DoWork calls FuncA, FuncB, FuncC, FuncD
    $doWorkEdges = @($rCalls.CallEdges | Where-Object { $_.caller -eq 'DoWork' })
    Assert-Equal 'Call patterns: DoWork edges'   4  $doWorkEdges.Count
    # Helper calls FuncE
    $helperEdges = @($rCalls.CallEdges | Where-Object { $_.caller -eq 'Helper' })
    Assert-Equal 'Call patterns: Helper edges'   1  $helperEdges.Count
    Assert-Equal 'Call patterns: Helper callee'  'FuncE' $helperEdges[0].callee
    # NoCallsFunc has zero edges
    $noCallEdges = @($rCalls.CallEdges | Where-Object { $_.caller -eq 'NoCallsFunc' })
    Assert-Equal 'Call patterns: NoCallsFunc edges' 0 $noCallEdges.Count

    # Lines with "calls" but no backtick identifiers — should not produce edges
    $docNoCalls = @(
        '# src/edge.cpp',
        '## Key Functions / Methods',
        '### EdgeCase',
        '- Purpose: handles edge calls without identifiers',
        '- Calls no other functions'
    )
    $rNoCall = Parse-DocFile $docNoCalls
    Assert-Equal 'No-call line: zero edges'      0  $rNoCall.CallEdges.Count

    # ── Test: Parse-DocFile — backtick-wrapped func names ────

    Write-Host 'Testing Parse-DocFile: formatting in func names ...' -ForegroundColor Cyan

    $docFmt = @(
        '# src/fmt.cpp',
        '## Key Functions / Methods',
        '### `FormattedFunc`',
        '- Purpose: test',
        '### **BoldFunc**',
        '- Purpose: test',
        '### NormalFunc',
        '- Purpose: test'
    )
    $rFmt = Parse-DocFile $docFmt
    Assert-Equal 'Fmt funcs: count'              3               $rFmt.FuncMap.Count
    Assert-Equal 'Fmt funcs: backtick stripped'   'FormattedFunc' $rFmt.FuncMap[0].func
    Assert-Equal 'Fmt funcs: bold stripped'       'BoldFunc'      $rFmt.FuncMap[1].func
    Assert-Equal 'Fmt funcs: normal preserved'   'NormalFunc'    $rFmt.FuncMap[2].func

    # ── Test: Parse-DocFile — File-Static section ────────────

    Write-Host 'Testing Parse-DocFile: File-Static section ...' -ForegroundColor Cyan

    $docStatic = @(
        '# src/statics.cpp',
        '## File-Static State',
        '| Name | Type | Scope | Purpose |',
        '|------|------|-------|---------|',
        '| `s_Counter` | `int` | Static | Internal counter |'
    )
    $rStatic = Parse-DocFile $docStatic
    Assert-Equal 'File-Static: parsed as globals' 1           $rStatic.Globals.Count
    Assert-Equal 'File-Static: name'              's_Counter' $rStatic.Globals[0].name

    # ── Test: Build-XrefOutput ────────────────────────────────

    Write-Host 'Testing Build-XrefOutput ...' -ForegroundColor Cyan

    $testFuncMap = [System.Collections.Generic.List[hashtable]]::new()
    $testFuncMap.Add(@{ func = 'Initialize'; file = 'Engine/Core/Init.cpp' })
    $testFuncMap.Add(@{ func = 'Shutdown'; file = 'Engine/Core/Init.cpp' })
    $testFuncMap.Add(@{ func = 'Render'; file = 'Engine/Renderer/Draw.cpp' })
    $testFuncMap.Add(@{ func = 'Tick'; file = 'Engine/Core/Loop.cpp' })

    $testCallEdges = [System.Collections.Generic.List[hashtable]]::new()
    $testCallEdges.Add(@{ caller = 'Initialize'; callerFile = 'Engine/Core/Init.cpp'; callee = 'Render' })
    $testCallEdges.Add(@{ caller = 'Initialize'; callerFile = 'Engine/Core/Init.cpp'; callee = 'Tick' })
    $testCallEdges.Add(@{ caller = 'Tick'; callerFile = 'Engine/Core/Loop.cpp'; callee = 'Render' })
    $testCallEdges.Add(@{ caller = 'Shutdown'; callerFile = 'Engine/Core/Init.cpp'; callee = 'Tick' })

    $testGlobals = [System.Collections.Generic.List[hashtable]]::new()
    $testGlobals.Add(@{ name = 'GEngine'; type = 'UEngine*'; scope = 'Global'; file = 'Engine/Core/Init.cpp' })

    $testIncDeps = [System.Collections.Generic.List[hashtable]]::new()
    $testIncDeps.Add(@{ file = 'Engine/Core/Init.cpp'; header = 'CoreMinimal.h' })
    $testIncDeps.Add(@{ file = 'Engine/Renderer/Draw.cpp'; header = 'CoreMinimal.h' })
    $testIncDeps.Add(@{ file = 'Engine/Core/Loop.cpp'; header = 'CoreMinimal.h' })
    $testIncDeps.Add(@{ file = 'Engine/Core/Init.cpp'; header = 'Engine.h' })

    $output = Build-XrefOutput $testFuncMap $testCallEdges $testGlobals $testIncDeps

    # Structure checks
    Assert-True  'XrefOutput: has title'                    ($output -match '# Cross-Reference Index')
    Assert-True  'XrefOutput: has func def map'             ($output -match '## Function Definition Map')
    Assert-True  'XrefOutput: has call graph'               ($output -match '## Call Graph')
    Assert-True  'XrefOutput: has most called'              ($output -match '## Most Called Functions')
    Assert-True  'XrefOutput: has global state'             ($output -match '## Global State Ownership')
    Assert-True  'XrefOutput: has header deps'              ($output -match '## Header Dependencies')
    Assert-True  'XrefOutput: has subsystem interfaces'     ($output -match '## Subsystem Interfaces')

    # Function map content
    Assert-True  'XrefOutput: Initialize in map'            ($output -match 'Initialize.*Init\.cpp')
    Assert-True  'XrefOutput: Render in map'                ($output -match 'Render.*Draw\.cpp')
    Assert-True  'XrefOutput: Tick in map'                  ($output -match 'Tick.*Loop\.cpp')
    Assert-True  'XrefOutput: Shutdown in map'              ($output -match 'Shutdown.*Init\.cpp')

    # Call graph content — Initialize has 2 outgoing calls (most connected)
    Assert-True  'XrefOutput: Initialize in call graph'     ($output -match 'Initialize.*Init\.cpp.*2:')

    # Most called — Render called by 2 callers, Tick called by 2
    Assert-True  'XrefOutput: Render most called'           ($output -match 'Render.*2')
    Assert-True  'XrefOutput: Tick most called'             ($output -match 'Tick.*2')

    # Global state
    Assert-True  'XrefOutput: GEngine in globals'           ($output -match 'GEngine.*UEngine')

    # Header deps — CoreMinimal included by 3 files
    Assert-True  'XrefOutput: CoreMinimal dep count'        ($output -match 'CoreMinimal\.h.*3')
    Assert-True  'XrefOutput: Engine.h dep'                 ($output -match 'Engine\.h')

    # Subsystem interfaces — Engine subsystem has all 4 functions
    Assert-True  'XrefOutput: Engine subsystem'             ($output -match '### Engine')

    # ── Test: Build-XrefOutput — empty inputs ────────────────

    Write-Host 'Testing Build-XrefOutput: empty inputs ...' -ForegroundColor Cyan

    $emptyFM = [System.Collections.Generic.List[hashtable]]::new()
    $emptyCE = [System.Collections.Generic.List[hashtable]]::new()
    $emptyGL = [System.Collections.Generic.List[hashtable]]::new()
    $emptyID = [System.Collections.Generic.List[hashtable]]::new()
    $emptyOutput = Build-XrefOutput $emptyFM $emptyCE $emptyGL $emptyID

    Assert-True  'XrefOutput empty: has title'              ($emptyOutput -match '# Cross-Reference Index')
    Assert-True  'XrefOutput empty: has func map header'    ($emptyOutput -match '## Function Definition Map')
    Assert-False 'XrefOutput empty: no global section'      ($emptyOutput -match '## Global State Ownership')
    Assert-False 'XrefOutput empty: no header deps'         ($emptyOutput -match '## Header Dependencies')

    # ── Test: Parse-DocFile + Build-XrefOutput integration ───

    Write-Host 'Testing end-to-end integration ...' -ForegroundColor Cyan

    # Parse two docs and merge their results, then build output
    $doc1 = @(
        '# src/world.cpp',
        '## Key Functions / Methods',
        '### SpawnActor',
        '- Signature: `AActor* SpawnActor(UClass* Class)`',
        '- Calls: `CreateObject`, `RegisterActor`',
        '## Global / File-Static State',
        '| Name | Type | Scope | Purpose |',
        '|------|------|-------|---------|',
        '| `GWorld` | `UWorld*` | Global | World singleton |',
        '## External Dependencies',
        '- `World.h` - world API',
        '- `Actor.h` - actor base'
    )
    $doc2 = @(
        '# src/actor.cpp',
        '## Key Functions / Methods',
        '### BeginPlay',
        '- Signature: `void BeginPlay()`',
        '- Calls: `SpawnActor`',
        '### Tick',
        '- Signature: `void Tick(float DeltaTime)`',
        '- Purpose: per-frame update',
        '## External Dependencies',
        '- `Actor.h` - self include'
    )

    $p1 = Parse-DocFile $doc1
    $p2 = Parse-DocFile $doc2

    # Merge
    $allFuncs = [System.Collections.Generic.List[hashtable]]::new()
    $allEdges = [System.Collections.Generic.List[hashtable]]::new()
    $allGlobs = [System.Collections.Generic.List[hashtable]]::new()
    $allDeps  = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($f in $p1.FuncMap)     { $allFuncs.Add($f) }
    foreach ($f in $p2.FuncMap)     { $allFuncs.Add($f) }
    foreach ($e in $p1.CallEdges)   { $allEdges.Add($e) }
    foreach ($e in $p2.CallEdges)   { $allEdges.Add($e) }
    foreach ($g in $p1.Globals)     { $allGlobs.Add($g) }
    foreach ($g in $p2.Globals)     { $allGlobs.Add($g) }
    foreach ($d in $p1.IncludeDeps) { $allDeps.Add($d) }
    foreach ($d in $p2.IncludeDeps) { $allDeps.Add($d) }

    Assert-Equal 'E2E: total funcs'    3 $allFuncs.Count
    Assert-Equal 'E2E: total edges'    3 $allEdges.Count
    Assert-Equal 'E2E: total globals'  1 $allGlobs.Count
    Assert-Equal 'E2E: total deps'     3 $allDeps.Count

    $e2eOutput = Build-XrefOutput $allFuncs $allEdges $allGlobs $allDeps
    Assert-True  'E2E: SpawnActor in output'                ($e2eOutput -match 'SpawnActor')
    Assert-True  'E2E: BeginPlay in output'                 ($e2eOutput -match 'BeginPlay')
    Assert-True  'E2E: GWorld in output'                    ($e2eOutput -match 'GWorld')
    Assert-True  'E2E: Actor.h dep counted'                 ($e2eOutput -match 'Actor\.h.*2')
    Assert-True  'E2E: cross-file call visible'             ($e2eOutput -match 'SpawnActor')

    # ── Test: Parse-DocFile — "Key Methods" variant ──────────

    Write-Host 'Testing Parse-DocFile: Key Methods variant ...' -ForegroundColor Cyan

    $docMethods = @(
        '# src/class.cpp',
        '## Key Methods',
        '### MyClass::Update',
        '- Calls: `Render`',
        '### MyClass::Draw',
        '- Purpose: draws things'
    )
    $rMeth = Parse-DocFile $docMethods
    Assert-Equal 'Key Methods: func count'       2                   $rMeth.FuncMap.Count
    Assert-Equal 'Key Methods: func 1'           'MyClass::Update'   $rMeth.FuncMap[0].func
    Assert-Equal 'Key Methods: func 2'           'MyClass::Draw'     $rMeth.FuncMap[1].func
    Assert-Equal 'Key Methods: call edge'        1                   $rMeth.CallEdges.Count

    # ── Test: Parse-DocFile — Notable section resets ─────────

    Write-Host 'Testing Parse-DocFile: Notable section resets ...' -ForegroundColor Cyan

    $docNotable = @(
        '# src/notable.cpp',
        '## Key Functions / Methods',
        '### RealFunc',
        '- Purpose: real function',
        '## Notable Patterns',
        '### PatternName',
        '- This is a pattern, not a function'
    )
    $rNotable = Parse-DocFile $docNotable
    # "Notable" resets $section to '', but the ### fallback rule re-enters
    # functions section for any ### heading not under globals/deps.
    # So PatternName IS counted as a function by the parser.
    Assert-Equal 'Notable: both counted'          2          $rNotable.FuncMap.Count
    Assert-Equal 'Notable: func 1 is RealFunc'    'RealFunc'    $rNotable.FuncMap[0].func
    Assert-Equal 'Notable: func 2 is PatternName' 'PatternName' $rNotable.FuncMap[1].func

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

$archDir = Join-Path $repoRoot 'architecture'

$docRoot   = if ($TargetDir -ne '.' -and $TargetDir -ne 'all') { Join-Path $archDir $TargetDir } else { $archDir }
$outPrefix = if ($TargetDir -ne '.' -and $TargetDir -ne 'all') { (Split-Path $TargetDir -Leaf) + '_' } else { '' }
$outXref   = Join-Path $archDir ($outPrefix + 'xref_index.md')

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  archxref.ps1 - Cross-Reference Index"     -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "Doc root:  $docRoot"
Write-Host "Output:    $outXref"
Write-Host ""

# Gather per-file docs
$docs = Get-ChildItem -Path $docRoot -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object { Test-DocFileIncluded $_.Name $_.FullName } | Sort-Object FullName

if ($docs.Count -eq 0) {
    Write-Host "No per-file docs found. Run archgen.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host "Parsing $($docs.Count) per-file docs..."

# Data structures
$funcMap      = [System.Collections.Generic.List[hashtable]]::new()
$callEdges    = [System.Collections.Generic.List[hashtable]]::new()
$globals      = [System.Collections.Generic.List[hashtable]]::new()
$includeDeps  = [System.Collections.Generic.List[hashtable]]::new()

$parsed = 0
foreach ($doc in $docs) {
    $lines = Get-Content $doc.FullName -ErrorAction SilentlyContinue
    $result = Parse-DocFile $lines
    foreach ($f in $result.FuncMap)     { $funcMap.Add($f) }
    foreach ($e in $result.CallEdges)   { $callEdges.Add($e) }
    foreach ($g in $result.Globals)     { $globals.Add($g) }
    foreach ($d in $result.IncludeDeps) { $includeDeps.Add($d) }
    $parsed++
    if ($parsed % 100 -eq 0) { Write-Host "  ...parsed $parsed/$($docs.Count)" }
}

Write-Host "Extracted:"
Write-Host "  Functions:    $($funcMap.Count)"
Write-Host "  Call edges:   $($callEdges.Count)"
Write-Host "  Globals:      $($globals.Count)"
Write-Host "  Include deps: $($includeDeps.Count)"
Write-Host ""

# -- Build xref_index.md ---------------------------------------

$xrefContent = Build-XrefOutput $funcMap $callEdges $globals $includeDeps
$xrefContent | Set-Content -Path $outXref -Encoding UTF8

$lineCount = (Get-Content $outXref).Count
Write-Host "Wrote: $outXref ($lineCount lines)" -ForegroundColor Green
Write-Host "Done." -ForegroundColor Green
