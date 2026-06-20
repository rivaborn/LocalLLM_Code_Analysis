# Architecture Analysis Toolkit — File Reference

## Pipeline Scripts (PowerShell)

### serena_extract.ps1 — LSP Context Extraction (Step 0)
PowerShell wrapper that orchestrates adaptive parallel LSP extraction via clangd. Reads `.env` for preset/include/exclude patterns, verifies prerequisites (compile_commands.json, clangd index), and invokes `serena_extract.py` via `uv run --python 3.12`. Zero Claude API calls — all extraction is local clangd queries. Supports `-Preset`, `-TargetDir`, `-Jobs`, `-Workers`, `-Force`, `-SkipRefs`, `-Compress`, `-MinFreeRAM`, `-RAMPerWorker` flags. Auto-scales worker count based on available system RAM. The `-Compress` flag collapses classes to "ClassName (Class, N methods)" and keeps only top-10 functions.

### serena_extract.py — Adaptive Parallel LSP Client (Python)
Standalone Python script that spawns multiple clangd processes and communicates via LSP JSON-RPC over stdio. Workers pull files from a shared queue — whoever finishes first grabs the next file. RAM is monitored every ~60 seconds: scales up when >10 GB free, scales down when <4 GB free. For each source file: opens the file, extracts the symbol tree (`documentSymbol`), optionally queries cross-file references, generates LSP-trimmed source for large files, and writes a `.serena_context.txt` file. Each clangd instance restarts every 1000 files to reclaim memory. Auto-detects clangd crashes (broken pipe / Errno 22) and restarts the process with a single retry per file. Empty files (no symbols) are recorded in the hash DB so they're skipped on rerun; failed files are not, so they retry automatically. Writes per-file performance log and error log with timing breakdown. Uses SHA1 hashing for incremental support. ETA is calculated from successfully completed files only (empty/failed files excluded). Supports `--compress` mode: collapses classes to "ClassName (Class, N methods)" and keeps only top-10 functions. **PCH cleanup**: clangd's `--pch-storage=disk` writes `preamble-*.pch` files to the system temp directory (averaging ~80 MB each for UE files). The script snapshots existing PCH files at startup and automatically cleans up session-created PCH files on worker shutdown and via `atexit`, preventing unbounded disk usage (observed: 50+ GB without cleanup).

### archgen_dirs.ps1 — Directory-Level Overview Generator (Step 0b)
Generates per-directory architectural overviews before Pass 1. Scans source directories, produces a `.dir.md` overview for each using Claude (sonnet via tiered model). Output: `architecture/.dir_context/<dir>.dir.md`. These directory overviews are automatically loaded by `archgen.ps1` workers to provide architectural context for each file. Run between `serena_extract.ps1` and `archgen.ps1` in the pipeline.

### archgen.ps1 — Pass 1: Per-File Documentation (Step 1)
Main workhorse. Walks every source file, bundles local `#include` headers for context, sends each to Claude CLI, and generates a structured `.md` doc per file. Default model is `CLAUDE_MODEL` from `.env` (haiku). With `TIERED_MODEL=1` (the default), high-complexity files auto-upgrade to `HIGH_COMPLEXITY_MODEL` (sonnet). Runs in parallel (`-Jobs N`), tracks progress via hash DB line counting (append-only, no contention) with `[Console]::Write()` for single-line updates and ETA in h:m:s format, retries on transient failures, and maintains a SHA1 hash database for resumability. Supports `-Preset` for common engines. Auto-detects `architecture/.serena_context/` and injects LSP context into each file's Claude call when available. Auto-selects `file_doc_prompt_lsp.txt` when LSP context is present. Pre-computes shared directory headers (80%+ threshold) into `architecture/.dir_headers/<dir>.headers.txt`; workers load these first. Loads directory-level overviews from `architecture/.dir_context/` when available. Built-in token optimizations: skips generated/trivial files (`SKIP_TRIVIAL`), adaptive output budget per file, tiered model selection (`TIERED_MODEL`), header doc bundling (`BUNDLE_HEADER_DOCS`), batch templated files (`BATCH_TEMPLATED`), and LSP-guided source trimming for large files. New opt-in flags: `-MaxTokens` (maps adaptive budget to `--max-tokens`), `-JsonOutput` (switches to JSON output format), `-Classify` (two-phase haiku classification as ANALYZE or STUB). Corresponding `.env` variables: `USE_MAX_TOKENS`, `JSON_OUTPUT`, `CLASSIFY_FILES`.

### archgen_worker.ps1 — Pass 1 Worker
Per-file worker dispatched by `archgen.ps1` via `Start-Job`. Builds the Claude payload (source + headers + LSP context + output budget), calls Claude CLI, handles rate limits, and writes output. Fixed bug: PowerShell 5.1 `if/else` expression unwraps single-element arrays to scalars, so `$relList[0]` indexed the first character of the path string instead of returning the whole path - fixed by wrapping the entire `if/else` in `@()`. Uses `file_doc_system_prompt.txt` as a fixed system prompt across all calls to enable API-level prompt caching; the per-file prompt schema is embedded in the user message. Three-stage fallback for "prompt too long": stage 0 (full + headers + LSP), stage 1 (full + LSP, no headers), stage 2 (truncated, no headers, no LSP). Uses LSP-trimmed source for large files when available (from `.serena_context.txt`). Bundles header docs instead of raw source when `BUNDLE_HEADER_DOCS=1`. Appends adaptive output budget instruction to payload.

### archxref.ps1 — Cross-Reference Index (Step 2)
Parses all Pass 1 docs and builds a cross-reference index: function-to-file mappings, call graph edges, global state ownership, header dependency counts, and subsystem interfaces. Pure text processing — no Claude calls, completes in seconds.

### archgraph.ps1 — Call Graph & Dependency Diagrams (Step 3)
Extracts function call edges from Pass 1 docs and generates Mermaid diagrams: function-level call graphs grouped by subsystem, and subsystem dependency diagrams with cross-boundary call counts. No Claude calls. Configurable via `-MaxCallEdges` and `-MinCallSignificance`.

### arch_overview.ps1 — Architecture Overview (Step 4)
Synthesizes all Pass 1 docs into a subsystem-level architecture overview. Auto-chunks by directory for large codebases. Recursively splits oversized subsystems. Single-child directories are now descended through instead of stopping the chunked split, so paths like `Engine/Source/Runtime/Engine/Private` properly split into subdirectories (Animation, Audio, PhysicsEngine, etc.). When `TIERED_MODEL=1` (the default), auto-upgrades to `HIGH_COMPLEXITY_MODEL` (sonnet); set `TIERED_MODEL=0` to keep it on `CLAUDE_MODEL`. Benefits from higher-quality Pass 1 docs when LSP context was injected. Incremental by default: tracks subsystem doc hashes in `overview_hashes.tsv` — unchanged subsystems skip on re-run. Use `-Full` flag to force full regeneration.

### archpass2_context.ps1 — Targeted Pass 2 Context (Step 4b)
Builds per-file targeted context extracts for Pass 2. For each source file with a Pass 1 doc, extracts only the relevant architecture overview paragraphs and xref index entries (by subsystem matching and filename grep). Produces small `.ctx.txt` files (~30-80 lines) instead of the full 500-line global context blobs. Zero Claude calls — pure text processing, runs in seconds. The Pass 2 worker auto-detects these files.

### archpass2.ps1 — Pass 2: Selective Re-Analysis (Step 5)
Re-analyzes source files with architecture overview + xref index + Pass 1 doc as context. Default model is `CLAUDE_MODEL` from `.env` (haiku). With `TIERED_MODEL=1` (the default), high-complexity files auto-upgrade to `HIGH_COMPLEXITY_MODEL` (sonnet), matching the same tiered behavior as `archgen.ps1`. Supports `-Top N` for selective processing: scores files by incoming reference count and file size, discounts files that already had LSP context in Pass 1. `-ScoreOnly` flag previews scores without running. Supports `-Only file1,file2,...` for manual targeting.

### archpass2_worker.ps1 — Pass 2 Worker
Per-file worker dispatched by `archpass2.ps1`. Uses `file_doc_system_prompt.txt` as a fixed system prompt across all calls to enable API-level prompt caching; the per-file prompt schema is embedded in the user message. Auto-detects targeted context files (`.pass2_context/<path>.ctx.txt`) and uses them instead of global truncated blobs when available. Four-stage fallback: stage 0 (source + pass1 + targeted or global context), stage 1 (drop xref/targeted context), stage 2 (drop arch context, truncate harder), stage 3 (source only). Handles rate limits with shared pause file coordination across parallel workers.

## Pipeline Scripts (Bash Equivalents)

### archgen.sh — Pass 1 (Bash)
Bash equivalent of `archgen.ps1`. Same functionality for Linux/macOS/WSL environments.

### archxref.sh — Cross-Reference Index (Bash)
Bash equivalent of `archxref.ps1`. Uses `awk` for text processing.

### archgraph.sh — Call Graph Diagrams (Bash)
Bash equivalent of `archgraph.ps1`.

### arch_overview.sh — Architecture Overview (Bash)
Bash equivalent of `arch_overview.ps1`.

### archpass2.sh — Pass 2 (Bash)
Bash equivalent of `archpass2.ps1`.

## Prompt Files

### file_doc_prompt.txt — Standard Analysis Prompt
Instructs Claude to produce a structured per-file architecture doc with sections for file purpose, core responsibilities, key types, key functions (with signature, purpose, calls, and side effects), global state, external dependencies, and control flow. Language-agnostic — works for C, C++, C#, Rust, GDScript, and others. ~1000-1200 token output limit.

### file_doc_prompt_lsp.txt — LSP-Enhanced Analysis Prompt
Enhanced variant of the standard prompt for use when LSP context is available. Instructs Claude to use the LSP Symbol Overview authoritatively for types/functions, use Incoming References for "Called by" fields, and use Direct Include Dependencies for specific file locations. Adds "Called by (from LSP context)" field to function docs. ~1200-1500 token output limit. Auto-selected by `archgen.ps1` when `architecture/.serena_context/` exists.

### file_doc_prompt_compact.txt — Compressed Analysis Prompt
Minimal token version (~150 tokens vs ~500 for standard). Same output schema in terse format. Claude produces identical quality output. References `OUTPUT_BUDGET` appended by the worker to dynamically control response length per file. Set via `PROMPT_FILE=file_doc_prompt_compact.txt` in `.env`. Saves ~350 tokens per call — over 20K files, that's ~7M fewer input tokens.

### file_doc_prompt_learn.txt — Learning-Oriented Prompt
Alternative prompt for studying engine architecture. Adds "Why This File Exists", "Key Concepts to Understand First", "Design Patterns & Idioms", "Historical Context", and "Study Questions" sections.

### file_doc_prompt_pass2.txt — Pass 2 Enrichment Prompt
Instructs Claude to produce an enhanced analysis with architectural role, incoming/outgoing cross-references, design patterns & rationale, data flow, learning notes, and potential issues. ~1500 token output limit. Must not repeat Pass 1 content.

### file_doc_system_prompt.txt — Shared System Prompt (Prompt Caching)
Short fixed system prompt (~6 lines, ~500 tokens) used by both `archgen_worker.ps1` and `archpass2_worker.ps1`. Identical across all Claude calls, enabling API-level prompt caching. Cached system prompt tokens are charged at ~10% of the full rate. Over 20K calls, this saves ~9M tokens worth of cost. The per-file prompt schema (compact, standard, LSP, minimal, pass2, pass2_delta) is embedded in the user message instead.

### classify_prompt.txt — Classification Prompt
Used by the two-phase classification feature (`-Classify` / `CLASSIFY_FILES=1`). Ultra-cheap haiku call that classifies each file as ANALYZE (needs full analysis) or STUB (trivial/generated, gets stub doc). Enables more accurate trivial file detection than pattern matching alone.

## Configuration Files

### .env — Pipeline Configuration
Key-value configuration for the archgen pipeline. Core settings: `CLAUDE_MODEL`, `JOBS`, `MAX_RETRIES`, `BUNDLE_HEADERS`, `MAX_FILE_LINES`, `PROMPT_FILE`, `CLAUDE1_CONFIG_DIR`/`CLAUDE2_CONFIG_DIR`, `PRESET`, `INCLUDE_EXT_REGEX`, `EXCLUDE_DIRS_REGEX`, `CODEBASE_DESC`. Token optimization settings: `SKIP_TRIVIAL`, `MIN_TRIVIAL_LINES`, `TIERED_MODEL`, `HIGH_COMPLEXITY_MODEL`, `BUNDLE_HEADER_DOCS`, `BATCH_TEMPLATED`, `USE_MAX_TOKENS`, `JSON_OUTPUT`, `CLASSIFY_FILES`.

### .clangd — clangd Configuration
Controls clangd behavior for the UE codebase. Disables diagnostics, suppresses warnings, skips standard library indexing, and enables background indexing. Located at repository root.

### .serena/project.yml — Serena Per-Project Configuration
Configures Serena's LSP integration: language (cpp), clangd arguments (`-j=4`, `--background-index`, `--pch-storage=disk`), ignored paths, and read-only mode.

## Documentation

### SerenaFinal.md — Complete Reference
Definitive 16-section reference document covering the entire multi-session effort: project goals, environment, archgen toolchain, UE 5.7.3 setup, compile_commands.json generation, Serena installation/bugs, clangd configuration, overnight indexing results, Serena verification, pipeline integration (Serena-first design), Quake 2 config, working configuration files, outstanding issues, and lessons learned.

### Optimization.md — Token Optimization Guide
Documents 8 token optimization strategies with implementation details, code examples, impact estimates, and prioritized implementation order. Covers: skip generated/trivial files, shared header analysis, LSP-guided source trimming, per-file targeted Pass 2 context, tiered model selection, batch templated files, compressed prompt format, and adaptive output budget. Estimated combined impact: ~72% token reduction.

### Optimizations v3.md — v3 Optimization Documentation
Documents the v3 optimization changes: directory-level overviews (`archgen_dirs.ps1`), shared directory headers, incremental overview, hard output cap (`-MaxTokens`), LSP compression (`-Compress`), JSON output (`-JsonOutput`), and two-phase classification (`-Classify`).

### Instructions.md — Command Reference
Complete CLI reference for every script. Covers syntax, all parameters with types and defaults, usage examples, .env variables, presets, and common workflows. Includes adaptive parallelism docs, RAM budget guide, and performance log details.

### Summary - 1.md — Initial Troubleshooting Summary
First session summary covering the clangd crash, emergency `.clangd` config, and initial Serena setup.

### Summary - 2.md — Extended Session Summary
Second session summary covering archgen toolchain, Quake 2 config, Serena integration plan, UE setup details, and overnight indexing configuration.

### SETUP.md — Setup & Usage Guide
Comprehensive guide covering pipeline diagram, prerequisites, Claude CLI multi-account setup, installation, `.env` configuration with token optimization variables, Serena/clangd setup, all pipeline steps with examples, prompt files, presets, full Quake 2 and Unreal Engine walkthroughs with time estimates, output directory structure, resumability, and troubleshooting.

### FileReference.md — This File
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
