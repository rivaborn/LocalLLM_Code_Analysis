# Architecture Analysis Toolkit — Setup & Usage Guide

Automated architecture documentation for game engine codebases using Claude CLI, with optional LSP-powered semantic analysis via clangd. Built for learning by reading real engine code (DOOM, Quake, Unreal, Godot, Unity, etc.).

---

## Table of Contents

1. [Complete Pipeline](#1-complete-pipeline)
2. [Files in This Toolkit](#2-files-in-this-toolkit)
3. [Prerequisites](#3-prerequisites)
4. [Installation](#4-installation)
5. [Claude CLI Multi-Account Setup](#5-claude-cli-multi-account-setup)
6. [Configuration (.env)](#6-configuration-env)
7. [Serena / clangd Setup (Optional, for LSP)](#7-serena--clangd-setup-optional-for-lsp)
8. [Step 0: serena_extract — LSP Context Extraction](#8-step-0-serena_extract--lsp-context-extraction)
9. [Step 1: archgen — Per-File Documentation](#9-step-1-archgen--per-file-documentation)
10. [Step 2: archxref — Cross-Reference Index](#10-step-2-archxref--cross-reference-index)
11. [Step 3: archgraph — Call Graph Diagrams](#11-step-3-archgraph--call-graph-diagrams)
12. [Step 4: arch_overview — Architecture Overview](#12-step-4-arch_overview--architecture-overview)
13. [Step 5: archpass2 — Selective Re-Analysis](#13-step-5-archpass2--selective-re-analysis)
14. [Prompt Files](#14-prompt-files)
15. [Presets Reference](#15-presets-reference)
16. [Example: Full Quake 2 Pipeline](#16-example-full-quake-2-pipeline)
17. [Example: Unreal Engine Pipeline (with Serena)](#17-example-unreal-engine-pipeline-with-serena)
18. [Output Directory Structure](#18-output-directory-structure)
19. [Resumability & Incremental Runs](#19-resumability--incremental-runs)
20. [Troubleshooting](#20-troubleshooting)

---

## 1. Complete Pipeline

The toolkit runs as a multi-stage pipeline. Each stage builds on the previous one. The optional Step 0 (LSP extraction) is free and enriches everything downstream.

```
                 ┌────────────────────┐
  clangd index ─▶│ serena_extract.ps1 │──▶ .serena_context.txt (per file)
                 └────────┬───────────┘    (zero Claude calls)
                          │
                 ┌────────▼───────────┐
                 │ archgen_dirs.ps1   │──▶ .dir_context/<dir>.dir.md
                 └────────┬───────────┘    (few Claude calls, sonnet)
                          │
                 ┌────────▼───────────┐
  Source files ─▶│   archgen.ps1      │──▶ Per-file .md docs (pass 1)
  + LSP + dirs   │ (+ shared headers) │    (with cross-refs from LSP)
                 └────────┬───────────┘
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
   ┌──────────────┐ ┌───────────┐ ┌────────────────┐
   │ archxref.ps1 │ │archgraph  │ │arch_overview.ps1│
   └──────┬───────┘ └─────┬─────┘ └───────┬────────┘
           │              │                │  (incremental)
           ▼              ▼                ▼
    xref_index.md   callgraph.mermaid  architecture.md
           │                               │
           └───────────┬───────────────────┘
                       │
              ┌────────▼─────────┐
              │  archpass2.ps1   │──▶ Per-file .pass2.md (enriched)
              │ (selective -Top) │    (only highest-value files)
              └──────────────────┘
```

| Step | Script                  | Claude Calls                  | Cost   | What It Produces                                            |
|------|-------------------------|-------------------------------|--------|-------------------------------------------------------------|
| 0    | `serena_extract.ps1`    | **0** (local clangd)          | Free   | LSP symbol overviews + cross-file references + trimmed source |
| 0b   | `archgen_dirs.ps1`      | 1 per directory (sonnet)      | Low    | Per-directory architectural overviews (`.dir.md`)           |
| 1    | `archgen.ps1`           | 1 per non-trivial file        | Haiku  | Per-file architecture docs with LSP + dir context + shared headers |
| 2    | `archxref.ps1`          | **0** (text processing)       | Free   | Cross-reference index: who calls whom                       |
| 3    | `archgraph.ps1`         | **0** (text processing)       | Free   | Mermaid call graph + subsystem diagrams                     |
| 4    | `arch_overview.ps1`     | 1 (small) or N+1 (chunked)   | Varies | Subsystem-level architecture overview (incremental)         |
| 4b   | `archpass2_context.ps1` | **0** (text processing)       | Free   | Per-file targeted context for Pass 2                        |
| 5    | `archpass2.ps1`         | 1 per selected file           | Haiku+ | Context-aware enriched analysis (complex files auto-upgrade to sonnet) |

Step 0 is optional but recommended for C/C++ codebases with a `compile_commands.json`. Step 0b generates directory-level overviews used as context in Step 1. Steps 2, 3, 4b are always free. Step 1 auto-skips generated/trivial files (configurable) and pre-computes shared directory headers. Step 4 is incremental by default (unchanged subsystems skip; use `-Full` to force). Step 5 with `-Top N` processes only the most important files.

### Token Optimizations (Built-In)

The pipeline includes 9 token optimizations that can reduce total API cost by up to 72%:

| Optimization                      | Default                                    | .env Variable                                                |
|-----------------------------------|--------------------------------------------|------------------------------------------------------------|
| Skip generated/trivial files      | **ON**                                     | `SKIP_TRIVIAL=1`                                             |
| Adaptive output budget            | **ON**                                     | Always active                                                |
| Compressed prompt format          | Opt-in                                     | `PROMPT_FILE=file_doc_prompt_compact.txt`                    |
| Per-file targeted Pass 2 context  | **ON** (if `archpass2_context.ps1` was run) | Always active                                                |
| Shared header doc bundling        | Opt-in                                     | `BUNDLE_HEADER_DOCS=1`                                       |
| Tiered model selection            | **ON**                                     | `TIERED_MODEL=1` (default). Set `TIERED_MODEL=0` to disable. |
| Batch templated files             | Opt-in                                     | `BATCH_TEMPLATED=1`                                          |
| LSP-guided source trimming        | **ON** (if LSP context has trimmed source)  | Always active                                                |
| Prompt caching                    | **ON**                                     | Always active (fixed system prompt across all calls)         |

See `Optimization.md` for detailed descriptions of each.

---

## 2. Files in This Toolkit

### Pipeline Scripts (PowerShell)

| File                     | Purpose                                                                                  |
|--------------------------|------------------------------------------------------------------------------------------|
| `serena_extract.ps1`     | Step 0: LSP extraction wrapper (calls Python script). `-Compress` for LSP compression.   |
| `serena_extract.py`      | LSP client — talks directly to clangd via JSON-RPC                                       |
| `archgen_dirs.ps1`       | Step 0b: per-directory architectural overviews (few Claude calls, sonnet)                 |
| `archgen.ps1`            | Step 1: per-file docs with dir context + shared headers + LSP context + trivial skipping |
| `archgen_worker.ps1`     | Worker dispatched by archgen (do not run directly)                                       |
| `archxref.ps1`           | Step 2: cross-reference index (no Claude)                                                |
| `archgraph.ps1`          | Step 3: Mermaid diagrams (no Claude)                                                     |
| `arch_overview.ps1`      | Step 4: architecture overview with auto-chunking (incremental by default)                |
| `archpass2_context.ps1`  | Step 4b: per-file targeted context for Pass 2 (no Claude)                                |
| `archpass2.ps1`          | Step 5: selective re-analysis with scoring                                               |
| `archpass2_worker.ps1`   | Worker dispatched by archpass2 (do not run directly)                                     |

### Pipeline Scripts (Bash Equivalents)

| File               | Purpose                                          |
|--------------------|--------------------------------------------------|
| `archgen.sh`       | Bash equivalent of archgen.ps1 (Linux/macOS/WSL) |
| `archxref.sh`      | Bash equivalent of archxref.ps1                  |
| `archgraph.sh`     | Bash equivalent of archgraph.ps1                 |
| `arch_overview.sh` | Bash equivalent of arch_overview.ps1             |
| `archpass2.sh`     | Bash equivalent of archpass2.ps1                 |

### Prompt Files

| File                          | Purpose                                                      |
|-------------------------------|--------------------------------------------------------------|
| `file_doc_prompt.txt`         | Standard per-file analysis prompt (~500 tokens)              |
| `file_doc_prompt_lsp.txt`     | LSP-enhanced prompt (auto-selected when LSP context exists)  |
| `file_doc_prompt_compact.txt` | Compressed prompt (~150 tokens, same schema)                 |
| `file_doc_prompt_learn.txt`   | Learning-oriented prompt (design rationale, study questions) |
| `file_doc_prompt_pass2.txt`   | Pass 2 enrichment prompt                                     |
| `file_doc_system_prompt.txt`  | Fixed system prompt for prompt caching (used by both workers)|
| `classify_prompt.txt`         | Classification prompt for two-phase mode (`-Classify`)       |

### Configuration

| File                  | Purpose                                                      |
|-----------------------|--------------------------------------------------------------|
| `.env`                | Pipeline configuration (Claude accounts, model, jobs, preset, etc.) |
| `.clangd`             | clangd behavior config (indexing, diagnostics, completion)   |
| `.serena/project.yml` | Serena per-project config (language servers, ignored paths)  |

### Documentation

| File                  | Purpose                                                  |
|-----------------------|----------------------------------------------------------|
| `SETUP.md`            | This file                                                |
| `SerenaFinal.md`      | Complete technical reference for the Serena integration  |
| `FileReference.md`    | Index of all files with descriptions                     |
| `Optimization.md`     | Token optimization guide (v1/v2)                         |
| `Optimizations v3.md` | v3 optimization documentation                            |
| `Summary - 1.md`      | Session 1 troubleshooting summary                        |
| `Summary - 2.md`      | Session 2 extended summary                               |

---

## 3. Prerequisites

### Required

- **PowerShell 5.1+** (Windows) or **Bash 4+** (Linux/macOS/WSL)
- **Claude CLI** installed and in `$PATH` (`claude --version`)
- **Claude Pro account** (two recommended for rate-limit rotation)

### Optional (for LSP extraction)

- **Python 3.12** — via `uv python install 3.12`
- **uv** — Python package manager (`powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`)
- **clangd** — C++ language server (install via VS2022 Clang components or `winget install LLVM.LLVM`)
- **compile_commands.json** — compilation database at repo root (see Section 7)

---

## 4. Installation

### PowerShell (Windows)

```powershell
cd C:\path\to\your\game-engine-repo

# Copy all toolkit files to repo root
Copy-Item C:\path\to\toolkit\archgen.ps1 .
Copy-Item C:\path\to\toolkit\archgen_worker.ps1 .
Copy-Item C:\path\to\toolkit\archxref.ps1 .
Copy-Item C:\path\to\toolkit\archgraph.ps1 .
Copy-Item C:\path\to\toolkit\arch_overview.ps1 .
Copy-Item C:\path\to\toolkit\archpass2.ps1 .
Copy-Item C:\path\to\toolkit\archpass2_worker.ps1 .
Copy-Item C:\path\to\toolkit\serena_extract.ps1 .
Copy-Item C:\path\to\toolkit\serena_extract.py .
Copy-Item C:\path\to\toolkit\file_doc_prompt*.txt .
Copy-Item C:\path\to\toolkit\.env.template .env  # then edit

# Add to .gitignore
Add-Content .gitignore "`n.env`narchitecture/"
```

### Bash (Linux/macOS/WSL)

```bash
cd /path/to/your/game-engine-repo

cp /path/to/toolkit/arch*.sh /path/to/toolkit/file_doc_prompt*.txt .
cp /path/to/toolkit/.env.template .env  # then edit
chmod +x arch*.sh

echo -e ".env\narchitecture/" >> .gitignore
```

---

## 5. Claude CLI Multi-Account Setup

Two Claude Pro accounts allow rate-limit rotation — when one account hits its limit, the pipeline switches to the other.

### PowerShell

```powershell
# Create config directories
New-Item -ItemType Directory -Force "$HOME\.claudeaccount1"
New-Item -ItemType Directory -Force "$HOME\.claudeaccount2"

# Authenticate each account
$env:CLAUDE_CONFIG_DIR = "$HOME\.claudeaccount1"
claude  # login with account 1

$env:CLAUDE_CONFIG_DIR = "$HOME\.claudeaccount2"
claude  # login with account 2
```

### Bash

```bash
mkdir ~/.claudeaccount1 ~/.claudeaccount2

alias claude1="CLAUDE_CONFIG_DIR=~/.claudeaccount1 claude"
alias claude2="CLAUDE_CONFIG_DIR=~/.claudeaccount2 claude"
source ~/.bashrc

claude1  # login with account 1
claude2  # login with account 2
```

### Configure in .env

```env
CLAUDE1_CONFIG_DIR=$HOME/.claudeaccount1
CLAUDE2_CONFIG_DIR=$HOME/.claudeaccount2
```

The pipeline uses account 2 by default. Pass `-Claude1` to switch:

```powershell
.\archgen.ps1 -Preset unreal -Claude1
```

---

## 6. Configuration (.env)

Create a `.env` file at the repo root. All variables are optional except the Claude config directories.

### Core Settings

| Variable              | Default      | Description                          |
|-----------------------|--------------|--------------------------------------|
| `CLAUDE1_CONFIG_DIR`  | *(required)* | First Claude account config path     |
| `CLAUDE2_CONFIG_DIR`  | *(required)* | Second Claude account config path    |
| `CLAUDE_MODEL`        | `sonnet`     | Model: `haiku`, `sonnet`, `opus`     |
| `CLAUDE_MAX_TURNS`    | `1`          | Max turns per Claude call            |
| `CLAUDE_OUTPUT_FORMAT` | `text`       | Output format                        |
| `JOBS`                | `2`          | Parallel workers                     |
| `MAX_RETRIES`         | `2`          | Retries per file on transient failure |
| `RETRY_DELAY`         | `5`          | Seconds between retries              |

### Preset & Filtering

| Variable              | Default          | Description                                                          |
|-----------------------|------------------|----------------------------------------------------------------------|
| `PRESET`              | *(empty)*        | Engine preset: `quake`, `unreal`, `godot`, `unity`, `source`, `rust` |
| `INCLUDE_EXT_REGEX`   | *(from preset)*  | Regex for file extensions to include                                 |
| `EXCLUDE_DIRS_REGEX`  | *(from preset)*  | Regex for directories to exclude                                     |
| `EXTRA_EXCLUDE_REGEX` | *(empty)*        | Additional exclude regex (stacks with preset)                        |
| `CODEBASE_DESC`       | *(from preset)*  | Human description of the codebase for Claude                         |
| `DEFAULT_FENCE`       | *(from preset)*  | Markdown fence language (e.g., `cpp`, `c`, `csharp`)                 |

### File Handling

| Variable              | Default | Description                                        |
|-----------------------|---------|----------------------------------------------------|
| `BUNDLE_HEADERS`      | `1`     | Include local `#include` headers with source files |
| `MAX_BUNDLED_HEADERS` | `5`     | Max headers to bundle per file                     |
| `MAX_FILE_LINES`      | `4000`  | Truncation limit for source files                  |
| `CHUNK_THRESHOLD`     | `1500`  | Lines above which arch_overview auto-chunks        |

### Token Optimization

| Variable                | Default  | Description                                                                                                          |
|-------------------------|----------|----------------------------------------------------------------------------------------------------------------------|
| `SKIP_TRIVIAL`          | `1`      | Skip generated/trivial files (write stub docs instead of Claude calls)                                               |
| `MIN_TRIVIAL_LINES`     | `20`     | Files under this line count are considered trivial                                                                    |
| `TIERED_MODEL`          | `1`      | Enable tiered model selection (haiku for simple, sonnet for complex). Applies to `archgen.ps1`, `archpass2.ps1`, and `arch_overview.ps1`. |
| `HIGH_COMPLEXITY_MODEL` | `sonnet` | Model used for high-complexity files when `TIERED_MODEL=1`                                                           |
| `BUNDLE_HEADER_DOCS`    | `0`      | Bundle header `.md` docs (~400 tokens) instead of raw source (~4000 tokens)                                          |
| `BATCH_TEMPLATED`       | `0`      | Group structurally identical files, analyze one representative per group                                              |
| `USE_MAX_TOKENS`        | `0`      | Hard output cap: map adaptive budget to `--max-tokens` on Claude CLI. Also via `-MaxTokens` flag.                    |
| `JSON_OUTPUT`           | `0`      | Switch `archgen.ps1` output format to JSON. Also via `-JsonOutput` flag.                                             |
| `CLASSIFY_FILES`        | `0`      | Two-phase classification: haiku classifies files as ANALYZE or STUB. Also via `-Classify` flag.                      |

### Prompt Selection

| Variable        | Default                     | Description                                                                                                                                                                         |
|-----------------|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `PROMPT_FILE`   | Auto-selected               | Pass 1 prompt file. Auto-selects `file_doc_prompt_lsp.txt` when LSP context exists, otherwise `file_doc_prompt.txt`. Set to `file_doc_prompt_compact.txt` for minimum token usage. |
| `PROMPT_FILE_P2` | `file_doc_prompt_pass2.txt` | Pass 2 prompt file                                                                                                                                                                  |

### Example .env

```env
CLAUDE1_CONFIG_DIR=$HOME/.claudeaccount1
CLAUDE2_CONFIG_DIR=$HOME/.claudeaccount2
CLAUDE_MODEL=haiku
JOBS=8
PRESET=unreal
BUNDLE_HEADERS=1
MAX_BUNDLED_HEADERS=5
MAX_FILE_LINES=4000
CODEBASE_DESC=Unreal Engine 5.7.3 C++ source. Core, CoreUObject, Engine, Renderer, PhysicsCore, Slate/UMG, AIModule.

# Token optimizations (all optional, sensible defaults)
SKIP_TRIVIAL=1
TIERED_MODEL=1
HIGH_COMPLEXITY_MODEL=sonnet
BUNDLE_HEADER_DOCS=1
BATCH_TEMPLATED=1
PROMPT_FILE=file_doc_prompt_compact.txt

# v3 opt-in features (all default to 0)
USE_MAX_TOKENS=0
JSON_OUTPUT=0
CLASSIFY_FILES=0
```

---

## 7. Serena / clangd Setup (Optional, for LSP)

This section covers setting up clangd for LSP-powered semantic analysis. This is optional — the pipeline works without it, but LSP context significantly improves cross-reference accuracy in Pass 1.

### 7.1 Generate compile_commands.json

**For Unreal Engine:**

```powershell
# Install Clang via VS Installer → Individual Components:
#   - C++ Clang Compiler for Windows
#   - C++ Clang-cl for v143 build tools (x64/x86)

# Generate the database (UE 5.x uses "UnrealEditor", not "UE4Editor")
.\Engine\Build\BatchFiles\RunUBT.bat `
    UnrealEditor Win64 Development `
    -Mode=GenerateClangDatabase `
    -engine -progress
```

**For other projects:** Use CMake (`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`) or Bear (`bear -- make`).

### 7.2 Configure clangd

Create `.clangd` at repo root:

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

### 7.3 Configure Serena (Optional — for interactive LSP queries)

Create `.serena/project.yml` at repo root:

```yaml
name: YourProject
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
  - .git

read_only: true
```

Register Serena as an MCP server in Claude Code:

```powershell
claude mcp add-json "serena" '{\"command\":\"uvx\",\"args\":[\"--python\",\"3.12\",\"--from\",\"git+https://github.com/oraios/serena\",\"serena\",\"start-mcp-server\",\"--context\",\"claude-code\",\"--project\",\"C:\\path\\to\\repo\"]}'
```

### 7.4 Build the clangd Index

The first time clangd runs, it needs to build a background index. For large codebases like Unreal Engine (36K+ translation units), this takes several hours.

1. Start a Claude Code session in the repo directory (Serena auto-launches, which starts clangd).
2. Monitor RAM usage:
   ```powershell
   while ($true) {
       $p = Get-Process clangd -ErrorAction SilentlyContinue
       if ($p) {
           $mem = [math]::Round($p.WorkingSet64 / 1GB, 2)
           Write-Host "$(Get-Date -Format 'HH:mm:ss') | RAM: ${mem} GB"
       } else { Write-Host "$(Get-Date -Format 'HH:mm:ss') | clangd not running" }
       Start-Sleep 60
   }
   ```
3. Wait for RAM to stabilize at ~4 GB (indexing complete). For UE 5.7.3, this takes ~8.5 hours with `-j=4`.
4. The index is cached at `.cache/clangd/index/` and persists across sessions.

**After the first build**, subsequent sessions load the cached index in seconds.

### 7.5 Memory Budget

| Codebase Size           | `-j` Flag | Peak RAM | Index Time |
|-------------------------|-----------|----------|------------|
| Small (~150 files)      | `-j=4`    | ~1-2 GB  | Minutes    |
| Medium (~5K files)      | `-j=4`    | ~4-8 GB  | ~1 hour    |
| Large (36K+ TUs, UE)   | `-j=4`    | ~19 GB   | ~8.5 hours |

For systems with <32 GB RAM on large codebases, reduce to `-j=2`.

---

## 8. Step 0: serena_extract — LSP Context Extraction

Extracts symbol overviews and cross-file references from clangd's index using adaptive parallel workers. **Zero Claude calls — completely free.** Automatically scales clangd instance count based on available RAM. This data is automatically injected into Pass 1.

### Prerequisites

- `compile_commands.json` at repo root
- clangd installed (via VS2022 Clang components or LLVM)
- clangd background index built (`.cache/clangd/index/`)
- Python 3.12 (`uv python install 3.12`)

### Usage

```powershell
# Auto-detect workers based on free RAM
.\serena_extract.ps1 -Preset unreal

# Explicit 3 parallel workers
.\serena_extract.ps1 -Preset unreal -Workers 3

# Fast mode: symbols only, no reference queries
.\serena_extract.ps1 -Preset unreal -SkipRefs

# Max speed: 3 workers + skip refs
.\serena_extract.ps1 -Preset unreal -Workers 3 -SkipRefs

# Single subsystem
.\serena_extract.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal

# Force re-extraction (ignore cached results)
.\serena_extract.ps1 -Preset unreal -Force

# Tune for tight RAM (16 GB system)
.\serena_extract.ps1 -Preset unreal -Workers 1 -MinFreeRAM 4 -RAMPerWorker 4
```

### Adaptive Parallelism

The script runs multiple clangd instances in parallel, each pulling files from a shared queue. RAM is monitored every ~60 seconds:

- **Free RAM > 10 GB** and workers < max → spawns another clangd instance
- **Free RAM < 4 GB** and workers > 1 → stops the newest worker
- Each clangd restarts every 1000 files to reclaim accumulated memory

The progress line shows live status (single-line, overwrites in place):

```
  500/20000  done=480 empty=15 fail=5  avg=0.4/s now=0.6/s  w=2  clangd=8.3GB free=12.1GB  eta=9h04m10s
```

Where `w` = active workers, `clangd` = total clangd RAM, `free` = free system RAM, `now` = instantaneous rate (last 30s), `eta` = based on avg rate of successfully completed files.

### RAM Budget

**Workers vs Jobs**: `-Workers` controls the number of clangd **processes** (separate instances). `-Jobs` controls clangd's internal `-j` flag (how many **threads** each process uses). With `-Workers 3 -Jobs 2`, you get 3 processes x 2 threads = 6 total threads. Sweet spot for 32 GB: `-Workers 2 -Jobs 2` (~8 GB).

| Workers | Jobs | Total Threads | Est. RAM |
|---------|------|---------------|----------|
| 3       | 2    | 6             | ~12 GB   |
| 2       | 4    | 8             | ~10 GB   |
| 2       | 2    | 4             | ~8 GB    |
| 1       | 4    | 4             | ~6 GB    |

| System RAM | Recommended            | Expected Workers |
|------------|------------------------|------------------|
| 16 GB      | `-Workers 1`           | 1                |
| 32 GB      | `-Workers 3` or auto   | 2-3              |
| 64 GB      | `-Workers 6` or auto   | 4-6              |

### What It Produces

For each source file, a `.serena_context.txt` file in `architecture/.serena_context/` containing:

- **Symbol Overview** — Classes, structs, enums, functions, methods, file-scope variables with line ranges
- **Incoming References** — Which files/functions across the codebase call symbols defined in this file (skipped with `-SkipRefs`)
- **Direct Include Dependencies** — What this file includes
- **Trimmed Source** — For large files (>800 lines), key code sections extracted using symbol ranges. Used by archgen to send focused code instead of blunt head+tail truncation.

A performance log at `architecture/.serena_context/.state/perf.log` records per-file timing breakdown. An error log at `architecture/.serena_context/.state/errors.log` records EMPTY, FAIL, CRASH, and RESTART events per worker.

### Crash Recovery

If a clangd process crashes (broken pipe / Errno 22), the worker automatically restarts a fresh clangd instance and retries the current file once. Without this, a single crash would fail every remaining file in that worker's queue.

### Incremental Support

| File outcome                 | Skipped on rerun          | Rationale                                     |
|------------------------------|---------------------------|-----------------------------------------------|
| **Done** (symbols extracted) | Yes (if source unchanged) | Normal skip                                   |
| **Empty** (no symbols)       | Yes                       | `.cs` files, bridging headers — won't change  |
| **Failed** (crash, error)    | No (retried)              | Failure may be transient                       |

Safe to interrupt (Ctrl+C) and resume — completed and empty files are skipped, failed files retry.

---

## 8b. Step 0b: archgen_dirs — Directory-Level Overviews

Generates per-directory architectural overviews before Pass 1. Uses sonnet (tiered model). Few Claude calls — one per directory. These overviews are automatically loaded by `archgen.ps1` workers as context for each file.

### Usage

```powershell
# Full codebase
.\archgen_dirs.ps1 -Preset unreal

# Single subsystem
.\archgen_dirs.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal
```

### What It Produces

Per-directory overview files in `architecture/.dir_context/<dir>.dir.md`, each describing the directory's purpose, structure, and key responsibilities.

---

## 9. Step 1: archgen — Per-File Documentation

Generates one `.md` doc per source file. When LSP context is available, it's automatically injected to give Claude accurate cross-references from the start. Directory-level overviews (from Step 0b) are loaded as additional context. Common includes (80%+ threshold per directory) are pre-computed into shared headers at `architecture/.dir_headers/`.

### Usage

```powershell
# Basic usage with preset
.\archgen.ps1 -Preset unreal -Jobs 8

# Specific subdirectory
.\archgen.ps1 -TargetDir Engine\Source\Runtime\Renderer -Preset unreal

# Disable header bundling
.\archgen.ps1 -Preset unreal -NoHeaders

# Use account 1 instead of account 2
.\archgen.ps1 -Preset unreal -Claude1

# Start fresh (removes all previous output)
.\archgen.ps1 -Preset unreal -Clean
```

### Built-In Token Optimizations

The following optimizations are applied automatically during Pass 1:

**Trivial file skipping** (`SKIP_TRIVIAL=1`, default ON): Files matching generated code patterns (`.generated.h`, `.gen.cpp`, `Module.*.cpp`) or under 20 lines are skipped. A one-line stub doc is written instead of a Claude call. The banner shows `trivial=N` in the skip count.

**Adaptive output budget** (always active): Each file gets a token budget proportional to its size and complexity. A 30-line header gets `~200 tokens`, a 4000-line source file gets `~1200 tokens`. Prevents Claude from padding small files with filler.

**LSP-guided source trimming** (active when LSP context includes trimmed source): For large files that exceed `MAX_FILE_LINES`, the worker uses the LSP-trimmed source (key code sections extracted by symbol ranges) instead of blunt head+tail truncation. Results in more focused analysis.

**Tiered model selection** (`TIERED_MODEL=1`, default ON): Files are classified as low/medium/high complexity using LSP symbol and reference counts. High-complexity hub files get `HIGH_COMPLEXITY_MODEL` (default sonnet), others use `CLAUDE_MODEL` (haiku). Applies to `archgen.ps1`, `archpass2.ps1`, and `arch_overview.ps1`. Set `TIERED_MODEL=0` to keep all stages on `CLAUDE_MODEL`. Saves cost by reserving expensive models for files that benefit most.

**Header doc bundling** (`BUNDLE_HEADER_DOCS=1`, opt-in): When a header already has a Pass 1 `.md` doc, the worker bundles the doc (~400 tokens) instead of the raw header source (~4000 tokens). Requires running headers through Pass 1 first (two-pass strategy).

**Batch templated files** (`BATCH_TEMPLATED=1`, opt-in): Groups structurally identical files (same first-20-lines structural hash). Groups of 3+ files: one representative is analyzed by Claude, the rest get path-substituted docs. Safe for generated code; human-authored files with shared structure still get individual analysis if groups are <3.

**Prompt caching** (always active): Both `archgen_worker.ps1` and `archpass2_worker.ps1` use a fixed system prompt (`file_doc_system_prompt.txt`) identical across all Claude calls. The per-file prompt schema is embedded in the user message. This enables API-level prompt caching — cached system prompt tokens are charged at ~10% of the full rate. Over 20K calls with a ~500 token system prompt, this saves ~9M tokens worth of cost. No configuration needed.

### LSP Context Auto-Detection

When `architecture/.serena_context/` exists (from Step 0):
- The banner shows `Serena context: YES`
- `file_doc_prompt_lsp.txt` is auto-selected as the prompt (unless overridden in `.env`)
- Each worker loads the matching `.serena_context.txt` and injects it into the Claude payload
- Claude uses the LSP data authoritatively for cross-references

When no LSP context exists:
- The banner shows `Serena context: NO`
- Standard `file_doc_prompt.txt` is used
- Pipeline works exactly as before

### Fallback Chain (Prompt Too Long)

If Claude returns "prompt too long", the worker degrades context in stages:

| Stage      | Source Content                             | Headers              | LSP Context |
|------------|-------------------------------------------|----------------------|-------------|
| 0 (normal) | Full or LSP-trimmed (up to MAX_FILE_LINES) | Bundled (raw or doc) | Injected    |
| 1          | Full or LSP-trimmed                        | Dropped              | Injected    |
| 2          | Truncated to 25% (head+tail)               | Dropped              | Dropped     |

### Output

Per-file docs in `architecture/<relative_path>.md`.

---

## 10. Step 2: archxref — Cross-Reference Index

Parses all Pass 1 docs and builds a cross-reference index. **No Claude calls** — pure text processing, runs in seconds.

```powershell
.\archxref.ps1
```

### What It Produces

`architecture/xref_index.md` containing:
- **Function-to-file map** — Where every function is defined
- **Call graph table** — Most-connected functions, sorted by call count
- **Reverse call map** — Most-called functions and who calls them
- **Global state ownership** — Which file owns each global variable
- **Header dependencies** — Most-included headers
- **Subsystem interfaces** — Functions exported by each directory

---

## 11. Step 3: archgraph — Call Graph Diagrams

Extracts call edges from Pass 1 docs and produces Mermaid diagrams. **No Claude calls.**

```powershell
.\archgraph.ps1
```

### What It Produces

- `architecture/callgraph.mermaid` — Function-level call graph grouped by subsystem
- `architecture/subsystems.mermaid` — Subsystem dependency diagram with cross-boundary call counts
- `architecture/callgraph.md` — Both diagrams in a single markdown file

View in GitHub, VS Code (Mermaid extension), mermaid.live, or Obsidian.

---

## 12. Step 4: arch_overview — Architecture Overview

Synthesizes all Pass 1 docs into a subsystem-level architecture overview. When `TIERED_MODEL=1` (the default), auto-upgrades to `HIGH_COMPLEXITY_MODEL` (sonnet). Set `TIERED_MODEL=0` to use `CLAUDE_MODEL` instead. Incremental by default: tracks subsystem doc hashes in `overview_hashes.tsv` — unchanged subsystems skip on re-run. Use `-Full` to force full regeneration.

```powershell
# Auto-detects single vs chunked mode (incremental by default)
.\arch_overview.ps1 -Preset unreal

# Force full regeneration (skip incremental)
.\arch_overview.ps1 -Preset unreal -Full
```

### Auto-Chunking

If the extracted data exceeds the chunk threshold (default 1500 lines), the script automatically:
1. Discovers subsystem directories
2. Generates a per-subsystem overview for each (focused Claude call)
3. Synthesizes a final overview from the subsystem overviews
4. Recursively splits oversized subsystems

Single-child directories are automatically descended through during chunking rather than stopping the split. For example, a path like `Engine/Source/Runtime/Engine/Private` where each level has only one subdirectory will be traversed until a directory with multiple children (or leaf docs) is reached. This prevents degenerate chunks containing a single nested path and ensures proper splitting for deep directory structures common in UE.

This produces dramatically better results for large codebases.

### Output

- `architecture/architecture.md` — Final synthesized overview
- `architecture/<subsystem> architecture.md` — Per-subsystem overviews (chunked mode)

---

## 12b. Step 4b: archpass2_context — Targeted Context (Optional)

Builds per-file targeted context extracts for Pass 2. Instead of injecting the same 200-line architecture overview and 300-line xref excerpt into every Pass 2 call (mostly irrelevant), this script extracts only the relevant portions for each specific file. **Zero Claude calls — pure text processing, runs in seconds.**

```powershell
.\archpass2_context.ps1
.\archpass2_context.ps1 -TargetDir Engine\Source\Runtime\Renderer
```

### Prerequisites

Run steps 2 and 4 first (`archxref.ps1` and `arch_overview.ps1`).

### What It Produces

Per-file context files in `architecture/.pass2_context/<path>.ctx.txt`, each containing:
- **Architecture Context** — Only the subsystem paragraph relevant to this file
- **Cross-Reference Entries** — Only xref lines mentioning this file's name or path

### Impact

Instead of 500 lines of mostly irrelevant context per Pass 2 call, each file gets 30-80 lines of highly relevant context. Over thousands of calls, this saves millions of input tokens.

The Pass 2 worker auto-detects these targeted context files and uses them when available, falling back to the global truncated blobs when not.

---

## 13. Step 5: archpass2 — Selective Re-Analysis

Re-analyzes source files with the architecture overview and cross-reference index injected as context. Now supports **selective processing** — only the highest-value files get re-analyzed.

### Usage

```powershell
# Process all files (original behavior)
.\archpass2.ps1 -Preset unreal -Jobs 8

# Selective: only top 500 highest-scoring files
.\archpass2.ps1 -Preset unreal -Jobs 8 -Top 500

# Preview scores without running
.\archpass2.ps1 -Preset unreal -Top 500 -ScoreOnly

# Manual file selection
.\archpass2.ps1 -Only "Engine/Source/Runtime/Engine/Private/Actor.cpp,Engine/Source/Runtime/CoreUObject/Private/UObject/UObjectBase.cpp"
```

### Scoring (with -Top N)

Files are scored by:
```
score = (incoming_reference_count * 3) + (line_count / 100)
if has_serena_context: score *= 0.5  // Discount: Pass 1 was already enriched
```

- **High incoming references** = "hub" files called by many others (most architecturally significant)
- **Large files** = more likely to contain complex logic worth analyzing
- **Serena discount** = files that already had LSP context in Pass 1 need less re-analysis

### Prerequisites

Run steps 1, 2, and 4 first. The script checks for `architecture.md` and `xref_index.md`.

### Output

Per-file enriched docs in `architecture/<relative_path>.pass2.md` (does NOT overwrite Pass 1 docs).

Each `.pass2.md` includes:
- **Architectural Role** — How this file fits in the broader engine
- **Cross-References** — Incoming callers, outgoing dependencies
- **Design Patterns & Rationale** — Why the code is structured this way
- **Data Flow** — What enters, how it's transformed, where it goes
- **Learning Notes** — What a student should take away
- **Potential Issues** — Only if clearly inferable

---

## 14. Prompt Files

### file_doc_prompt.txt — Standard Prompt

Used when no LSP context is available. Produces structured docs with:
- File purpose, core responsibilities
- Key types/data structures
- Global/file-static state
- Key functions with signatures, purpose, inputs, outputs, side effects, calls
- Control flow notes
- External dependencies

### file_doc_prompt_lsp.txt — LSP-Enhanced Prompt

Auto-selected when `architecture/.serena_context/` exists. Same schema as the standard prompt, but instructs Claude to:
- Use the LSP Symbol Overview authoritatively (don't miss types/functions)
- Use Incoming References for "Called by" in function docs
- Use Direct Include Dependencies for specific file locations
- Treat LSP cross-references as ground truth, not guesses

Adds a "Called by (from LSP context)" field to each function entry.

### file_doc_prompt_compact.txt — Compressed Prompt

Minimal token version (~150 tokens vs ~500 for standard). Same output schema, terse format. Claude produces identical quality output. Saves ~350 tokens per call — over 20K files, that's ~7M fewer input tokens.

Set via: `PROMPT_FILE=file_doc_prompt_compact.txt` in `.env`.

References `OUTPUT_BUDGET` appended by the worker to dynamically control response length per file.

### file_doc_prompt_learn.txt — Learning-Oriented Prompt

For studying engine architecture. Adds sections the standard prompt doesn't have:
- **"Why This File Exists"** — Not just what, but why it's separate
- **"Key Concepts to Understand First"** — Prerequisites before reading
- **"Design Patterns & Idioms"** — Named patterns, Carmack-isms, modern comparisons
- **"Historical Context"** — Hardware constraints that influenced the code
- **"Study Questions"** — Questions to test your understanding

Usage:
```powershell
.\archgen.ps1 -Preset quake -Jobs 4   # edit .env: PROMPT_FILE=file_doc_prompt_learn.txt
```

### file_doc_prompt_pass2.txt — Pass 2 Prompt

Used by `archpass2.ps1`. Instructs Claude to enrich the analysis with cross-cutting insights not possible in Pass 1. Auto-generated on first run if missing.

### file_doc_system_prompt.txt — Shared System Prompt (Prompt Caching)

Short fixed system prompt (~6 lines, ~500 tokens) used by both `archgen_worker.ps1` and `archpass2_worker.ps1`. Identical across all Claude calls, enabling API-level prompt caching at ~10% of the full token rate. The per-file prompt schema is embedded in the user message instead. No configuration needed — always active.

---

## 15. Presets Reference

| Preset                        | Languages                         | Excludes                                           | Description                |
|-------------------------------|-----------------------------------|----------------------------------------------------|----------------------------|
| `quake` / `doom` / `idtech`   | `.c .h .cpp .hpp .inl .inc`       | `baseq2`, `base`, build dirs                       | id Software / Quake-family |
| `unreal` / `ue4` / `ue5`     | `.cpp .h .hpp .cc .cxx .inl .cs`  | `Binaries`, `Intermediate`, `ThirdParty`, `Build`  | Unreal Engine 4/5          |
| `godot`                       | `.cpp .h .gd .cs .tscn .tres`     | `.godot`, `.import`, build                         | Godot (C++, GDScript, C#)  |
| `unity`                       | `.cs .shader .hlsl .cginc`        | `Library`, `Temp`, `Packages/com.unity`            | Unity (C#, shaders)        |
| `source` / `valve`            | `.cpp .h .c .cc .cxx .inl .vpc`   | `lib`, `thirdparty`                                | Source Engine (Valve)      |
| `rust`                        | `.rs .toml`                        | `target`, `.cargo`                                 | Rust engines (Bevy, etc.)  |

Use `--preset` or set `PRESET` in `.env`.

---

## 16. Example: Full Quake 2 Pipeline

A small codebase (~150 files) that completes quickly. No LSP extraction needed.

```powershell
cd C:\path\to\quake2-rerelease-dll

# Configure
# Set PRESET=quake, CLAUDE_MODEL=haiku, JOBS=8 in .env

# Step 1: Per-file docs (~20 min at JOBS=8, haiku)
.\archgen.ps1 -TargetDir rerelease -Preset quake -Jobs 8

# Step 2: Cross-reference index (instant)
.\archxref.ps1

# Step 3: Call graph diagrams (instant)
.\archgraph.ps1

# Step 4: Architecture overview
.\arch_overview.ps1 -Preset quake

# Step 5: Context-aware re-analysis on key files
.\archpass2.ps1 -Preset quake -Jobs 8 -Only `
    "rerelease/g_main.cpp,rerelease/p_client.cpp,rerelease/g_combat.cpp"
```

### Time Estimates (JOBS=8, Haiku)

| Step                          | Files | Time        |
|-------------------------------|-------|-------------|
| archgen.ps1 (~150 files)      | 150   | ~20 min     |
| archxref.ps1                  | --    | <5 sec      |
| archgraph.ps1                 | --    | <5 sec      |
| arch_overview.ps1             | --    | ~3 min      |
| archpass2.ps1 (5 key files)   | 5     | ~2 min      |
| **Total (targeted pass 2)**   |       | **~25 min** |

---

## 17. Example: Unreal Engine Pipeline (with Serena)

A massive codebase (36K+ translation units). The Serena-first approach is recommended to get accurate cross-references from the start.

### One-Time Setup

```powershell
cd C:\Coding\Epic_Games\UnrealEngine

# 1. Install prerequisites
uv python install 3.12

# 2. Install Clang (VS Installer → Individual Components):
#    - C++ Clang Compiler for Windows
#    - C++ Clang-cl for v143 build tools (x64/x86)

# 3. Generate compile_commands.json
.\Engine\Build\BatchFiles\RunUBT.bat `
    UnrealEditor Win64 Development `
    -Mode=GenerateClangDatabase -engine -progress

# 4. Build clangd index (first time only, ~8.5 hours)
#    Start Serena via Claude Code, monitor RAM, wait for stabilization at ~4 GB.
#    Index persists at .cache/clangd/index/ for future sessions.
```

### Full Pipeline Run

```powershell
# Step 0: LSP extraction (free, adaptive parallel workers)
#   Auto-scales clangd instances based on free RAM
.\serena_extract.ps1 -Preset unreal

# Or: explicit 3 workers, skip refs for max speed
.\serena_extract.ps1 -Preset unreal -Workers 3 -SkipRefs

# Step 0b: Directory-level overviews (few Claude calls, sonnet)
.\archgen_dirs.ps1 -Preset unreal

# Step 1: Pass 1 with LSP + dir context + shared headers + all optimizations
#   Auto-skips trivial files, uses LSP-trimmed source, adaptive output budget
.\archgen.ps1 -Preset unreal -Jobs 8

# Step 2: Cross-reference index (instant)
.\archxref.ps1

# Step 3: Call graph diagrams (instant)
.\archgraph.ps1

# Step 4: Architecture overview (incremental by default, chunked for UE)
.\arch_overview.ps1 -Preset unreal

# Step 4b: Targeted per-file context for Pass 2 (instant, free)
.\archpass2_context.ps1

# Step 5: Selective Pass 2 (top 500 files only, uses targeted context)
.\archpass2.ps1 -Preset unreal -Jobs 8 -Top 500
```

### Subsystem-by-Subsystem Approach (Alternative)

For the first analysis, targeting one subsystem at a time is faster:

```powershell
# Start with Core (foundational types)
.\serena_extract.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal
.\archgen.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal -Jobs 8

# Then CoreUObject (UObject system)
.\serena_extract.ps1 -TargetDir Engine\Source\Runtime\CoreUObject -Preset unreal
.\archgen.ps1 -TargetDir Engine\Source\Runtime\CoreUObject -Preset unreal -Jobs 8

# Then run xref/overview across everything analyzed so far
.\archxref.ps1
.\arch_overview.ps1 -Preset unreal
```

### Recommended Subsystem Order

| Priority | Subsystem Path                                       | Approx Files | Why Start Here                              |
|----------|------------------------------------------------------|--------------|---------------------------------------------|
| 1        | `Engine/Source/Runtime/Core`                          | ~300         | Foundational types, no UE dependencies      |
| 2        | `Engine/Source/Runtime/CoreUObject`                   | ~200         | UObject system — everything depends on this |
| 3        | `Engine/Source/Runtime/Engine/Classes/GameFramework`  | ~150         | Actor/Pawn/Character — gameplay backbone    |
| 4        | `Engine/Source/Runtime/Renderer`                      | ~350         | Rendering pipeline                          |
| 5        | `Engine/Source/Runtime/Engine/Classes/Components`     | ~200         | Component system                            |

### Time Estimates (JOBS=8, Haiku)

| Step                          | Scope            | Files (approx) | 1 worker | 3 workers |
|-------------------------------|------------------|----------------|----------|-----------|
| serena_extract.ps1            | Single subsystem | ~300           | ~25 min  | ~10 min   |
| serena_extract.ps1            | Full Runtime     | ~3,000         | ~4 hrs   | ~1.5 hrs  |
| serena_extract.ps1            | Full engine      | ~20,000+       | ~28 hrs  | ~10 hrs   |
| serena_extract.ps1 -SkipRefs  | Full engine      | ~20,000+       | ~14 hrs  | ~5 hrs    |
| archgen_dirs.ps1              | Full engine      | dirs           | ~10 min  | --        |
| archgen.ps1                   | Single subsystem | ~300           | ~30 min  | --        |
| archgen.ps1                   | Full Runtime     | ~3,000         | ~4 hrs   | --        |
| archgen.ps1                   | Full engine      | ~10,000+       | ~14 hrs  | --        |
| archxref.ps1                  | Any scope        | --             | <30 sec  | --        |
| archgraph.ps1                 | Any scope        | --             | <30 sec  | --        |
| arch_overview.ps1 (chunked)   | Runtime          | --             | ~20 min  | --        |
| arch_overview.ps1 (incremental)| Re-run          | --             | ~5 min   | --        |
| archpass2_context.ps1         | Any scope        | --             | <30 sec  | --        |
| archpass2.ps1 -Top 500        | Selective        | 500            | ~1 hr    | --        |

Note: serena_extract times vary significantly based on include chain depth. UE files average ~5s each due to heavy headers. The `-SkipRefs` flag roughly halves extraction time by skipping cross-file reference queries (symbols and trimmed source are still extracted).

### Key UE Files to Prioritize for Pass 2

```powershell
.\archpass2.ps1 -Only `
    "Engine/Source/Runtime/CoreUObject/Private/UObject/UObjectBase.cpp," + `
    "Engine/Source/Runtime/CoreUObject/Private/UObject/GarbageCollection.cpp," + `
    "Engine/Source/Runtime/Engine/Private/Actor.cpp," + `
    "Engine/Source/Runtime/Engine/Private/World.cpp," + `
    "Engine/Source/Runtime/Renderer/Private/DeferredShadingRenderer.cpp," + `
    "Engine/Source/Runtime/RHI/Private/RHICommandList.cpp"
```

---

## 18. Output Directory Structure

```
architecture/
├── Engine/Source/Runtime/Core/
│   ├── Private/Math/UnrealMath.cpp.md          ← Pass 1 doc
│   ├── Private/Math/UnrealMath.cpp.pass2.md    ← Pass 2 doc (if processed)
│   └── ...
├── .serena_context/                             ← LSP extraction output
│   ├── Engine/Source/Runtime/Core/
│   │   └── Private/Math/UnrealMath.cpp.serena_context.txt
│   └── .state/hashes.tsv                        ← Extraction state
├── .dir_context/                                ← Directory-level overviews (from archgen_dirs.ps1)
│   └── Engine/Source/Runtime/Core.dir.md        ← Per-directory architectural overview
├── .dir_headers/                                ← Shared include lists (from archgen.ps1)
│   └── Engine/Source/Runtime/Core.headers.txt   ← Common includes (80%+ threshold)
├── .pass2_context/                              ← Targeted Pass 2 context
│   └── Engine/Source/Runtime/Core/
│       └── Private/Math/UnrealMath.cpp.ctx.txt  ← Per-file relevant arch+xref
├── .archgen_state/                              ← Pass 1 state
│   ├── hashes.tsv                               ← SHA1 skip database
│   ├── counter.json                             ← Progress counter
│   └── last_claude_error.log                    ← Error log
├── .pass2_state/                                ← Pass 2 state
│   └── (same structure as .archgen_state/)
├── overview_hashes.tsv                          ← Incremental overview hash tracking
├── architecture.md                              ← Synthesized overview
├── xref_index.md                                ← Cross-reference index
├── callgraph.md                                 ← Mermaid diagrams (markdown)
├── callgraph.mermaid                            ← Raw Mermaid
├── subsystems.mermaid                           ← Subsystem dependency diagram
└── diagram_data.md                              ← Extracted signal for overview
```

---

## 19. Resumability & Incremental Runs

All scripts are fully resumable. If interrupted (rate limit, crash, `Ctrl+C`), re-run the same command to continue.

### How It Works

- **archgen.ps1 / archpass2.ps1**: Each processed file's SHA1 hash is recorded in `hashes.tsv`. On re-run, files with matching hashes and existing output are skipped.
- **serena_extract.ps1**: Same SHA1-based incremental logic. Files with existing `.serena_context.txt` and unchanged source are skipped.
- **archxref.ps1 / archgraph.ps1**: Always run from scratch (they're instant).
- **arch_overview.ps1**: Incremental by default — tracks subsystem doc hashes in `overview_hashes.tsv`. Unchanged subsystems skip on re-run. Use `-Full` to force full regeneration.

### Rate Limits

When a Claude rate limit is hit:
1. The worker detects the rate-limit response
2. Parses the reset time (e.g., "resets at 6pm")
3. Writes a shared pause file that all parallel workers honor
4. All workers sleep until the reset time + 10-minute buffer
5. Processing resumes automatically

If using two accounts, switch with `-Claude1` / default (account 2) when one is rate-limited.

### Clean Start

```powershell
.\archgen.ps1 -Preset unreal -Clean     # Removes ALL architecture output + state
.\archpass2.ps1 -Preset unreal -Clean    # Removes only Pass 2 output + state
```

---

## 20. Troubleshooting

### "Prompt too long" errors

The worker automatically degrades context in stages (drop headers → drop LSP → truncate source). If all stages fail, the file is logged as fatal. Solutions:
- Reduce `MAX_FILE_LINES` in `.env`
- Use `haiku` model (larger context window per token cost)
- Disable header bundling: `-NoHeaders` or `BUNDLE_HEADERS=0`

### "Missing prerequisite files" on archpass2

Run steps 1, 2, and 4 first:
```powershell
.\archgen.ps1 -Preset unreal -Jobs 8
.\archxref.ps1
.\arch_overview.ps1 -Preset unreal
# Then:
.\archpass2.ps1 -Preset unreal -Jobs 8
```

### clangd crashes / high memory

- Reduce parallelism: change `-j=4` to `-j=2` in `.serena/project.yml`
- Enable disk storage: ensure `--pch-storage=disk` is set
- Disable standard library indexing: `StandardLibrary: No` in `.clangd`
- See `SerenaFinal.md` Section 8 for the full configuration guide

### clangd crashes during serena_extract

The extraction script auto-detects clangd crashes and restarts the process. Check the error log for details:
```powershell
Get-Content architecture\.serena_context\.state\errors.log | Select-String "CRASH|RESTART"
```
If crashes are frequent, reduce workers (`-Workers 1`) or clangd parallelism (`-Jobs 1`). Failed files are automatically retried on the next run.

### Many empty files in serena_extract

Expected for non-C++ files (`.cs`, `.Build.cs`), bridging headers, and forward-declaration-only headers. clangd is a C++ language server and returns no symbols for these. Empty files are recorded in the hash DB and skipped on rerun. Check which files were empty:
```powershell
Get-Content architecture\.serena_context\.state\errors.log | Select-String "EMPTY" | Select-Object -Last 20
```

### serena_extract.py timeouts

Some symbols (like `UObject::GetClass`) have thousands of references. The script caps at 20 references per symbol with a 10-second timeout. If timeouts are excessive:
- Skip references entirely: `-SkipRefs` (symbols and trimmed source are still extracted)
- Target a smaller subdirectory: `-TargetDir Engine\Source\Runtime\Core`
- Reduce clangd parallelism: `-Jobs 2`

### Claude CLI not found

Ensure `claude` is in your `$PATH`:
```powershell
claude --version
```

### Rate limit persists after switching accounts

Delete the stale pause file:
```powershell
Remove-Item architecture\.archgen_state\ratelimit_resume.txt
Remove-Item architecture\.pass2_state\ratelimit_resume.txt
```

### Encoding issues (mojibake in output)

Ensure your terminal and `.env` are UTF-8. The pipeline writes all files as UTF-8. If you see `ΓÇö` instead of `—`, your terminal's code page may be wrong:
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

### WSL-specific issues

- Keep `JOBS=2` — higher parallelism exhausts WSL memory
- UE files are significantly larger than Quake files; `MAX_FILE_LINES=3000` may be needed
- Use bash scripts (`archgen.sh`, etc.) instead of PowerShell in WSL
