# Deprecated bash scripts

These `.sh` ports of the toolkit are **deprecated and unmaintained**. The toolkit
is PowerShell-first; the active scripts are the `.ps1` files at the repo root.

In particular, these bash scripts predate the **local-LLM backend** (the
`LLM_BACKEND` switch in `.env` that routes doc generation through the LLMConfig
vLLM gateway — see `../llm_core.ps1` and `../CLAUDE.md`). They still assume the
`claude` CLI only. Use the `.ps1` scripts instead.

Kept here for reference / future re-port only.
