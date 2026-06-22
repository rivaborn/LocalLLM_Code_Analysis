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
.\serena_extract.ps1 -Preset unreal -Workers 2 -Jobs 2
.\archgen.ps1        -Preset unreal -Jobs 8
.\archxref.ps1
.\archgraph.ps1
.\arch_overview.ps1
.\archpass2.ps1      -Preset unreal -Jobs 8 -Top 500
```

Scope any script to a subtree with `-TargetDir <path>`.

## LLM backend

`LLM_BACKEND` in `.env` selects the backend for every doc-generation call:

- **`vllm`** (default) — LLMConfig OpenAI `/v1` gateway (`http://<LLM_HOST>:11430`); auto-loads the model.
- **`ollama`** — raw Ollama server (`http://<LLM_HOST>:11434`).
- **`claude`** — the `claude` CLI (haiku/sonnet via the `CLAUDE_*` keys); the only backend needing `CLAUDE*_CONFIG_DIR`.

See `llm_core.ps1` for the implementation and `.env.example` for all keys.

## Documentation

- `CLAUDE.md` — toolkit guide (pipeline, config, known issues)
- `prompts/` — LLM prompt templates (`file_doc_prompt_*.txt`, system prompt, classify, preamble)
- `docs/Quickstart.md` — condensed reference
- `docs/Instructions.md` — per-script CLI reference
- `docs/SETUP.md` — full setup guide
- `docs/SerenaFinal.md` — LSP-extraction technical reference
- `docs/Optimizations.md` — token-optimization strategies
- `docs/FileReference.md` — index of every file
- `Dep/` — deprecated bash ports (unmaintained; PowerShell is the supported path)
