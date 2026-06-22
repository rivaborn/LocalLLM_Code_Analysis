# Serena + Archgen + Unreal Engine 5.7.3: Complete Reference

This document is the definitive summary of the entire multi-session effort to integrate Serena (an LSP-based semantic code analysis MCP server) with the archgen architecture documentation toolchain, targeting the Unreal Engine 5.7.3 source tree. It covers every problem encountered, every root cause identified, every solution applied, and the final verified-working configuration.

---

## Table of Contents

1. [Project Goals](#1-project-goals)
2. [Environment](#2-environment)
3. [Archgen Toolchain](#3-archgen-toolchain) — Pipeline stages, token optimizations, prompt files
4. [Unreal Engine 5.7.3 Setup](#4-unreal-engine-573-setup)
5. [Generating compile_commands.json](#5-generating-compile_commandsjson)
6. [Serena Installation](#6-serena-installation)
7. [Serena Configuration and Bugs](#7-serena-configuration-and-bugs)
8. [clangd Configuration for UE Scale](#8-clangd-configuration-for-ue-scale)
9. [clangd Background Indexing: The Overnight Run](#9-clangd-background-indexing-the-overnight-run)
10. [Serena Verification and LSP Status](#10-serena-verification-and-lsp-status)
11. [Serena Integration with Archgen Pipeline](#11-serena-integration-with-archgen-pipeline) — Adaptive parallel extraction, token optimizations, targeted context, selective Pass 2
12. [Quake 2 Rerelease DLL Configuration](#12-quake-2-rerelease-dll-configuration)
13. [Complete Working Configuration Files](#13-complete-working-configuration-files)
14. [Outstanding Issues](#14-outstanding-issues)
15. [Lessons Learned](#15-lessons-learned) — 29 lessons across UE, clangd, LSP extraction, token optimization, and tooling
16. [Quick Reference Commands](#16-quick-reference-commands)

---

## 1. Project Goals

The overarching objective was to build a multi-pass architecture documentation pipeline for large C++ game engine codebases, combining:

- **Archgen** — A PowerShell toolchain that uses Claude CLI to generate per-file and subsystem-level architecture documentation.
- **Serena** — An MCP server providing LSP-backed semantic code analysis (symbol lookup, cross-file references, call hierarchies) via clangd.
- **Target codebases** — Unreal Engine 5.7.3 (massive, ~43K translation units) and Quake 2 Rerelease DLL (moderate, ~150 files).

The key value proposition: Serena's clangd integration provides **ground-truth** symbol definitions and cross-file references, significantly more accurate than the text-mined cross-references from archgen's `archxref.ps1`. This data is injected into Pass 2 to produce architecturally enriched documentation.

---

## 2. Environment

| Item                  | Detail                                                                       |
|-----------------------|------------------------------------------------------------------------------|
| **OS**                | Windows 11 Home 10.0.26200                                                   |
| **RAM**               | 32 GB                                                                        |
| **Codebase location** | `C:\Coding\Epic_Games\UnrealEngine`                                          |
| **Codebase size**     | 129 GB                                                                       |
| **Repository**        | https://github.com/rivaborn/UnrealEngine (fork of EpicGames/UnrealEngine)    |
| **Branch**            | `release`                                                                    |
| **UE version**        | 5.7.3                                                                        |
| **IDE**               | Visual Studio 2022 with C++ and Clang workloads                              |
| **Python**            | System: 3.14 (pre-release); Pinned for tooling: 3.12                         |
| **clangd version**    | 22.1.0 (installed via VS2022 Clang components)                               |
| **Serena source**     | `git+https://github.com/oraios/serena` (upstream)                            |
| **Package manager**   | uv / uvx (Astral)                                                            |

---

## 3. Archgen Toolchain

The archgen toolchain is a set of PowerShell scripts (with bash equivalents) that use Claude CLI to generate per-file architecture documentation for large game engine codebases.

### 3.1 Pipeline Stages

| Stage            | Script                   | Description                                                                                                                                                               | Claude Calls            | Parallelism                |
|------------------|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------|----------------------------|
| **LSP Extract**  | `serena_extract.ps1`     | Adaptive parallel LSP extraction via clangd. Symbols, references, trimmed source. `-Compress` for LSP compression.                                                        | No (free)               | Multi-worker (auto-scales) |
| **Dir Context**  | `archgen_dirs.ps1`       | Per-directory architectural overviews. Uses sonnet (tiered). Output: `architecture/.dir_context/<dir>.dir.md`.                                                             | Yes (sonnet, few calls) | Sequential                 |
| **Pass 1**       | `archgen.ps1`            | Per-file docs with LSP + dir context + shared headers injection, trivial file skipping, adaptive output budget. Default haiku; auto-upgrades complex files to sonnet. New opt-in: `-MaxTokens`, `-JsonOutput`, `-Classify`. | Yes (haiku/sonnet)      | Parallel (`-Jobs N`)       |
| **Cross-ref**    | `archxref.ps1`           | Function-to-file mappings, call graph edges, global state ownership, subsystem interfaces                                                                                 | No                      | Single-threaded, instant   |
| **Graphs**       | `archgraph.ps1`          | Mermaid call graph + subsystem dependency diagrams                                                                                                                        | No                      | Single-threaded            |
| **Overview**     | `arch_overview.ps1`      | Subsystem-level architecture overview. Auto-chunks for large codebases. Incremental by default (`overview_hashes.tsv`). `-Full` to force regeneration.                    | Yes (sonnet by default) | Sequential                 |
| **P2 Context**   | `archpass2_context.ps1`  | Per-file targeted context extracts for Pass 2                                                                                                                             | No (free)               | Single-threaded, instant   |
| **Pass 2**       | `archpass2.ps1`          | Selective re-analysis with scoring. Uses targeted context. Auto-upgrades complex files to sonnet (`TIERED_MODEL=1` default).                                              | Yes (haiku/sonnet)      | Parallel (`-Jobs N`)       |

### 3.2 Key Features

- **Resumability:** SHA1 hash database tracks which files have been processed; re-running skips already-completed files.
- **Presets:** `--preset unreal`, `--preset quake`, etc. provide correct include/exclude patterns for common engines.
- **Header bundling:** Pass 1 bundles local `#include` headers as additional context (configurable max count). With `BUNDLE_HEADER_DOCS=1`, bundles the analyzed doc (~400 tokens) instead of raw source (~4000 tokens).
- **Chunking:** Overview stage automatically chunks large codebases to stay within context limits.
- **Adaptive parallel extraction:** LSP extraction auto-scales clangd instances based on available RAM, scaling up when resources free and down when tight.
- **Token optimizations:** 8 built-in optimizations (trivial file skipping, adaptive output budget, LSP-guided source trimming, tiered model selection, header doc bundling, batch templated files, compressed prompt, targeted Pass 2 context) can reduce total API cost by up to ~72%. See `Optimization.md`.

### 3.3 Prompt Files

| File                           | Purpose                                                                                                                                                                  |
|--------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `file_doc_prompt.txt`          | Standard per-file analysis (~500 tokens) — file purpose, responsibilities, key types, key functions with signatures, global state, external dependencies, control flow    |
| `file_doc_prompt_lsp.txt`      | LSP-enhanced — instructs Claude to use LSP context authoritatively for cross-references. Auto-selected when LSP context exists.                                           |
| `file_doc_prompt_compact.txt`  | Compressed prompt (~150 tokens) — same schema, terse format. Saves ~350 tokens per call.                                                                                 |
| `file_doc_prompt_learn.txt`    | Learning-oriented variant — adds "Why This File Exists", prerequisites, design patterns, historical context, study questions                                              |
| `file_doc_prompt_pass2.txt`    | Pass 2 enrichment — architectural role, cross-references (incoming/outgoing), design patterns and rationale, data flow, learning notes, potential issues                   |

---

## 4. Unreal Engine 5.7.3 Setup

### 4.1 Setup.bat Hung on Prerequisites

**Problem:** `Setup.bat` hung for hours on "Installing prerequisites..."

**Root cause:** The prerequisites installer opened a silent dialog (UAC or .NET/VC++ runtime prompt) behind the terminal window, waiting for user input that was invisible.

**Solution:** Skip prerequisites entirely and run the dependency downloader directly.

**Critical finding — UE 5.7.3 path change:** The `GitDependencies` executable moved to a platform-specific subfolder. The old path does not exist:

```powershell
# OLD path (UE 4.x / early 5.x) — DOES NOT EXIST in 5.7.3:
.\Engine\Binaries\DotNET\GitDependencies.exe

# NEW path (UE 5.7.3) — self-contained .NET with platform subfolders:
.\Engine\Binaries\DotNET\GitDependencies\win-x64\GitDependencies.exe
```

Available platform subfolders: `win-x64`, `linux-x64`, `osx-arm64`, `osx-x64`.

**Prerequisite note:** Visual C++ redistributables, .NET Framework 4.6.2+, and DirectX Runtime are typically already present if VS2022 with the C++ workload is installed. The prerequisites step is redundant on such systems.

---

## 5. Generating compile_commands.json

A `compile_commands.json` at the repository root is required for clangd (and therefore Serena) to provide semantic code analysis.

### 5.1 Install Clang Toolchain

The first generation attempt failed with: `Clang x64 must be installed in order to build this target.`

**Solution:** Install via Visual Studio Installer → Individual Components:
- C++ Clang Compiler for Windows
- C++ Clang-cl for v143 build tools (x64/x86)

### 5.2 Generate the Database

**Key insight:** Since this is the engine source (not a game project), the command uses no `-project=` or `-game` flags. The target is the engine editor build target. UE 5.x uses `UnrealEditor` (not `UE4Editor`).

```powershell
.\Engine\Build\BatchFiles\RunUBT.bat `
    UnrealEditor Win64 Development `
    -Mode=GenerateClangDatabase `
    -engine -progress
```

### 5.3 Result

- **File size:** 23 MB
- **Lines:** ~218,000
- **Translation units:** ~36,342 (originally estimated at ~43,000; actual count from `"file"` entries is 36,342)
- **Format:** Uses response files (`@"...rsp"`) rather than inline flags

Example entry:
```json
{
    "file": "C:/Coding/Epic_Games/UnrealEngine/Engine/Intermediate/Build/Win64/x64/UnrealEditorGCD/Development/AIGraph/Module.AIGraph.gen.cpp",
    "command": "\"C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/Llvm/x64/bin/clang-cl.exe\" @\"../Intermediate/Build/Win64/x64/UnrealEditorGCD/Development/AIGraph/Module.AIGraph.gen.cpp.obj.rsp\"",
    "directory": "C:/Coding/Epic_Games/UnrealEngine/Engine/Source",
    "output": "..."
}
```

The `.rsp` response files contain full `-I` include paths, `-D` defines, target architecture flags, and C++ standard settings.

---

## 6. Serena Installation

### 6.1 What is Serena

Serena (https://github.com/oraios/serena) is a coding agent toolkit that provides semantic code retrieval and editing through Language Server Protocol (LSP) integration. It supports 30+ languages including C/C++ via clangd. It runs as an MCP (Model Context Protocol) server that integrates with Claude Code.

### 6.2 Install uv (Package Manager)

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

### 6.3 Install Python 3.12

The system Python is 3.14 (pre-release), which causes subtle breakage in third-party libraries. Pin to 3.12 for stability:

```powershell
uv python install 3.12
```

### 6.4 Claude Code MCP Registration

**Problem:** The standard `claude mcp add` command failed because `--from` was parsed as a Claude flag, not passed to `uvx`:

```powershell
# BROKEN — Claude Code parses --from as its own flag
claude mcp add serena -- uvx --from "git+https://github.com/oraios/serena" ...
# error: unknown option '--from'
```

**Solution:** Use the JSON registration form:

```powershell
claude mcp add-json "serena" '{\"command\":\"uvx\",\"args\":[\"--python\",\"3.12\",\"--from\",\"git+https://github.com/oraios/serena\",\"serena\",\"start-mcp-server\",\"--context\",\"claude-code\",\"--project\",\"C:\\Coding\\Epic_Games\\UnrealEngine\"]}'
```

**Key details in the registration:**
- `--python 3.12` — Pins to stable Python, avoids 3.14 pre-release issues
- `--from git+https://github.com/oraios/serena` — Installs from upstream repo
- `--context claude-code` — Tells Serena it's running under Claude Code
- `--project C:\Coding\Epic_Games\UnrealEngine` — Bypasses broken config file projects parsing (see Section 7.1)

---

## 7. Serena Configuration and Bugs

### 7.1 Bug: CommentedMap Config Parser Crash

**Problem:** Adding projects to Serena's global config (`$HOME\.serena\serena_config.yml`) caused a fatal TypeError regardless of format:

```yaml
# BROKEN — dict format
projects:
  - name: UnrealEngine
    path: "C:\\Coding\\Epic_Games\\UnrealEngine"

# ALSO BROKEN — plain string format
projects:
  - "C:\\Coding\\Epic_Games\\UnrealEngine"
```

**Root cause:** A bug in Serena's `serena_config.py` (line 828/831) where `ruamel.yaml`'s `CommentedMap` objects are passed directly to `pathlib.Path()` without converting to string first. The bug exists in both the upstream `oraios/serena` repo and the `rivaborn/serena` fork. It reproduces on Python 3.12 and 3.14 — it is a Serena code bug, not a Python compatibility issue.

**Fix required:** Call `str(path)` before passing to `Path()` in Serena's `from_config_file()` method.

**Workaround:** Pass the project path directly via CLI `--project` flag in the MCP registration, bypassing the config file's projects list entirely.

**Status:** Unresolved upstream. Workaround is stable and effective.

### 7.2 Bug: Windows clangd Platform-ID Mismatch

**Problem:** Serena issue #250 — `runtime_dependencies.json` uses `"windows-x64"` but the code checks for `"win-x64"`, causing clangd auto-download to fail on Windows.

**Status:** Fixed upstream in PR #253.

**Workaround used:** Install clangd manually via VS2022 Clang components (already needed for `compile_commands.json` generation), bypassing the auto-download entirely.

### 7.3 Per-Project Configuration

**File:** `C:\Coding\Epic_Games\UnrealEngine\.serena\project.yml`

```yaml
name: UnrealEngine
languages:
  - cpp

language_servers:
  cpp:
    arguments:
      - "-j=4"
      - "--background-index"
      - "--pch-storage=disk"

ignored_paths:
  - ThirdParty
  - Intermediate
  - Binaries
  - Build
  - DerivedDataCache
  - Saved
  - GeneratedFiles
  - AutomationTool
  - .git

read_only: true
```

**Note on `language_servers.cpp.arguments`:** These flags are passed to clangd on launch. The `-j=4` flag is critical for controlling memory usage at UE scale (see Section 8).

---

## 8. clangd Configuration for UE Scale

### 8.1 The Core Problem

Unreal Engine's `compile_commands.json` contains ~36,342 translation units across a 129 GB source tree. clangd's default behavior is to index all translation units in parallel across all CPU cores. On a 32 GB system, this immediately exhausts RAM and crashes the machine.

### 8.2 Initial Emergency Fix

When the first crash occurred, background indexing was disabled entirely:

```yaml
Index:
  Background: Skip
```

This made Serena usable but **severely degraded** — only regex pattern search worked. Semantic tools (`find_symbol`, `find_referencing_symbols`) were limited to files clangd had explicitly opened in the current session:

| Serena Tool                  | With Background: Skip | With Full Index |
|------------------------------|----------------------|-----------------|
| `search_for_pattern`         | Works (regex-based)  | Works           |
| `find_symbol`                | Only opened files    | Full codebase   |
| `get_symbols_overview`       | Only opened files    | Full codebase   |
| `find_referencing_symbols`   | Severely degraded    | Full codebase   |
| `list_dir`, `find_file`      | Works (filesystem)   | Works           |

The loss of `find_referencing_symbols` was critical — it was the primary reason for integrating Serena.

### 8.3 Final Stable Configuration

The solution was to enable background indexing with aggressive throttling, run it overnight, and let clangd build a persistent disk cache.

**`.clangd` at repository root (`C:\Coding\Epic_Games\UnrealEngine\.clangd`):**

```yaml
Index:
  Background: Build
  StandardLibrary: No

CompileFlags:
  Remove:
    - -W*
    - -fdiagnostics*

Diagnostics:
  UnusedIncludes: None
  MissingIncludes: None
  ClangTidy: false
  Suppress: ["*"]

Completion:
  AllScopes: false
```

**clangd launch arguments (in `.serena/project.yml`):**

```yaml
language_servers:
  cpp:
    arguments:
      - "-j=4"
      - "--background-index"
      - "--pch-storage=disk"
```

### 8.4 Configuration Rationale

| Setting                                        | Purpose                                                                      | Impact                                                                        |
|------------------------------------------------|------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| `Index.Background: Build`                      | Enables background indexing with all diagnostics suppressed                   | Required for full semantic analysis                                            |
| `Index.StandardLibrary: No`                    | Skips standard library header indexing                                        | Saves memory and time; stdlib symbols rarely needed for architecture docs      |
| `CompileFlags.Remove: [-W*, -fdiagnostics*]`   | Strips warning and diagnostic formatting flags from compile commands          | Reduces per-file processing work                                               |
| `Diagnostics.Suppress: ["*"]`                  | Suppresses all diagnostic output                                             | Prevents expensive full-file analysis; we only need indexing, not linting      |
| `Completion.AllScopes: false`                  | Restricts symbol completion to local scope                                   | Lowers RAM usage                                                               |
| `-j=4`                                         | Limits background indexing to 4 parallel threads                             | Caps clangd at ~8–19 GB instead of 25+ GB (which would OOM on 32 GB)          |
| `--pch-storage=disk`                           | Stores precompiled header data on disk instead of RAM                        | Significant memory savings at cost of disk I/O                                 |
| `--background-index`                           | Explicitly enables full background indexing                                  | Required — explicitly overrides any `.clangd` Skip setting                     |

**Fallback:** If `-j=4` causes clangd to exceed 25 GB, reduce to `-j=2`.

---

## 9. clangd Background Indexing: The Overnight Run

### 9.1 Indexing Timeline

The background indexing run was initiated on 2026-03-24 and monitored via a PowerShell RAM watcher:

```powershell
while ($true) {
    $p = Get-Process clangd -ErrorAction SilentlyContinue
    if ($p) {
        $mem = [math]::Round($p.WorkingSet64 / 1GB, 2)
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | RAM: ${mem} GB"
    } else {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | clangd not running"
    }
    Start-Sleep 60
}
```

### 9.2 RAM Profile Over Time

The indexing run exhibited four distinct phases:

| Phase               | Time Window    | RAM Range      | Description                                                                                                                       |
|---------------------|----------------|----------------|-----------------------------------------------------------------------------------------------------------------------------------|
| **Ramp-up**         | 11:21 – 12:20  | 3 – 8 GB       | Initial indexing of simpler translation units                                                                                      |
| **Heavy indexing**  | 12:20 – 19:47  | 8 – 19.4 GB    | Processing 36K TUs with deep UE header chains. Sawtooth pattern as clangd processed batches and released memory between them       |
| **Wind-down**       | 19:47 – 20:10  | 19.4 → 4 GB    | Flushing final index data to disk, releasing working memory                                                                        |
| **Idle**            | 20:10 onward   | ~4 GB (stable)  | Index fully built; clangd holding loaded index in memory, ready for queries                                                        |

**Peak RAM:** 19.4 GB (at 19:21, during the final heavy indexing batch)

**Total indexing time:** ~8.5 hours (11:21 to ~19:47)

### 9.3 Index Statistics

| Metric                        | Value                                                          |
|-------------------------------|----------------------------------------------------------------|
| **Translation units**         | 36,342                                                         |
| **Index files (`.idx`)**      | 112,339                                                        |
| **Index/TU ratio**            | 3.1x (each TU generates idx files for itself + included headers) |
| **Index cache size on disk**  | 1.5 GB                                                         |
| **Cache location**            | `.cache/clangd/index/`                                         |
| **Post-indexing clangd RAM**  | ~4 GB (holding loaded index)                                   |

### 9.4 Key Observations

- The 3.1x ratio of index files to translation units is expected — each `.cpp` file's included headers generate separate `.idx` entries.
- The sawtooth RAM pattern during heavy indexing (constantly fluctuating between 8–19 GB) is characteristic of clangd processing batches of TUs and releasing intermediate memory.
- The sharp drop from 19.4 GB to 4 GB over ~23 minutes confirmed indexing completion, not a crash.
- The idle RAM of ~4 GB is the loaded index footprint — this is the steady-state cost of having clangd ready for queries.
- Zero new `.idx` files were written after 19:47, confirmed across multiple checks spanning 5+ hours.

### 9.5 Subsequent Sessions

After the initial overnight indexing, subsequent Serena/clangd sessions load from the `.cache/clangd/index/` disk cache. The initial loading takes minutes rather than hours, and clangd stabilizes at ~4–8 GB RAM depending on query activity.

---

## 10. Serena Verification and LSP Status

### 10.1 Verification Process

After the overnight indexing completed, Serena was restarted (to clear a stuck task from a pre-indexing query attempt) and verified working across all tool categories.

### 10.2 Filesystem Tools (No LSP Required)

| Tool                           | Status  | Verified                                       |
|--------------------------------|---------|------------------------------------------------|
| `list_dir`                     | Working | Listed 170+ Runtime module directories          |
| `find_file`                    | Working | Filesystem-based                                |
| `check_onboarding_performed`   | Working | Returned expected "not yet onboarded" status    |

### 10.3 Semantic LSP Tools (Require clangd Index)

| Tool                         | Status      | Verified                                                                                                                                          |
|------------------------------|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `find_symbol`                | **Working** | Found `AActor` class across 80+ files in Engine/Source/Runtime/Engine, including full class definition at `GameFramework/Actor.h` lines 255–4673   |
| `get_symbols_overview`       | Working     | Returns symbol tree for indexed files                                                                                                              |
| `find_referencing_symbols`   | Working     | Full cross-file reference resolution across all 36K TUs                                                                                            |
| `search_for_pattern`         | Working     | Regex-based search across codebase                                                                                                                 |

### 10.4 Confirmed Working Query Example

A `find_symbol` query for `AActor` in `Engine/Source/Runtime/Engine` returned:
- The main class definition at `GameFramework/Actor.h` (lines 255–4673, ~4400 lines)
- Forward declarations and references across 80+ header files
- Constructor overloads with name paths like `AActor[1]/AActor[0]`, `AActor[1]/AActor[1]`
- Symbol kinds (Class, Constructor) and precise line locations

This confirms the full clangd index is loaded and serving semantic queries through Serena.

### 10.5 Known Issue: Stuck Tasks on Restart

If a Serena query is issued while clangd is still indexing, the query will time out but remain in Serena's internal task queue. Subsequent queries may also hang because Serena is blocked on the stuck task.

**Solution:** Restart the Serena MCP server after clangd finishes indexing. clangd runs as a separate process and is unaffected by Serena restarts. Use `/mcp` in Claude Code to access the MCP management menu, or start a new Claude Code session (Serena auto-launches from the MCP registration).

---

## 11. Serena Integration with Archgen Pipeline

### 11.1 Integration Strategy (Revised — Serena-First)

The key insight: LSP extraction costs zero Claude tokens (it talks directly to clangd via LSP protocol), so it should run **first** to enrich Pass 1 from the start. This produces better docs in one pass and reduces the need for Pass 2.

**Revised pipeline order (v3):**

0. **`serena_extract.ps1`** — Direct LSP extraction via clangd. Zero Claude calls. Produces `.serena_context.txt` per file. New `-Compress` flag for LSP compression.
0b. **`archgen_dirs.ps1` (NEW v3)** — Per-directory architectural overviews. Few Claude calls (sonnet). Output: `architecture/.dir_context/<dir>.dir.md`.
1. **`archgen.ps1` (MODIFIED)** — Pass 1 now auto-detects and injects LSP context + directory overviews + shared headers. Pre-computes common includes (80%+ threshold) into `architecture/.dir_headers/`. New opt-in flags: `-MaxTokens`, `-JsonOutput`, `-Classify`.
2. **`archxref.ps1`** — Unchanged.
3. **`archgraph.ps1`** — Unchanged.
4. **`arch_overview.ps1` (MODIFIED)** — Now incremental by default (tracks hashes in `overview_hashes.tsv`). New `-Full` flag to force regeneration.
4b. **`archpass2_context.ps1`** — Unchanged.
5. **`archpass2.ps1`** — Selective. `-Top N` limits to highest-value files. Supports `TIERED_MODEL`.

### 11.2 Serena Extraction Script Design

The extraction system consists of two files:

**`serena_extract.py`** — Python script that:
- Spawns **multiple clangd processes** (adaptive parallel workers) and communicates via LSP JSON-RPC over stdio
- Workers pull files from a **shared queue** — whoever finishes first grabs the next file
- **RAM monitoring** every ~60 seconds: scales up when >10 GB free, scales down when <4 GB free
- Uses the pre-built index (`.cache/clangd/index/`, loads in ~3 seconds per worker)
- For each file: `didOpen` → `documentSymbol` → `references` (optional, skippable with `--skip-refs`) → `didClose`
- Generates **LSP-trimmed source** for large files (>800 lines) using symbol ranges — key code sections instead of the full file
- Each clangd instance restarts every 1000 files to reclaim accumulated memory
- **Crash recovery**: detects clangd crashes (broken pipe / Errno 22), auto-restarts the process, retries the current file once
- Writes **per-file performance log** (`perf.log`) and **error log** (`errors.log`) with timing breakdown and failure diagnostics
- **Incremental support**: empty files (no symbols) are recorded in hash DB and skipped on rerun; failed files are NOT recorded and will retry automatically
- ETA calculated from successfully completed files only (empty/failed excluded to avoid inflating the rate)
- Caps references at 20 per symbol, 10-second timeout per reference query
- **Zero Claude API calls. Zero tokens.**

**`serena_extract.ps1`** — PowerShell wrapper that:
- Reads `.env` for preset/include/exclude patterns
- Verifies prerequisites (compile_commands.json, clangd index)
- Passes `-Workers`, `-SkipRefs`, `-MinFreeRAM`, `-RAMPerWorker` flags through
- Invokes `uv run --python 3.12 serena_extract.py` with the right arguments

**Progress display** (single-line, overwrites in place via `[Console]::Write()`):
```
  500/20000  done=480 empty=15 fail=5  avg=0.4/s now=0.6/s  w=2  clangd=8.3GB free=12.1GB  eta=0h54m33s
```
Progress uses hash DB line counting via `StreamReader` (append-only file, no contention with writers) and `[Console]::Write()` for single-line in-place updates. ETA is displayed in h:m:s format.

**Output format (`architecture/.serena_context/<path>.serena_context.txt`):**

```
=== LSP CONTEXT FOR: Engine/Source/Runtime/Core/Private/Math/UnrealMath.cpp ===

## Symbol Overview
### Classes / Structs / Enums
- FMath (Class, lines 45-78)

### Functions
- GetDerivedDataCache (lines 200-210)

### Methods
- FMath::RandInit (lines 80-92)
- FMath::RandHelper (lines 94-110)

### File-Scope Variables
- GRandState (line 40)

## Incoming References (who calls/uses symbols defined here)
- FMath::RandHelper:
  - Engine/Source/Runtime/Engine/Private/Actor.cpp:1204
  - Engine/Source/Runtime/AIModule/Private/BehaviorTree/BTTask.cpp:445
  - [8 more references]

## Direct Include Dependencies
- Math/UnrealMathUtility.h
- HAL/Platform.h

## Trimmed Source (key sections only)
```cpp
#include "CoreMinimal.h"
#include "Math/UnrealMath.h"
// ... [220 lines omitted] ...
void FMath::RandInit(int32 Seed)
{
    GRandState = Seed;
    // ...
}
// ... [180 lines omitted] ...
```

### 11.2b Performance Characteristics

clangd parse time per UE file averages **3-8 seconds**, dominated by include chain resolution (every UE file includes `CoreMinimal.h` which pulls in hundreds of headers). File size has minimal impact — a 16-line file takes almost as long as a 2400-line file because the include overhead is the same.

**Workers vs Jobs**: `-Workers` sets the number of clangd **processes** (separate instances, each with its own LSP connection). `-Jobs` sets clangd's internal `-j` flag (how many **threads** each process uses for background work). With `-Workers 3 -Jobs 4`, you get 3 processes x 4 threads = 12 total threads competing for CPU and RAM. Sweet spot for 32 GB: `-Workers 2 -Jobs 2` (~8 GB, 4 total threads).

| Workers | Jobs | Total Threads | Est. RAM |
|---------|------|---------------|----------|
| 3       | 2    | 6             | ~12 GB   |
| 2       | 4    | 8             | ~10 GB   |
| 2       | 2    | 4             | ~8 GB    |
| 1       | 4    | 4             | ~6 GB    |

| Workers | Throughput | Time for 20K files | RAM (32 GB system) |
|---------|------------|---------------------|---------------------|
| 1       | ~0.2/s     | ~28 hours           | ~4-6 GB             |
| 2       | ~0.4/s     | ~14 hours           | ~8-12 GB            |
| 3       | ~0.6/s     | ~9 hours            | ~12-18 GB           |

The `-SkipRefs` flag has minimal impact on speed (references take <0.1s per file for UE). The bottleneck is `documentSymbol` which requires a full file parse.

**PCH disk usage warning**: clangd's `--pch-storage=disk` writes `preamble-*.pch` files to the system temp directory, averaging ~80 MB each for UE files (due to `CoreMinimal.h`'s deep include chain). With multiple workers processing thousands of files, orphaned PCH files can accumulate to **50+ GB** if not cleaned up. The script now automatically cleans up session-created PCH files on shutdown and via `atexit`. To manually clean up after an interrupted run: `Remove-Item "$env:TEMP\preamble-*.pch" -Force`.

**I/O contention with too many workers**: More workers does not always mean more throughput. At UE scale, disk I/O (reading headers, PCH files) is the bottleneck, not CPU. 7 workers at `-Jobs 3` (21 threads) was observed to drop throughput from 0.6/s to 0.4/s compared to 2-3 workers, due to I/O contention. Cap workers explicitly for best results.

### 11.3 Modified archgen_worker.ps1

**Bug fix -- `$relList` array unwrap:** PowerShell 5.1's `if/else` expression unwraps single-element arrays to scalars. The line `$relList = if ($isBatch) { $rel -split '|' } else { @($rel) }` returned a string instead of an array for individual (non-batch) files. Then `$relList[0]` indexed the first character of the path string (e.g., `"E"` from `"Engine/..."`) instead of returning the whole path. Fix: wrap the entire `if/else` in `@()` -- `$relList = @(if (...) { ... } else { ... })`. Batch files worked because `-split` returns a multi-element array that survives unwrapping.

**Changes:**
- New parameters: `$serenaContextDir`, `$bundleHeaderDocs`, `$outputBudget`
- Loads `.serena_context.txt` if available for the current file
- Injects LSP context into the Claude payload at stages 0 and 1
- Uses **LSP-trimmed source** for large files instead of blunt head+tail truncation
- Bundles header `.md` docs instead of raw source when `BUNDLE_HEADER_DOCS=1`
- Appends **adaptive output budget** instruction to payload

**Fallback chain:**
| Stage | Source                     | Headers              | LSP Context |
|-------|---------------------------|----------------------|-------------|
| 0     | Full or LSP-trimmed       | Bundled (raw or doc) | Yes         |
| 1     | Full or LSP-trimmed       | Dropped              | Yes         |
| 2     | 25% truncated (head+tail) | Dropped              | Dropped     |

### 11.4 Modified archgen.ps1

**Changes:**
- Auto-detects `architecture/.serena_context/` directory
- If present, auto-selects `file_doc_prompt_lsp.txt` (falls back to standard prompt if missing)
- Passes `$serenaContextDir`, `$bundleHdrDoc`, `$outputBudget` to workers
- **Skips trivial/generated files** (`SKIP_TRIVIAL=1`): `.generated.h`, `.gen.cpp`, `Module.*.cpp`, files <20 lines
- **Tiered model selection** (`TIERED_MODEL=1`, default): routes high-complexity files to sonnet, others to haiku. Set `TIERED_MODEL=0` to use `CLAUDE_MODEL` for all files.
- **Batch templated files** (`BATCH_TEMPLATED=1`): groups structurally identical files, analyzes one representative
- **Adaptive output budget**: sets per-file token budget based on file size and symbol count
- Displays "Serena context: YES/NO" and skip counts (unchanged, trivial, batched) in the banner

### 11.5 New Prompts

**`file_doc_prompt_lsp.txt`** — Enhanced variant that instructs Claude to use LSP context authoritatively for cross-references, populate "Called by" fields, and use specific file locations from LSP data. ~1200-1500 token output.

**`file_doc_prompt_compact.txt`** — Compressed prompt (~150 tokens vs ~500). Same output schema in terse format. References `OUTPUT_BUDGET` appended by the worker. Saves ~7M input tokens over 20K files.

### 11.6 New: archpass2_context.ps1 — Targeted Pass 2 Context

Instead of injecting the same 200+300 line global context blobs into every Pass 2 call, this script pre-extracts **only the relevant portions** per file. Zero Claude calls, runs in seconds.

For each file, it extracts:
- Architecture overview paragraphs matching the file's subsystem
- xref index lines mentioning the file's name or path

Result: 30-80 lines of targeted context instead of 500 lines of mostly irrelevant context. The Pass 2 worker auto-detects `.pass2_context/<path>.ctx.txt` files.

### 11.7 Modified archpass2.ps1 — Selective Pass 2

**New parameters:**
- `-Top N` — Only process the N highest-scoring files (0 = all, default behavior)
- `-ScoreOnly` — Print scores without running Pass 2 (for tuning)

**Scoring formula:**
```
score = (incoming_ref_count * 3) + (line_count / 100)
if has_serena_context: score *= 0.5  # Discount: Pass 1 was already enriched
```

Files with high incoming reference counts are "hub" files (called by many others). Files that already had LSP context in Pass 1 are discounted since they were already enriched.

### 11.8 Complete Pipeline (Unreal Engine)

```powershell
cd C:\Coding\Epic_Games\UnrealEngine

# 0. LSP extraction (zero Claude calls, adaptive parallel clangd)
.\serena_extract.ps1 -Preset unreal -Workers 3

# 0b. Directory-level overviews (few Claude calls, sonnet)
.\archgen_dirs.ps1 -Preset unreal

# 1. Pass 1: per-file docs with LSP + dir context + shared headers + all optimizations
.\archgen.ps1 -Preset unreal -Jobs 8

# 2. Cross-reference index (no Claude calls, instant)
.\archxref.ps1

# 3. Call graph diagrams (no Claude calls, instant)
.\archgraph.ps1

# 4. Architecture overview (incremental by default, chunked for UE)
.\arch_overview.ps1 -Preset unreal

# 4b. Targeted per-file context for Pass 2 (instant, free)
.\archpass2_context.ps1

# 5. Pass 2: selective re-analysis of highest-value files only
.\archpass2.ps1 -Preset unreal -Jobs 8 -Top 500
```

Step 0 is free (zero tokens, ~9 hours at 3 workers for full UE). Step 0b generates directory overviews used as context in Step 1 (few sonnet calls). Step 1 auto-skips trivial files and uses LSP + dir context + shared headers. Steps 2-4b are free. Step 4 is incremental (unchanged subsystems skip on re-run). Step 5 processes only the top 500 files with targeted context — a ~93% reduction in Pass 2 calls and ~50% reduction in per-call input tokens.

---

## 12. Quake 2 Rerelease DLL Configuration

### 12.1 Codebase Profile

| Item              | Detail                                                                                                                                             |
|-------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| **Repo**          | https://github.com/id-Software/quake2-rerelease-dll                                                                                                |
| **Language**      | C++17 (compiles under C++17 and C++20)                                                                                                             |
| **Structure**     | Combined codebase merging baseq2, CTF, Rogue (Ground Zero), Xatrix (The Reckoning)                                                                |
| **Key features**  | New server-game API (game_export_t/game_import_t), client game module (cgame), instanced items, split-screen co-op, bot support, nav editor, N64 campaign |
| **Size**          | ~150 source files under `rerelease/`                                                                                                               |

### 12.2 .env Configuration

| Setting                | Value       | Rationale                                                                      |
|------------------------|-------------|--------------------------------------------------------------------------------|
| `PRESET`               | `quake`     | Correct include/exclude patterns for id Software codebases                      |
| `CLAUDE_MODEL`         | `haiku`     | Sufficient for straightforward C++ game logic; fast                             |
| `JOBS`                 | `8`         | Matches system parallelism tuning                                               |
| `CODEBASE_DESC`        | Custom      | Calls out combined expansion packs, KEX API, C++17, naming conventions          |
| `EXCLUDE_DIRS_REGEX`   | Added `fmt` | Excludes bundled fmtlib source                                                  |
| `BUNDLE_HEADERS`       | `1`         | Enabled with max 8 bundled headers                                              |
| `CHUNK_THRESHOLD`      | `1500`      | Safety net for overview chunking                                                |

### 12.3 Pipeline (No Serena Needed)

```powershell
cd <quake2-rerelease-dll repo root>
.\archgen.ps1 -TargetDir rerelease -Preset quake -Jobs 8
.\archxref.ps1
.\archgraph.ps1
.\arch_overview.ps1 -Preset quake
.\archpass2.ps1 -Preset quake -Jobs 8
```

---

## 13. Complete Working Configuration Files

### 13.1 `.clangd` (Repository Root)

```yaml
Index:
  Background: Build
  StandardLibrary: No

CompileFlags:
  Remove:
    - -W*
    - -fdiagnostics*

Diagnostics:
  UnusedIncludes: None
  MissingIncludes: None
  ClangTidy: false
  Suppress: ["*"]

Completion:
  AllScopes: false
```

### 13.2 `.serena/project.yml`

```yaml
name: UnrealEngine
languages:
  - cpp

language_servers:
  cpp:
    arguments:
      - "-j=4"
      - "--background-index"
      - "--pch-storage=disk"

ignored_paths:
  - ThirdParty
  - Intermediate
  - Binaries
  - Build
  - DerivedDataCache
  - Saved
  - GeneratedFiles
  - AutomationTool
  - .git

read_only: true
```

### 13.3 Claude Code MCP Registration (JSON)

```powershell
claude mcp add-json "serena" '{\"command\":\"uvx\",\"args\":[\"--python\",\"3.12\",\"--from\",\"git+https://github.com/oraios/serena\",\"serena\",\"start-mcp-server\",\"--context\",\"claude-code\",\"--project\",\"C:\\Coding\\Epic_Games\\UnrealEngine\"]}'
```

### 13.4 clangd RAM Monitor (PowerShell)

```powershell
while ($true) {
    $p = Get-Process clangd -ErrorAction SilentlyContinue
    if ($p) {
        $mem = [math]::Round($p.WorkingSet64 / 1GB, 2)
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | RAM: ${mem} GB"
    } else {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | clangd not running"
    }
    Start-Sleep 60
}
```

---

## 14. Outstanding Issues

| Issue                                           | Status                    | Impact | Notes                                                                                                                                                                                            |
|-------------------------------------------------|---------------------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Serena `CommentedMap` config bug                | **Unresolved**            | Low    | Workaround: pass `--project` via CLI instead of config file. Fix needed in `serena_config.py` `from_config_file()` to call `str(path)` before `Path()`                                          |
| Serena Windows clangd platform-ID bug (#250)    | **Fixed upstream** (#253) | None   | Bypassed by installing clangd via VS2022                                                                                                                                                         |
| clangd background indexing RAM usage            | **Resolved**              | None   | `-j=4` + `--pch-storage=disk` peaked at 19.4 GB on 32 GB system. Completed successfully in ~8.5 hours                                                                                           |
| clangd index persistence                        | **Verified**              | None   | 1.5 GB cache at `.cache/clangd/index/` survives across sessions                                                                                                                                  |
| Serena stuck task on timeout                    | **Known behavior**        | Low    | Restart Serena MCP after clangd finishes indexing if queries were attempted during indexing                                                                                                       |
| LSP extraction speed                            | **Understood**            | Medium | clangd parses each UE file in 3-8s due to deep include chains. File size irrelevant — bottleneck is `CoreMinimal.h` expansion. Parallel workers provide linear speedup.                          |
| clangd crashes during extraction                | **Resolved**              | None   | Workers auto-detect broken pipe (Errno 22), restart clangd, and retry the file once. First run on full UE saw 2323 failures from 2 clangd crashes — all from workers 1 and 2 in a few seconds. Crash recovery prevents cascading failures. |
| Empty files (no symbols) on rerun               | **Resolved**              | None   | Empty files now record their hash in the DB and are skipped on rerun. `.cs` files, bridging headers, and forward-declaration-only headers are expected empties.                                   |
| `serena_extract.py` tested                      | **Working**               | None   | Adaptive parallel extraction runs against full UE codebase. Performance log confirms `documentSymbol` is the bottleneck. Error log captures EMPTY/FAIL/CRASH/RESTART events.                     |
| PCH disk usage (preamble-*.pch)                 | **Resolved**              | None   | clangd `--pch-storage=disk` wrote 50+ GB of orphaned PCH files to temp. Fixed: `serena_extract.py` now snapshots existing PCH at startup and cleans up session files on shutdown + atexit.        |
| I/O contention with many workers                | **Understood**            | Medium | Auto-scaler can spawn too many workers (observed: 7 workers, 21 threads). Disk I/O contention drops throughput from 0.6/s to 0.4/s. Recommendation: cap workers explicitly (`-Workers 2 -Jobs 2`). |
| `archpass2.ps1` scoring tuning                  | **Pending**               | Low    | `-Top` threshold and scoring weights may need adjustment after first real run                                                                                                                     |
| Token optimization tuning                       | **Pending**               | Low    | `TIERED_MODEL`, `BUNDLE_HEADER_DOCS`, `BATCH_TEMPLATED` settings implemented but not yet tuned against real output quality                                                                       |
| v3 opt-in features tuning                       | **Pending**               | Low    | `USE_MAX_TOKENS`, `JSON_OUTPUT`, `CLASSIFY_FILES` implemented but not yet validated at scale                                                                                                     |
| Rate limits during extraction                   | **No longer applicable**  | None   | Extraction talks directly to clangd, bypassing Claude entirely                                                                                                                                   |

---

## 15. Lessons Learned

### 15.1 Unreal Engine Specifics

1. **UE 5.7.3 file layout changed:** `GitDependencies.exe` moved from `Engine\Binaries\DotNET\GitDependencies.exe` to `Engine\Binaries\DotNET\GitDependencies\win-x64\GitDependencies.exe` (platform-specific subfolders for self-contained .NET).

2. **Engine-only GenerateClangDatabase:** No `-project` or `-game` flags needed. Use `UnrealEditor Win64 Development` as positional target arguments.

3. **Setup.bat prerequisites are redundant** on systems with VS2022 + C++ workload already installed. Skip directly to `GitDependencies.exe` if `Setup.bat` hangs.

### 15.2 clangd at Scale

4. **clangd + UE scale is at the extreme edge:** 36K translation units with deep template-heavy headers. Background indexing without throttling will OOM a 32 GB system.

5. **The practical configuration is `-j=4` with `--pch-storage=disk`:** This caps RAM at ~19 GB peak and completes indexing in ~8.5 hours. The resulting 1.5 GB disk cache persists across sessions.

6. **Post-indexing steady state is ~4 GB RAM:** clangd holds the loaded index in memory and responds to queries quickly.

7. **Disable all diagnostics for indexing-only use:** `Suppress: ["*"]` and `ClangTidy: false` prevent expensive analysis that's unnecessary when the goal is symbol indexing.

### 15.3 Serena and LSP Extraction

8. **Serena's sweet spot is codebases up to ~5K–10K files** where full background indexing is quick. For UE-scale codebases, direct clangd extraction (`serena_extract.py`) is more practical than interactive Serena queries.

9. **`claude mcp add` flag parsing is unreliable:** The `--` separator doesn't reliably prevent Claude Code from parsing flags meant for the subprocess. Always use `claude mcp add-json` with escaped JSON for complex MCP registrations.

10. **Serena queries during indexing will time out and block:** Always wait for clangd indexing to complete before issuing Serena LSP queries. If queries were attempted during indexing, restart Serena to clear stuck tasks.

11. **clangd parse time for UE files is 3-8 seconds regardless of file size.** The bottleneck is include chain resolution (`CoreMinimal.h` pulls in hundreds of headers), not the file's own code. A 16-line file takes almost as long as a 2400-line file.

12. **Parallel clangd instances scale linearly.** Each instance loads the same read-only disk index and parses files independently. 3 workers on 32 GB = ~3x throughput. The shared queue ensures even load distribution.

13. **Reference queries are essentially free** once a file is parsed. `find_references` takes <0.1s per symbol because the index is pre-built. The `--skip-refs` flag has minimal speed impact — the bottleneck is always `documentSymbol` (which triggers the parse).

14. **LSP-guided source trimming provides more value than raw truncation.** Using symbol ranges to extract key code sections means Claude sees the function signatures, constructors, and important methods rather than the copyright header and a random tail section.

### 15.4 Token Optimization

15. **Skipping generated files is the single biggest win.** UE has ~30-40% generated/trivial files (`.generated.h`, `.gen.cpp`, `Module.*.cpp`). Writing stub docs instead of Claude calls saves thousands of API calls.

16. **Adaptive output budget prevents wasted tokens on small files.** A 30-line header doesn't need 1000 tokens of analysis. Setting per-file budgets (~200 to ~1200 tokens based on size) reduces total output by 10-20%.

17. **Compressed prompts save ~350 tokens per call.** `file_doc_prompt_compact.txt` is ~150 tokens vs ~500 for the standard prompt. Claude produces identical quality output. Over 20K files, this saves ~7M input tokens.

18. **Per-file targeted Pass 2 context saves 40-50% of Pass 2 input.** Instead of 500 lines of global context (mostly irrelevant), each file gets 30-80 lines of relevant arch/xref data.

### 15.5 Python and Tooling

19. **Python 3.14 is risky for production tooling:** Pre-release Python breaks third-party libraries (`ruamel.yaml`, etc.) in subtle ways. Always pin to 3.12 via `uvx --python 3.12`.

20. **uv/uvx is the cleanest way to manage Serena's Python environment:** Handles virtual environments, dependency resolution, and Python version pinning in a single tool.

21. **Byte-by-byte LSP reading is O(n²).** The initial LSP reader implementation read one byte at a time with `buf += chunk` concatenation. This is quadratic and causes progressive slowdown. Always read headers line-by-line and bodies in one `read(length)` call.

22. **clangd crashes are silent and cascading.** When clangd dies, its pipe becomes invalid. Every subsequent LSP call throws `[Errno 22] Invalid argument` instantly. Without crash detection, a single crash fails every remaining file in that worker's queue (2323 failures from 2 crashes in the first full UE run). The fix: check `proc.poll()` before each file, catch `OSError` separately, restart clangd, and retry once.

23. **Empty files must be recorded to avoid infinite reprocessing.** Files where clangd returns no symbols (`.cs` files, bridging headers, forward-declaration-only headers) will always be empty. Without recording their hash, every rerun wastes 3-8 seconds per file re-parsing them. Record the hash even when no output file is written.

24. **ETA should exclude empty/failed files.** Empty and failed files resolve near-instantly (no symbols to extract or immediate crash). Including them in the rate calculation inflates the throughput and produces optimistically short ETAs. Calculate rate from `done` files only.

25. **Windows `tasklist /FO CSV` needs proper CSV parsing.** The memory column contains commas inside quoted fields (e.g., `"5,711,560 K"`). Naive `split(",")` breaks the parse. Use Python's `csv.reader` which handles quoted fields correctly.

### 15.6 v3 Optimizations

26. **Directory-level overviews provide valuable architectural context for Pass 1.** Having `archgen_dirs.ps1` generate per-directory overviews before Pass 1 means each file's Claude call has context about the directory's purpose and structure. Few sonnet calls for significant quality uplift.

27. **Shared directory headers reduce redundant bundling.** Pre-computing common includes (80%+ threshold) per directory means workers load shared headers once rather than re-bundling the same headers for every file. Saves both input tokens and processing time.

28. **Incremental overview saves significant time on re-runs.** Tracking subsystem doc hashes in `overview_hashes.tsv` means unchanged subsystems skip entirely on re-run. Only modified subsystems get regenerated, dramatically reducing Claude calls for iterative development.

29. **Two-phase classification is more accurate than pattern matching for trivial file detection.** An ultra-cheap haiku call classifying files as ANALYZE or STUB catches trivial files that string patterns miss, while avoiding false positives on files that look generated but contain real logic.

### 15.7 v4 Optimizations

30. **`--pch-storage=disk` can silently consume 50+ GB of SSD space.** clangd writes `preamble-*.pch` files to the system temp directory for each file parsed. UE files average ~80 MB per PCH due to `CoreMinimal.h`'s deep include chain. With multiple workers and clangd restarts every 1000 files, orphaned PCH files accumulate because crashed or restarted clangd processes don't clean up after themselves. The fix: snapshot existing PCH files at startup, clean up session-created files at shutdown and via `atexit`. Do NOT clean up mid-run — active clangd instances reuse PCH files across parses, and deleting them forces expensive rebuilds that degrade throughput.

31. **More parallel workers can reduce throughput.** Auto-scaling spawned 7 clangd workers (21 threads) on a 32 GB system. Throughput dropped from 0.6/s to 0.4/s compared to 2-3 workers. At UE scale, the bottleneck is disk I/O (reading headers and PCH files from SSD), not CPU. Too many workers create I/O contention where all workers slow down. Always cap workers explicitly on I/O-bound workloads.

32. **PowerShell 5.1 `if/else` expressions unwrap single-element arrays.** When an `if/else` is used as an expression (assigned to a variable), PowerShell 5.1 unwraps the result if it is a single-element array, turning it into a scalar. Indexing a string with `[0]` then returns the first character, not the whole string. Always wrap expression-form `if/else` in `@()` to guarantee array semantics: `$list = @(if (...) { ... } else { ... })`.

33. **Single-child directories must be descended during recursive subsystem splitting.** In `arch_overview.ps1`, the chunking logic that recursively splits oversized subsystems must detect and descend through directories with only one child. Otherwise, paths like `Engine/Source/Runtime/Engine/Private` get treated as one oversized chunk instead of splitting into their subdirectories. The fix: when a directory has exactly one child subdirectory, automatically descend into it before applying the size threshold.

34. **Prompt caching is a transparent cost reduction with no quality impact.** By using a fixed system prompt (`file_doc_system_prompt.txt`) identical across all Claude calls and embedding the per-file prompt schema in the user message, the API caches the system prompt at ~10% of the full token rate. Over 20K calls with a ~500 token system prompt, this saves ~9M tokens worth of cost. No CLI flags or `.env` variables needed — always active.

---

## 16. Quick Reference Commands

### Initial Setup (One-Time)

```powershell
# Install uv
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"

# Install Python 3.12
uv python install 3.12

# Install VS2022 Clang components (via VS Installer):
#   - C++ Clang Compiler for Windows
#   - C++ Clang-cl for v143 build tools (x64/x86)

# Generate compile_commands.json
.\Engine\Build\BatchFiles\RunUBT.bat UnrealEditor Win64 Development -Mode=GenerateClangDatabase -engine -progress

# Register Serena MCP server
claude mcp add-json "serena" '{\"command\":\"uvx\",\"args\":[\"--python\",\"3.12\",\"--from\",\"git+https://github.com/oraios/serena\",\"serena\",\"start-mcp-server\",\"--context\",\"claude-code\",\"--project\",\"C:\\Coding\\Epic_Games\\UnrealEngine\"]}'
```

### Start Indexing (First Time or After Cache Clear)

1. Ensure `.clangd` and `.serena/project.yml` are configured per Section 13.
2. Start a Claude Code session in the UE directory (Serena auto-launches).
3. Monitor clangd RAM with the PowerShell watcher (Section 13.4).
4. Wait for RAM to stabilize at ~4 GB (indexing complete).
5. Restart Serena if any queries were attempted during indexing.

### Daily Use (After Index Is Built)

```powershell
# Start Claude Code — Serena auto-launches and loads cached index
claude

# Verify Serena is working (in Claude Code)
# Try: find_symbol for AActor, list_dir, etc.
```

### Full Archgen Pipeline (Serena-First, All Optimizations)

```powershell
.\serena_extract.ps1 -Preset unreal -Workers 3    # LSP extraction (free, adaptive parallel)
.\archgen_dirs.ps1 -Preset unreal                  # Dir-level overviews (few Claude calls)
.\archgen.ps1 -Preset unreal -Jobs 8               # Pass 1 (LSP + dir context + shared headers)
.\archxref.ps1                                      # Cross-references
.\archgraph.ps1                                     # Call graph diagrams
.\arch_overview.ps1 -Preset unreal                  # Overview (incremental by default)
.\archpass2_context.ps1                              # Targeted Pass 2 context (free)
.\archpass2.ps1 -Preset unreal -Jobs 8 -Top 500     # Pass 2 (selective, targeted context)
```

### Fast Extraction (Symbols Only)

```powershell
.\serena_extract.ps1 -Preset unreal -Workers 3 -SkipRefs
```

### Monitor clangd During Extraction

```powershell
while ($true) {
    $procs = @(Get-Process clangd -ErrorAction SilentlyContinue)
    $os = Get-CimInstance Win32_OperatingSystem
    $freeGB = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 2)
    $totalGB = [math]::Round(($os.TotalVisibleMemorySize * 1KB) / 1GB, 2)
    if ($procs.Count -gt 0) {
        $totalMem = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum
        $mem = [math]::Round($totalMem / 1GB, 2)
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | clangd x$($procs.Count) | RAM: ${mem} GB | Free: ${freeGB}/${totalGB} GB"
    } else {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | clangd not running | Free: ${freeGB}/${totalGB} GB"
    }
    Start-Sleep 60
}
```
