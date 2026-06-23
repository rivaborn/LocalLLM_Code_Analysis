# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Architecture documentation toolkit for large C++ codebases (ships tuned for Unreal Engine 5.x via the `unreal` preset). Generates per-file and subsystem-level architecture docs using a configurable LLM backend (local Ollama/vLLM via LLMConfig, or the Claude CLI), with LSP-powered semantic analysis via clangd.

This is the standalone **toolkit** repository — the `arch*.ps1` + `serena_extract.*` scripts in `llm_scripts/`, the prompt templates in `llm_prompts/`, the docs in `llm_doc/`, and the deprecated `.sh` ports in `llm_Dep/`. It is run from the root of whatever codebase you want to analyze (e.g. an Unreal Engine source tree); that target codebase is the *subject*, not part of this repo. `README.md` is the toolkit's own readme.

**Repository:** `github.com/rivaborn/LocalLLM_Code_Analysis`
**Target example:** Unreal Engine 5.7.3 source (the `unreal` preset + bundled prompts target UE)
**System:** Windows 11, 32 GB RAM

The toolkit is **PowerShell-first**: the active scripts live in `llm_scripts/` (run them from the codebase root, e.g. `.\llm_scripts\archgen.ps1`), all reading `.env` from the codebase root. `*_worker.ps1` scripts are dispatched via `Start-Job` and must never be run directly. The old `.sh` ports are **deprecated** and live in `llm_Dep/` (they predate the local-LLM backend and assume the `claude` CLI only) — do not use or update them.

## Pipeline Order

```
0.  serena_extract.ps1       Free (direct clangd, no Claude)
0b. archgen_dirs.ps1         Few Claude calls (sonnet, per-directory)
1.  archgen.ps1              Per-file docs (haiku, sonnet for complex files)
2.  archxref.ps1             Free (text processing)
3.  archgraph.ps1            Free (text processing)
4.  arch_overview.ps1        Subsystem synthesis (sonnet, incremental)
4b. archpass2_context.ps1    Free (text processing)
5.  archpass2.ps1            Selective re-analysis (haiku, sonnet for complex)
```

## Common Commands

Run from the repo root (PowerShell). Scripts read `.env`; `-Preset unreal` and `-Jobs` are usually passed explicitly. Steps marked *free* make zero Claude calls. All scripts are incremental — Ctrl+C and re-run resumes (completed files skipped via SHA1 hash in `hashes.tsv`); failed files are retried, done/empty are not.

```powershell
# Full pipeline (recommended order)
.\llm_scripts\serena_extract.ps1 -Preset unreal -Workers 2 -Jobs 2   # free; LSP extract (slow, hours on first index)
.\llm_scripts\archgen_dirs.ps1   -Preset unreal                      # per-directory overviews (few sonnet calls)
.\llm_scripts\archgen.ps1        -Preset unreal -Jobs 8              # Pass 1 per-file docs (haiku, sonnet for complex)
.\llm_scripts\archxref.ps1                                           # free; cross-reference index
.\llm_scripts\archgraph.ps1                                          # free; Mermaid call graphs
.\llm_scripts\arch_overview.ps1                                      # subsystem synthesis (sonnet, incremental)
.\llm_scripts\archpass2_context.ps1                                  # free; targeted Pass 2 context
.\llm_scripts\archpass2.ps1      -Preset unreal -Jobs 8 -Top 500    # selective Pass 2 (highest-scoring files)
```

Useful options:
- Scope to a subdirectory on any script: `-TargetDir Engine/Source/Runtime/Core`
- `-Clean` on `archgen.ps1` restarts Pass 1 but preserves `.serena_context/`, `.dir_context/`, `.dir_headers/`
- `-Claude1` switches from account 2 (default) to account 1 for rate-limit rotation
- `archpass2.ps1 -ScoreOnly` prints scores without running; `-Only <paths>` processes specific files
- `serena_extract.ps1`: **Workers** = clangd processes, **Jobs** = `-j` threads each. 32 GB sweet spot is `-Workers 2 -Jobs 2` (more workers cause I/O contention, not speedup)

## Outputs

Everything lands under `architecture/` (excluded from analysis):

```
architecture/
  <path>.md             Pass 1 per-file doc
  <path>.pass2.md       Pass 2 enriched doc
  xref_index.md         cross-references
  architecture.md       subsystem overview
  callgraph.md          Mermaid diagrams
  .serena_context/      LSP extraction (preserve across subsystems — hours to regenerate)
  .dir_context/         per-directory overviews (archgen_dirs.ps1)
  .dir_headers/         shared include lists per directory (archgen.ps1)
  .pass2_context/       targeted Pass 2 context
  .archgen_state/       Pass 1 state: hashes.tsv (progress), counter.json (fail/retries)
  .pass2_state/         Pass 2 state
```

The workflow is **one subsystem at a time**: analyze, then rename `architecture/` (e.g. `architecture_CoreUObject/`). Keep `.serena_context/` — it covers the entire codebase and is reused across subsystems.

## Key Configuration

- `.env` has `CLAUDE_MODEL=haiku` with `TIERED_MODEL=1` (auto-upgrades complex files to sonnet)
- `CLAUDE1_CONFIG_DIR` and `CLAUDE2_CONFIG_DIR` for dual-account rate-limit rotation
- `-Clean` on archgen.ps1 preserves `.serena_context/`, `.dir_context/`, `.dir_headers/`

## Local LLM backend (LLMConfig)

The LLM-driven stages can run against the homelab **LLMConfig** box instead of the `claude` CLI. The backend is selected by `LLM_BACKEND` in `.env`:

- **`ollama`** (current default) — raw Ollama server at `http://<LLM_HOST>:<LLM_PORT>` (default `:11434`), serving **`qwen3.6:27B`**. This is a **thinking model**: with `LLM_THINK=true` and the native `/api/chat` path (used when `LLM_NUM_CTX>0`), its reasoning goes to a separate `message.thinking` field and is kept OUT of the doc content. Slower than vLLM (reasoning pass every call) but produces clean Qwen-3.6 output. NOTE: this hits raw Ollama directly, bypassing the gateway's GPU arbitration — before a run, load the model once via the gateway (`POST :11430/api/load {server:ollama,model:qwen3.6:27B}`) so Ollama owns the card. The toolkit forces `Jobs=1` on the ollama backend (concurrent requests split `num_ctx` across slots and silently drop large files).
- **`vllm`** — LLMConfig OpenAI `/v1` gateway at `http://192.168.1.40:11430`; auto-loads the model on first request. Fast (~1s/call). Use a non-thinking served-name like `qwen3-coder-30b` — thinking models (e.g. `qwen3.6-27b`) leak chain-of-thought into content here (no reasoning-parser on the gateway).
- **`claude`** — the `claude` CLI path (haiku/sonnet via the `CLAUDE_*` keys). The only backend that requires a valid `CLAUDE{1,2}_CONFIG_DIR`.

Relevant `.env` keys: `LLM_BACKEND`, `LLM_HOST`, `LLM_ENDPOINT` (full-URL override), `LLM_PORT` (ollama only), `LLM_DEFAULT_MODEL` (default `qwen3.6:27B`; Ollama tags use `:`, vLLM served-names use `-`), `LLM_THINK` (ollama thinking-model reasoning separation), `LLM_TEMPERATURE`, `LLM_MAX_TOKENS`, `LLM_TIMEOUT`, `LLM_NUM_CTX` (ollama `/api/chat` only, must be >0 for the native path). `arch_overview.ps1` and `archgen_dirs.ps1` use larger budgets via `LLM_OVERVIEW_MAX_TOKENS` / `LLM_DIR_MAX_TOKENS`.

Implementation: `llm_core.ps1` (`Get-LLMBackend` / `Get-LLMEndpoint` / `Get-LLMModel` / `Invoke-LocalLLM`) is dot-sourced by every LLM-calling script. Because `*_worker.ps1` run in `Start-Job` runspaces (where `$PSScriptRoot` is empty), they dot-source `llm_core.ps1` via a `toolkitDir` passed from the parent, and receive the resolved backend/endpoint/model/think flags as `-llm*` parameters. Each call site branches on `$llmBackend`: `claude` keeps the original `& claude` path; anything else calls `Invoke-LocalLLM`. The vLLM path posts to `/v1/chat/completions` (OpenAI schema); the ollama path posts to `/api/chat` when `NumCtx>0` (sending `think` when enabled). When `-Think` is on, `Invoke-LocalLLM` floors the token budget (`LLM_THINK_MIN_TOKENS`, 8000) so reasoning + content both fit. On non-claude backends `archgen.ps1` also forces `Jobs=1` and disables file batching + header bundling (local models choke on the big multi-file / multi-header prompts those create) -- each file is sent on its own with its injected LSP context, and any still-oversized file auto-degrades (drop headers, then truncate).

**Prompt policy -- online keeps every optimization; local is minimized.** For a non-`claude` `LLM_BACKEND`, `archgen.ps1` builds a lean Pass-1 prompt = file source (truncated) + injected LSP/serena context + the compact schema (`file_doc_prompt_compact.txt`) + the output-budget line; it force-disables header bundling, file/template batching, the engine preamble, and directory context. `archpass2.ps1` drops the global architecture + xref context for local (keeping the small per-file `.pass2_context`); `arch_overview.ps1` caps the synthesis chunk size; and Step 0b `archgen_dirs.ps1` is claude-only (its `.dir_context` is unused by the local Pass-1 prompt). All gating is by backend, so the `claude` path is unchanged.

## Known Issues and Bugs

### archgen_worker.ps1 — Files not written to disk (FIXED)
Root cause: PowerShell 5.1 `if/else` expression unwraps single-element arrays to scalars. The line `$relList = if ($isBatch) { $rel -split '\|' } else { @($rel) }` returned a string instead of an array for individual (non-batch) files. Then `$relList[0]` indexed the first character of the string (e.g., `"E"` from `"Engine/..."`) instead of returning the whole path. Fix: wrap the entire `if/else` in `@()` — `$relList = @(if ($isBatch) { ... } else { ... })`. Batch files worked because `$rel -split '\|'` returns a multi-element array that survives unwrapping.

### PowerShell em dash encoding
Em dashes (`—`) in PowerShell scripts get mojibaked to `â€"` on some systems. Replace with regular dashes (`-`) in all `.ps1` files.

### PowerShell strict mode and .Count
Under `Set-StrictMode -Version Latest`, calling `.Count` on a non-array fails. Always wrap `Get-PerFileDocs` and similar calls in `@()` to ensure array return.

### archpass2_context.ps1 — regex in double-quoted strings
PowerShell 5.1 chokes on `$([regex]::Escape($key))` inside double-quoted strings in certain contexts. Use a separate variable instead: `$escaped = [regex]::Escape($key)`.

### serena_extract.py — scale-up worker missing compress arg
Fixed: the scale-up worker creation (line ~1020) was missing `compress=args.compress`. Both initial and scale-up worker creation must pass all arguments.

### -Clean deletes .serena_context/
Fixed: `-Clean` now preserves `.serena_context/`, `.dir_context/`, and `.dir_headers/`. These are expensive to regenerate (hours of clangd extraction).

### serena_extract.py -- PCH disk bloat (preamble-*.pch)
Fixed: clangd `--pch-storage=disk` wrote orphaned `preamble-*.pch` files to temp, accumulating 50+ GB. The script now snapshots existing PCH at startup and cleans up session files on shutdown + `atexit`. Cleanup only runs at exit (not mid-run) to avoid degrading throughput -- active clangd instances reuse PCH files across parses.

### serena_extract.py -- I/O contention with many workers
Auto-scaler can spawn too many workers (observed: 7 workers at `-Jobs 3` = 21 threads). Disk I/O contention drops throughput from 0.6/s to 0.4/s. Cap workers explicitly: `-Workers 2 -Jobs 2` for 32 GB systems.

### archgen.ps1 switch parameters
Changed from `[switch]` to `[string]` for the v2/v3 opt-in flags (`$ElideSource`, `$NoBatch`, `$NoPreamble`, `$MaxTokens`, `$JsonOutput`, `$Classify`) due to a PowerShell binding error. Check with `-ne ''` instead of boolean test.

### archgen.ps1 -- progress display not updating (FIXED)
Reading `counter.json` (written by workers via mutex + `Set-Content`) from the parent process was unreliable -- file contention caused silent read failures inside `catch {}`. Fixed: progress now counts lines in `hashes.tsv` (append-only, read with `StreamReader`) and reads `counter.json` only for fail/retries (best-effort). Display uses `[Console]::Write()` with `\r` for single-line in-place updates. ETA shown in `0h54m33s` format. The `[math]::Floor()` results must be cast to `[int]` for PowerShell's `:D2` format specifier.

### arch_overview.ps1 -- chunking fails on deep single-child paths (FIXED)
When `Get-Subsystems` encountered a directory with only 1 child (e.g., `Engine` -> `Source` -> `Runtime` -> `Engine` -> `Private`), it stopped splitting and treated the entire oversized subtree as one chunk. Fix: single-child directories are now descended through without incrementing depth, so the recursion reaches the actual multi-child directory (e.g., `Private` with Animation, Audio, PhysicsEngine, etc.).

## Workers vs Jobs (serena_extract)

- **Workers** = number of clangd processes
- **Jobs** = `-j` threads per clangd process
- 3 workers x 4 jobs = 12 threads, too much for 32 GB
- Sweet spot for 32 GB: `-Workers 2 -Jobs 2`

## clangd Index

- Built once, cached at `.cache/clangd/index/` (1.5 GB, 112K idx files)
- Takes ~8.5 hours to build from scratch with `-j=4`
- Post-indexing steady state: ~4 GB RAM per clangd instance
- Parse time per UE file: 3-8 seconds (bottleneck is include chain resolution, not file size)

## Token Optimizations

28 optimizations documented in `llm_doc/Optimizations.md`, grouped v1-v4:
- v1: 8 (skip trivial, shared headers, LSP trimming, targeted P2 context, tiered model, batch templates, compressed prompt, adaptive budget)
- v2: 6 (batch small files, preamble, schema pruning, delta P2, source elision, pattern cache)
- v3: 7 (max-tokens, dir-first analysis, LSP compression, JSON output, shared dir headers, incremental overview, classification)
- v4: 1 implemented (prompt caching), 5 documented (diff-based, on-demand, cluster, sampling, templates)

Baseline ~250M tokens -> after v1-v3: ~12M tokens (95% reduction)

## Documentation Files

Toolkit docs live in `llm_doc/`:
- `llm_doc/SETUP.md` — Full setup guide
- `llm_doc/Instructions.md` — Per-script CLI reference
- `Quickstart.md` — Condensed reference (at repo root)
- `llm_doc/SerenaFinal.md` — Complete LSP-extraction technical reference
- `llm_doc/FileReference.md` — Index of all files
- `llm_doc/Optimizations.md` — Token optimization strategies

Prompt templates live in `llm_prompts/` (`file_doc_prompt_*.txt`, `file_doc_system_prompt.txt`, `classify_prompt.txt`, `ue_preamble.txt`); `archgen.ps1`/`archpass2.ps1` resolve them as a sibling of `llm_scripts/` via `(Split-Path $PSScriptRoot -Parent)/llm_prompts`.
