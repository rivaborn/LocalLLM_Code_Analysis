# LocalLLM Code Analysis

A PowerShell + clangd toolkit that generates per-file and subsystem-level **architecture
documentation** for large C++ codebases. It drives an LLM backend — a local model via the
[LLMConfig](https://github.com/rivaborn/LLMConfig) vLLM/Ollama gateway, or the `claude` CLI — over
an incremental, resumable pipeline, with LSP-powered semantic context from clangd.

Originally built against the Unreal Engine 5.x source tree (the bundled prompts/preset target UE),
but the pipeline is codebase-agnostic via presets.

## Pipeline

```
0.  serena_extract.ps1       LSP symbol + trimmed-source extraction (free; direct clangd)
0b. archgen_dirs.ps1         per-directory overviews
1.  archgen.ps1              per-file docs (Pass 1)
2.  archxref.ps1             cross-reference index (free)
3.  archgraph.ps1            Mermaid call graphs (free)
4.  arch_overview.ps1        subsystem synthesis (incremental)
4b. archpass2_context.ps1    targeted Pass 2 context (free)
5.  archpass2.ps1            selective re-analysis (Pass 2)
```

All scripts are **incremental**: Ctrl+C and re-run resumes (completed files skipped via SHA1 hash).
Output lands under `architecture/`.

## Quick start

```powershell
# 1. Configure
copy .env.example .env        # then fill in CLAUDE1/2_CONFIG_DIR (only needed for the claude backend)

# 2. Run from the root of the codebase you want to analyze
.\llm_scripts\serena_extract.ps1 -Preset unreal -Workers 2 -Jobs 2
.\llm_scripts\archgen.ps1        -Preset unreal -Jobs 8
.\llm_scripts\archxref.ps1
.\llm_scripts\archgraph.ps1
.\llm_scripts\arch_overview.ps1
.\llm_scripts\archpass2.ps1 -Jobs 8 -Top 500
```

Scope any script to a subtree with `-TargetDir <path>`.

## LLM backend

`LLM_BACKEND` in `.env` selects the backend for every doc-generation call:

- **`ollama`** (default) — raw Ollama server (`http://<LLM_HOST>:11434`), serving `qwen3.6:27B` (a thinking model; reasoning is kept out of the doc via the native `/api/chat` path + `LLM_THINK=true`).
- **`vllm`** — LLMConfig OpenAI `/v1` gateway (`http://<LLM_HOST>:11430`); auto-loads the model, fast. Use a non-thinking served-name like `qwen3-coder-30b`.
- **`claude`** — the `claude` CLI (haiku/sonnet via the `CLAUDE_*` keys); the only backend needing `CLAUDE*_CONFIG_DIR`.

On the local backends, files that hit the degrade path are escalated once to a named claude model when `DEGRADE_FALLBACK_MODEL` is set (empty = disabled).

See `llm_scripts/llm_core.ps1` for the implementation and `.env.example` for all keys.

## Documentation

- `CLAUDE.md` — toolkit guide (pipeline, config, known issues)
- `llm_scripts/` — the pipeline scripts (`.ps1` + `serena_extract.py`)
- `llm_prompts/` — LLM prompt templates (`file_doc_prompt_*.txt`, system prompt, classify, preamble)
- `Quickstart.md` — condensed reference (repo root)
- `llm_doc/Instructions.md` — per-script CLI reference
- `llm_doc/SETUP.md` — full setup guide
- `llm_doc/SerenaFinal.md` — LSP-extraction technical reference
- `llm_doc/Optimizations.md` — token-optimization strategies
- `llm_doc/FileReference.md` — index of every file
- `llm_Dep/` — deprecated bash ports (unmaintained; PowerShell is the supported path)
