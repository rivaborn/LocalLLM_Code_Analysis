# ============================================================
# archgraph.ps1 - Call Graph & Dependency Diagram Generator
#
# Parses per-file architecture docs (from archgen.ps1) and produces
# Mermaid diagrams:
#   architecture/callgraph.mermaid       - function-level call graph
#   architecture/subsystems.mermaid      - subsystem dependency diagram
#   architecture/callgraph.md            - both diagrams in markdown
#
# No Claude calls - pure text processing. Fast even on 1000+ files.
# Run after archgen.ps1 (and optionally archxref.ps1).
#
# Usage:
#   .\archgraph.ps1 [-TargetDir <subsystem>] [-MaxCallEdges <n>] [-MinCallSignificance <n>]
#   .\archgraph.ps1 -Test
# ============================================================

[CmdletBinding()]
param(
    [string]$TargetDir           = ".",
    [int]   $MaxCallEdges        = 150,
    [int]   $MinCallSignificance = 2,
    [string]$EnvFile             = ".env",
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

function SanitizeId($name) { $name -replace '[^A-Za-z0-9_]','_' }

function Parse-GraphDoc($lines) {
    $result = @{
        FilePath  = ''
        Subsystem = 'root'
        FuncFile  = [System.Collections.Generic.List[hashtable]]::new()
        Edges     = [System.Collections.Generic.List[hashtable]]::new()
    }

    if (-not $lines -or $lines.Count -eq 0) { return $result }

    $filePath    = ''
    $subsystem   = 'root'
    $section     = ''
    $currentFunc = ''

    foreach ($line in $lines) {
        if ($filePath -eq '' -and $line -match '^# (.+)') {
            $filePath = $Matches[1].Trim()
            $parts = $filePath -split '/', 2
            $subsystem = if ($parts.Count -ge 2) { $parts[0] } else { 'root' }
            $result.FilePath  = $filePath
            $result.Subsystem = $subsystem
            continue
        }

        if ($line -match '^## Key (Functions|Methods)')   { $section = 'functions'; $currentFunc = ''; continue }
        if ($line -match '^## (Global|File-Static)')       { $section = ''; continue }
        if ($line -match '^## (External|Control|File Purpose|Core Resp|Key Types)') { $section = ''; continue }

        if ($line -match '^### ' -and $section -ne 'globals') { $section = 'functions' }

        if ($section -eq 'functions' -and $line -match '^### (.+)') {
            $currentFunc = $Matches[1].Trim() -replace '`','' -replace '\*',''
            if ($filePath -ne '') {
                $result.FuncFile.Add(@{ func = $currentFunc; file = $filePath; sub = $subsystem })
            }
            continue
        }

        if ($section -eq 'functions' -and $currentFunc -ne '' -and $line -match '^- ' -and $line -imatch 'calls?[^a-z]') {
            $m = [regex]::Matches($line, '`([A-Za-z_][A-Za-z0-9_]*)`')
            foreach ($match in $m) {
                $result.Edges.Add(@{ caller = $currentFunc; callee = $match.Groups[1].Value; sub = $subsystem })
            }
        }
    }

    return $result
}

function Get-SignificantFunctions($edges, $minCallSignificance) {
    $calleeCounts = @{}
    foreach ($e in $edges) {
        if (-not $calleeCounts.ContainsKey($e.callee)) { $calleeCounts[$e.callee] = 0 }
        $calleeCounts[$e.callee]++
    }

    $significant = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($kv in $calleeCounts.GetEnumerator()) {
        if ($kv.Value -ge $minCallSignificance) { $significant.Add($kv.Key) | Out-Null }
    }
    foreach ($e in $edges) { $significant.Add($e.caller) | Out-Null }

    return ,$significant
}

function Build-CallGraph($funcFile, $edges, $significant, $maxCallEdges) {
    $cgSb = [System.Text.StringBuilder]::new()
    $cgSb.AppendLine("%%{ init: { 'theme': 'dark', 'flowchart': { 'curve': 'basis' } } }%%") | Out-Null
    $cgSb.AppendLine("graph LR") | Out-Null
    $cgSb.AppendLine("") | Out-Null

    $subsystems = @($funcFile | ForEach-Object { $_.sub } | Sort-Object -Unique)
    foreach ($sub in $subsystems) {
        $cgSb.AppendLine("  subgraph $sub") | Out-Null
        $funcsInSub = $funcFile | Where-Object { $_.sub -eq $sub } | ForEach-Object { $_.func } | Sort-Object -Unique
        foreach ($func in $funcsInSub) {
            if ($significant.Contains($func)) {
                $nodeId = SanitizeId $func
                $cgSb.AppendLine("    ${nodeId}[`"${func}`"]") | Out-Null
            }
        }
        $cgSb.AppendLine("  end") | Out-Null
        $cgSb.AppendLine("") | Out-Null
    }

    $edgeCount = 0
    $seenEdges = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($e in $edges) {
        if ($edgeCount -ge $maxCallEdges) { break }
        if (-not $significant.Contains($e.caller)) { continue }
        if (-not $significant.Contains($e.callee)) { continue }
        $callerId = SanitizeId $e.caller
        $calleeId = SanitizeId $e.callee
        if ($callerId -eq $calleeId) { continue }
        $key = "${callerId}__${calleeId}"
        if ($seenEdges.Contains($key)) { continue }
        $seenEdges.Add($key) | Out-Null
        $cgSb.AppendLine("  $callerId --> $calleeId") | Out-Null
        $edgeCount++
    }

    return $cgSb.ToString()
}

function Get-CrossSubsystemEdges($edges, $funcFile) {
    $funcSub = @{}
    foreach ($entry in $funcFile) {
        if (-not $funcSub.ContainsKey($entry.func)) { $funcSub[$entry.func] = $entry.sub }
    }

    $crossEdges = @{}
    foreach ($e in $edges) {
        $calleeSub = if ($funcSub.ContainsKey($e.callee)) { $funcSub[$e.callee] } else { $null }
        if ($calleeSub -and $calleeSub -ne $e.sub) {
            $key = "$($e.sub)`t$calleeSub"
            if (-not $crossEdges.ContainsKey($key)) { $crossEdges[$key] = 0 }
            $crossEdges[$key]++
        }
    }

    return $crossEdges
}

function Build-SubsystemDiagram($funcFile, $crossEdges) {
    $subFuncCount = @{}
    foreach ($entry in $funcFile) {
        if (-not $subFuncCount.ContainsKey($entry.sub)) { $subFuncCount[$entry.sub] = 0 }
        $subFuncCount[$entry.sub]++
    }

    $ssSb = [System.Text.StringBuilder]::new()
    $ssSb.AppendLine("%%{ init: { 'theme': 'dark' } }%%") | Out-Null
    $ssSb.AppendLine("graph TD") | Out-Null
    $ssSb.AppendLine("") | Out-Null

    foreach ($kv in ($subFuncCount.GetEnumerator() | Sort-Object { -$_.Value })) {
        $subId = SanitizeId $kv.Key
        $ssSb.AppendLine("  ${subId}[`"$($kv.Key) ($($kv.Value) funcs)`"]") | Out-Null
    }
    $ssSb.AppendLine("") | Out-Null

    $crossEdges.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First 50 | ForEach-Object {
        $parts  = $_.Key -split "`t", 2
        $fromId = SanitizeId $parts[0]
        $toId   = SanitizeId $parts[1]
        if ($fromId -ne $toId) {
            $ssSb.AppendLine("  $fromId -->|$($_.Value) calls| $toId") | Out-Null
        }
    }

    return $ssSb.ToString()
}

function Build-CombinedMarkdown($callgraphMermaid, $subsystemsMermaid, $funcCount, $edgeCount, $subsystemCount, $minSig, $maxEdges) {
    $mdSb = [System.Text.StringBuilder]::new()
    $mdSb.AppendLine("# Call Graph & Dependency Diagrams") | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine("Auto-generated from per-file architecture docs.") | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine("## Function Call Graph") | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine("Showing functions with $minSig+ incoming calls. Limited to $maxEdges edges.") | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine('```mermaid') | Out-Null
    $mdSb.Append($callgraphMermaid) | Out-Null
    $mdSb.AppendLine('```') | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine("## Subsystem Dependencies") | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine("Cross-subsystem call edges. Arrow labels show call counts.") | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine('```mermaid') | Out-Null
    $mdSb.Append($subsystemsMermaid) | Out-Null
    $mdSb.AppendLine('```') | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine("## Statistics") | Out-Null
    $mdSb.AppendLine("") | Out-Null
    $mdSb.AppendLine("- Total functions documented: $funcCount") | Out-Null
    $mdSb.AppendLine("- Total call edges: $edgeCount") | Out-Null
    $mdSb.AppendLine("- Subsystems: $subsystemCount") | Out-Null

    return $mdSb.ToString()
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
    Write-Host '  archgraph.ps1 - Unit Tests' -ForegroundColor Yellow
    Write-Host '============================================' -ForegroundColor Yellow
    Write-Host ''

    # ── Test: SanitizeId ──────────────────────────────────────

    Write-Host 'Testing SanitizeId ...' -ForegroundColor Cyan

    Assert-Equal 'SanitizeId: simple name'         'DoWork'          (SanitizeId 'DoWork')
    Assert-Equal 'SanitizeId: with colons'         'FMath__Clamp'    (SanitizeId 'FMath::Clamp')
    Assert-Equal 'SanitizeId: with spaces'         'My_Func'         (SanitizeId 'My Func')
    Assert-Equal 'SanitizeId: with parens'         'Init_int_'       (SanitizeId 'Init(int)')
    Assert-Equal 'SanitizeId: with angle brackets' 'TArray_int_'     (SanitizeId 'TArray<int>')
    Assert-Equal 'SanitizeId: with tilde'          '_Destructor'     (SanitizeId '~Destructor')
    Assert-Equal 'SanitizeId: underscore preserved' 'my_func_name'  (SanitizeId 'my_func_name')
    Assert-Equal 'SanitizeId: numbers preserved'    'Func123'        (SanitizeId 'Func123')
    Assert-Equal 'SanitizeId: all special chars'    '___'             (SanitizeId '!@#')
    Assert-Equal 'SanitizeId: empty string'         ''                (SanitizeId '')

    # ── Test: Parse-GraphDoc — basic extraction ───────────────

    Write-Host 'Testing Parse-GraphDoc: basic extraction ...' -ForegroundColor Cyan

    $doc1 = @(
        '# Engine/Source/Runtime/Core/Private/Math.cpp',
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
        '- Calls: `RandInit`'
    )

    $r1 = Parse-GraphDoc $doc1
    Assert-Equal 'Parse basic: file path'         'Engine/Source/Runtime/Core/Private/Math.cpp' $r1.FilePath
    Assert-Equal 'Parse basic: subsystem'         'Engine' $r1.Subsystem
    Assert-Equal 'Parse basic: func count'        2  $r1.FuncFile.Count
    Assert-Equal 'Parse basic: func 1 name'       'RandInit'  $r1.FuncFile[0].func
    Assert-Equal 'Parse basic: func 1 sub'        'Engine'    $r1.FuncFile[0].sub
    Assert-Equal 'Parse basic: func 2 name'       'RandHelper' $r1.FuncFile[1].func
    Assert-Equal 'Parse basic: edge count'        3  $r1.Edges.Count
    Assert-Equal 'Parse basic: edge 1 caller'     'RandInit'   $r1.Edges[0].caller
    Assert-Equal 'Parse basic: edge 1 callee'     'SetSeed'    $r1.Edges[0].callee
    Assert-Equal 'Parse basic: edge 1 sub'        'Engine'     $r1.Edges[0].sub
    Assert-Equal 'Parse basic: edge 3 callee'     'RandInit'   $r1.Edges[2].callee

    # ── Test: Parse-GraphDoc — subsystem detection ────────────

    Write-Host 'Testing Parse-GraphDoc: subsystem detection ...' -ForegroundColor Cyan

    $docSub1 = @('# Renderer/Private/Draw.cpp', '## Key Functions', '### Render', '- Purpose: draws')
    $rSub1 = Parse-GraphDoc $docSub1
    Assert-Equal 'Subsystem: Renderer'            'Renderer' $rSub1.Subsystem

    $docSub2 = @('# standalone.cpp', '## Key Functions', '### Main', '- Purpose: entry point')
    $rSub2 = Parse-GraphDoc $docSub2
    Assert-Equal 'Subsystem: root for no slash'   'root' $rSub2.Subsystem

    $docSub3 = @('# Engine/Source/Runtime/AIModule/Private/BT.cpp', '## Key Functions', '### Tick', '- Purpose: tick')
    $rSub3 = Parse-GraphDoc $docSub3
    Assert-Equal 'Subsystem: first component'     'Engine' $rSub3.Subsystem

    # ── Test: Parse-GraphDoc — section transitions ────────────

    Write-Host 'Testing Parse-GraphDoc: section transitions ...' -ForegroundColor Cyan

    $docTransitions = @(
        '# src/file.cpp',
        '## File Purpose',
        'Purpose text.',
        '## Core Responsibilities',
        '- Resp 1',
        '## Key Types / Data Structures',
        '### MyStruct',
        '- A struct',
        '## Key Functions / Methods',
        '### DoWork',
        '- Calls: `Helper`',
        '## Global / File-Static State',
        '| Name | Type | Scope | Purpose |',
        '## External Dependencies',
        '- `Header.h`',
        '## Control Flow',
        '### NotAFunction',
        '- Sequential flow'
    )
    $rTrans = Parse-GraphDoc $docTransitions
    # ### headings under reset sections (Key Types, Control) still trigger
    # the fallback rule: if section != globals && section != deps, set section = functions.
    # So MyStruct, DoWork, and NotAFunction are all counted as functions.
    Assert-Equal 'Transitions: func count'        3  $rTrans.FuncFile.Count
    Assert-Equal 'Transitions: DoWork found'      'DoWork' $rTrans.FuncFile[1].func
    Assert-Equal 'Transitions: edge count'        1  $rTrans.Edges.Count

    # ── Test: Parse-GraphDoc — empty/null ─────────────────────

    Write-Host 'Testing Parse-GraphDoc: edge cases ...' -ForegroundColor Cyan

    $rEmpty = Parse-GraphDoc @()
    Assert-Equal 'Parse empty: file path'         '' $rEmpty.FilePath
    Assert-Equal 'Parse empty: no funcs'          0  $rEmpty.FuncFile.Count
    Assert-Equal 'Parse empty: no edges'          0  $rEmpty.Edges.Count

    $rNull = Parse-GraphDoc $null
    Assert-Equal 'Parse null: no funcs'           0  $rNull.FuncFile.Count

    # ── Test: Parse-GraphDoc — backtick/bold func names ───────

    Write-Host 'Testing Parse-GraphDoc: func name formatting ...' -ForegroundColor Cyan

    $docFmt = @(
        '# src/fmt.cpp',
        '## Key Functions',
        '### `TickedFunc`',
        '- Purpose: test',
        '### **BoldFunc**',
        '- Purpose: test'
    )
    $rFmt = Parse-GraphDoc $docFmt
    Assert-Equal 'Fmt: backtick stripped'         'TickedFunc' $rFmt.FuncFile[0].func
    Assert-Equal 'Fmt: bold stripped'             'BoldFunc'   $rFmt.FuncFile[1].func

    # ── Test: Get-SignificantFunctions ─────────────────────────

    Write-Host 'Testing Get-SignificantFunctions ...' -ForegroundColor Cyan

    $testEdges = [System.Collections.Generic.List[hashtable]]::new()
    # A calls B (x3), A calls C (x1), D calls B (x1)
    $testEdges.Add(@{ caller = 'FuncA'; callee = 'FuncB'; sub = 'Core' })
    $testEdges.Add(@{ caller = 'FuncA'; callee = 'FuncB'; sub = 'Core' })
    $testEdges.Add(@{ caller = 'FuncA'; callee = 'FuncB'; sub = 'Core' })
    $testEdges.Add(@{ caller = 'FuncA'; callee = 'FuncC'; sub = 'Core' })
    $testEdges.Add(@{ caller = 'FuncD'; callee = 'FuncB'; sub = 'Core' })

    # MinCallSignificance = 2: FuncB (called 4x) is significant as callee
    # FuncA and FuncD are significant as callers
    # FuncC (called 1x) is NOT significant as callee but also not a caller
    $sig2 = Get-SignificantFunctions $testEdges 2
    Assert-True  'Significant: FuncA (caller)'       $sig2.Contains('FuncA')
    Assert-True  'Significant: FuncB (callee 4x)'    $sig2.Contains('FuncB')
    Assert-True  'Significant: FuncD (caller)'        $sig2.Contains('FuncD')
    Assert-False 'Significant: FuncC not sig (1x)'    $sig2.Contains('FuncC')

    # MinCallSignificance = 1: FuncC now significant
    $sig1 = Get-SignificantFunctions $testEdges 1
    Assert-True  'Significant min=1: FuncC now sig'   $sig1.Contains('FuncC')
    Assert-True  'Significant min=1: FuncB still sig'  $sig1.Contains('FuncB')

    # MinCallSignificance = 5: only callers, no callees meet threshold
    $sig5 = Get-SignificantFunctions $testEdges 5
    Assert-True  'Significant min=5: FuncA (caller)'  $sig5.Contains('FuncA')
    Assert-True  'Significant min=5: FuncD (caller)'  $sig5.Contains('FuncD')
    Assert-False 'Significant min=5: FuncB not sig'   $sig5.Contains('FuncB')

    # Empty edges
    $emptyEdges = [System.Collections.Generic.List[hashtable]]::new()
    $sigEmpty = Get-SignificantFunctions $emptyEdges 2
    Assert-Equal 'Significant empty: count 0'         0 $sigEmpty.Count

    # ── Test: Build-CallGraph ─────────────────────────────────

    Write-Host 'Testing Build-CallGraph ...' -ForegroundColor Cyan

    $cgFuncs = [System.Collections.Generic.List[hashtable]]::new()
    $cgFuncs.Add(@{ func = 'Init';   file = 'Core/Init.cpp';   sub = 'Core' })
    $cgFuncs.Add(@{ func = 'Render'; file = 'Render/Draw.cpp'; sub = 'Render' })
    $cgFuncs.Add(@{ func = 'Tick';   file = 'Core/Loop.cpp';   sub = 'Core' })

    $cgEdges = [System.Collections.Generic.List[hashtable]]::new()
    $cgEdges.Add(@{ caller = 'Init';   callee = 'Render'; sub = 'Core' })
    $cgEdges.Add(@{ caller = 'Init';   callee = 'Tick';   sub = 'Core' })
    $cgEdges.Add(@{ caller = 'Tick';   callee = 'Render'; sub = 'Core' })

    $allSig = [System.Collections.Generic.HashSet[string]]::new()
    $allSig.Add('Init')   | Out-Null
    $allSig.Add('Render') | Out-Null
    $allSig.Add('Tick')   | Out-Null

    $cg = Build-CallGraph $cgFuncs $cgEdges $allSig 150
    Assert-True  'CallGraph: has mermaid header'      ($cg -match 'graph LR')
    Assert-True  'CallGraph: has Core subgraph'       ($cg -match 'subgraph Core')
    Assert-True  'CallGraph: has Render subgraph'     ($cg -match 'subgraph Render')
    Assert-True  'CallGraph: Init node present'       ($cg -match 'Init\[')
    Assert-True  'CallGraph: Render node present'     ($cg -match 'Render\[')
    Assert-True  'CallGraph: Tick node present'       ($cg -match 'Tick\[')
    Assert-True  'CallGraph: Init->Render edge'       ($cg -match 'Init --> Render')
    Assert-True  'CallGraph: Init->Tick edge'         ($cg -match 'Init --> Tick')
    Assert-True  'CallGraph: Tick->Render edge'       ($cg -match 'Tick --> Render')
    Assert-True  'CallGraph: has theme config'        ($cg -match 'theme.*dark')

    # Self-call edges should be excluded
    $cgSelfEdges = [System.Collections.Generic.List[hashtable]]::new()
    $cgSelfEdges.Add(@{ caller = 'Recurse'; callee = 'Recurse'; sub = 'Core' })
    $selfSig = [System.Collections.Generic.HashSet[string]]::new()
    $selfSig.Add('Recurse') | Out-Null
    $selfFuncs = [System.Collections.Generic.List[hashtable]]::new()
    $selfFuncs.Add(@{ func = 'Recurse'; file = 'Core/Rec.cpp'; sub = 'Core' })
    $cgSelf = Build-CallGraph $selfFuncs $cgSelfEdges $selfSig 150
    Assert-False 'CallGraph: no self-edge'            ($cgSelf -match 'Recurse --> Recurse')

    # Duplicate edges should be deduplicated
    $cgDupEdges = [System.Collections.Generic.List[hashtable]]::new()
    $cgDupEdges.Add(@{ caller = 'Init'; callee = 'Render'; sub = 'Core' })
    $cgDupEdges.Add(@{ caller = 'Init'; callee = 'Render'; sub = 'Core' })
    $cgDupEdges.Add(@{ caller = 'Init'; callee = 'Render'; sub = 'Core' })
    $cgDup = Build-CallGraph $cgFuncs $cgDupEdges $allSig 150
    $dupEdgeMatches = [regex]::Matches($cgDup, 'Init --> Render')
    Assert-Equal 'CallGraph: dedup edges'             1 $dupEdgeMatches.Count

    # MaxCallEdges limit
    $cgMany = Build-CallGraph $cgFuncs $cgEdges $allSig 1
    $manyEdgeMatches = [regex]::Matches($cgMany, ' --> ')
    Assert-Equal 'CallGraph: max 1 edge'              1 $manyEdgeMatches.Count

    # Non-significant functions excluded
    $partialSig = [System.Collections.Generic.HashSet[string]]::new()
    $partialSig.Add('Init')   | Out-Null
    $partialSig.Add('Render') | Out-Null
    # Tick is NOT significant
    $cgPartial = Build-CallGraph $cgFuncs $cgEdges $partialSig 150
    Assert-False 'CallGraph: non-sig Tick excluded'   ($cgPartial -match 'Init --> Tick')
    Assert-True  'CallGraph: sig Init->Render kept'   ($cgPartial -match 'Init --> Render')

    # ── Test: Get-CrossSubsystemEdges ─────────────────────────

    Write-Host 'Testing Get-CrossSubsystemEdges ...' -ForegroundColor Cyan

    $cssFuncs = [System.Collections.Generic.List[hashtable]]::new()
    $cssFuncs.Add(@{ func = 'Init';   file = 'Core/Init.cpp';      sub = 'Core' })
    $cssFuncs.Add(@{ func = 'Render'; file = 'Renderer/Draw.cpp';  sub = 'Renderer' })
    $cssFuncs.Add(@{ func = 'Tick';   file = 'Core/Loop.cpp';      sub = 'Core' })
    $cssFuncs.Add(@{ func = 'Audio';  file = 'Audio/Mix.cpp';      sub = 'Audio' })

    $cssEdges = [System.Collections.Generic.List[hashtable]]::new()
    # Core -> Renderer (x2)
    $cssEdges.Add(@{ caller = 'Init'; callee = 'Render'; sub = 'Core' })
    $cssEdges.Add(@{ caller = 'Tick'; callee = 'Render'; sub = 'Core' })
    # Core -> Audio (x1)
    $cssEdges.Add(@{ caller = 'Init'; callee = 'Audio';  sub = 'Core' })
    # Intra-subsystem (Core -> Core) — should NOT appear
    $cssEdges.Add(@{ caller = 'Init'; callee = 'Tick';   sub = 'Core' })

    $cross = Get-CrossSubsystemEdges $cssEdges $cssFuncs
    Assert-Equal 'CrossSub: 2 unique cross edges'    2 $cross.Count
    $coreToRenderer = $cross["Core`tRenderer"]
    Assert-Equal 'CrossSub: Core->Renderer count'    2 $coreToRenderer
    $coreToAudio = $cross["Core`tAudio"]
    Assert-Equal 'CrossSub: Core->Audio count'       1 $coreToAudio

    # No intra-subsystem edge
    Assert-False 'CrossSub: no Core->Core'            ($cross.ContainsKey("Core`tCore"))

    # Unknown callee (not in funcFile) is ignored
    $cssEdgesUnknown = [System.Collections.Generic.List[hashtable]]::new()
    $cssEdgesUnknown.Add(@{ caller = 'Init'; callee = 'Unknown'; sub = 'Core' })
    $crossUnknown = Get-CrossSubsystemEdges $cssEdgesUnknown $cssFuncs
    Assert-Equal 'CrossSub: unknown callee ignored'   0 $crossUnknown.Count

    # ── Test: Build-SubsystemDiagram ──────────────────────────

    Write-Host 'Testing Build-SubsystemDiagram ...' -ForegroundColor Cyan

    $ssDiagram = Build-SubsystemDiagram $cssFuncs $cross
    Assert-True  'SubsDiagram: has mermaid header'    ($ssDiagram -match 'graph TD')
    Assert-True  'SubsDiagram: Core node'             ($ssDiagram -match 'Core.*funcs')
    Assert-True  'SubsDiagram: Renderer node'         ($ssDiagram -match 'Renderer.*funcs')
    Assert-True  'SubsDiagram: Audio node'            ($ssDiagram -match 'Audio.*funcs')
    Assert-True  'SubsDiagram: cross edge label'      ($ssDiagram -match '2 calls')
    Assert-True  'SubsDiagram: Core->Renderer edge'   ($ssDiagram -match 'Core -->.*Renderer')
    Assert-True  'SubsDiagram: theme config'          ($ssDiagram -match 'theme.*dark')

    # Func counts in node labels
    Assert-True  'SubsDiagram: Core 2 funcs'          ($ssDiagram -match 'Core \(2 funcs\)')
    Assert-True  'SubsDiagram: Renderer 1 funcs'      ($ssDiagram -match 'Renderer \(1 funcs\)')

    # Empty cross edges
    $emptyCross = @{}
    $ssEmpty = Build-SubsystemDiagram $cssFuncs $emptyCross
    Assert-True  'SubsDiagram empty: nodes present'   ($ssEmpty -match 'Core')
    Assert-False 'SubsDiagram empty: no edges'        ($ssEmpty -match ' -->\|')

    # ── Test: Build-CombinedMarkdown ──────────────────────────

    Write-Host 'Testing Build-CombinedMarkdown ...' -ForegroundColor Cyan

    $md = Build-CombinedMarkdown 'graph LR; A-->B' 'graph TD; C-->D' 42 15 3 2 150
    Assert-True  'Markdown: has title'                ($md -match '# Call Graph & Dependency Diagrams')
    Assert-True  'Markdown: has function call graph'  ($md -match '## Function Call Graph')
    Assert-True  'Markdown: has subsystem deps'       ($md -match '## Subsystem Dependencies')
    Assert-True  'Markdown: has statistics'            ($md -match '## Statistics')
    Assert-True  'Markdown: mermaid fence'             ($md -match '```mermaid')
    Assert-True  'Markdown: callgraph content'        ($md -match 'A-->B')
    Assert-True  'Markdown: subsystem content'        ($md -match 'C-->D')
    Assert-True  'Markdown: func count stat'          ($md -match '42')
    Assert-True  'Markdown: edge count stat'          ($md -match '15')
    Assert-True  'Markdown: subsystem count stat'     ($md -match '3')
    Assert-True  'Markdown: min sig in description'   ($md -match '2\+ incoming')
    Assert-True  'Markdown: max edges in description' ($md -match '150 edges')

    # ── Test: End-to-end integration ──────────────────────────

    Write-Host 'Testing end-to-end integration ...' -ForegroundColor Cyan

    $e2eDoc1 = @(
        '# Core/Private/Init.cpp',
        '## Key Functions',
        '### Initialize',
        '- Calls: `Render`, `PlayAudio`',
        '### Shutdown',
        '- Calls: `Render`'
    )
    $e2eDoc2 = @(
        '# Renderer/Private/Draw.cpp',
        '## Key Functions',
        '### Render',
        '- Calls: `SwapBuffers`',
        '### SwapBuffers',
        '- Purpose: present frame'
    )
    $e2eDoc3 = @(
        '# Audio/Private/Mix.cpp',
        '## Key Functions',
        '### PlayAudio',
        '- Calls: `Render`'
    )

    $p1 = Parse-GraphDoc $e2eDoc1
    $p2 = Parse-GraphDoc $e2eDoc2
    $p3 = Parse-GraphDoc $e2eDoc3

    # Merge
    $allFuncs = [System.Collections.Generic.List[hashtable]]::new()
    $allEdges = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($p in @($p1, $p2, $p3)) {
        foreach ($f in $p.FuncFile) { $allFuncs.Add($f) }
        foreach ($e in $p.Edges)    { $allEdges.Add($e) }
    }

    Assert-Equal 'E2E: total funcs'               5 $allFuncs.Count
    Assert-Equal 'E2E: total edges'               5 $allEdges.Count

    # Significance at min=2: Render (called 3x), all callers
    $e2eSig = Get-SignificantFunctions $allEdges 2
    Assert-True  'E2E sig: Render (3x callee)'       $e2eSig.Contains('Render')
    Assert-True  'E2E sig: Initialize (caller)'       $e2eSig.Contains('Initialize')
    Assert-True  'E2E sig: Shutdown (caller)'         $e2eSig.Contains('Shutdown')
    Assert-True  'E2E sig: PlayAudio (caller)'        $e2eSig.Contains('PlayAudio')
    Assert-False 'E2E sig: SwapBuffers (1x, not caller)' $e2eSig.Contains('SwapBuffers')

    # Cross-subsystem
    $e2eCross = Get-CrossSubsystemEdges $allEdges $allFuncs
    Assert-True  'E2E cross: Core->Renderer exists'  ($e2eCross.ContainsKey("Core`tRenderer"))
    Assert-Equal 'E2E cross: Core->Renderer = 2'     2 $e2eCross["Core`tRenderer"]
    Assert-True  'E2E cross: Audio->Renderer exists'  ($e2eCross.ContainsKey("Audio`tRenderer"))

    # Full pipeline
    $e2eCallgraph = Build-CallGraph $allFuncs $allEdges $e2eSig 150
    Assert-True  'E2E cg: has Init->Render'           ($e2eCallgraph -match 'Initialize --> Render')
    Assert-False 'E2E cg: no Init->SwapBuffers'       ($e2eCallgraph -match 'Initialize --> SwapBuffers')

    $e2eSubDiag = Build-SubsystemDiagram $allFuncs $e2eCross
    Assert-True  'E2E sub: Core->Renderer edge'       ($e2eSubDiag -match 'Core -->.*Renderer')

    $e2eMd = Build-CombinedMarkdown $e2eCallgraph $e2eSubDiag 5 4 3 2 150
    Assert-True  'E2E md: has statistics'             ($e2eMd -match 'Total functions documented: 5')
    Assert-True  'E2E md: has edge stat'              ($e2eMd -match 'Total call edges: 4')
    Assert-True  'E2E md: has subsystem stat'         ($e2eMd -match 'Subsystems: 3')

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
$outPrefix = if ($TargetDir -ne '.' -and $TargetDir -ne 'all') { (Split-Path $TargetDir -Leaf) + ' ' } else { '' }

$outCallgraph  = Join-Path $archDir ($outPrefix + 'callgraph.mermaid')
$outSubsystems = Join-Path $archDir ($outPrefix + 'subsystems.mermaid')
$outCallgraphMd = Join-Path $archDir ($outPrefix + 'callgraph.md')

Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  archgraph.ps1 - Call Graph Generator"     -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "Doc root:  $docRoot"
Write-Host "Max edges: $MaxCallEdges"
Write-Host ""

$docs = @(Get-ChildItem -Path $docRoot -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object {
        $n = $_.Name
        if ($_.FullName -match '[/\\]\.archgen_state[/\\]') { return $false }
        if ($_.FullName -match '[/\\]\.overview_state[/\\]') { return $false }
        if ($n -match '^(architecture|diagram_data|xref_index|callgraph)') { return $false }
        if ($n -match '\.pass2\.md$') { return $false }
        return $true
    } | Sort-Object FullName)

if ($docs.Count -eq 0) {
    Write-Host "No per-file docs found. Run archgen.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host "Parsing $($docs.Count) per-file docs..."

$funcFile = [System.Collections.Generic.List[hashtable]]::new()
$edges    = [System.Collections.Generic.List[hashtable]]::new()

$parsed = 0
foreach ($doc in $docs) {
    $lines = Get-Content $doc.FullName -ErrorAction SilentlyContinue
    $result = Parse-GraphDoc $lines
    foreach ($f in $result.FuncFile) { $funcFile.Add($f) }
    foreach ($e in $result.Edges)    { $edges.Add($e) }
    $parsed++
    if ($parsed % 100 -eq 0) { Write-Host "  ...parsed $parsed/$($docs.Count)" }
}

Write-Host "Found $($funcFile.Count) functions, $($edges.Count) call edges."

$significant = Get-SignificantFunctions $edges $MinCallSignificance

$callgraphMermaid = Build-CallGraph $funcFile $edges $significant $MaxCallEdges
$callgraphMermaid | Set-Content -Path $outCallgraph -Encoding UTF8
Write-Host "Wrote: $outCallgraph"

$crossEdges = Get-CrossSubsystemEdges $edges $funcFile
$subsystemsMermaid = Build-SubsystemDiagram $funcFile $crossEdges
$subsystemsMermaid | Set-Content -Path $outSubsystems -Encoding UTF8
Write-Host "Wrote: $outSubsystems"

$subsystems = @($funcFile | ForEach-Object { $_.sub } | Sort-Object -Unique)
$mdContent = Build-CombinedMarkdown $callgraphMermaid $subsystemsMermaid $funcFile.Count $edges.Count $subsystems.Count $MinCallSignificance $MaxCallEdges
$mdContent | Set-Content -Path $outCallgraphMd -Encoding UTF8
Write-Host "Wrote: $outCallgraphMd"
Write-Host ""
Write-Host "Done. View Mermaid diagrams in GitHub, VS Code, or mermaid.live" -ForegroundColor Green
