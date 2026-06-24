# Architecture Analysis Toolkit — Quickstart

Generate architecture documentation for C++ game engine codebases using a local LLM (or the Claude CLI) + clangd LSP.

Scripts live in `llm_scripts/`; run them from the codebase root as `.\llm_scripts\<name>.ps1`.

---

## Pipeline

Run in order. Steps marked *free* make zero LLM calls.

```
0 (free)   serena_extract.ps1     → LSP symbol data + trimmed source
0b         archgen_dirs.ps1       → per-directory architectural overviews (few LLM calls)
1          archgen.ps1            → per-file .md docs (with dir context + shared headers)
2 (free)   archxref.ps1           → cross-reference index
3 (free)   archgraph.ps1          → Mermaid call graph diagrams
4          arch_overview.ps1      → subsystem architecture overview (incremental)
4b (free)  archpass2_context.ps1  → per-file targeted context
5          archpass2.ps1          → enriched .pass2.md docs (selective)
```

---

## Minimal Setup

```powershell
# 1. Configure .env at codebase root
#    Default backend is a local LLM (ollama):
LLM_BACKEND=ollama
LLM_HOST=192.168.1.40
LLM_PORT=11434
LLM_DEFAULT_MODEL=qwen3.6:27B
JOBS=8
PRESET=unreal

# 2. Run the pipeline
.\llm_scripts\archgen.ps1 -Preset unreal -Jobs 8
.\llm_scripts\archxref.ps1
.\llm_scripts\archgraph.ps1
.\llm_scripts\arch_overview.ps1
.\llm_scripts\archpass2.ps1 -Preset unreal -Jobs 8
```

---

## With LSP Extraction (Recommended for C++)

Requires: `compile_commands.json` + clangd with built index.

```powershell
.\llm_scripts\serena_extract.ps1 -Preset unreal              # Free: extract LSP data
.\llm_scripts\archgen_dirs.ps1 -Preset unreal                # Dir-level overviews (few LLM calls)
.\llm_scripts\archgen.ps1 -Preset unreal -Jobs 8             # Auto-injects LSP + dir context + shared headers
.\llm_scripts\archxref.ps1
.\llm_scripts\archgraph.ps1
.\llm_scripts\arch_overview.ps1               # Incremental by default
.\llm_scripts\archpass2_context.ps1                           # Free: targeted context
.\llm_scripts\archpass2.ps1 -Preset unreal -Jobs 8 -Top 500  # Selective Pass 2
```

---

## Script Reference

### serena_extract.ps1

Adaptive parallel LSP extraction via clangd. Zero LLM calls.

```
.\llm_scripts\serena_extract.ps1 [options]
```

| Option           | Default        | Description                                                          |
|------------------|----------------|----------------------------------------------------------------------|
| `-TargetDir`     | `.`            | Subdirectory to scan                                                 |
| `-Preset`        | *(from .env)*  | Engine preset (`unreal`, `quake`, `godot`, `unity`, `source`, `rust`)|
| `-Jobs`          | `2`            | clangd `-j` flag: internal **threads** per clangd process            |
| `-Workers`       | `0` (auto)     | Number of clangd **processes** (separate instances). Auto-scales based on free RAM. |
| `-Force`         | off            | Re-extract even if context exists                                    |
| `-SkipRefs`      | off            | Skip reference queries (faster, symbols + trimmed source only)       |
| `-Compress`      | off            | Collapse classes to "ClassName (Class, N methods)", top-10 functions only |
| `-MinFreeRAM`    | `6.0`          | GB of free RAM to maintain (scale-down threshold)                    |
| `-RAMPerWorker`  | `5.0`          | Estimated GB per clangd instance                                     |
| `-ClangdPath`    | `clangd`       | Path to clangd binary                                                |
| `-EnvFile`       | `.env`         | Config file path                                                     |

**Disk usage**: clangd `--pch-storage=disk` writes ~80 MB PCH files per source file to temp. Auto-cleaned on exit; manual cleanup after interrupted runs: `Remove-Item "$env:TEMP\preamble-*.pch" -Force`.

**Worker cap**: More workers != more throughput. I/O contention at 7+ workers drops speed. Sweet spot for 32 GB: `-Workers 2 -Jobs 2`.

### archgen_dirs.ps1

Generates per-directory architectural overviews before Pass 1. On the claude backend, uses sonnet (tiered model). Few LLM calls.

```
.\llm_scripts\archgen_dirs.ps1 [options]
```

| Option           | Default        | Description                          |
|------------------|----------------|--------------------------------------|
| `-TargetDir`     | `.`            | Subdirectory to scan                 |
| `-Preset`        | *(from .env)*  | Engine preset                        |
| `-EnvFile`       | `.env`         | Config file path                     |

Output: `architecture/.dir_context/<dir>.dir.md`

### archgen.ps1

Pass 1: per-file architecture docs. On the claude backend, haiku by default with complex files auto-upgraded to sonnet. Pre-computes shared directory headers (80%+ threshold).

```
.\llm_scripts\archgen.ps1 [options]
```

| Option           | Default        | Description                                          |
|------------------|----------------|------------------------------------------------------|
| `-TargetDir`     | `.`            | Subdirectory to scan                                 |
| `-Preset`        | *(from .env)*  | Engine preset                                        |
| `-Jobs`          | *(from .env)*  | Parallel workers                                     |
| `-Claude1`       | off            | Use claude account 1 instead of 2 (claude backend)  |
| `-NoHeaders`     | off            | Disable header bundling                              |
| `-Clean`         | off            | Remove all output and restart                        |
| `-EnvFile`       | `.env`         | Config file path                                     |
| `-MaxTokens`     | off            | Map adaptive budget to `--max-tokens`                |
| `-JsonOutput`    | off            | Switch output format to JSON                         |
| `-Classify`      | off            | Two-phase classification (classifies as ANALYZE/STUB) |

### archxref.ps1

Cross-reference index. No LLM calls.

```
.\llm_scripts\archxref.ps1 [-TargetDir <dir>] [-EnvFile .env]
```

### archgraph.ps1

Mermaid call graph + subsystem dependency diagrams. No LLM calls.

```
.\llm_scripts\archgraph.ps1 [options]
```

| Option                  | Default | Description                            |
|-------------------------|---------|----------------------------------------|
| `-TargetDir`            | `.`     | Subdirectory scope                     |
| `-MaxCallEdges`         | `150`   | Max edges in function call graph       |
| `-MinCallSignificance`  | `2`     | Min call count to include a function   |
| `-EnvFile`              | `.env`  | Config file path                       |

### arch_overview.ps1

Subsystem architecture overview. Auto-chunks large codebases. On the claude backend, uses sonnet by default (when `TIERED_MODEL=1`). Incremental by default (tracks subsystem doc hashes in `overview_hashes.tsv`; unchanged subsystems skip on re-run). Single-child directories are descended through during chunking so deep paths like `Engine/Source/Runtime/Engine/Private` properly split into subdirectories (Animation, Audio, etc.).

```
.\llm_scripts\arch_overview.ps1 [options]
```

| Option           | Default | Description                                       |
|------------------|---------|---------------------------------------------------|
| `-TargetDir`     | `all`   | Subdirectory scope                                |
| `-Chunked`       | off     | Force two-tier chunked mode                       |
| `-Single`        | off     | Force single-pass mode                            |
| `-Full`          | off     | Force full regeneration (skip incremental logic)  |
| `-Clean`         | off     | Remove previous overview                          |
| `-Claude1`       | off     | Use claude account 1 (claude backend)            |
| `-EnvFile`       | `.env`  | Config file path                                  |

### archpass2_context.ps1

Per-file targeted context for Pass 2. No LLM calls.

```
.\llm_scripts\archpass2_context.ps1 [-TargetDir <dir>] [-EnvFile .env]
```

### archpass2.ps1

Pass 2: selective re-analysis with architecture context.

```
.\llm_scripts\archpass2.ps1 [options]
```

| Option           | Default        | Description                                  |
|------------------|----------------|----------------------------------------------|
| `-TargetDir`     | `.`            | Subdirectory scope                           |
| `-Preset`        | *(from .env)*  | Engine preset                                |
| `-Jobs`          | *(from .env)*  | Parallel workers                             |
| `-Claude1`       | off            | Use claude account 1 (claude backend)        |
| `-Clean`         | off            | Remove Pass 2 output and restart             |
| `-Only`          | *(empty)*      | Comma-separated file paths to process        |
| `-Top`           | `0` (all)      | Only process N highest-scoring files         |
| `-ScoreOnly`     | off            | Print scores without running                 |
| `-EnvFile`       | `.env`         | Config file path                             |

---

## Backend

The LLM-driven stages run against the backend selected by `LLM_BACKEND` in `.env`:

- **`ollama`** (default) — local Ollama server at `LLM_HOST:LLM_PORT` (default `192.168.1.40:11434`), model `qwen3.6:27B` (a thinking model; `LLM_THINK=true`).
- **`vllm`** — OpenAI-compatible gateway at `192.168.1.40:11430`, model `qwen3-coder-30b`.
- **`claude`** — `claude` CLI (haiku/sonnet via the `CLAUDE_*` keys, dual-account rotation).

The model/tier columns below describe the **claude** backend; on the local backends, every call uses `LLM_DEFAULT_MODEL`.

## Models

| Script                    | Model (claude backend) | Notes                                                        |
|---------------------------|------------------------|-------------------------------------------------------------|
| `serena_extract.ps1`      | None    | Free (local clangd)                                         |
| `archgen.ps1`             | haiku   | Complex files auto-upgrade to sonnet (`TIERED_MODEL=1`)     |
| `archxref.ps1`            | None    | Free (text processing)                                       |
| `archgraph.ps1`           | None    | Free (text processing)                                       |
| `arch_overview.ps1`       | sonnet  | sonnet (when `TIERED_MODEL=1`)                              |
| `archpass2_context.ps1`   | None    | Free (text processing)                                       |
| `archpass2.ps1`           | haiku   | Complex files auto-upgrade to sonnet (`TIERED_MODEL=1`)     |

Set `TIERED_MODEL=0` in `.env` to disable auto-upgrade (everything uses `CLAUDE_MODEL`).

---

## .env Variables

> The **Default** column lists each script's **code default** (the fallback used when the key is absent). The shipped `.env`/`.env.example` may set different values — for example `CLAUDE_MODEL=haiku` (code default `sonnet`), `MAX_FILE_LINES=3000` (code default `4000`), `MAX_BUNDLED_HEADERS=8` (code default `5`). When in doubt, the value in your `.env` wins.

### Backend

| Variable              | Default            | Description                                                  |
|-----------------------|--------------------|-------------------------------------------------------------|
| `LLM_BACKEND`         | `ollama`           | LLM backend: `ollama` / `vllm` / `claude`                   |
| `LLM_HOST`            | `192.168.1.40`     | Host for ollama/vllm backends                               |
| `LLM_PORT`            | `11434`            | Ollama port (vllm uses the gateway URL)                     |
| `LLM_ENDPOINT`        | *(derived)*        | Full-URL override for the backend endpoint                  |
| `LLM_DEFAULT_MODEL`   | `qwen3.6:27B`      | Model id (ollama tag `name:tag`, vllm served-name)          |
| `LLM_THINK`           | `true`             | Enable thinking mode (ollama thinking models)               |
| `LLM_NUM_CTX`         | `32768`            | Context window (ollama `/api/chat`)                         |
| `LLM_TEMPERATURE`     | `0.2`              | Sampling temperature                                        |
| `LLM_MAX_TOKENS`      | *(per stage)*      | Output token budget for local backends                      |
| `LLM_TIMEOUT`         | *(seconds)*        | Per-request timeout                                         |

### Required (claude backend only)

| Variable              | Description                        |
|-----------------------|------------------------------------|
| `CLAUDE1_CONFIG_DIR`  | First Claude account config path   |
| `CLAUDE2_CONFIG_DIR`  | Second Claude account config path  |

### Core

| Variable              | Default          | Description                                  |
|-----------------------|------------------|----------------------------------------------|
| `CLAUDE_MODEL`        | `sonnet`         | Default model on the claude backend (`haiku`, `sonnet`, `opus`) |
| `JOBS`                | `2`              | Parallel workers                             |
| `PRESET`              | *(empty)*        | Engine preset                                |
| `CODEBASE_DESC`       | *(from preset)*  | Codebase description passed to the model     |
| `MAX_RETRIES`         | `2`              | Retries per file                             |
| `RETRY_DELAY`         | `5`              | Seconds between retries                      |

### File Handling

| Variable              | Default | Description                                     |
|-----------------------|---------|-------------------------------------------------|
| `BUNDLE_HEADERS`      | `1`     | Bundle `#include` headers with source           |
| `MAX_BUNDLED_HEADERS` | `5`     | Max headers per file                            |
| `MAX_FILE_LINES`      | `4000`  | Source truncation limit                         |
| `CHUNK_THRESHOLD`     | `1500`  | Lines above which overview auto-chunks          |

### Token Optimization

| Variable                | Default  | Description                                              |
|-------------------------|----------|----------------------------------------------------------|
| `SKIP_TRIVIAL`          | `1`      | Skip generated/trivial files                             |
| `MIN_TRIVIAL_LINES`     | `20`     | Line count threshold for trivial                         |
| `TIERED_MODEL`          | `1`      | Auto-upgrade complex files + overview + pass 2 to sonnet |
| `HIGH_COMPLEXITY_MODEL` | `sonnet` | Model for complex files when tiered                      |
| `BUNDLE_HEADER_DOCS`    | `0`      | Bundle header .md docs instead of raw source             |
| `BATCH_TEMPLATED`       | `0`      | Group identical files, analyze one per group             |
| `USE_MAX_TOKENS`        | `0`      | Map adaptive budget to a hard output-token cap          |
| `JSON_OUTPUT`           | `0`      | Switch archgen output format to JSON                     |
| `CLASSIFY_FILES`        | `0`      | Two-phase classification (classifies as ANALYZE/STUB)   |

### Prompts

| Variable              | Default                         | Description                                                                         |
|-----------------------|---------------------------------|-------------------------------------------------------------------------------------|
| `PROMPT_FILE`         | *(auto)*                        | Auto-selects LSP prompt when context exists. Set to `file_doc_prompt_compact.txt` for min tokens. |
| `PROMPT_FILE_P2`      | `file_doc_prompt_pass2.txt`     | Pass 2 prompt                                                                       |

---

## Presets

| Preset                          | Languages          | Description          |
|---------------------------------|--------------------|----------------------|
| `unreal` / `ue4` / `ue5`       | cpp, h, cs         | Unreal Engine        |
| `quake` / `doom` / `idtech`    | c, h, cpp          | id Software engines  |
| `godot`                         | cpp, h, gd, cs     | Godot                |
| `unity`                         | cs, shader, hlsl   | Unity                |
| `source` / `valve`             | cpp, h, c          | Source Engine        |
| `rust`                          | rs, toml           | Rust engines         |

---

## Output

```
architecture/
  <path>.md              ← Pass 1 doc
  <path>.pass2.md        ← Pass 2 doc
  xref_index.md          ← Cross-references
  architecture.md        ← Overview
  callgraph.md           ← Mermaid diagrams
  .serena_context/       ← LSP extraction output
  .dir_context/          ← Per-directory architectural overviews (from archgen_dirs.ps1)
  .dir_headers/          ← Shared include lists per directory (from archgen.ps1)
  .pass2_context/        ← Targeted Pass 2 context
  .archgen_state/        ← Pass 1 state (hashes, progress)
  .pass2_state/          ← Pass 2 state
```

Project-specific files live at the analyzed codebase's root, not in the toolkit: `ANALYSIS_STATUS.md` (completed subsystems, doc counts, gaps) and `Analysis Map.md` (subsystem plan / `-TargetDir` paths).

---

## Resumability

All scripts are incremental. Interrupt with Ctrl+C and re-run to continue. Completed files are skipped via SHA1 hash matching. Steps marked *free* make zero LLM calls.

| Outcome              | Skipped on rerun |
|----------------------|------------------|
| Done                 | Yes              |
| Empty (no symbols)   | Yes              |
| Failed               | No (retried)     |
