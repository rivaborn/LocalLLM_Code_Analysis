# Architecture Analysis Toolkit — Command Reference

Complete command-line reference for every script in the toolkit. Each section covers syntax, all parameters, defaults, and usage examples.

---

## Table of Contents

1. [Pipeline Overview](#1-pipeline-overview)
2. [serena_extract.ps1 — LSP Context Extraction](#2-serena_extractps1--lsp-context-extraction)
3. [serena_extract.py — Python LSP Client (Direct)](#3-serena_extractpy--python-lsp-client-direct)
4. [archgen_dirs.ps1 — Directory-Level Overviews](#4-archgen_dirsps1--directory-level-overviews)
5. [archgen.ps1 — Pass 1: Per-File Documentation](#5-archgenps1--pass-1-per-file-documentation)
6. [archxref.ps1 — Cross-Reference Index](#6-archxrefps1--cross-reference-index)
7. [archgraph.ps1 — Call Graph Diagrams](#7-archgraphps1--call-graph-diagrams)
8. [arch_overview.ps1 — Architecture Overview](#8-arch_overviewps1--architecture-overview)
9. [archpass2_context.ps1 — Targeted Pass 2 Context](#9-archpass2_contextps1--targeted-pass-2-context)
10. [archpass2.ps1 — Pass 2: Selective Re-Analysis](#10-archpass2ps1--pass-2-selective-re-analysis)
11. [Bash Ports (Deprecated)](#11-bash-ports-deprecated)
12. [Model / Backend Usage](#12-model--backend-usage) — Backends, models by script, tiered quality impact, per-script recommendations
13. [.env Configuration Variables](#13-env-configuration-variables)
14. [Presets](#14-presets)
15. [Common Workflows](#15-common-workflows)

---

## 1. Pipeline Overview

Run scripts in this order. Steps marked "free" make zero Claude API calls.

```
Step 0 (free):   serena_extract.ps1      → .serena_context.txt files
Step 0b:         archgen_dirs.ps1        → per-directory .dir.md overviews (few Claude calls)
Step 1:          archgen.ps1             → per-file .md docs (with dir context + shared headers)
Step 2 (free):   archxref.ps1            → xref_index.md
Step 3 (free):   archgraph.ps1           → Mermaid diagrams
Step 4:          arch_overview.ps1       → architecture.md (incremental by default)
Step 4b (free):  archpass2_context.ps1   → per-file targeted .ctx.txt
Step 5:          archpass2.ps1           → per-file .pass2.md docs (selective)
```

Step 0 is optional. Step 0b generates directory-level overviews used as context in Step 1. Steps 2-3 can run in either order. Step 4 is incremental by default (unchanged subsystems skip; use `-Full` to force). Step 4b is optional but saves significant tokens in Step 5. Step 5 requires steps 1, 2, and 4.

---

## 2. serena_extract.ps1 — LSP Context Extraction

Extracts symbol overviews and cross-file references from clangd using adaptive parallel workers. Zero Claude calls. Automatically scales worker count based on available RAM.

### Syntax

```
.\llm_scripts\serena_extract.ps1
    [-TargetDir <string>]
    [-Preset <string>]
    [-Jobs <int>]
    [-Workers <int>]
    [-Force]
    [-SkipRefs]
    [-Compress]
    [-MinFreeRAM <double>]
    [-RAMPerWorker <double>]
    [-EnvFile <string>]
    [-ClangdPath <string>]
```

### Parameters

| Parameter       | Type   | Default    | Description                                                                                              |
|-----------------|--------|------------|----------------------------------------------------------------------------------------------------------|
| `-TargetDir`    | string | `"."`      | Subdirectory to scan (relative to repo root). Use `"."` for entire repo.                                 |
| `-Preset`       | string | `""`       | Engine preset for include/exclude patterns. See [Presets](#14-presets). Falls back to `PRESET` in `.env`. |
| `-Jobs`         | int    | `2`        | clangd `-j` flag: number of internal **threads** each clangd process uses for background work.           |
| `-Workers`      | int    | `0`        | Number of clangd **processes** (each is a separate instance with its own LSP connection). `0` = auto-detect based on free RAM. |
| `-Force`        | switch | off        | Re-extract all files even if `.serena_context.txt` already exists and source is unchanged.                |
| `-SkipRefs`     | switch | off        | Skip reference queries. Much faster — extracts symbols and trimmed source only, no incoming references.   |
| `-Compress`     | switch | off        | LSP compression: collapses classes to "ClassName (Class, N methods)", keeps only top-10 functions.        |
| `-MinFreeRAM`   | double | `6.0`      | Minimum free RAM in GB to maintain. Workers are shed if free RAM drops below this.                        |
| `-RAMPerWorker` | double | `5.0`      | Estimated RAM per clangd instance in GB. Used for auto-detect and scaling decisions.                      |
| `-EnvFile`      | string | `".env"`   | Path to environment configuration file.                                                                  |
| `-ClangdPath`   | string | `"clangd"` | Path to clangd binary. Use full path if clangd is not in `$PATH`.                                        |

### Adaptive Parallelism

The script runs multiple clangd instances in parallel, automatically scaling based on system RAM:

- **Startup**: Calculates initial workers as `(free_RAM - MinFreeRAM) / RAMPerWorker`
- **Scale up**: When free RAM > 10 GB and workers < max, spawns an additional clangd instance (~4s startup)
- **Scale down**: When free RAM < 4 GB and workers > 1, stops the newest worker (instant)
- **Checks**: RAM is monitored every ~60 seconds
- **Work distribution**: All workers pull from a shared queue — whoever finishes first grabs the next file

Each clangd instance is restarted every 1000 files to reclaim accumulated memory.

### PCH Disk Usage

clangd's `--pch-storage=disk` flag writes precompiled header files (`preamble-*.pch`) to the system temp directory. For UE files, each PCH averages ~80 MB due to `CoreMinimal.h`'s deep include chain. With multiple workers processing thousands of files, orphaned PCH files can accumulate to **50+ GB** if not cleaned up.

The script automatically manages this:
- **Startup**: Snapshots existing PCH files in temp so they are not touched
- **Shutdown**: Removes all session-created PCH files after workers stop
- **Exit safety**: Registers an `atexit` handler as a fallback for abnormal exits

To manually clean up orphaned PCH files from a previous interrupted run:

```powershell
Remove-Item "$env:TEMP\preamble-*.pch" -Force
```

**Important**: PCH files are reused by clangd across file parses (files sharing the same preamble, e.g., `CoreMinimal.h`, reuse the cached PCH). Cleanup only runs at shutdown, not mid-run, to avoid degrading throughput.

### Progress Display

```
  500/20000  done=480 empty=15 fail=5  avg=0.4/s now=0.6/s  w=2  clangd=8.3GB free=12.1GB  eta=9h04m10s
```

| Field    | Meaning                                                            |
|----------|--------------------------------------------------------------------|
| `done`   | Files successfully extracted                                       |
| `empty`  | Files with no symbols (skipped on rerun)                           |
| `fail`   | Files that failed (retried on rerun)                               |
| `avg`    | Cumulative average rate (done files / total time)                  |
| `now`    | Instantaneous rate (last 30 seconds)                               |
| `w`      | Active worker count                                                |
| `clangd` | Total RAM used by all clangd processes                             |
| `free`   | Free system RAM                                                    |
| `eta`    | Estimated time remaining based on avg rate (hours/minutes/seconds) |

The progress line stays on one line (overwrites in place). Scaling events appear inline: `[scaled up to 3w, 11.2GB free]` or `[scaled down to 2w, 3.8GB free]`.

### Crash Recovery

If a clangd process crashes (detected via broken pipe / `Errno 22`), the worker automatically:
1. Restarts a fresh clangd instance (~4 seconds)
2. Retries the current file once
3. Logs the crash event to `errors.log`
4. Continues processing the queue

Without crash recovery, a single clangd crash would fail every remaining file in that worker's queue.

### Incremental Behavior

| File outcome                  | Hash recorded | Skipped on rerun          | Rationale                           |
|-------------------------------|---------------|---------------------------|-------------------------------------|
| **Done** (symbols extracted)  | Yes           | Yes (if source unchanged) | Normal skip                         |
| **Empty** (no symbols)        | Yes           | Yes                       | clangd can't parse it; won't change |
| **Failed** (crash, error)     | No            | No (retried)              | Failure may be transient            |

### Performance Log

Written to `architecture/.serena_context/.state/perf.log` — tab-separated timing data per file showing breakdown of time spent in `didOpen`, `documentSymbol`, `find_references`, and `trimmed_source` phases. Includes the 3 slowest reference queries per file.

### Error Log

Written to `architecture/.serena_context/.state/errors.log` — tab-separated entries with timestamp, worker ID, event type (`EMPTY`, `FAIL`, `CRASH`, `RESTART`), file path, and message. Useful for diagnosing clangd crashes and identifying files that consistently fail.

### Prerequisites

- `compile_commands.json` at repo root
- clangd installed (via VS2022 Clang components or LLVM)
- clangd background index built (`.cache/clangd/index/`)
- Python 3.12+ via uv (`uv python install 3.12`)

### Output

```
architecture/.serena_context/<relative_path>.serena_context.txt
architecture/.serena_context/.state/perf.log
architecture/.serena_context/.state/errors.log
architecture/.serena_context/.state/hashes.tsv
```

### Examples

```powershell
# Auto-detect workers based on free RAM
.\llm_scripts\serena_extract.ps1 -Preset unreal

# Explicit 3 workers
.\llm_scripts\serena_extract.ps1 -Preset unreal -Workers 3

# Fast mode: symbols only, no reference queries
.\llm_scripts\serena_extract.ps1 -Preset unreal -SkipRefs

# Compressed LSP output (collapse classes, keep top-10 functions)
.\llm_scripts\serena_extract.ps1 -Preset unreal -Compress

# Max speed: 3 workers, skip refs
.\llm_scripts\serena_extract.ps1 -Preset unreal -Workers 3 -SkipRefs

# Single subsystem
.\llm_scripts\serena_extract.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal

# Force re-extraction of everything
.\llm_scripts\serena_extract.ps1 -Preset unreal -Force

# Tune RAM thresholds (tight system)
.\llm_scripts\serena_extract.ps1 -Preset unreal -Workers 2 -MinFreeRAM 4 -RAMPerWorker 4

# Use a specific clangd binary
.\llm_scripts\serena_extract.ps1 -Preset unreal -ClangdPath "C:\Program Files\LLVM\bin\clangd.exe"
```

### Workers vs Jobs

**Workers** = number of clangd **processes** (each is a separate clangd instance with its own LSP connection).
**Jobs** = clangd's internal `-j` flag — how many **threads** each clangd process uses for background work.

With `-Workers 3 -Jobs 4`, you get 3 separate clangd processes, each using 4 internal threads = 12 total threads competing for CPU and RAM.

Recommended combinations for 32 GB RAM:

| Workers | Jobs | Total Threads | Est. RAM |
|---------|------|---------------|----------|
| 3       | 2    | 6             | ~12 GB   |
| 2       | 4    | 8             | ~10 GB   |
| 2       | 2    | 4             | ~8 GB    |
| 1       | 4    | 4             | ~6 GB    |

Sweet spot for 32 GB: `-Workers 2 -Jobs 2`

**Warning**: More workers does not always mean more throughput. At UE scale, the bottleneck is disk I/O (reading headers, PCH files), not CPU. Too many workers cause I/O contention and all of them slow down. For example, 7 workers at `-Jobs 3` (21 threads) was observed to drop throughput from 0.6/s to 0.4/s compared to 2-3 workers.

### RAM Budget Guide

| System RAM | Recommended          | Expected Workers | Notes                   |
|------------|----------------------|------------------|-------------------------|
| 16 GB      | `-Workers 1`         | 1                | Single worker, safe     |
| 32 GB      | `-Workers 3` or auto | 2-3              | Auto scales between 1-3 |
| 64 GB      | `-Workers 6` or auto | 4-6              | Fast parallel extraction |

---

## 3. serena_extract.py — Python LSP Client (Direct)

The Python script that `serena_extract.ps1` invokes. Can be run directly for advanced use.

### Syntax

```
python serena_extract.py
    --repo-root <path>
    [--target-dir <path>]
    [--output-dir <path>]
    [--clangd-path <path>]
    [--jobs <int>]
    [--workers <int>]
    [--file-list <path>]
    [--include-rx <regex>]
    [--exclude-rx <regex>]
    [--force]
    [--skip-refs]
    [--min-free-ram <float>]
    [--ram-per-worker <float>]
```

### Parameters

| Parameter          | Type   | Default                              | Description                                                                              |
|--------------------|--------|--------------------------------------|------------------------------------------------------------------------------------------|
| `--repo-root`      | string | *(required)*                         | Absolute path to the repository root.                                                    |
| `--target-dir`     | string | `"."`                                | Subdirectory to scan within the repo root.                                               |
| `--output-dir`     | string | `architecture/.serena_context`       | Output directory for `.serena_context.txt` files.                                        |
| `--clangd-path`    | string | `"clangd"`                           | Path to clangd binary.                                                                   |
| `--jobs`           | int    | `2`                                  | clangd `-j` parallelism per instance.                                                    |
| `--workers`        | int    | `0`                                  | Max parallel clangd instances. `0` = auto based on free RAM.                             |
| `--file-list`      | string | `None`                               | Path to a text file containing one relative path per line. Overrides directory scanning.  |
| `--include-rx`     | regex  | `\.(cpp\|cc\|cxx\|h\|hpp\|inl\|c)$` | Regex for file extensions to include.                                                    |
| `--exclude-rx`     | regex  | *(long default)*                     | Regex for directories/paths to exclude.                                                  |
| `--force`          | flag   | off                                  | Re-extract even if context file exists and source is unchanged.                          |
| `--skip-refs`      | flag   | off                                  | Skip reference queries. Extracts symbols and trimmed source only.                        |
| `--min-free-ram`   | float  | `6.0`                                | Minimum free RAM in GB to maintain.                                                      |
| `--ram-per-worker` | float  | `5.0`                                | Estimated RAM per clangd instance in GB.                                                 |

### Examples

```bash
# Run directly via uv with auto workers
uv run --python 3.12 serena_extract.py --repo-root C:/Coding/Epic_Games/UnrealEngine

# 3 workers, skip refs
uv run --python 3.12 serena_extract.py --repo-root . --workers 3 --skip-refs

# Extract specific files from a list
uv run --python 3.12 serena_extract.py --repo-root . --file-list my_files.txt

# Custom output directory
uv run --python 3.12 serena_extract.py --repo-root . --output-dir ./lsp_data
```

---

## 4. archgen_dirs.ps1 — Directory-Level Overviews

Generates per-directory architectural overviews before Pass 1. Uses sonnet (tiered model). Few Claude calls — one per directory. Output is used as context by `archgen.ps1` workers.

### Syntax

```
.\llm_scripts\archgen_dirs.ps1
    [-TargetDir <string>]
    [-Preset <string>]
    [-EnvFile <string>]
```

### Parameters

| Parameter    | Type   | Default  | Description                                                                 |
|--------------|--------|----------|-----------------------------------------------------------------------------|
| `-TargetDir` | string | `"."`    | Subdirectory to scan. Use `"."` for entire repo.                            |
| `-Preset`    | string | `""`     | Engine preset. Falls back to `PRESET` in `.env`. See [Presets](#14-presets). |
| `-EnvFile`   | string | `".env"` | Path to environment configuration file.                                     |

### Output

```
architecture/.dir_context/<dir>.dir.md
```

### Examples

```powershell
# Generate directory overviews for full codebase
.\llm_scripts\archgen_dirs.ps1 -Preset unreal

# Single subsystem
.\llm_scripts\archgen_dirs.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal
```

---

## 5. archgen.ps1 — Pass 1: Per-File Documentation

Generates one structured `.md` doc per source file using Claude CLI. Automatically injects LSP context when available.

### Syntax

```
.\llm_scripts\archgen.ps1
    [-TargetDir <string>]
    [-Preset <string>]
    [-Claude1]
    [-Clean]
    [-NoHeaders]
    [-Jobs <int>]
    [-EnvFile <string>]
    [-MaxTokens <string>]
    [-JsonOutput <string>]
    [-CompressLSP <string>]
    [-Classify <string>]
    [-ElideSource <string>]
    [-NoBatch <string>]
    [-NoPreamble <string>]
```

> **Note on the optimization flags.** `-MaxTokens`, `-JsonOutput`, `-CompressLSP`, `-Classify`, `-ElideSource`, `-NoBatch`, and `-NoPreamble` are declared as `[string]` parameters (default `""`), **not** `[switch]` — this works around a PowerShell parameter-binding error. Enable each by passing a non-empty value, e.g. `-MaxTokens "1"` or `-Classify "1"`. Passing the flag with no value does **not** enable it. Each also has an `.env` equivalent (see table).

### Parameters

| Parameter      | Type   | Default         | Description                                                                                                |
|----------------|--------|-----------------|------------------------------------------------------------------------------------------------------------|
| `-TargetDir`   | string | `"."`           | Subdirectory to scan. Use `"."` for entire repo.                                                           |
| `-Preset`      | string | `""`            | Engine preset. Falls back to `PRESET` in `.env`. See [Presets](#14-presets).                                |
| `-Claude1`     | switch | off             | Use account 1 (`CLAUDE1_CONFIG_DIR`) instead of account 2.                                                 |
| `-Clean`       | switch | off             | Delete all output and state, then start fresh. **Irreversible.**                                           |
| `-NoHeaders`   | switch | off             | Disable header bundling. Overrides `BUNDLE_HEADERS` in `.env`.                                             |
| `-Jobs`        | int    | 0 (from `.env`) | Parallel worker count. 0 means use `JOBS` from `.env` (default 2).                                         |
| `-EnvFile`     | string | `".env"`        | Path to environment configuration file.                                                                    |
| `-MaxTokens`   | string | `""`            | Pass a value (e.g. `"1"`) to enable. Hard output cap: maps adaptive budget to `--max-tokens` (Claude backend). Also via `USE_MAX_TOKENS=1`. |
| `-JsonOutput`  | string | `""`            | Pass a value to enable. Switches output format to JSON. Also via `JSON_OUTPUT=1`.                          |
| `-CompressLSP` | string | `""`            | Pass a value to enable. Compresses injected LSP context to save tokens. Also via `COMPRESS_LSP=1`.         |
| `-Classify`    | string | `""`            | Pass a value to enable. Two-phase classification: ultra-cheap classifier call labels files ANALYZE or STUB. Also via `CLASSIFY_FILES=1`. |
| `-ElideSource` | string | `""`            | Pass a value to enable. Elide source from payload.                                                         |
| `-NoBatch`     | string | `""`            | Pass a value to enable. Disable batch templated files.                                                     |
| `-NoPreamble`  | string | `""`            | Pass a value to enable. Disable preamble in output.                                                        |

### Automatic Behaviors

- **LSP context injection**: When `architecture/.serena_context/` exists, the worker loads matching `.serena_context.txt` files and injects them into the Claude payload. No flag needed.
- **Prompt auto-selection**: When LSP context exists, `file_doc_prompt_lsp.txt` is used. Otherwise, `file_doc_prompt.txt`. Override with `PROMPT_FILE` in `.env`.
- **Resumability**: Files with unchanged SHA1 hashes and existing output are skipped automatically.
- **Prompt caching**: Both `archgen_worker.ps1` and `archpass2_worker.ps1` use a fixed system prompt (`file_doc_system_prompt.txt`) identical across all calls, enabling API-level prompt caching at ~10% of the full token rate. The per-file prompt schema is embedded in the user message. No configuration needed.
- **Rate-limit handling**: Workers detect rate limits, parse reset times, and pause all threads until the limit resets.

### Output

```
architecture/<relative_path>.md
```

### Progress Display

```
PROGRESS: 480/20000  skip=15  fail=5  retries=2  rate=0.4/s  eta=0h54m33s
```

| Field     | Meaning                                                    |
|-----------|------------------------------------------------------------|
| `skip`    | Files skipped (unchanged hash)                             |
| `fail`    | Files that failed                                          |
| `retries` | Retry attempts (read from `counter.json`)                  |
| `rate`    | Cumulative average rate (done / elapsed time)              |
| `eta`     | Estimated time remaining in `Xh YYm ZZs` format           |

The progress line uses `[Console]::Write()` for single-line in-place updates. Done count is read from the append-only hash DB (`hashes.tsv`) to avoid file contention with `counter.json` that workers write via mutex. Rate-limit status is appended when active (e.g., `[RATE LIMITED ~3m, until 2:15 PM]`).

### State Files

```
architecture/.archgen_state/hashes.tsv            — SHA1 skip database
architecture/.archgen_state/counter.json           — Progress counter
architecture/.archgen_state/last_claude_error.log  — Error log
architecture/.archgen_state/ratelimit_resume.txt   — Shared rate-limit pause
architecture/.archgen_state/fatal.flag             — Fatal error flag
architecture/.archgen_state/fatal.msg              — Fatal error message
```

### Examples

```powershell
# Full codebase with preset
.\llm_scripts\archgen.ps1 -Preset unreal -Jobs 8

# Single subsystem
.\llm_scripts\archgen.ps1 -TargetDir Engine\Source\Runtime\Renderer -Preset unreal -Jobs 4

# Without header bundling
.\llm_scripts\archgen.ps1 -Preset unreal -NoHeaders

# Using account 1
.\llm_scripts\archgen.ps1 -Preset unreal -Claude1

# Clean start (removes all previous output)
.\llm_scripts\archgen.ps1 -Preset unreal -Clean

# Custom .env file
.\llm_scripts\archgen.ps1 -Preset unreal -EnvFile .env.production
```

---

## 6. archxref.ps1 — Cross-Reference Index

Parses Pass 1 docs and builds a cross-reference index. No Claude calls. Runs in seconds.

### Syntax

```
.\llm_scripts\archxref.ps1
    [-TargetDir <string>]
    [-EnvFile <string>]
```

### Parameters

| Parameter    | Type   | Default  | Description                              |
|--------------|--------|----------|------------------------------------------|
| `-TargetDir` | string | `"."`    | Scope the index to a subdirectory's docs. |
| `-EnvFile`   | string | `".env"` | Path to environment configuration file.  |

### Output

```
architecture/xref_index.md
```

Contains: function-to-file map, call graph table, reverse call map, global state ownership, header dependencies, subsystem interfaces.

### Examples

```powershell
# Build index from all Pass 1 docs
.\llm_scripts\archxref.ps1

# Build index for a specific subsystem
.\llm_scripts\archxref.ps1 -TargetDir Engine\Source\Runtime\Renderer
```

---

## 7. archgraph.ps1 — Call Graph Diagrams

Extracts call edges from Pass 1 docs and generates Mermaid diagrams. No Claude calls.

### Syntax

```
.\llm_scripts\archgraph.ps1
    [-TargetDir <string>]
    [-MaxCallEdges <int>]
    [-MinCallSignificance <int>]
    [-EnvFile <string>]
```

### Parameters

| Parameter              | Type   | Default  | Description                                                                                          |
|------------------------|--------|----------|------------------------------------------------------------------------------------------------------|
| `-TargetDir`           | string | `"."`    | Scope diagrams to a subdirectory's docs.                                                             |
| `-MaxCallEdges`        | int    | `150`    | Maximum number of call edges to include in the function-level graph. Higher values produce larger diagrams. |
| `-MinCallSignificance` | int    | `2`      | Minimum call count for a function to appear. Set higher to filter noise.                             |
| `-EnvFile`             | string | `".env"` | Path to environment configuration file.                                                              |

### Output

```
architecture/callgraph.mermaid     — Function-level call graph (raw Mermaid)
architecture/subsystems.mermaid    — Subsystem dependency diagram (raw Mermaid)
architecture/callgraph.md          — Both diagrams in markdown with embedded Mermaid
```

### Examples

```powershell
# Default settings
.\llm_scripts\archgraph.ps1

# More edges, lower threshold
.\llm_scripts\archgraph.ps1 -MaxCallEdges 300 -MinCallSignificance 1

# Only renderer subsystem
.\llm_scripts\archgraph.ps1 -TargetDir Engine\Source\Runtime\Renderer
```

---

## 8. arch_overview.ps1 — Architecture Overview

Synthesizes Pass 1 docs into a subsystem-level architecture overview using Claude.

### Syntax

```
.\llm_scripts\arch_overview.ps1
    [-TargetDir <string>]
    [-Chunked]
    [-Single]
    [-Full]
    [-Clean]
    [-Claude1]
    [-EnvFile <string>]
```

### Parameters

| Parameter    | Type   | Default  | Description                                                            |
|--------------|--------|----------|------------------------------------------------------------------------|
| `-TargetDir` | string | `"all"`  | Subdirectory to scope the overview. `"all"` uses all docs.             |
| `-Chunked`   | switch | off      | Force two-tier chunked mode even if data is small.                     |
| `-Single`    | switch | off      | Force single-pass mode even if data is large. May hit context limits.  |
| `-Full`      | switch | off      | Force full regeneration, skipping incremental logic.                   |
| `-Clean`     | switch | off      | Remove previous overview output before generating.                     |
| `-Claude1`   | switch | off      | Use account 1 instead of account 2.                                    |
| `-EnvFile`   | string | `".env"` | Path to environment configuration file.                                |

### Incremental Behavior

By default, `arch_overview.ps1` tracks subsystem doc hashes in `overview_hashes.tsv`. On re-run, subsystems whose underlying docs have not changed are skipped. Use `-Full` to force regeneration of all subsystems.

### Auto-Chunking

If the extracted data exceeds `CHUNK_THRESHOLD` lines (default 1500 in `.env`):
1. Discovers subsystem directories from the Pass 1 docs
2. Generates a per-subsystem overview for each (one Claude call per subsystem)
3. Synthesizes a final overview from those subsystem overviews
4. Recursively splits subsystems that are still too large

Single-child directories are descended through during chunking instead of stopping the split. For example, `Engine/Source/Runtime/Engine/Private` properly splits into its subdirectories (Animation, Audio, etc.) instead of being treated as one oversized chunk.

### Output

```
architecture/architecture.md                    — Final synthesized overview
architecture/<subsystem> architecture.md        — Per-subsystem overviews (chunked mode)
architecture/diagram_data.md                    — Extracted signal data for synthesis
```

### Examples

```powershell
# Auto-detect single vs chunked
.\llm_scripts\arch_overview.ps1 -Preset unreal

# Force chunked mode
.\llm_scripts\arch_overview.ps1 -Preset unreal -Chunked

# Single subsystem overview
.\llm_scripts\arch_overview.ps1 -TargetDir Engine\Source\Runtime\Renderer

# Clean and regenerate
.\llm_scripts\arch_overview.ps1 -Preset unreal -Clean
```

---

## 9. archpass2_context.ps1 — Targeted Pass 2 Context

Builds per-file targeted context extracts for Pass 2. Extracts only the relevant architecture overview and xref entries for each file. Zero Claude calls.

### Syntax

```
.\llm_scripts\archpass2_context.ps1
    [-TargetDir <string>]
    [-EnvFile <string>]
```

### Parameters

| Parameter    | Type   | Default  | Description                             |
|--------------|--------|----------|-----------------------------------------|
| `-TargetDir` | string | `"."`    | Scope to a subdirectory.                |
| `-EnvFile`   | string | `".env"` | Path to environment configuration file. |

### Prerequisites

Must run these first:
1. `archxref.ps1` — xref_index.md (required)
2. `arch_overview.ps1` — architecture.md (required)

### Output

```
architecture/.pass2_context/<relative_path>.ctx.txt
```

Each `.ctx.txt` contains:
- **Architecture Context** — Only the subsystem paragraph relevant to this specific file
- **Cross-Reference Entries** — Only xref lines mentioning this file's name or symbols

### Impact

Replaces the blunt 200+300 line global context with 30-80 lines of targeted context per file. The Pass 2 worker auto-detects these files and uses them when available.

### Examples

```powershell
# Build targeted context for all files
.\llm_scripts\archpass2_context.ps1

# Build for a specific subsystem
.\llm_scripts\archpass2_context.ps1 -TargetDir Engine\Source\Runtime\Renderer
```

---

## 10. archpass2.ps1 — Pass 2: Selective Re-Analysis

Re-analyzes source files with architecture context injected. Supports selective processing to target only the highest-value files.

### Syntax

```
.\llm_scripts\archpass2.ps1
    [-TargetDir <string>]
    [-Claude1]
    [-Clean]
    [-Only <string>]
    [-Jobs <int>]
    [-EnvFile <string>]
    [-Top <int>]
    [-ScoreOnly]
    [-Delta]
```

### Parameters

| Parameter    | Type   | Default          | Description                                                                                                            |
|--------------|--------|------------------|------------------------------------------------------------------------------------------------------------------------|
| `-TargetDir` | string | `"."`            | Subdirectory to scope the re-analysis.                                                                                 |
| `-Claude1`   | switch | off              | Use account 1 instead of account 2.                                                                                    |
| `-Clean`     | switch | off              | Remove all Pass 2 output and state, then start fresh. Does NOT affect Pass 1 docs.                                     |
| `-Only`      | string | `""`             | Comma-separated list of relative file paths to process. Overrides normal file collection.                              |
| `-Jobs`      | int    | 0 (from `.env`) | Parallel worker count. 0 means use `JOBS` from `.env`.                                                                 |
| `-EnvFile`   | string | `".env"`         | Path to environment configuration file.                                                                                |
| `-Top`       | int    | `0`              | Only process the N highest-scoring files. 0 means process all files (original behavior).                               |
| `-ScoreOnly` | switch | off              | Print file scores and exit without running any model calls. Use with `-Top` to preview which files would be selected.  |
| `-Delta`     | switch | off              | Delta-only mode: emit only new insights beyond the Pass 1 doc rather than a full re-written document. Saves tokens.    |

### Scoring Formula (with -Top)

When `-Top N` is specified, files are scored:

```
score = (incoming_reference_count * 3) + (line_count / 100)
if file has .serena_context.txt: score *= 0.5
```

- **Incoming references**: How many times other files reference this file in `xref_index.md`. High count = "hub" file.
- **Line count**: Larger files score higher (more likely to contain complex logic).
- **Serena discount**: Files that had LSP context in Pass 1 are discounted (already enriched).

Files are sorted by score descending, and the top N are processed.

### Prerequisites

Must run these first:
1. `archgen.ps1` — per-file docs (required)
2. `archxref.ps1` — xref_index.md (required)
3. `arch_overview.ps1` — architecture.md (required)

### Output

```
architecture/<relative_path>.pass2.md
```

Does NOT overwrite Pass 1 `.md` files.

### State Files

```
architecture/.pass2_state/hashes.tsv              — SHA1 skip database
architecture/.pass2_state/counter.json             — Progress counter
architecture/.pass2_state/last_claude_error.log    — Error log
architecture/.pass2_state/ratelimit_resume.txt     — Shared rate-limit pause
```

### Examples

```powershell
# Process all files (original behavior)
.\llm_scripts\archpass2.ps1 -Preset unreal -Jobs 8

# Selective: top 500 highest-scoring files
.\llm_scripts\archpass2.ps1 -Preset unreal -Jobs 8 -Top 500

# Preview scores without running
.\llm_scripts\archpass2.ps1 -Preset unreal -Top 500 -ScoreOnly

# Manual file selection
.\llm_scripts\archpass2.ps1 -Only "Engine/Source/Runtime/Engine/Private/Actor.cpp,Engine/Source/Runtime/CoreUObject/Private/UObject/UObjectBase.cpp"

# Specific subdirectory
.\llm_scripts\archpass2.ps1 -TargetDir Engine\Source\Runtime\Renderer -Jobs 4

# Clean Pass 2 output and regenerate
.\llm_scripts\archpass2.ps1 -Preset unreal -Clean -Jobs 8

# Using account 1
.\llm_scripts\archpass2.ps1 -Preset unreal -Claude1 -Jobs 8
```

---

## 11. Bash Ports (Deprecated)

**The bash (`.sh`) ports are deprecated and unmaintained. Use the PowerShell scripts on all platforms (Windows, Linux, macOS, WSL) via `pwsh`.**

A small set of old `.sh` ports survives under `llm_Dep/` for historical reference only:

```
llm_Dep/arch_overview.sh
llm_Dep/archgen.sh
llm_Dep/archgraph.sh
llm_Dep/archpass2.sh
llm_Dep/archxref.sh
```

These five scripts:
- predate the local-LLM backend and assume the `claude` CLI only (no `LLM_BACKEND` / vLLM / Ollama support);
- have not been kept in sync with the `.ps1` scripts (missing optimization flags, dir-context, shared headers, etc.);
- have no ports for `serena_extract`, `archgen_dirs`, or `archpass2_context`.

Do not use them for new work. PowerShell 7+ (`pwsh`) is cross-platform; run the `.ps1` scripts directly on Linux/macOS.

For the LSP extraction step on non-Windows systems, run the Python client directly:

```bash
uv run --python 3.12 serena_extract.py --repo-root /path/to/repo --target-dir src
```

---

## 12. Model / Backend Usage

### Backends

The LLM-driven stages (`archgen.ps1`, `archgen_dirs.ps1`, `arch_overview.ps1`, `archpass2.ps1`) route through `llm_core.ps1` and are selected by `LLM_BACKEND` in `.env`:

| `LLM_BACKEND` | Target                                                      | Model selection                                                                                       |
|---------------|-------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| `ollama`      | **Default.** Raw Ollama server (`/api/chat`).               | `LLM_DEFAULT_MODEL` (default `qwen3.6:27B`, a thinking model). `LLM_THINK=true` separates reasoning.   |
| `vllm`        | LLMConfig OpenAI gateway at `http://192.168.1.40:11430/v1`. | `LLM_DEFAULT_MODEL` (e.g. `qwen3-coder-30b`, a vLLM served-name with hyphens).                         |
| `claude`      | `claude` CLI. Only backend needing `CLAUDE{1,2}_CONFIG_DIR`. | `CLAUDE_MODEL` (`haiku`/`sonnet`) with `TIERED_MODEL` auto-upgrade (see below).                |

`llm_core.ps1` exposes `Get-LLMBackend`, `Get-LLMEndpoint`, `Get-LLMModel`, and `Invoke-LocalLLM`. Model id conventions differ: vLLM served-names use hyphens (`qwen3.6-27b`), Ollama tags use colons (`qwen3.6:27B`).

The `haiku`/`sonnet` model selection and the `TIERED_MODEL` auto-upgrade described in the rest of this section apply **only when `LLM_BACKEND=claude`**. For the local backends (`ollama`, `vllm`) the served model is fixed by `LLM_DEFAULT_MODEL` (with `arch_overview.ps1` / `archgen_dirs.ps1` using larger token budgets via `LLM_OVERVIEW_MAX_TOKENS` / `LLM_DIR_MAX_TOKENS`).

### Models by Script (Claude backend)

| Script                  | Default Model       | With `TIERED_MODEL=1` (default)                  | With `TIERED_MODEL=0`          |
|-------------------------|---------------------|--------------------------------------------------|--------------------------------|
| `serena_extract.ps1`    | **None**            | No change                                        | No change                      |
| `archgen.ps1`           | haiku (from `.env`) | High-complexity files auto-upgrade to **sonnet** | All files use `CLAUDE_MODEL`   |
| `archxref.ps1`          | **None**            | No change                                        | No change                      |
| `archgraph.ps1`         | **None**            | No change                                        | No change                      |
| `arch_overview.ps1`     | haiku (from `.env`) | Auto-upgrades to **sonnet**                      | Uses `CLAUDE_MODEL`            |
| `archpass2_context.ps1` | **None**            | No change                                        | No change                      |
| `archpass2.ps1`         | haiku (from `.env`) | High-complexity files auto-upgrade to **sonnet** | All files use `CLAUDE_MODEL`   |

Only `archgen.ps1`, `archgen_dirs.ps1`, `arch_overview.ps1`, and `archpass2.ps1` make LLM calls. When `LLM_BACKEND=claude`, `archgen.ps1`, `arch_overview.ps1`, and `archpass2.ps1` support `TIERED_MODEL` for automatic haiku-to-sonnet upgrades. All other scripts are either free (local clangd / text processing) or use no AI at all.

### Tiered Model: Quality Impact

With `TIERED_MODEL=1` (the default), `archgen.ps1` and `archpass2.ps1` classify each file:

| Complexity | Criteria                         | Model  | Quality Effect                                                                                                                                               |
|------------|----------------------------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Low**    | <100 lines AND <=2 symbols       | haiku  | No difference — files are too simple for sonnet to add value                                                                                                 |
| **Medium** | Everything else                  | haiku  | Minimal difference — straightforward code, haiku handles well                                                                                                |
| **High**   | >1000 lines OR >10 incoming refs | sonnet | **Noticeably better** — tracks deeper call chains, identifies non-obvious design patterns, handles large files with many interacting symbols more coherently |

For `arch_overview.ps1`, sonnet is always used (when tiered is enabled) because the overview synthesizes all Pass 1 docs into a coherent subsystem-level architecture narrative — a task that benefits from sonnet's stronger reasoning.

Setting `TIERED_MODEL=0` forces all scripts to use `CLAUDE_MODEL` from `.env` (haiku by default). This is cheaper but produces lower quality on complex files, Pass 2 re-analysis, and the architecture overview.

### Per-Script Recommendations

**`arch_overview.ps1` — sonnet recommended (default with `TIERED_MODEL=1`)**

The overview synthesizes all Pass 1 docs into a coherent subsystem-level architecture narrative. This requires understanding relationships between subsystems, identifying coupling patterns, and producing a well-structured summary. Sonnet is significantly better at this kind of high-level synthesis. The cost impact is minimal — only a handful of Claude calls (one per chunk + one final synthesis).

**`archpass2.ps1` — haiku + tiered auto-upgrade (default, same as archgen.ps1)**

Pass 2 already receives rich context (Pass 1 doc + architecture overview + xref/targeted context). With `TIERED_MODEL=1` (the default), high-complexity files (>1000 lines or >10 incoming references in the xref index) auto-upgrade to sonnet, matching the same behavior as `archgen.ps1`. With `-Top 500` selective mode, only the most architecturally complex files are processed — many of which will be auto-upgraded to sonnet. Set `TIERED_MODEL=0` to keep all files on `CLAUDE_MODEL`.

**`archgen.ps1` — haiku + tiered auto-upgrade (default)**

~90% of files use haiku (same quality for simple files, much cheaper). ~10% high-complexity hub files get sonnet (better quality where it matters). Net effect: similar overall quality to running everything on sonnet, at ~30-50% lower cost.

---

## 13. .env Configuration Variables

All variables are optional. Set these in a `.env` file at the repo root.

### LLM Backend Settings

| Variable                  | Default          | Description                                                                                       |
|---------------------------|------------------|--------------------------------------------------------------------------------------------------|
| `LLM_BACKEND`             | `ollama`         | LLM backend: `ollama`, `vllm`, or `claude`.                                                       |
| `LLM_DEFAULT_MODEL`       | `qwen3.6:27B`    | Served model for `ollama`/`vllm` (Ollama tags use colons, vLLM served-names use hyphens).        |
| `LLM_THINK`               | `true`           | Ollama only: separate reasoning from the answer for thinking models (e.g. `qwen3.6:27B`).         |
| `LLM_HOST`                | *(from backend)* | Host for the local backend.                                                                       |
| `LLM_PORT`                | `11434`          | Ollama port.                                                                                      |
| `LLM_ENDPOINT`            | *(derived)*      | Full-URL override for the backend endpoint.                                                       |
| `LLM_TEMPERATURE`         | *(model)*        | Sampling temperature.                                                                             |
| `LLM_MAX_TOKENS`          | *(backend)*      | Max output tokens per call.                                                                       |
| `LLM_OVERVIEW_MAX_TOKENS` | *(larger)*       | Token budget for `arch_overview.ps1`.                                                             |
| `LLM_DIR_MAX_TOKENS`      | *(larger)*       | Token budget for `archgen_dirs.ps1`.                                                              |
| `LLM_TIMEOUT`             | *(backend)*      | Per-call timeout in seconds.                                                                      |
| `LLM_NUM_CTX`             | `0`              | Ollama `/api/chat` context window. `>0` switches the request to the `num_ctx` chat path.          |

### Claude Settings (only when `LLM_BACKEND=claude`)

| Variable               | Default      | Description                                      |
|------------------------|--------------|--------------------------------------------------|
| `CLAUDE1_CONFIG_DIR`   | *(required)* | Path to first Claude account config directory    |
| `CLAUDE2_CONFIG_DIR`   | *(required)* | Path to second Claude account config directory   |
| `CLAUDE_MODEL`         | `sonnet`     | Claude model to use: `haiku`, `sonnet`, `opus`   |
| `CLAUDE_MAX_TURNS`     | `1`          | Maximum turns per Claude CLI call                |
| `CLAUDE_OUTPUT_FORMAT` | `text`       | Claude output format                             |

### Parallelism & Retries

| Variable      | Default | Description                                                                   |
|---------------|---------|-------------------------------------------------------------------------------|
| `JOBS`        | `2`     | Number of parallel workers. Safe default for WSL; use 4-8 on native Windows.  |
| `MAX_RETRIES` | `2`     | Retries per file on transient Claude failure                                  |
| `RETRY_DELAY` | `5`     | Seconds to wait between retries                                               |

### File Filtering

| Variable              | Default          | Description                                                          |
|-----------------------|------------------|----------------------------------------------------------------------|
| `PRESET`              | *(empty)*        | Engine preset: `quake`, `unreal`, `godot`, `unity`, `source`, `rust` |
| `INCLUDE_EXT_REGEX`   | *(from preset)*  | Regex matching file extensions to include                            |
| `EXCLUDE_DIRS_REGEX`  | *(from preset)*  | Regex matching directories/paths to exclude                          |
| `EXTRA_EXCLUDE_REGEX` | *(empty)*        | Additional exclude regex (stacks with preset exclusions)             |
| `CODEBASE_DESC`       | *(from preset)*  | Human-readable description of the codebase, passed to Claude         |
| `DEFAULT_FENCE`       | *(from preset)*  | Markdown code fence language identifier (e.g., `cpp`, `c`, `csharp`) |

### File Handling

| Variable              | Default | Description                                                                      |
|-----------------------|---------|----------------------------------------------------------------------------------|
| `BUNDLE_HEADERS`      | `1`     | `1` = bundle local `#include` headers with each source file. `0` = disable.      |
| `MAX_BUNDLED_HEADERS` | `5`     | Maximum number of headers to bundle per source file                              |
| `MAX_FILE_LINES`      | `4000`  | Source file truncation limit. Files exceeding this are head+tail truncated.       |
| `CHUNK_THRESHOLD`     | `1500`  | Lines above which `arch_overview.ps1` auto-switches to chunked mode              |

### Token Optimization

| Variable                | Default  | Description                                                                                                                                                                                                  |
|-------------------------|----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `SKIP_TRIVIAL`          | `1`      | Skip generated/trivial files. Writes stub docs instead of Claude calls. Patterns: `.generated.h`, `.gen.cpp`, `Module.*.cpp`, files under `MIN_TRIVIAL_LINES`.                                               |
| `MIN_TRIVIAL_LINES`     | `20`     | Files with fewer lines than this are considered trivial and auto-skipped                                                                                                                                     |
| `TIERED_MODEL`          | `1`      | Enable tiered model selection. High-complexity files (>1000 lines or >10 incoming refs) use `HIGH_COMPLEXITY_MODEL`, others use `CLAUDE_MODEL`. Applies to `archgen.ps1`, `archpass2.ps1`, and `arch_overview.ps1`. |
| `HIGH_COMPLEXITY_MODEL` | `sonnet` | Model for high-complexity files when `TIERED_MODEL=1`                                                                                                                                                        |
| `BUNDLE_HEADER_DOCS`    | `0`      | When a header already has a Pass 1 `.md` doc, bundle the doc (~400 tokens) instead of the raw source (~4000 tokens). Requires two-pass strategy (headers first).                                             |
| `BATCH_TEMPLATED`       | `0`      | Group structurally identical files (by first-20-lines hash). Groups of 3+ files: one representative analyzed, rest get path-substituted docs.                                                                |
| `USE_MAX_TOKENS`        | `0`      | Hard output cap: maps adaptive budget to `--max-tokens` on Claude CLI. Also via `-MaxTokens` flag on `archgen.ps1`.                                                                                         |
| `JSON_OUTPUT`           | `0`      | Switches `archgen.ps1` output format to JSON. Also via `-JsonOutput` flag.                                                                                                                                   |
| `CLASSIFY_FILES`        | `0`      | Two-phase classification: ultra-cheap haiku call classifies files as ANALYZE or STUB before full analysis. Also via `-Classify` flag on `archgen.ps1`.                                                       |

### Prompt Selection

| Variable         | Default                     | Description                                                                                                                                                                       |
|------------------|-----------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `PROMPT_FILE`    | *(auto-selected)*           | Pass 1 prompt path. Auto-selects `llm_prompts/file_doc_prompt_lsp.txt` when LSP context exists, otherwise `llm_prompts/file_doc_prompt.txt`. Set to `llm_prompts/file_doc_prompt_compact.txt` for ~70% fewer prompt tokens. (Prompt templates live in `llm_prompts/`; an explicit value is used as-is, so give a path that resolves from the repo root.) |
| `PROMPT_FILE_P2` | `llm_prompts/file_doc_prompt_pass2.txt` | Pass 2 prompt file (under `llm_prompts/`)                                                                                                                              |

### Example .env

```env
# LLM backend (default: ollama)
LLM_BACKEND=ollama
LLM_DEFAULT_MODEL=qwen3.6:27B
LLM_THINK=true

# Claude accounts (only needed when LLM_BACKEND=claude)
# CLAUDE1_CONFIG_DIR=$HOME/.claudeaccount1
# CLAUDE2_CONFIG_DIR=$HOME/.claudeaccount2
# CLAUDE_MODEL=haiku

# Parallelism
JOBS=8
MAX_RETRIES=2

# Codebase
PRESET=unreal
CODEBASE_DESC=Unreal Engine 5.7.3 C++ source. Core, CoreUObject, Engine, Renderer, PhysicsCore, Slate/UMG, AIModule.

# File handling
BUNDLE_HEADERS=1
MAX_BUNDLED_HEADERS=5
MAX_FILE_LINES=4000
CHUNK_THRESHOLD=1500

# Token optimizations
SKIP_TRIVIAL=1
TIERED_MODEL=1
HIGH_COMPLEXITY_MODEL=sonnet
BUNDLE_HEADER_DOCS=1
BATCH_TEMPLATED=1
PROMPT_FILE=llm_prompts/file_doc_prompt_compact.txt
```

---

## 14. Presets

Presets configure include/exclude patterns and codebase descriptions. Set via `-Preset` flag or `PRESET` in `.env`.

| Preset Name(s)                                 | File Extensions                                                                              | Excluded Directories                                                                                                                             | Description                         |
|-------------------------------------------------|----------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------|
| `quake`, `quake2`, `quake3`, `doom`, `idtech`   | `.c .cc .cpp .cxx .h .hh .hpp .inl .inc`                                                    | `.git`, `architecture`, `build`, `out`, `dist`, `obj`, `bin`, `Debug`, `Release`, `baseq2`, `baseq3`, `base`                                    | id Software / Quake-family C engine |
| `unreal`, `ue4`, `ue5`                          | `.cpp .h .hpp .cc .cxx .inl .cs`                                                             | `.git`, `architecture`, `Binaries`, `Build`, `DerivedDataCache`, `Intermediate`, `Saved`, `ThirdParty`, `GeneratedFiles`, `AutomationTool`       | Unreal Engine C++/C#                |
| `godot`                                         | `.cpp .h .hpp .c .cc .gd .gdscript .tscn .tres .cs`                                         | `.git`, `architecture`, `.godot`, `.import`, `build`, `export`                                                                                   | Godot engine (C++/GDScript/C#)      |
| `unity`                                         | `.cs .shader .cginc .hlsl .compute .glsl .cpp .c .h`                                        | `.git`, `architecture`, `Library`, `Temp`, `Obj`, `Build`, `Builds`, `Logs`, `UserSettings`                                                      | Unity (C#/shaders)                  |
| `source`, `valve`                               | `.cpp .h .hpp .c .cc .cxx .inl .inc .vpc .vgc`                                              | `.git`, `architecture`, `build`, `out`, `obj`, `bin`, `Debug`, `Release`, `lib`, `thirdparty`                                                    | Source Engine (Valve)               |
| `rust`                                          | `.rs .toml`                                                                                  | `.git`, `architecture`, `target`, `.cargo`                                                                                                       | Rust game engines (Bevy, etc.)      |
| *(none / empty)*                                | `.c .cc .cpp .cxx .h .hh .hpp .inl .inc .cs .java .py .rs .lua .gd .gdscript .m .mm .swift` | `.git`, `architecture`, `build`, `out`, `dist`, `obj`, `bin`, `Debug`, `Release`, `.vs`, `.vscode`, `node_modules`, `.godot`, `Library`, `Temp`  | Generic fallback for any codebase   |

Presets can be overridden by setting `INCLUDE_EXT_REGEX`, `EXCLUDE_DIRS_REGEX`, `CODEBASE_DESC`, or `DEFAULT_FENCE` in `.env`. The `.env` values take precedence over preset defaults.

---

## 15. Common Workflows

### Small Codebase (No LSP)

For codebases under ~500 files where LSP setup isn't worth the effort:

```powershell
.\llm_scripts\archgen.ps1 -Preset quake -Jobs 8
.\llm_scripts\archxref.ps1
.\llm_scripts\archgraph.ps1
.\llm_scripts\arch_overview.ps1
.\llm_scripts\archpass2.ps1 -Preset quake -Jobs 8
```

### Large C++ Codebase (With LSP, Full Optimizations)

For codebases with `compile_commands.json` and a built clangd index. All optimizations enabled:

```powershell
.\llm_scripts\serena_extract.ps1 -Preset unreal                        # Free: LSP + trimmed source
.\llm_scripts\archgen_dirs.ps1 -Preset unreal                          # Dir-level overviews (few Claude calls)
.\llm_scripts\archgen.ps1 -Preset unreal -Jobs 8                       # Auto-skips trivial, injects LSP + dir context + shared headers
.\llm_scripts\archxref.ps1
.\llm_scripts\archgraph.ps1
.\llm_scripts\arch_overview.ps1 -Preset unreal                         # Incremental by default
.\llm_scripts\archpass2_context.ps1                                     # Free: targeted context
.\llm_scripts\archpass2.ps1 -Preset unreal -Jobs 8 -Top 500            # Selective, targeted context
```

### Single Subsystem Deep-Dive

Analyze one part of a large codebase in detail:

```powershell
.\llm_scripts\serena_extract.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal
.\llm_scripts\archgen.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal -Jobs 8
.\llm_scripts\archxref.ps1 -TargetDir Engine\Source\Runtime\Core
.\llm_scripts\archgraph.ps1 -TargetDir Engine\Source\Runtime\Core
.\llm_scripts\arch_overview.ps1 -TargetDir Engine\Source\Runtime\Core
.\llm_scripts\archpass2_context.ps1 -TargetDir Engine\Source\Runtime\Core
.\llm_scripts\archpass2.ps1 -TargetDir Engine\Source\Runtime\Core -Jobs 4
```

### Learning-Oriented Analysis

Use the learning prompt for educational documentation:

```powershell
# Set in .env: PROMPT_FILE=llm_prompts/file_doc_prompt_learn.txt
.\llm_scripts\archgen.ps1 -Preset quake -Jobs 4
.\llm_scripts\archxref.ps1
.\llm_scripts\arch_overview.ps1
.\llm_scripts\archpass2.ps1 -Only "server/sv_main.c,client/cl_main.c,game/g_main.c"
```

### Preview Pass 2 Scoring

See which files would be selected before committing to a run:

```powershell
.\llm_scripts\archpass2.ps1 -Preset unreal -Top 200 -ScoreOnly
```

### Resume After Rate Limit

Simply re-run the same command. All scripts are fully resumable:

```powershell
# This skips already-completed files and continues where it left off
.\llm_scripts\archgen.ps1 -Preset unreal -Jobs 8
```

If switching Claude accounts after a rate limit:

```powershell
# Clear stale pause file, then switch accounts
Remove-Item architecture\.archgen_state\ratelimit_resume.txt -ErrorAction SilentlyContinue
.\llm_scripts\archgen.ps1 -Preset unreal -Jobs 8 -Claude1
```

### Clean Start

```powershell
# Remove ALL output (Pass 1, Pass 2, xref, overview, diagrams, state)
.\llm_scripts\archgen.ps1 -Clean

# Remove only Pass 2 output and state
.\llm_scripts\archpass2.ps1 -Clean
```
