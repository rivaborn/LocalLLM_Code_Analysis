# Architecture Analysis Toolkit — Optimizations

Token optimization strategies for minimizing Claude API usage when analyzing large codebases (36K+ translation units). 28 optimizations across 4 versions.

**Baseline:** ~250M tokens for full UE analysis.

| Version | Optimizations | Cumulative Total Tokens | Reduction |
|---------|---------------|------------------------|-----------|
| v1      | 8 implemented | ~70M                   | 72%       |
| v2      | 6 implemented | ~30M                   | 88%       |
| v3      | 7 implemented | ~12M                   | 95%       |
| v4      | 1 implemented, 5 documented | ~6M (first run), ~0.7M (re-run) | 97.6-99.7% |

---

## Table of Contents

### v1 — Core Optimizations (8 implemented)
1. [Skip Generated and Trivial Files](#v1-1-skip-generated-and-trivial-files)
2. [Shared Header Analysis](#v1-2-shared-header-analysis)
3. [LSP-Guided Source Trimming](#v1-3-lsp-guided-source-trimming)
4. [Per-File Targeted Context in Pass 2](#v1-4-per-file-targeted-context-in-pass-2)
5. [Tiered Model Selection](#v1-5-tiered-model-selection)
6. [Batch Templated Files](#v1-6-batch-templated-files)
7. [Compressed Prompt Format](#v1-7-compressed-prompt-format)
8. [Adaptive Output Budget](#v1-8-adaptive-output-budget)

### v2 — Advanced Optimizations (6 implemented)
9. [Batch Small Files Into Single Calls](#v2-9-batch-small-files-into-single-calls)
10. [Shared Engine Knowledge Preamble](#v2-10-shared-engine-knowledge-preamble)
11. [Output Schema Pruning for Simple Files](#v2-11-output-schema-pruning-for-simple-files)
12. [Incremental Pass 2 (Delta-Only)](#v2-12-incremental-pass-2-delta-only)
13. [Source Elision With LSP Context](#v2-13-source-elision-with-lsp-context)
14. [Response Caching for Templated Patterns](#v2-14-response-caching-for-templated-patterns)

### v3 — Structural Pipeline Optimizations (7 implemented)
15. [Hard Output Cap via --max-tokens](#v3-15-hard-output-cap-via---max-tokens)
16. [Hierarchical Directory-First Analysis](#v3-16-hierarchical-directory-first-analysis)
17. [Semantic LSP Context Compression](#v3-17-semantic-lsp-context-compression)
18. [JSON Output Format](#v3-18-json-output-format)
19. [Per-Directory Shared Include Context](#v3-19-per-directory-shared-include-context)
20. [Incremental Overview Updates](#v3-20-incremental-overview-updates)
21. [Two-Phase Classification](#v3-21-two-phase-classification)

### v4 — Structural Rethinking (1 implemented, 5 not implemented)
22. [Prompt Caching (API-Level)](#v4-22-prompt-caching-api-level) -- IMPLEMENTED
23. [Diff-Based Incremental Re-Analysis](#v4-23-diff-based-incremental-re-analysis) -- NOT IMPLEMENTED
24. [On-Demand Progressive Analysis](#v4-24-on-demand-progressive-analysis) -- NOT IMPLEMENTED
25. [Cluster-Then-Analyze](#v4-25-cluster-then-analyze) -- NOT IMPLEMENTED
26. [Sampling-Based Architecture Overview](#v4-26-sampling-based-architecture-overview) -- NOT IMPLEMENTED
27. [Output Template Library](#v4-27-output-template-library) -- NOT IMPLEMENTED

---

# v1 — Core Optimizations (8 implemented)

These target the most impactful inefficiencies in the baseline pipeline. Combined impact: ~72% token reduction.

---

## v1-1. Skip Generated and Trivial Files

**Status: IMPLEMENTED** | **Savings: 30-40% fewer Claude calls** | **Effort: Low | Risk: Low**

UE has thousands of generated files that follow mechanical patterns. Analyzing them individually is pure waste.

### What to Skip

- `Module.*.gen.cpp` -- UBT module registration stubs, identical boilerplate
- `*.generated.h` / `*.gen.cpp` -- UHT reflection code, not human-authored
- Files under 20 lines -- forward declarations, empty stubs
- Files that are purely `#include` chains (no logic)

### Implementation

Add a pre-filter stage to `archgen.ps1` that classifies files before dispatching:

```powershell
# In archgen.ps1, after file collection
$trivialPatterns = @(
    '\.generated\.h$',
    '\.gen\.cpp$',
    'Module\.\w+\.cpp$',       # Module registration stubs
    'Classes\.h$'               # Auto-generated class headers
)

$trivialQueue = [System.Collections.Generic.List[string]]::new()
$normalQueue  = [System.Collections.Generic.List[string]]::new()

foreach ($rel in $queue) {
    $isTrivial = $false
    foreach ($pat in $trivialPatterns) {
        if ($rel -match $pat) { $isTrivial = $true; break }
    }
    # Also check line count
    if (-not $isTrivial) {
        $src = Join-Path $repoRoot ($rel -replace '/','\')
        $lineCount = @(Get-Content $src -ErrorAction SilentlyContinue).Count
        if ($lineCount -lt 20) { $isTrivial = $true }
    }

    if ($isTrivial) { $trivialQueue.Add($rel) }
    else            { $normalQueue.Add($rel) }
}
```

For skipped files, generate a one-line stub doc instead of a Claude call:

```markdown
# Engine/Source/Runtime/Engine/Classes/Engine/Engine.generated.h
## File Purpose
Auto-generated UHT reflection code for Engine module. No manual analysis needed.
```

### Impact

Reduces file count from ~36K to ~20-22K Claude calls for full UE. This is the single biggest win.

---

## v1-2. Shared Header Analysis

**Status: IMPLEMENTED** | **Savings: 15-20% input token reduction** | **Effort: Medium | Risk: Low**

The same header gets bundled into dozens of files. `Actor.h` (4600 lines) is bundled into every file that includes it -- that's ~4K tokens of input repeated 50+ times.

### The Problem

```
Current:  source.cpp (2000 tokens) + Actor.h raw (4000 tokens) = 6000 tokens input
Better:   source.cpp (2000 tokens) + Actor.h doc (400 tokens)  = 2400 tokens input
```

### Solution

Pre-analyze the N most-included headers once, store the result, and inject the **doc** instead of the raw header.

### Implementation

1. After Pass 1 completes for headers, build an index of header docs
2. In the worker, instead of bundling raw header content, bundle the Pass 1 `.md` doc for that header (which is ~400 tokens vs. the full source)
3. Add a new config option: `BUNDLE_HEADER_DOCS=1`

```powershell
# In archgen_worker.ps1, Build-Payload header resolution
if ($resolved -and (Test-Path $resolved)) {
    $localPath = $resolved.Substring($repoRoot.Length).TrimStart("\","/") -replace "\\","/"

    # Check for existing doc (header doc bundling)
    $headerDoc = Join-Path $archDir (($localPath -replace "/","\\") + ".md")
    if ($bundleHeaderDocs -eq "1" -and (Test-Path $headerDoc)) {
        $hdrContent = Get-Content $headerDoc -Raw -ErrorAction SilentlyContinue
        $headerSection += "`n--- $localPath (analyzed doc) ---`n$hdrContent"
    } else {
        # Fall back to raw header content
        $hdrContent = Get-Content $resolved -Raw -ErrorAction SilentlyContinue
        $headerSection += "`n--- $localPath ---`n``````$hdrFence`n$hdrContent`n``````"
    }
    $hdrCount++
}
```

### Two-Pass Strategy

Run `archgen.ps1` twice:
1. First pass: process headers only (files matching `\.h$|\.hpp$`). Raw bundling as usual.
2. Second pass: process `.cpp` files with `BUNDLE_HEADER_DOCS=1`. Now headers have docs that can be bundled instead of raw source.

---

## v1-3. LSP-Guided Source Trimming

**Status: IMPLEMENTED** | **Savings: 20-30% input token reduction** | **Effort: Medium | Risk: Medium**

Current truncation is blunt: head + tail. This misses important code in the middle and includes irrelevant boilerplate at the top (copyright headers, includes, forward declarations).

### Solution

Use the `.serena_context.txt` symbol ranges to extract only the meaningful parts of each file.

### Implementation

```python
def generate_trimmed_source(file_path, symbols, max_lines=800):
    """Extract only meaningful code sections using LSP symbol ranges."""
    lines = Path(file_path).read_text(encoding="utf-8", errors="replace").splitlines()

    # Always include first 30 lines (includes, namespace declarations)
    regions = [(0, min(30, len(lines)))]

    # Add each symbol's range (with 2-line buffer)
    for sym in symbols:
        start = max(0, sym["start_line"] - 2)
        end = min(len(lines), sym["end_line"] + 1)
        # For large functions, take first 15 and last 5 lines
        if (end - start) > 25:
            regions.append((start, start + 15))
            regions.append((end - 5, end))
        else:
            regions.append((start, end))

    # Merge overlapping regions, emit with "// ..." between gaps
    regions.sort()
    merged = merge_regions(regions)

    output = []
    last_end = 0
    for start, end in merged:
        if start > last_end:
            output.append(f"// ... [{start - last_end} lines omitted] ...")
        output.extend(lines[start:end])
        last_end = end

    return "\n".join(output[:max_lines])
```

### Impact

For a 4000-line file with 30 key functions: ~600 lines sent instead of 4000 -- an 85% reduction in source tokens for large files.

---

## v1-4. Per-File Targeted Context in Pass 2

**Status: IMPLEMENTED** | **Savings: 40-50% Pass 2 input token reduction** | **Effort: Low | Risk: Low**

Currently, every Pass 2 call gets the same 200-line architecture overview and 300-line xref excerpt. Most of that context is irrelevant to the specific file being analyzed.

### The Problem

```
File: Engine/Source/Runtime/Renderer/Private/LightRendering.cpp

Gets 200 lines of architecture overview (covering ALL subsystems)
Gets 300 lines of xref index (covering ALL files)

Only ~20 lines of that are relevant to LightRendering.cpp.
The rest is wasted input tokens, repeated for every file.
```

### Solution

Build per-file context extracts with `archpass2_context.ps1` (zero Claude calls):

```powershell
function Build-TargetedContext($rel, $archContent, $xrefContent) {
    $lines = @()

    # Extract relevant architecture section
    $subsystem = ($rel -split '/')[3..4] -join '/'  # e.g., "Runtime/Renderer"
    $archLines = $archContent -split "`n"
    $inSection = $false
    foreach ($line in $archLines) {
        if ($line -match "^##.*$subsystem" -or $line -match $subsystem) {
            $inSection = $true
        }
        if ($inSection) {
            $lines += $line
            if ($line -match '^##' -and $lines.Count -gt 5) { break }
        }
    }

    # Extract relevant xref entries
    $xrefLines = $xrefContent -split "`n"
    $fileName = Split-Path $rel -Leaf
    foreach ($line in $xrefLines) {
        if ($line -match [regex]::Escape($fileName) -or $line -match [regex]::Escape($rel)) {
            $lines += $line
        }
    }

    return $lines -join "`n"
}
```

### Impact

Instead of 200 + 300 = 500 lines of mostly irrelevant context, each file gets 30-80 lines of highly relevant context. Over thousands of Pass 2 calls, this saves millions of input tokens.

---

## v1-5. Tiered Model Selection

**Status: IMPLEMENTED** | **Savings: 30-50% cost reduction** | **Effort: Medium | Risk: Low**

Not all files need the same model. A 50-line utility header doesn't need the same analysis depth as the 4600-line Actor.h.

### Tiers

| Complexity | Criteria | Model | Output Budget |
|-----------|----------|-------|---------------|
| Low | <100 lines, <=2 functions, no classes | haiku | ~400 tokens |
| Medium | 100-1000 lines, standard patterns | haiku | ~800 tokens |
| High | >1000 lines, or >10 incoming refs, or hub file | sonnet | ~1200 tokens |

### Implementation

```powershell
function Get-FileComplexity($rel, $serenaContextDir, $repoRoot) {
    $src = Join-Path $repoRoot ($rel -replace '/','\')
    $lineCount = @(Get-Content $src -ErrorAction SilentlyContinue).Count

    $serenaPath = Join-Path $serenaContextDir (($rel -replace '/','\') + '.serena_context.txt')
    $symbolCount = 0
    $refCount = 0
    if (Test-Path $serenaPath) {
        $ctx = Get-Content $serenaPath
        $symbolCount = @($ctx | Select-String '^- ').Count
        $refCount = @($ctx | Select-String '^\s+- ').Count
    }

    if ($lineCount -lt 100 -and $symbolCount -le 2) { return 'low' }
    if ($lineCount -gt 1000 -or $refCount -gt 10)   { return 'high' }
    return 'medium'
}
```

### Impact

Sonnet costs ~15x more per token than haiku. Reserving sonnet for only the ~10% most complex files reduces total cost dramatically while maintaining quality where it matters.

---

## v1-6. Batch Templated Files

**Status: IMPLEMENTED** | **Savings: 5-10% fewer Claude calls** | **Effort: Medium | Risk: Medium**

Many UE files follow identical structural patterns. All `Module.*.gen.cpp` files have the same structure. All `*BlueprintGeneratedClass.cpp` files follow the same pattern.

### Solution

Analyze one representative file per template, then generate docs for the rest by substitution:

1. Group files by pattern (regex on filename + structural hash of first 20 lines)
2. Send one representative from each group to Claude
3. For remaining files in the group, generate docs by replacing names/paths in the template doc

```powershell
function Get-StructuralHash($filePath) {
    $lines = Get-Content $filePath -First 20 -ErrorAction SilentlyContinue
    $normalized = $lines | ForEach-Object {
        $_ -replace '\b[A-Z][A-Za-z0-9_]+\b', 'IDENT' `
           -replace '\b\d+\b', 'NUM' `
           -replace '"[^"]*"', 'STR'
    }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized -join "`n")
    return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}
```

### Caution

Only safe for truly templated files (generated code, registration stubs). For human-authored files that happen to share structure, always use Claude -- the logic differences matter.

---

## v1-7. Compressed Prompt Format

**Status: IMPLEMENTED** | **Savings: 10-15% system prompt token reduction** | **Effort: Low | Risk: Low**

The current prompts use verbose markdown schema descriptions. Every Claude call includes the full prompt (~500 tokens). Over 20K+ calls, that's 10M+ tokens of repeated instructions.

### Implementation

`file_doc_prompt_compact.txt` (~150 tokens vs ~500):

```
Static arch analysis of game engine file.

Input: FILE PATH, LSP CONTEXT (if any), FILE CONTENT, possibly BUNDLED HEADERS.
LSP context is authoritative for cross-refs.

Output schema (deterministic md):
# <PATH>
## Purpose (1-3 sent)
## Responsibilities (3-8 bullets)
## Types | Name | Kind | Purpose | (or "None")
## Globals | Name | Type | Scope | Purpose | (or "None")
## Key Functions (skip trivial helpers)
### <name> | sig | purpose | in | out | side-fx | callers(LSP) | calls | notes
## Control Flow (init/frame/update/render/shutdown)
## Deps (includes, external symbols w/ locations from LSP, key callers)

Rules: No speculation. Use LSP refs when available. Max ~OUTPUT_BUDGET tokens.
```

### Impact

Over 20K calls: saves ~7M input tokens (20K * 350 saved per call).

---

## v1-8. Adaptive Output Budget

**Status: IMPLEMENTED** | **Savings: 10-20% output token reduction** | **Effort: Low | Risk: Low**

The prompt says "keep output under ~1000-1200 tokens" for every file. A 30-line header doesn't need 1000 tokens of analysis.

### Implementation

```powershell
function Get-OutputBudget($lineCount, $symbolCount) {
    if ($lineCount -lt 50)                           { return "~200 tokens" }
    if ($lineCount -lt 200 -and $symbolCount -le 5)  { return "~400 tokens" }
    if ($lineCount -lt 500)                          { return "~600 tokens" }
    if ($lineCount -lt 1500)                         { return "~1000 tokens" }
    return "~1200 tokens"
}
```

In the worker, append the budget to the payload:

```powershell
$budget = Get-OutputBudget $srcLines.Count $symbolCount
$payload += "`n`nOUTPUT BUDGET: $budget"
```

### Impact

Prevents Claude from padding small files with filler. Over thousands of small files, this adds up.

---

## v1 Impact Summary

| # | Optimization | Token Savings | Effort | Risk |
|---|-------------|--------------|--------|------|
| 1 | Skip generated/trivial files | 30-40% fewer calls | Low | Low |
| 2 | Shared header analysis | 15-20% input reduction | Medium | Low |
| 3 | LSP-guided source trimming | 20-30% input reduction | Medium | Medium |
| 4 | Per-file targeted Pass 2 context | 40-50% Pass 2 input reduction | Low | Low |
| 5 | Tiered model selection | 30-50% cost reduction | Medium | Low |
| 6 | Batch templated files | 5-10% fewer calls | Medium | Medium |
| 7 | Compressed prompt format | 10-15% prompt savings | Low | Low |
| 8 | Adaptive output budget | 10-20% output reduction | Low | Low |

| Metric | Before | After v1 | Reduction |
|--------|--------|----------|-----------|
| Claude calls (Pass 1) | ~36,000 | ~20,000 | 44% |
| Input tokens per call (avg) | ~5,000 | ~2,500 | 50% |
| Output tokens per call (avg) | ~1,000 | ~600 | 40% |
| Pass 2 calls | ~36,000 | ~500 (selective) | 98% |
| Pass 2 input tokens per call | ~3,000 | ~1,200 | 60% |
| **Total estimated token cost** | **~250M tokens** | **~70M tokens** | **~72%** |

---

# v2 — Advanced Optimizations (6 implemented)

These target remaining inefficiencies after v1 is active. Combined with v1: ~88% total reduction.

---

## v2-9. Batch Small Files Into Single Calls

**Status: IMPLEMENTED** | **Savings: 30% fewer API calls for small files** | **Effort: Medium | Risk: Low**

Currently every file gets its own Claude call, even 15-line headers. Small files (<100 lines) could be batched 3-5 per call.

### The Problem

```
Current:  file1 (30 lines) -> 1 call -> 1 doc
          file2 (45 lines) -> 1 call -> 1 doc
          file3 (20 lines) -> 1 call -> 1 doc
          = 3 calls, 3x prompt overhead

Batched:  file1 + file2 + file3 -> 1 call -> 3 docs
          = 1 call, 1x prompt overhead
```

### Implementation

```powershell
# In archgen.ps1, after building the queue:
$smallFiles = $queue | Where-Object {
    $src = Join-Path $repoRoot ($_ -replace '/','\')
    @(Get-Content $src -ErrorAction SilentlyContinue).Count -lt 100
}
$largeFiles = $queue | Where-Object { $_ -notin $smallFiles }

# Batch small files in groups of 4
$batches = for ($i = 0; $i -lt $smallFiles.Count; $i += 4) {
    ,@($smallFiles[$i..([math]::Min($i + 3, $smallFiles.Count - 1))])
}
```

### Impact

For UE, roughly 40% of files are under 100 lines. Batching them in groups of 4 cuts ~30% of total API calls.

---

## v2-10. Shared Engine Knowledge Preamble

**Status: IMPLEMENTED** | **Savings: 10-15% input reduction, 100-200 output tokens per file** | **Effort: Low | Risk: Low**

Every file, Claude rediscovers that `UCLASS()` is a reflection macro, `FName` is an interned string, `TArray` is a dynamic array, etc. A shared preamble injected once per call eliminates this rediscovery.

### Implementation

`ue_preamble.txt`:

```
UE CONVENTIONS (do not explain these in output - the reader already knows them):
- UCLASS/USTRUCT/UENUM/UPROPERTY/UFUNCTION = UHT reflection macros
- GENERATED_BODY() = UHT macro expanding to reflection boilerplate
- FName = interned string, FString = mutable string, FText = localized string
- TArray = dynamic array, TMap = hash map, TSet = hash set, TWeakObjectPtr = weak ref
- AActor = base game object with transform, UActorComponent = composable behavior
- UObject = root of reflection hierarchy, supports GC, CDO, serialization
- APawn = possessable actor, ACharacter = pawn with movement component
- FTickFunction = per-frame callback, registered with tick groups
- .generated.h = auto-generated reflection code (do not analyze internals)
- Module.*.cpp = UBT module registration stub (do not analyze)
- Super::Method() = calling parent class implementation
- check()/ensure()/verify() = assertion macros
- WITH_EDITOR = editor-only code block
- FORCEINLINE = platform-specific inline hint
```

### Impact

- Prevents Claude from wasting output tokens explaining UE conventions in every file
- Over 20K files at ~150 saved output tokens each = ~3M fewer output tokens

---

## v2-11. Output Schema Pruning for Simple Files

**Status: IMPLEMENTED** | **Savings: 15-25% output reduction on simple files** | **Effort: Low | Risk: Low**

The current prompt asks for 7 sections regardless of file complexity. A 30-line utility with 2 functions produces empty sections like "## Key Types / Data Structures\nNone." -- ~50 wasted output tokens per simple file.

### Implementation

`file_doc_prompt_minimal.txt` for files <100 lines with <=3 symbols:

```
Static arch analysis. Output ONLY non-empty sections from:
# <PATH>
## Purpose (1-2 sentences)
## Functions (### name | sig | purpose | calls)
## Deps (includes, external symbols)
Omit Types/Globals/ControlFlow if none. Max ~200 tokens.
```

### Impact

- Simple files: 200 tokens output instead of 600-800
- ~40% of UE files qualify as "simple"
- Saves ~3-4M output tokens across a full UE run

---

## v2-12. Incremental Pass 2 (Delta-Only)

**Status: IMPLEMENTED** | **Savings: 30-40% Pass 2 output reduction** | **Effort: Medium | Risk: Medium**

Pass 2 often repeats information from Pass 1. Instead of producing a complete new doc, ask Claude to output **only new insights** not present in the Pass 1 doc.

### Implementation

Delta-focused `file_doc_prompt_pass2_delta.txt`:

```
You have the Pass 1 doc below. Output ONLY information that is NEW -
cross-cutting insights, architectural context, and cross-references
that could not be determined from the file alone.

Do NOT repeat anything already in the Pass 1 doc. If a section adds
nothing new beyond what Pass 1 already covers, omit it entirely.

Possible sections (include only if you have new insights):
## Architectural Role (how this file fits in the broader engine)
## Cross-References (specific incoming callers / outgoing deps from xref)
## Design Patterns (why structured this way, what tradeoffs)
## Data Flow (what enters, transforms, exits - if non-obvious)

Keep output under ~500 tokens. Empty output is acceptable if Pass 1
already captured everything meaningful about this file.
```

### Impact

- Average Pass 2 output drops from ~1200 tokens to ~400 tokens
- Many simple files produce empty Pass 2 output (Pass 1 was sufficient)

---

## v2-13. Source Elision With LSP Context

**Status: IMPLEMENTED** | **Savings: 30-50% input reduction when LSP context exists** | **Effort: Medium | Risk: Medium**

When LSP context exists, Claude already knows the symbols, their types, and their line ranges from the `## Symbol Overview` section. The trimmed source provides key code sections. Sending the full `FILE CONTENT` on top of that is redundant.

### The Insight

```
Current payload for a 2000-line file with LSP context:

  LSP CONTEXT:        ~400 tokens (symbols, refs, includes)
  LSP TRIMMED SOURCE: ~600 tokens (key sections)
  FILE CONTENT:       ~6000 tokens (full source, mostly redundant)
  HEADERS:            ~2000 tokens
  PROMPT:             ~200 tokens
  Total:              ~9200 tokens

With source elision:

  LSP CONTEXT:        ~400 tokens
  LSP TRIMMED SOURCE: ~600 tokens
  (no FILE CONTENT - trimmed source is sufficient)
  HEADERS:            ~2000 tokens (or header docs at ~400)
  PROMPT:             ~200 tokens
  Total:              ~3600 tokens (61% reduction)
```

### Risk

Claude may miss context from code sections not captured in the trimmed source (e.g., complex macro expansions, inline comments explaining design decisions). Mitigation:
- Only elide for files where LSP context has both Symbol Overview AND Trimmed Source
- Keep header bundling active (headers provide type definitions)
- Fall back to full source at stage 1 if output quality seems low

---

## v2-14. Response Caching for Templated Patterns

**Status: IMPLEMENTED** | **Savings: 5-15% fewer calls** | **Effort: High | Risk: Medium**

Beyond structural deduplication (v1-6), cache Claude's **response patterns** by semantic class. Many UE files follow the same class pattern (e.g., every `UAnimNotify` subclass has the same structure).

### Implementation

1. **Classification phase**: Extract the primary base class from LSP context
2. **Pattern database**: After analyzing N files of the same base class, extract the common doc template
3. **Template application**: For subsequent files of the same base class, generate the doc from the template with name substitution

### When It's Safe

Only apply to files that:
- Have a single primary class inheriting from a known base
- Are under 200 lines (simple override patterns)
- Have been seen 3+ times with the same base class

### Impact

UE has hundreds of `UAnimNotify`, `UBlueprintFunctionLibrary`, `UDeveloperSettings`, `USubsystem` subclasses. Potentially 500-1000 files could be templated this way.

---

## v2 Impact Summary

| #  | Optimization                         | Token Savings       | Effort | Risk   |
|----|--------------------------------------|---------------------|--------|--------|
| 9  | Batch small files per call           | 30% fewer calls     | Medium | Low    |
| 10 | Shared engine knowledge preamble     | 10-15% input        | Low    | Low    |
| 11 | Output schema pruning                | 15-25% output       | Low    | Low    |
| 12 | Delta-only Pass 2                    | 30-40% P2 output    | Medium | Medium |
| 13 | Source elision with LSP              | 30-50% input        | Medium | Medium |
| 14 | Response caching by class pattern    | 5-15% fewer calls   | High   | Medium |

| Metric                        | Baseline  | After v1   | After v1+v2 | Total Reduction |
|-------------------------------|-----------|------------|-------------|-----------------|
| Claude calls (Pass 1)         | ~36,000   | ~20,000    | ~14,000     | 61%             |
| Input tokens per call (avg)   | ~5,000    | ~2,500     | ~1,200      | 76%             |
| Output tokens per call (avg)  | ~1,000    | ~600       | ~350        | 65%             |
| Pass 2 calls                  | ~36,000   | ~500       | ~500        | 98%             |
| Pass 2 output per call        | ~1,500    | ~1,200     | ~500        | 67%             |
| **Total estimated tokens**    | **~250M** | **~70M**   | **~30M**    | **~88%**        |

---

# v3 — Structural Pipeline Optimizations (7 implemented)

These target structural pipeline inefficiencies and API-level savings. Combined with v1+v2: ~95% total reduction.

---

## v3-15. Hard Output Cap via --max-tokens

**Status: IMPLEMENTED** | **Savings: Eliminates over-generation entirely** | **Effort: Trivial | Risk: None**

Currently we ask Claude to "keep output under ~N tokens" in the prompt. Claude sometimes ignores this and generates 2x the budget. The Claude CLI supports `--max-tokens` which hard-caps the response at the API level.

### Implementation

```powershell
# In archgen_worker.ps1, map budget string to numeric cap
$maxOutputTokens = switch -Wildcard ($outputBudget) {
    '*200*'  { 250  }
    '*400*'  { 500  }
    '*600*'  { 750  }
    '*1000*' { 1200 }
    '*1200*' { 1500 }
    default  { 1500 }
}

# Add to the Claude CLI call
$resp = $payload | & claude -p `
    --model $model `
    --max-turns $maxTurns `
    --output-format $outputFmt `
    --max-tokens $maxOutputTokens `
    --append-system-prompt-file $promptFile 2>&1
```

### Impact

- Prevents Claude from generating 2000-token docs when 600 was requested
- Guaranteed savings on every call where Claude would have over-generated
- One-line change in the worker

---

## v3-16. Hierarchical Directory-First Analysis

**Status: IMPLEMENTED** | **Savings: Could eliminate Pass 2 entirely** | **Effort: High | Risk: Medium**

Instead of analyzing files independently then synthesizing context in Pass 2, analyze directories first and inject the directory summary into each file's Pass 1 call.

### Current vs Proposed Pipeline

```
Current:
  Pass 1: file -> Claude (no architectural context) -> doc
  Pass 2: file + Pass 1 doc + overview + xref -> Claude -> enriched doc

Proposed (directory-first):
  Phase 1: directory -> Claude (file listing + LSP summaries) -> directory overview (~500 tokens)
  Phase 2: file + directory overview -> Claude -> doc (already has architectural context)
```

Every file is analyzed once. The directory overview is a single cheap call shared across all files in that directory.

### Implementation

New script: `archgen_dirs.ps1`

```powershell
# For each directory with source files:
#   1. Collect file listing (names + line counts + primary class from LSP)
#   2. Send to Claude: "Summarize this directory's role in the engine"
#   3. Output: architecture/.dir_context/<dir_path>.dir.md (~300-500 tokens)
```

Then `archgen_worker.ps1` loads the directory context like it loads LSP context.

---

## v3-17. Semantic LSP Context Compression

**Status: IMPLEMENTED** | **Savings: 20-30% reduction in LSP context tokens** | **Effort: Medium | Risk: Low**

The LSP context lists every symbol exhaustively. For large files this produces 100+ lines of symbol data, most of which Claude ignores. Compress by significance.

### Solution

In `serena_extract.py`, compress the symbol overview via the `-Compress` flag:
- Rank symbols by reference count
- Take top N, summarize the rest
- Collapse classes to "ClassName (Class, N methods)"

Output becomes:

```
## Symbol Overview
- FMath (Class, 45 methods, lines 45-4200)
- FMath::RandHelper (12 refs, lines 94-110)
- FMath::Clamp (8 refs, lines 120-125)
... and 40 more methods (low reference count)
```

### Impact

Large files go from 100+ lines of symbol data to 15-20 lines. Saves ~200-500 tokens per large file.

---

## v3-18. JSON Output Format

**Status: IMPLEMENTED** | **Savings: 15-20% output token reduction** | **Effort: Medium | Risk: Low**

Markdown is verbose. Headers, bullets, table syntax, pipe characters -- all consume tokens without adding information. JSON is 15-20% more token-efficient for the same structured data.

### Trade-off

- Requires a post-processing step (JSON -> markdown)
- Claude is slightly less natural at generating valid JSON than freeform markdown
- Need to handle malformed JSON gracefully
- Net savings: ~15-20% fewer output tokens, but adds ~5% processing overhead

---

## v3-19. Per-Directory Shared Include Context

**Status: IMPLEMENTED** | **Savings: 30-40% header bundling token reduction** | **Effort: Medium | Risk: Low**

Files in the same directory share 90%+ of their includes. Currently, each file independently resolves and bundles its headers.

### Solution

Pre-processing step in `archgen.ps1`: compute common includes (80%+ threshold) per directory into `architecture/.dir_headers/<dir>.headers.txt`. Workers load shared headers first, then only bundle per-file unique headers.

### Impact

For `Engine/Source/Runtime/Engine/Private/` (200 files, 4 shared headers at ~3000 tokens each):

| Approach                  | Header tokens per file | Total for directory |
|---------------------------|----------------------|---------------------|
| Current (per-file bundle) | ~12,000              | 2,400,000           |
| Shared + unique           | ~1,000 (shared ref)  | 212,000             |

~91% reduction in header bundling tokens for directories with heavy shared includes.

---

## v3-20. Incremental Overview Updates

**Status: IMPLEMENTED** | **Savings: 90% reduction in overview regeneration cost** | **Effort: Medium | Risk: Low**

Currently `arch_overview.ps1` regenerates the entire overview from scratch. For iterative development, this is wasteful.

### Implementation

Track subsystem doc hashes in `overview_hashes.tsv`. On re-run, skip unchanged subsystems. Use `-Full` flag to force full regeneration.

| Scenario                          | Current cost  | Incremental cost |
|-----------------------------------|--------------|-----------------|
| Full run (first time)             | ~20 min      | ~20 min          |
| Re-run, 0 files changed          | ~20 min      | ~10 sec          |
| Re-run, 10 files in 1 subsystem  | ~20 min      | ~2 min           |
| Re-run, 100 files in 5 subsystems| ~20 min      | ~8 min           |

---

## v3-21. Two-Phase Classification

**Status: IMPLEMENTED** | **Savings: 20-30% fewer full analysis calls** | **Effort: Medium | Risk: Medium**

Before full analysis, run an ultra-cheap classification pass to identify files that don't need full analysis.

### Implementation

Phase 1 prompt (~50 tokens):

```
Given: file path, line count, primary symbol from LSP.
Reply with ONLY one of:
  ANALYZE - needs full architecture doc
  STUB:<10-word purpose> - boilerplate, no full analysis needed
```

Phase 1 call (~80 total tokens per file via haiku).

### Cost Analysis

```
Without classification:
  20,000 files x ~3000 tokens/call = 60M tokens

With classification:
  20,000 files x ~80 tokens (phase 1) = 1.6M tokens
  14,000 files x ~3000 tokens (phase 2) = 42M tokens
  6,000 stub files x ~0 tokens = 0
  Total: 43.6M tokens (27% savings)
```

---

## v3 Impact Summary

| #  | Optimization                          | Token Savings         | Effort  | Risk   |
|----|---------------------------------------|-----------------------|---------|--------|
| 15 | Hard output cap (--max-tokens)        | Eliminates overflow   | Trivial | None   |
| 16 | Hierarchical directory-first          | Eliminates Pass 2     | High    | Medium |
| 17 | Semantic LSP context compression      | 20-30% LSP input      | Medium  | Low    |
| 18 | JSON output format                    | 15-20% output         | Medium  | Low    |
| 19 | Per-directory shared include context  | 30-40% header input   | Medium  | Low    |
| 20 | Incremental overview updates          | 90% overview cost     | Medium  | Low    |
| 21 | Two-phase classification              | 20-30% fewer calls    | Medium  | Medium |

| Metric                        | Baseline  | After v1   | After v1+v2 | After v1+v2+v3 | Total Reduction |
|-------------------------------|-----------|------------|-------------|----------------|-----------------|
| Claude calls (Pass 1)         | ~36,000   | ~20,000    | ~14,000     | ~10,000        | 72%             |
| Input tokens per call (avg)   | ~5,000    | ~2,500     | ~1,200      | ~800           | 84%             |
| Output tokens per call (avg)  | ~1,000    | ~600       | ~350        | ~280           | 72%             |
| Pass 2 calls                  | ~36,000   | ~500       | ~500        | ~100           | 99.7%           |
| Overview regeneration         | ~20 min   | ~20 min    | ~20 min     | ~2 min (incr)  | 90%             |
| **Total estimated tokens**    | **~250M** | **~70M**   | **~30M**    | **~12M**       | **~95%**        |

---

# v4 — Structural Rethinking (1 implemented, 5 not implemented)

These rethink how and when analysis happens, targeting the fundamental cost model rather than per-call efficiency.

**Operational fix (v4)**: `serena_extract.py` now cleans up orphaned `preamble-*.pch` files (from clangd `--pch-storage=disk`) at shutdown and via `atexit`. These files averaged ~80 MB each and accumulated to 50+ GB without cleanup. Cleanup runs only at exit, not mid-run, to preserve clangd's preamble cache reuse.

---

## v4-22. Prompt Caching (API-Level)

**Status: IMPLEMENTED** | **Savings: 50-70% reduction in system prompt token cost** | **Effort: Low | Risk: None**

The Claude API caches repeated prompt prefixes. If the system prompt is identical across calls, the API charges a reduced rate for the cached portion. Previously our system prompt varied per file (output budget was appended), breaking the cache.

### The Fix

Separate the fixed system prompt from the variable per-file content:

```
CACHED (system prompt - identical every call):
  [file_doc_system_prompt.txt contents]

NOT CACHED (user message - varies per file):
  FILE PATH: ...
  LSP CONTEXT: ...
  FILE CONTENT: ...
  OUTPUT BUDGET: ~600 tokens
```

### Implementation

Both `archgen_worker.ps1` and `archpass2_worker.ps1` use `file_doc_system_prompt.txt` as a fixed system prompt. The per-file prompt schema is embedded in the user message.

### Impact

| Component        | Current cost  | With caching   |
|------------------|--------------|----------------|
| System prompt    | 500 x 20K = 10M tokens (full rate) | 500 x 1 = 500 tokens (full) + 500 x 19,999 (cache rate ~10%) |
| User message     | ~2500 x 20K = 50M tokens | Same -- not cached |

Net savings: ~9M tokens.

---

## v4-23. Diff-Based Incremental Re-Analysis

**Status: NOT IMPLEMENTED** | **Savings: 80-90% fewer tokens on iterative re-runs** | **Effort: Medium | Risk: Low**

When a source file changes slightly (bug fix, added method), the current pipeline re-analyzes the entire file from scratch. For a 2000-line file with a 10-line change, this wastes ~95% of the input tokens.

### The Problem

```
Current (file changed by 10 lines):
  Input:  full source (3000 tokens) + headers (2000) + LSP (400) + prompt (200) = 5600 tokens
  Output: full doc (800 tokens)
  Total:  6400 tokens - to update 10 lines

Diff-based:
  Input:  existing doc (800 tokens) + git diff (100) + prompt (150) = 1050 tokens
  Output: updated sections only (200 tokens)
  Total:  1250 tokens - 80% savings
```

### Implementation

New mode in `archgen_worker.ps1`:

```powershell
# Detect if an existing doc exists and source changed
$existingDoc = Join-Path $archDir (($rel -replace '/','\\') + '.md')
$hasExistingDoc = Test-Path $existingDoc

if ($diffMode -and $hasExistingDoc) {
    # Get the diff since last analysis
    $lastHash = $oldSha[$rel]
    $diff = git diff $lastHash -- $src 2>$null
    if ($diff -and $diff.Length -lt 5000) {
        $existingContent = Get-Content $existingDoc -Raw
        $payload = @"
You wrote this architecture doc previously:
$existingContent

The source file changed:
```diff
$diff
```

Update ONLY the sections affected by this change. Output the complete
updated doc (not just the changed sections). If the change doesn't
affect the architecture (e.g., whitespace, comments), reply: NO_CHANGE
"@
    }
}
```

### When to Use

- **Iterative development**: change 50 files, re-run pipeline -> 80% cheaper
- **Code review**: generate updated docs for just the changed files in a PR
- **CI integration**: run on every commit, only paying for diffs

### When NOT to Use

- First run (no existing docs)
- Major refactors (diff is larger than the file)
- After changing LSP extraction (cross-references may have changed)

### CLI

```powershell
.\archgen.ps1 -Preset unreal -Jobs 8 -Diff    # Diff-based for changed files
.\archgen.ps1 -Preset unreal -Jobs 8           # Full re-analysis (current behavior)
```

---

## v4-24. On-Demand Progressive Analysis

**Status: NOT IMPLEMENTED** | **Savings: Only pay for what's actually read (potentially 80-95%)** | **Effort: High | Risk: Low**

The current pipeline analyzes every file upfront. In practice, users read docs for maybe 5-10% of files. The rest generate tokens that are never consumed.

### Progressive Levels

| Level | Content                    | Cost per file | When generated     |
|-------|---------------------------|---------------|-------------------|
| 0     | Directory overview         | ~0.5 Claude calls per dir | Upfront (archgen_dirs) |
| 1     | One-line purpose + symbols | Free (from LSP) or ~30 tokens (classify) | Upfront |
| 2     | Full architecture doc      | ~3000 tokens  | On demand          |
| 3     | Pass 2 enriched doc        | ~3000 tokens  | On demand          |

### Implementation

Phase 1 (upfront, cheap):
```powershell
# Already done: archgen_dirs.ps1 (Level 0)
# Already done: SKIP_TRIVIAL stubs (Level 1 for trivial files)
# New: generate Level 1 index for all files from LSP context
.\archgen_index.ps1 -Preset unreal   # Produces architecture/index.md
```

Phase 2 (on-demand):
```powershell
# User browses index.md, wants details on specific files
.\archgen.ps1 -Only "Engine/Source/Runtime/Engine/Private/Actor.cpp"
```

### Impact

For a 20K file codebase where users actually read 1000 file docs:

| Approach      | Total tokens | Files analyzed |
|---------------|-------------|---------------|
| Current       | ~30M        | 20,000        |
| On-demand     | ~3M         | ~1,000 + index |

---

## v4-25. Cluster-Then-Analyze

**Status: NOT IMPLEMENTED** | **Savings: 30-50% fewer calls for related files, better quality** | **Effort: High | Risk: Medium**

Files don't exist in isolation. Actor.cpp, Actor.h, ActorComponent.cpp, and ActorChannel.cpp form a logical cluster. Analyzing them together in one context window produces better cross-references than analyzing them separately.

### Implementation

Phase 1 -- Build clusters from LSP data:

```python
# 1. Build a file dependency graph from LSP references
# 2. Find connected components (clusters of tightly-coupled files)
# 3. Output cluster definitions: architecture/.clusters/cluster_001.txt
#
# Clustering algorithm:
# - Two files are connected if they share >3 cross-references
# - Cluster size capped at 5 files (context window limit)
# - Files in multiple clusters go to the one with the most connections
```

Phase 2 -- Analyze clusters:
```
Analyze these related files together. They form a tightly-coupled subsystem.
Use your understanding of ALL files to produce accurate cross-references.
Output one doc per file, separated by: === END FILE ===

FILE 1: Engine/Source/Runtime/Engine/Private/Actor.cpp
[source]

FILE 2: Engine/Source/Runtime/Engine/Classes/GameFramework/Actor.h
[source]
```

### Quality Impact

- **Cross-references**: Claude sees the actual caller and callee in the same context
- **Data flow**: Claude traces data across file boundaries in real-time
- **Design patterns**: Multi-file patterns (like Actor+Component composition) are visible

### Trade-off

- Larger per-call payload (3-5 files x ~1500 tokens = ~7500 tokens vs ~3000 for single file)
- Fewer total calls (20K files in ~5K clusters = 5K calls vs 20K)
- Net token usage similar, but quality significantly higher

---

## v4-26. Sampling-Based Architecture Overview

**Status: NOT IMPLEMENTED** | **Savings: 70-80% fewer Pass 1 calls for equivalent overview quality** | **Effort: Medium | Risk: Medium**

For generating the architecture overview, you don't need every file analyzed -- a representative sample gives the same subsystem-level understanding.

### Sampling Strategy

| Category                       | Selection       | % of files | Rationale                            |
|-------------------------------|-----------------|-----------|--------------------------------------|
| Hub files (>5 incoming refs)   | All             | ~10%      | Architecturally critical             |
| Large files (>500 lines)       | All             | ~5%       | Contain core logic                   |
| Headers (.h/.hpp)              | All             | ~30%      | Define interfaces                    |
| Remaining .cpp files           | Random 20%      | ~10%      | Representative implementation sample |
| **Total analyzed**             |                 | **~55%**  |                                      |

### When to Use

- First-time overview generation for a massive codebase
- Exploratory analysis -- understand the architecture before committing to full analysis
- CI pipeline -- quick overview update on every merge

### When NOT to Use

- When individual file docs are needed (use full analysis)
- After sampling -- want to fill in the remaining files (use `archgen.ps1` normally, it skips already-analyzed files)

---

## v4-27. Output Template Library

**Status: NOT IMPLEMENTED** | **Savings: 10-20% output token reduction across templated files** | **Effort: High | Risk: Low**

After analyzing thousands of UE files, common output patterns emerge. UAnimNotify subclasses all have the same doc structure. UBlueprintFunctionLibrary subclasses all have the same boilerplate sections.

### Template Structure

```yaml
# templates/UAnimNotify.template.yaml
match:
  base_class: UAnimNotify
  max_lines: 200
template: |
  # {PATH}

  ## File Purpose
  {CLASS} is a custom animation notify that {CUSTOM_BEHAVIOR}.

  ## Core Responsibilities
  - Trigger {NOTIFY_TYPE} events during animation playback
  - Implement Notify() callback for event handling
  - Provide editor display name via GetNotifyName()

  ## Key Functions / Methods
  ### Notify
  - Signature: virtual void Notify(USkeletalMeshComponent*, UAnimSequenceBase*, const FAnimNotifyEventReference&)
  - Purpose: Called when the notify is triggered during animation
  - {CUSTOM_NOTIFY_DETAILS}

  ## External Dependencies
  - Animation/AnimNotifies/AnimNotify.h
variables:
  CUSTOM_BEHAVIOR: "Extract from first comment or class body"
  NOTIFY_TYPE: "Infer from class name"
  CUSTOM_NOTIFY_DETAILS: "Extract from Notify() body"
```

### Two-Phase Application

Phase 1: For files matching a template, send a much shorter prompt:
```
This file implements {CLASS} : {BASE_CLASS}.
Template doc attached. Fill in ONLY the {VARIABLE} placeholders.
Keep output under 100 tokens - just the variable values.
```

Phase 2: Post-process to merge template + variables into the final doc.

### Impact

- Template prompt: ~200 tokens input + ~100 tokens output = ~300 total
- Full analysis: ~3000 tokens input + ~800 tokens output = ~3800 total
- Savings per templated file: ~92%
- If 10% of files match templates: ~9% total savings

---

## v4 Impact Summary

| #  | Optimization                     | Token Savings                  | Effort  | Risk   | Status          |
|----|----------------------------------|--------------------------------|---------|--------|-----------------|
| 22 | Prompt caching (API-level)       | 50-70% prompt tokens           | Low     | None   | **IMPLEMENTED** |
| 23 | Diff-based incremental           | 80-90% on re-runs              | Medium  | Low    | NOT IMPLEMENTED |
| 24 | On-demand progressive analysis   | Only pay for what's read       | High    | Low    | NOT IMPLEMENTED |
| 25 | Cluster-then-analyze             | 30-50% fewer calls + quality   | High    | Medium | NOT IMPLEMENTED |
| 26 | Sampling-based overview          | 70-80% fewer P1 calls          | Medium  | Medium | NOT IMPLEMENTED |
| 27 | Output template library          | 10-20% output                  | High    | Low    | NOT IMPLEMENTED |

### Recommendations

**Must-do**: #22 (prompt caching) -- trivial effort, guaranteed savings, no risk. **Done.**

**High-value for iterative use**: #23 (diff-based) -- the only one that fundamentally changes the re-run cost model from "re-analyze everything" to "update what changed."

**Philosophical shift**: #24 (on-demand) -- the most impactful long-term. Changes the question from "how do we analyze 20K files cheaply?" to "why are we analyzing files nobody reads?"

### Cumulative Impact (v1 + v2 + v3 + v4)

| Metric                        | Baseline  | After v1-v3 | After v1-v4 (first run) | After v1-v4 (re-run) |
|-------------------------------|-----------|-------------|------------------------|-----------------------|
| Claude calls (Pass 1)         | ~36,000   | ~10,000     | ~5,000 (sampled)       | ~500 (diff-only)      |
| Input tokens per call (avg)   | ~5,000    | ~800        | ~800                   | ~1,050 (diff payload) |
| Output tokens per call (avg)  | ~1,000    | ~280        | ~280                   | ~200 (update only)    |
| Pass 2 calls                  | ~36,000   | ~100        | ~100                   | ~10                   |
| **Total estimated tokens**    | **~250M** | **~12M**    | **~6M**                | **~0.7M**             |
| **Reduction from baseline**   |           | 95%         | 97.6%                  | 99.7%                 |

---

## Operational Notes

- **LSP extraction disk usage**: clangd `--pch-storage=disk` writes `preamble-*.pch` files to temp (~80 MB each for UE). Can accumulate to 50+ GB. Auto-cleaned on shutdown; manual cleanup: `Remove-Item "$env:TEMP\preamble-*.pch" -Force`.
- **Worker scaling**: Auto-scaling beyond 2-3 workers on 32 GB causes I/O contention. Cap explicitly: `-Workers 2 -Jobs 2`.
