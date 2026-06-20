# Architecture Analysis Toolkit - Unit Tests

772 unit tests across 9 scripts covering every script and helper in the pipeline.

---

## Quick Run

```powershell
# Run all tests (PowerShell)
.\archgen.ps1 -Test
.\archxref.ps1 -Test
.\archgraph.ps1 -Test
.\arch_overview.ps1 -Test
.\archpass2.ps1 -Test
.\archpass2_context.ps1 -Test
.\archgen_dirs.ps1 -Test
.\serena_extract.ps1 -Test

# Run Python tests
uv run --python 3.12 serena_extract.py --test
```

All tests run locally with no Claude API calls, no clangd, and no external dependencies. Temp files are created and cleaned up automatically.

---

## Coverage Map

```
Pipeline Script               Tests   Helpers Tested           How to Run
---------------------------   -----   ----------------------   ----------------------------------
serena_extract.ps1              50    (self-contained)         .\serena_extract.ps1 -Test
serena_extract.py               34    (self-contained)         uv run --python 3.12 serena_extract.py --test
archgen_dirs.ps1                29    (self-contained)         .\archgen_dirs.ps1 -Test
archgen.ps1                    193    archgen_worker.ps1       .\archgen.ps1 -Test
archxref.ps1                   106    (self-contained)         .\archxref.ps1 -Test
archgraph.ps1                  102    (self-contained)         .\archgraph.ps1 -Test
arch_overview.ps1              118    (self-contained)         .\arch_overview.ps1 -Test
archpass2_context.ps1           59    (self-contained)         .\archpass2_context.ps1 -Test
archpass2.ps1                   81    archpass2_worker.ps1     .\archpass2.ps1 -Test
---------------------------   -----
TOTAL                          772
```

---

## Pipeline Dependency Graph

```
                    ┌──────────────────────┐
  clangd index ───> │ serena_extract.ps1   │ 50 tests
                    │ serena_extract.py    │ 34 tests
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │ archgen_dirs.ps1     │ 29 tests
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
  Source files ───> │ archgen.ps1          │ 193 tests
                    │ + archgen_worker.ps1 │ (loaded via AST)
                    └──────────┬───────────┘
                               │
             ┌─────────────────┼──────────────────┐
             ▼                 ▼                   ▼
  ┌────────────────┐  ┌──────────────┐  ┌──────────────────┐
  │ archxref.ps1   │  │ archgraph.ps1│  │ arch_overview.ps1 │
  │ 106 tests      │  │ 102 tests    │  │ 118 tests         │
  └───────┬────────┘  └──────────────┘  └────────┬─────────┘
          │                                      │
          └──────────────┬───────────────────────┘
                         │
              ┌──────────▼─────────┐
              │archpass2_context.ps1│ 59 tests
              └──────────┬─────────┘
                         │
              ┌──────────▼─────────┐
              │ archpass2.ps1      │ 81 tests
              │+archpass2_worker.ps1│ (loaded via AST)
              └────────────────────┘
```

---

## Per-Script Test Details

### serena_extract.ps1 (50 tests)

```powershell
.\serena_extract.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `Read-EnvFile` | 6 | Key=value parsing, comments, quoted values, missing file |
| `Cfg` | 4 | Existing/missing/empty keys, default values |
| `Get-Preset` | 16 | Unreal/quake/empty presets, include/exclude regex patterns, alias equality |
| `Build-PyArgs` | 11 | Base args, conditional flags (--force/--skip-refs/--compress) |
| Prerequisite checks | 6 | compile_commands.json, clangd index, extract script validation |
| **Helpers covered** | None (thin wrapper) | |

### serena_extract.py (34 tests)

```
uv run --python 3.12 serena_extract.py --test
```

| Test Class | Tests | What's Verified |
|---|---|---|
| `TestFlattenSymbols` | 5 | Empty input, single function, nested class paths, all 26 symbol kinds, unknown kind |
| `TestUriToRelpath` | 4 | Windows file:// URIs, URL-encoded spaces, non-file passthrough, slash normalization |
| `TestGenerateTrimmedSource` | 7 | Small file (None), large file trimmed, no symbols, empty file, nested skipped, large symbol split, first-30-lines inclusion |
| `TestSha1File` | 2 | Deterministic hashing, different content divergence |
| `TestHashDb` | 3 | Empty load, save+load round-trip, duplicate overwrites |
| `TestCollectFiles` | 7 | Include patterns, exclude .git/ThirdParty, extension filter, target subdir, file list mode, sorted output |
| `TestPchCleanup` | 2 | Snapshot baseline, cleanup no-crash |
| `TestSymbolKinds` | 2 | Known kind names, reference-worthy set membership |
| `TestFuture` | 2 | Set+wait, timeout returns None |

### archgen_dirs.ps1 (29 tests)

```powershell
.\archgen_dirs.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `Read-EnvFile` | 10 | Key=value, comments, blank lines, quoted values, $HOME/~ expansion, missing file |
| `Cfg` | 4 | Existing/missing/empty keys, no-default case |
| `Group-FilesByDir` | 5 | Directory grouping, file counts, 2+ file filter |
| `Build-FileSummary` | 4 | Filename, line count, no-LSP case, LSP symbol extraction |
| `Build-DirPrompt` | 6 | Directory path, file entries, file count, token limit, role instruction |

### archgen.ps1 (193 tests)

```powershell
.\archgen.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `Read-EnvFile` | 10 | Parsing, quotes, `$HOME`/`~` expansion, comments, empty values, missing file |
| `Get-SHA1` | 4 | Hex format, determinism, collision avoidance |
| `Get-Preset` | 19 | All 6 presets + fallback, aliases (ue4/ue5/quake2/doom/etc.), include/exclude patterns |
| `Get-OutputBudget` | 14 | All 5 tiers, boundary conditions at 49/50/199/200/499/500/1499/1500 |
| `Test-TrivialFile` | 6 | .generated.h, .gen.cpp, Module.*.cpp, short files, include-only, normal files |
| `Write-TrivialStub` | 3 | File creation, path in heading, purpose section |
| `Get-FileComplexity` | 5 | Low/medium/high by lines, by refs, without context |
| `Get-StructuralHash` | 4 | Structural dedup, different structure, empty file |
| `Cfg` | 4 | Key lookup, defaults, empty values |
| Exclude patterns | 5 | UE excluded dirs (Binaries, ThirdParty, etc.), non-excluded paths |
| Hash DB round-trip | 5 | Write, read, dedup logic |
| **archgen_worker.ps1** | | |
| `Get-FenceLang` | 31 | All 28 extensions + unknown fallback + path handling |
| `Test-RateLimit` | 11 | 7 positive patterns, 4 negative (markdown headings) |
| `Test-TooLong` | 9 | 6 positive patterns, 3 negative |
| `Get-RateLimitResetTime` | 8 | 12h time, ISO 8601, unix timestamp, no-match |
| `Format-LocalTime` | 3 | PM/AM formatting |
| `Build-Payload` | 22 | Stages 0/1/2, LSP context, preamble, source elision, trimmed source, dir context, shared headers, header doc bundling |
| Batch relList parsing | 7 | Single file, batch split, PS 5.1 array unwrap fix |
| Batch response splitting | 4 | `=== END FILE ===` separator |

### archxref.ps1 (106 tests)

```powershell
.\archxref.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `Test-DocFileIncluded` | 12 | Normal docs included; meta files, pass2, state dirs excluded |
| `Parse-DocFile`: functions | 11 | Function extraction from `###` headings, file path from `#` heading |
| `Parse-DocFile`: call edges | 15 | `Calls:` parsing, multiple callees, `Call:` variant, no-backtick lines |
| `Parse-DocFile`: globals | 9 | Table row parsing, backtick stripping, header/separator filtering |
| `Parse-DocFile`: include deps | 6 | Backtick-wrapped header extraction |
| `Parse-DocFile`: sections | 10 | All section transitions |
| `Parse-DocFile`: edge cases | 8 | Empty, null, stub docs |
| `Parse-DocFile`: formatting | 3 | Backtick/bold stripping from func names |
| `Parse-DocFile`: File-Static | 2 | Parsed as globals |
| `Parse-DocFile`: Key Methods | 3 | `## Key Methods` variant |
| `Parse-DocFile`: Notable | 3 | `## Notable Patterns` behavior |
| `Build-XrefOutput` | 18 | All 7 output sections, content validation |
| `Build-XrefOutput`: empty | 4 | Valid output without globals/deps |
| End-to-end | 9 | Multi-doc parse, merge, cross-file references |

### archgraph.ps1 (102 tests)

```powershell
.\archgraph.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `SanitizeId` | 10 | Alphanumeric, `::`, spaces, parens, angle brackets, tilde, empty |
| `Parse-GraphDoc` | 22 | File path, subsystem detection, function/edge extraction, sections, empty/null, formatting |
| `Get-SignificantFunctions` | 10 | Threshold at min=1/2/5, callers always significant, empty |
| `Build-CallGraph` | 17 | Mermaid structure, subgraphs, edges, self-edge exclusion, dedup, max-edge, non-sig exclusion |
| `Get-CrossSubsystemEdges` | 5 | Cross-sub counting, intra-sub exclusion, unknown callee |
| `Build-SubsystemDiagram` | 9 | Nodes with func counts, edge labels, empty edges |
| `Build-CombinedMarkdown` | 12 | All sections, mermaid fences, statistics |
| End-to-end | 16 | Multi-doc pipeline through all functions |

### arch_overview.ps1 (118 tests)

```powershell
.\arch_overview.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `Cfg` | 5 | Key lookup, missing, empty, numeric, no default |
| `Test-RateLimit` | 15 | 429, JSON status, error patterns, markdown negative |
| `Test-TooLong` | 8 | All 4 positive patterns, 2 negative |
| `Test-OverviewDocIncluded` | 12 | Normal docs, meta files, pass2, state dirs |
| `Extract-DiagramSections` | 19 | Purpose/Responsibilities/Dependencies extraction, exclusion of other sections, empty/null/minimal/stub |
| `Get-OverviewMode` | 8 | Flag overrides, auto threshold, boundary, zero lines |
| `Get-SubsystemPrompt` | 10 | Description, rules, schema sections, BEGIN/END markers, content |
| `Get-SynthesisPrompt` | 14 | Description, cross-reference rule, schema, markers, content |
| `Get-SinglePassPrompt` | 9 | Description, schema, markers, content, language inference |
| `Get-PerFileDocs` | 3 | Filtering with temp files |
| `Build-DiagramData` | 10 | Doc count, section extraction, exclusion of Key Functions/Types |
| `Get-Subsystems` | 5 | High threshold, low threshold splits, single-child descent |

### archpass2_context.ps1 (59 tests)

```powershell
.\archpass2_context.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `Get-SubsystemKeys` | 9 | Deep path (3 keys), 2-level, 1-level, empty |
| `Extract-ArchSections` | 12 | Single/multi-key match, no match, empty inputs, section stops, 30-line cap, case-insensitive |
| `Extract-XrefEntries` | 5 | Match by filename/path, no match, empty |
| `Build-TargetedContext` | 14 | Full context, arch-only, xref-only, neither, 50-entry cap |
| `Get-DocRelPath` | 2 | Normal path, backslash normalization |
| End-to-end | 12 | Key derivation, arch/xref matching, context assembly, cross-subsystem exclusion |

### archpass2.ps1 (81 tests)

```powershell
.\archpass2.ps1 -Test
```

| Function | Tests | What's Verified |
|---|---|---|
| `Cfg` | 4 | Key lookup, missing, empty, no default |
| `Get-SHA1` | 3 | Hex format, determinism, collision |
| `Test-RateLimit` | 9 | 429, rate/usage limit, too many requests, overloaded, quota, negatives |
| `Get-FenceLang` | 9 | c, cpp, csharp, python, rust, hlsl, gdscript, toml, fallback |
| `Get-Pass2FileScore` | 8 | Zero values, weighted formula, Serena discount, hub-beats-big ranking |
| `Get-Pass2FileComplexity` | 6 | Tiered off, >1000 lines, >10 refs, both, boundary |
| **archpass2_worker.ps1** | | |
| `Test-TooLong` | 6 | All 4 positive, 2 negative |
| `Write-ErrorLog` | 7 | Type, file, exit code, stdout, stderr, timestamp, divider |
| `Get-RateLimitResetTime` | 5 | 12h time, ISO, unix, no-match |
| `Format-LocalTime` | 2 | PM formatting |
| `Build-Pass2Payload` | 31 | All 4 stages, truncation at 500/200/100, targeted context, global fallback |

---

## Exit Codes

All test runners exit with:
- `0` — all tests passed
- `N` — number of failed tests (PowerShell scripts)
- `1` — one or more failures (Python unittest)

---

## How Helper Scripts Are Tested

Worker scripts (`archgen_worker.ps1`, `archpass2_worker.ps1`) cannot run standalone because they expect to be dispatched via `Start-Job`. Their functions are loaded into the parent script's test block using PowerShell AST extraction:

```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile($workerPath, [ref]$null, [ref]$null)
$funcDefs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($fd in $funcDefs) { Invoke-Expression $fd.Extent.Text }
```

This evaluates only the `function` definitions from the worker, making them callable in the parent script's test scope without executing any of the worker's main logic.

---

## What's NOT Tested

- **Claude API calls** — all Claude interactions are mocked away by testing only the pure functions that build payloads, parse responses, and detect errors. The actual `claude` CLI invocation is untestable without an API key.
- **clangd interactions** — `ClangdClient`, `extract_file()`, and `ExtractionWorker._run()` in `serena_extract.py` require a running clangd process with a built index. The pure functions that process clangd's output (symbol flattening, URI conversion, source trimming) are tested.
- **Disk I/O side effects in main loops** — the main dispatch/drain loops in `archgen.ps1`, `archpass2.ps1`, and `arch_overview.ps1` are not tested end-to-end. The individual functions they call are tested.
- **Rate-limit sleep/retry behavior** — `Wait-UntilResumeTime` and retry loops involve real `Start-Sleep` calls. The detection functions (`Test-RateLimit`, `Get-RateLimitResetTime`) that feed into them are tested.
