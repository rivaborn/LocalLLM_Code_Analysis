# Architecture Analysis Toolkit — File Reference

## Layout

Scripts live in `llm_scripts/`, prompts in `llm_prompts/`, docs in `llm_doc/`, and deprecated bash ports in `llm_Dep/`. Run scripts from the codebase root as `.\llm_scripts\<name>.ps1`.

The LLM-driven stages can run against a local LLM (ollama or a vLLM gateway) or the `claude` CLI, selected by `LLM_BACKEND` in `.env`. The default backend is `ollama` (`qwen3.6:27B`, a thinking model); `vllm` targets the gateway at `192.168.1.40:11430` (`qwen3-coder-30b`); `claude` is the Claude CLI path. The shared backend module is `llm_scripts/llm_core.ps1`.

## Pipeline Scripts (PowerShell)

### llm_scripts/serena_extract.ps1 — LSP Context Extraction (Step 0)
PowerShell wrapper that orchestrates adaptive parallel LSP extraction via clangd. Reads `.env` for preset/include/exclude patterns, verifies prerequisites (compile_commands.json, clangd index), and invokes `llm_scripts/serena_extract.py` via `uv run --python 3.12`. Zero LLM calls — all extraction is local clangd queries. Supports `-Preset`, `-TargetDir`, `-Jobs`, `-Workers`, `-Force`, `-SkipRefs`, `-Compress`, `-MinFreeRAM`, `-RAMPerWorker` flags. Auto-scales worker count based on available system RAM. The `-Compress` flag collapses classes to "ClassName (Class, N methods)" and keeps only top-10 functions.

### llm_scripts/serena_extract.py — Adaptive Parallel LSP Client (Python)
Standalone Python script that spawns multiple clangd processes and communicates via LSP JSON-RPC over stdio. Workers pull files from a shared queue — whoever finishes first grabs the next file. RAM is monitored every ~60 seconds: scales up when >10 GB free, scales down when <4 GB free. For each source file: opens the file, extracts the symbol tree (`documentSymbol`), optionally queries cross-file references, generates LSP-trimmed source for large files, and writes a `.serena_context.txt` file. Each clangd instance restarts every 1000 files to reclaim memory. Auto-detects clangd crashes (broken pipe / Errno 22) and restarts the process with a single retry per file. Empty files (no symbols) are recorded in the hash DB so they're skipped on rerun; failed files are not, so they retry automatically. Writes per-file performance log and error log with timing breakdown. Uses SHA1 hashing for incremental support. ETA is calculated from successfully completed files only (empty/failed files excluded). Supports `--compress` mode: collapses classes to "ClassName (Class, N methods)" and keeps only top-10 functions. **PCH cleanup**: clangd's `--pch-storage=disk` writes `preamble-*.pch` files to the system temp directory (averaging ~80 MB each for UE files). The script snapshots existing PCH files at startup and automatically cleans up session-created PCH files on worker shutdown and via `atexit`, preventing unbounded disk usage (observed: 50+ GB without cleanup).

### llm_scripts/archgen_dirs.ps1 — Directory-Level Overview Generator (Step 0b)
Generates per-directory architectural overviews before Pass 1. Scans source directories, produces a `.dir.md` overview for each via the configured LLM backend (sonnet via tiered model when on the `claude` backend). Output: `architecture/.dir_context/<dir>.dir.md`. These directory overviews are automatically loaded by `archgen.ps1` workers to provide architectural context for each file. Run between `serena_extract.ps1` and `archgen.ps1` in the pipeline.

### llm_scripts/archgen.ps1 — Pass 1: Per-File Documentation (Step 1)
Main workhorse. Walks every source file, bundles local `#include` headers for context, sends each to the configured LLM backend (ollama / vllm / claude), and generates a structured `.md` doc per file. On the `claude` backend the default model is `CLAUDE_MODEL` from `.env`, and with `TIERED_MODEL=1` high-complexity files auto-upgrade to `HIGH_COMPLEXITY_MODEL` (sonnet). Runs in parallel (`-Jobs N`), tracks progress via hash DB line counting (append-only, no contention) with `[Console]::Write()` for single-line updates and ETA in h:m:s format, retries on transient failures, and maintains a SHA1 hash database for resumability. Supports `-Preset` for common engines. Auto-detects `architecture/.serena_context/` and injects LSP context into each file's LLM call when available. Auto-selects `file_doc_prompt_lsp.txt` when LSP context is present. Pre-computes shared directory headers (80%+ threshold) into `architecture/.dir_headers/<dir>.headers.txt`; workers load these first. Loads directory-level overviews from `architecture/.dir_context/` when available. Built-in token optimizations: skips generated/trivial files (`SKIP_TRIVIAL`), adaptive output budget per file, tiered model selection (`TIERED_MODEL`), header doc bundling (`BUNDLE_HEADER_DOCS`), batch templated files (`BATCH_TEMPLATED`), and LSP-guided source trimming for large files. Opt-in flags: `-MaxTokens` (maps adaptive budget to `--max-tokens`), `-JsonOutput` (switches to JSON output format), `-Classify` (two-phase classification as ANALYZE or STUB). Corresponding `.env` variables: `USE_MAX_TOKENS`, `JSON_OUTPUT`, `CLASSIFY_FILES`.

### llm_scripts/archgen_worker.ps1 — Pass 1 Worker
Per-file worker dispatched by `archgen.ps1` via `Start-Job`. Builds the payload (source + headers + LSP context + output budget), calls the resolved LLM backend (via `Invoke-LocalLLM` for ollama/vllm, or `& claude` on the `claude` backend), handles rate limits, and writes output. Dot-sources `llm_core.ps1` and receives the resolved backend/endpoint/model as `-llm*` parameters from its parent. Fixed bug: PowerShell 5.1 `if/else` expression unwraps single-element arrays to scalars, so `$relList[0]` indexed the first character of the path string instead of returning the whole path - fixed by wrapping the entire `if/else` in `@()`. Uses `file_doc_system_prompt.txt` as a fixed system prompt across all calls to enable prompt caching (claude backend); the per-file prompt schema is embedded in the user message. Three-stage fallback for "prompt too long": stage 0 (full + headers + LSP), stage 1 (full + LSP, no headers), stage 2 (truncated, no headers, no LSP). Uses LSP-trimmed source for large files when available (from `.serena_context.txt`). Bundles header docs instead of raw source when `BUNDLE_HEADER_DOCS=1`. Appends adaptive output budget instruction to payload.

### llm_scripts/archxref.ps1 — Cross-Reference Index (Step 2)
Parses all Pass 1 docs and builds a cross-reference index: function-to-file mappings, call graph edges, global state ownership, header dependency counts, and subsystem interfaces. Pure text processing — no LLM calls, completes in seconds.

### llm_scripts/archgraph.ps1 — Call Graph & Dependency Diagrams (Step 3)
Extracts function call edges from Pass 1 docs and generates Mermaid diagrams: function-level call graphs grouped by subsystem, and subsystem dependency diagrams with cross-boundary call counts. No LLM calls. Configurable via `-MaxCallEdges` and `-MinCallSignificance`.

### llm_scripts/arch_overview.ps1 — Architecture Overview (Step 4)
Synthesizes all Pass 1 docs into a subsystem-level architecture overview. Auto-chunks by directory for large codebases. Recursively splits oversized subsystems. Single-child directories are now descended through instead of stopping the chunked split, so paths like `Engine/Source/Runtime/Engine/Private` properly split into subdirectories (Animation, Audio, PhysicsEngine, etc.). On the `claude` backend with `TIERED_MODEL=1` (the default), auto-upgrades to `HIGH_COMPLEXITY_MODEL` (sonnet); set `TIERED_MODEL=0` to keep it on `CLAUDE_MODEL`. Benefits from higher-quality Pass 1 docs when LSP context was injected. Incremental by default: tracks subsystem doc hashes in `overview_hashes.tsv` — unchanged subsystems skip on re-run. Use `-Full` flag to force full regeneration.

### llm_scripts/archpass2_context.ps1 — Targeted Pass 2 Context (Step 4b)
Builds per-file targeted context extracts for Pass 2. For each source file with a Pass 1 doc, extracts only the relevant architecture overview paragraphs and xref index entries (by subsystem matching and filename grep). Produces small `.ctx.txt` files (~30-80 lines) instead of the full 500-line global context blobs. Zero LLM calls — pure text processing, runs in seconds. The Pass 2 worker auto-detects these files.

### llm_scripts/archpass2.ps1 — Pass 2: Selective Re-Analysis (Step 5)
Re-analyzes source files with architecture overview + xref index + Pass 1 doc as context. On the `claude` backend the default model is `CLAUDE_MODEL` from `.env`, and with `TIERED_MODEL=1` high-complexity files auto-upgrade to `HIGH_COMPLEXITY_MODEL` (sonnet), matching the tiered behavior of `archgen.ps1`. Supports `-Top N` for selective processing: scores files by incoming reference count and file size, discounts files that already had LSP context in Pass 1. `-ScoreOnly` flag previews scores without running. Supports `-Only file1,file2,...` for manual targeting.

### llm_scripts/archpass2_worker.ps1 — Pass 2 Worker
Per-file worker dispatched by `archpass2.ps1`. Dot-sources `llm_core.ps1` and calls the resolved LLM backend. Uses `file_doc_system_prompt.txt` as a fixed system prompt across all calls to enable prompt caching (claude backend); the per-file prompt schema is embedded in the user message. Auto-detects targeted context files (`.pass2_context/<path>.ctx.txt`) and uses them instead of global truncated blobs when available. Four-stage fallback: stage 0 (source + pass1 + targeted or global context), stage 1 (drop xref/targeted context), stage 2 (drop arch context, truncate harder), stage 3 (source only). Handles rate limits with shared pause file coordination across parallel workers.

### llm_scripts/llm_core.ps1 — LLM Backend Module
Shared module dot-sourced by every LLM-calling script and worker. Resolves the backend from `LLM_BACKEND` in `.env` (`ollama` default / `vllm` / `claude`) and exposes `Get-LLMBackend`, `Get-LLMEndpoint`, `Get-LLMModel`, and `Invoke-LocalLLM`. The vLLM path posts to `/v1/chat/completions` (OpenAI schema); the ollama path posts to `/api/chat` (with `LLM_NUM_CTX` when set). Workers receive the resolved backend/endpoint/model as `-llm*` parameters since they run in separate `Start-Job` runspaces.

## Pipeline Scripts (Deprecated Bash Equivalents — llm_Dep/)

These are legacy ports that predate the local-LLM backend (they assume the `claude` CLI only). Do not use or update them.

### llm_Dep/archgen.sh — Pass 1 (Bash)
Bash equivalent of `archgen.ps1`. Same functionality for Linux/macOS/WSL environments.

### llm_Dep/archxref.sh — Cross-Reference Index (Bash)
Bash equivalent of `archxref.ps1`. Uses `awk` for text processing.

### llm_Dep/archgraph.sh — Call Graph Diagrams (Bash)
Bash equivalent of `archgraph.ps1`.

### llm_Dep/arch_overview.sh — Architecture Overview (Bash)
Bash equivalent of `arch_overview.ps1`.

### llm_Dep/archpass2.sh — Pass 2 (Bash)
Bash equivalent of `archpass2.ps1`.

## Prompt Files (llm_prompts/)

### llm_prompts/file_doc_prompt.txt — Standard Analysis Prompt
Instructs the model to produce a structured per-file architecture doc with sections for file purpose, core responsibilities, key types, key functions (with signature, purpose, calls, and side effects), global state, external dependencies, and control flow. Language-agnostic — works for C, C++, C#, Rust, GDScript, and others. ~1000-1200 token output limit.

### llm_prompts/file_doc_prompt_lsp.txt — LSP-Enhanced Analysis Prompt
Enhanced variant of the standard prompt for use when LSP context is available. Instructs the model to use the LSP Symbol Overview authoritatively for types/functions, use Incoming References for "Called by" fields, and use Direct Include Dependencies for specific file locations. Adds "Called by (from LSP context)" field to function docs. ~1200-1500 token output limit. Auto-selected by `archgen.ps1` when `architecture/.serena_context/` exists.

### llm_prompts/file_doc_prompt_compact.txt — Compressed Analysis Prompt
Minimal token version (~150 tokens vs ~500 for standard). Same output schema in terse format, with comparable output quality. References `OUTPUT_BUDGET` appended by the worker to dynamically control response length per file. Set via `PROMPT_FILE=file_doc_prompt_compact.txt` in `.env`. Saves ~350 tokens per call — over 20K files, that's ~7M fewer input tokens.

### llm_prompts/file_doc_prompt_learn.txt — Learning-Oriented Prompt
Alternative prompt for studying engine architecture. Adds "Why This File Exists", "Key Concepts to Understand First", "Design Patterns & Idioms", "Historical Context", and "Study Questions" sections.

### llm_prompts/file_doc_prompt_minimal.txt — Minimal Schema Prompt
Pruned schema for simple files (<100 lines with <=3 symbols). Outputs only non-empty sections (Purpose, Functions, Deps), omitting Types/Globals/Control Flow when empty. ~200 token output cap. Used by the output schema pruning optimization.

### llm_prompts/file_doc_prompt_pass2.txt — Pass 2 Enrichment Prompt
Instructs the model to produce an enhanced analysis with architectural role, incoming/outgoing cross-references, design patterns & rationale, data flow, learning notes, and potential issues. ~1500 token output limit. Must not repeat Pass 1 content.

### llm_prompts/file_doc_prompt_pass2_delta.txt — Delta-Only Pass 2 Prompt
Delta-focused Pass 2 variant that emits ONLY new insights not already present in the Pass 1 doc (architectural role, cross-references, design patterns, data flow). Empty output is acceptable when Pass 1 was sufficient. ~500 token output cap.

### llm_prompts/file_doc_system_prompt.txt — Shared System Prompt (Prompt Caching)
Short fixed system prompt (~6 lines, ~500 tokens) used by both `archgen_worker.ps1` and `archpass2_worker.ps1`. Identical across all calls, enabling API-level prompt caching on the `claude` backend (cached system prompt tokens charged at ~10% of the full rate). The per-file prompt schema (compact, standard, LSP, minimal, pass2, pass2_delta) is embedded in the user message instead.

### llm_prompts/classify_prompt.txt — Classification Prompt
Used by the two-phase classification feature (`-Classify` / `CLASSIFY_FILES=1`). Ultra-cheap call that classifies each file as ANALYZE (needs full analysis) or STUB (trivial/generated, gets stub doc). Enables more accurate trivial file detection than pattern matching alone.

### llm_prompts/ue_preamble.txt — Shared Engine Knowledge Preamble
Compact list of UE conventions (UCLASS/UPROPERTY macros, FName/TArray/AActor semantics, generated/Module files, assertion macros, etc.) injected once per call so the model does not rediscover or re-explain them in every file's output.

## Configuration Files

### .env — Pipeline Configuration
Key-value configuration for the archgen pipeline. Backend selection: `LLM_BACKEND` (`ollama` default / `vllm` / `claude`), `LLM_HOST`, `LLM_PORT`, `LLM_DEFAULT_MODEL`, `LLM_THINK`, `LLM_NUM_CTX`, `LLM_TEMPERATURE`, `LLM_MAX_TOKENS`, `LLM_TIMEOUT`, `LLM_ENDPOINT`. Claude-CLI settings: `CLAUDE_MODEL`, `CLAUDE1_CONFIG_DIR`/`CLAUDE2_CONFIG_DIR`. Core settings: `JOBS`, `MAX_RETRIES`, `BUNDLE_HEADERS`, `MAX_FILE_LINES`, `PROMPT_FILE`, `PRESET`, `INCLUDE_EXT_REGEX`, `EXCLUDE_DIRS_REGEX`, `CODEBASE_DESC`. Token optimization settings: `SKIP_TRIVIAL`, `MIN_TRIVIAL_LINES`, `TIERED_MODEL`, `HIGH_COMPLEXITY_MODEL`, `BUNDLE_HEADER_DOCS`, `BATCH_TEMPLATED`, `USE_MAX_TOKENS`, `JSON_OUTPUT`, `CLASSIFY_FILES`.

### .clangd — clangd Configuration
Controls clangd behavior for the UE codebase. Disables diagnostics, suppresses warnings, skips standard library indexing, and enables background indexing. Located at repository root.

### .serena/project.yml — Serena Per-Project Configuration
Configures Serena's LSP integration: language (cpp), clangd arguments (`-j=4`, `--background-index`, `--pch-storage=disk`), ignored paths, and read-only mode.

## Documentation (llm_doc/)

### llm_doc/SerenaFinal.md — Complete Reference
Definitive 16-section reference document covering the entire multi-session effort: project goals, environment, archgen toolchain, UE 5.7.3 setup, compile_commands.json generation, Serena installation/bugs, clangd configuration, overnight indexing results, Serena verification, pipeline integration (Serena-first design), Quake 2 config, working configuration files, outstanding issues, and lessons learned.

### llm_doc/Optimizations.md — Token Optimization Guide
Single consolidated optimization document covering all 28 token optimization strategies (organized as v1-v4 sections within the one file) with implementation details, code examples, impact estimates, and prioritized order. Covers skip generated/trivial files, shared header analysis, LSP-guided source trimming, per-file targeted Pass 2 context, tiered model selection, directory-first analysis, shared directory headers, incremental overview, prompt caching, and more. Baseline ~250M tokens reduced to ~12M (95%) after v1-v3.

### llm_doc/Instructions.md — Command Reference
Complete CLI reference for every script. Covers syntax, all parameters with types and defaults, usage examples, .env variables, presets, and common workflows. Includes adaptive parallelism docs, RAM budget guide, and performance log details.

### Quickstart.md — Condensed Reference (repo root)
Condensed quick-reference: pipeline order, minimal setup, per-script options, model/backend notes, `.env` variables, presets, output layout, and resumability rules.

### llm_doc/UnitTests.md — Unit Test Reference
Coverage map and per-script test details for the toolkit's unit tests, plus how worker scripts are tested via AST extraction and what is not exercised.

### llm_doc/Analysis Map.md — Subsystem Map
Subsystems organized by layer (Foundation, Engine/Gameplay, Rendering, Physics/Audio, Networking, UI) with the `-TargetDir` path to pass to `archgen.ps1`, plus a recommended study order.

### llm_doc/Summary - 1.md — Initial Troubleshooting Summary
First session summary covering the clangd crash, emergency `.clangd` config, and initial Serena setup.

### llm_doc/Summary - 2.md — Extended Session Summary
Second session summary covering archgen toolchain, Quake 2 config, Serena integration plan, UE setup details, and overnight indexing configuration.

### llm_doc/SETUP.md — Setup & Usage Guide
Comprehensive guide covering pipeline diagram, prerequisites, LLM backend / multi-account setup, installation, `.env` configuration with token optimization variables, Serena/clangd setup, all pipeline steps with examples, prompt files, presets, full Quake 2 and Unreal Engine walkthroughs with time estimates, output directory structure, resumability, and troubleshooting.

### llm_doc/FileReference.md — This File
Index of all files in the project with descriptions.

## Output Directories

### architecture/
Contains all generated documentation: per-file `.md` docs (Pass 1), `.pass2.md` docs (Pass 2), `xref_index.md`, `architecture.md` (overview), and Mermaid diagram files.

### architecture/.serena_context/
Contains `.serena_context.txt` files produced by `serena_extract.py`. One file per source file, containing LSP symbol overviews, cross-file references, include dependencies, and LSP-trimmed source sections.

### architecture/.serena_context/.state/
LSP extraction state: `hashes.tsv` for incremental extraction (includes both successful and empty files for skip-on-rerun), `perf.log` with per-file timing breakdown (didOpen, documentSymbol, references, trimmed source, slowest reference queries), `errors.log` with timestamped entries for EMPTY, FAIL, CRASH, and RESTART events per worker.

### architecture/.dir_context/
Contains per-directory architectural overviews (`.dir.md`) produced by `archgen_dirs.ps1`. Each file provides a high-level overview of the directory's purpose and structure, used as context by `archgen.ps1` workers during Pass 1.

### architecture/.dir_headers/
Contains shared include lists per directory (`<dir>.headers.txt`) pre-computed by `archgen.ps1`. Includes appearing in 80%+ of files in a directory are extracted here. Workers load these shared headers first to reduce per-file header bundling overhead.

### architecture/.pass2_context/
Contains per-file targeted context files (`.ctx.txt`) produced by `archpass2_context.ps1`. Each file has only the relevant architecture overview paragraphs and xref entries for that specific source file.

### architecture/.archgen_state/
Pass 1 state: `hashes.tsv` (SHA1 database), `counter.json` (progress), `last_claude_error.log`, `ratelimit_resume.txt`, fatal flags.

### architecture/.pass2_state/
Pass 2 state: same structure as `.archgen_state/`.

### .cache/clangd/index/
clangd's persistent background index. 112,339 `.idx` files, 1.5 GB total. Built once (~8.5 hours for UE 5.7.3), reused across sessions.
