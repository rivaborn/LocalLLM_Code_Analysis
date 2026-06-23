# Model & Prompt Comparison — RHI/Public Benchmark

**Date:** 2026-06-23
**Subject:** `Engine/Source/Runtime/RHI/Public` (64 source files; 63 with LSP/serena context)
**Goal:** validate the backend-aware prompt minimization (local LLMs get a lean prompt; the
`claude` path keeps every optimization) and compare backends on the user's stated criteria —
**accuracy and cost** (speed explicitly not a factor).

## TL;DR

- The prompt minimization **restored full coverage** on the local model: `qwen3.6:27B` went from
  **24 → 64 docs** on RHI/Public, reaching exact parity with `claude` haiku and `qwen3-coder-30b`.
- **Accuracy did not regress.** On the one file checked against ground truth, the minimized local
  run had the *best* entity coverage of the three.
- **Cost:** the local backends (`ollama` / `vllm`) are $0 marginal (homelab GPU); `claude` haiku is
  paid API. Given coverage + accuracy parity, the local path wins on accuracy-per-dollar.
- **Zero chain-of-thought leakage** in any local doc (ollama think-separation held).

## What changed (the thing under test)

Historically the toolkit's token optimizations (bundled `#include` headers, engine preamble,
directory context, file batching) were built for the **online `claude`** backend, where large
prompts improve results and are cheap to cache. On **local LLM servers** those same additions are
harmful: big multi-header prompts drove `qwen3.6:27B` to **empty output** on the larger RHI headers.

Prompt construction is now **backend-aware** (gated by `if ($llmBackend -ne 'claude')`):

| Prompt component                  | `claude` (online) | local (ollama / vllm) |
| --------------------------------- | ----------------- | --------------------- |
| engine preamble (`ue_preamble`)   | ON                | **off**               |
| bundled `#include` headers        | ON                | **off**               |
| shared dir headers                | ON                | **off**               |
| file / templated batching         | ON                | **off**               |
| directory context (`.dir_context`)| ON                | **off**               |
| schema template                   | LSP / standard    | **compact**           |
| Pass-2 arch + xref context        | ON                | **off**               |
| overview chunk threshold          | 1500              | **800**               |
| LSP / serena context              | ON                | **ON (kept)**         |
| file source (truncated)           | ON                | **ON (kept)**         |

So the local Pass-1 payload is exactly: **compact schema + file path + LSP context + source +
output budget.** Nothing else.

### Verified lean prompt

Captured literal payload for `Android/AndroidDynamicRHI.h` (3,685 chars / 107 lines) via the
`ARCHGEN_DUMP_PROMPT` hook:

```
[OUTPUT SCHEMA]        compact template (file_doc_prompt_compact.txt)
[FILE PATH]            Engine/Source/Runtime/RHI/Public/Android/AndroidDynamicRHI.h
[LSP ANALYSIS CONTEXT] symbol overview + "Direct Include Dependencies: RHI.h, AndroidWindow.h"
[FILE CONTENT]         the actual source
[OUTPUT BUDGET]        ~200 tokens
```

Section-marker audit confirmed the online-only blocks are **absent**: no `ENGINE CONVENTIONS:`
(preamble), no `DIRECTORY CONTEXT:`, no `BUNDLED HEADERS (included for context):`.

The key win is visible in this file: the source `#include "RHI.h"` (a massive header) is the exact
thing that, when *inlined* as a bundled-headers block, drove the model to empty output. In the lean
prompt `RHI.h` appears only **by name** in the LSP "Direct Include Dependencies" list — the
prompt-killer is gone.

## Configurations compared

| Set          | Backend / model            | Prompt config         |
| ------------ | -------------------------- | --------------------- |
| qwen36 (old) | ollama / qwen3.6:27B (32k) | header-heavy (pre-fix)|
| qwen36_min   | ollama / qwen3.6:27B (32k) | minimized (this fix)  |
| haiku        | claude / haiku             | full online opts      |
| coder30      | vllm / qwen3-coder-30b     | headers off (interim) |

> **Provenance caveat.** The cleanest *controlled* comparison is **qwen36 (old) vs qwen36_min** —
> same model, same files, isolating only the prompt change. The `haiku` and `coder30` sets were
> generated earlier in the session as backend A/B data points and serve as quality references;
> their prompt configs differ (haiku used the full online optimizations; coder30 had headers gated
> off but predates the preamble/dir-context trims). Coverage numbers below are all measured fresh.

## Results

### Coverage (measured 2026-06-23)

| Set          | docs | real | stubs | avg bytes | CoT leak |
| ------------ | ---- | ---- | ----- | --------- | -------- |
| qwen36 (old) | 24   | 19   | 5     | 1778      | 0        |
| qwen36_min   | 64   | 59   | 5     | 3899      | 0        |
| haiku        | 64   | 59   | 5     | 3538      | 0        |
| coder30      | 64   | 59   | 5     | 5314      | 0        |

Notes:
- **"stubs" are not failures.** They are the 5 trivial files the toolkit skips via `SKIP_TRIVIAL`
  (e.g. `*DataDrivenShaderPlatformInfo.inl`, `RHIMemoryLayout.h`, `RHIUnitTests.h`,
  `TextureProfiler.h`) — auto-stubbed without an LLM call, identical across every set.
- So of the **59 LLM-eligible files**, haiku, coder30, and qwen36_min each produced **59/59**. The
  old header-heavy qwen36 produced only **19/59** — the rest returned empty output under the large
  bundled-header prompts. That 19 → 59 jump is the whole point of the minimization.

### Output size on representative files (bytes)

| File                  | haiku | coder30 | qwen36_min |
| --------------------- | ----- | ------- | ---------- |
| RHIDefinitions.h      | 6392  | 9517    | 4648 *     |
| AndroidDynamicRHI.h   | 2771  | 3172    | 2173       |
| RHIResources.h        | 8636  | 5093    | 6805       |
| DynamicRHI.h          | 6829  | 8622    | 6059       |
| RHIFwd.h              | 2620  | 7666    | 2482       |

`*` `RHIDefinitions.h` degraded for qwen36_min (see "Degrade case"). Elsewhere qwen36_min tracks
haiku/coder30 closely and even beats coder30 on `RHIResources.h`.

### Accuracy — `AndroidDynamicRHI.h` entity scorecard

Scored against the known source (2 callback typedefs + their get/set pairs, `FPSOServicePriInfo`
with ctor + `GetPriorityInfo`, `GetPSOServiceFailureThreshold`, and the `FPlatformDynamicRHI`
namespace alias):

| Entity in source                          | qwen36_min | haiku | coder30 |
| ----------------------------------------- | ---------- | ----- | ------- |
| Both callback typedefs                    | yes        | yes   | yes     |
| FPSOServicePriInfo ctor + GetPriorityInfo | yes        | yes   | no      |
| GetPSOServiceFailureThreshold             | yes        | no    | yes     |
| EPSOPrecacheCompileType alias             | yes        | no    | no      |
| FPlatformDynamicRHI namespace alias       | yes        | no    | no      |

Additional notes:
- `PriInfo` classification: qwen36_min and coder30 correctly reported "None" for Globals
  (`PriInfo` is a private class member); haiku listed it as a global (questionable).
- Dependency completeness: qwen36_min had the fullest `Deps` (it alone caught `TUniqueFunction`
  and `TOptional`).
- Style: coder30 is the most verbose (one block per function); qwen36_min is the most concise
  while still complete (it groups the four callback get/set functions); haiku is in between.

**On this file the leanest-prompt local run had the best entity coverage** — minimization did not
cost accuracy.

## Chain-of-thought leakage

`qwen3.6:27B` is a thinking model. On the `ollama` backend with `LLM_THINK=true` and the native
`/api/chat` path, reasoning is routed to a separate `message.thinking` field and kept out of the
doc. A scan for CoT markers (`<think>`, "Okay,", "Let me analyze", "I need to…", etc.) found
**0 leaks** across all 59 qwen36_min docs. (This is why the toolkit uses the ollama backend for
thinking models rather than the vLLM gateway, which has no reasoning parser and would leak CoT.)

## Degrade case

`RHIDefinitions.h` (one of the largest RHI headers) hit the thinking-model budget:
`thinking=4 chars, num_predict=8000` — the model spun in reasoning and emitted almost no thinking
content before exhausting the token budget. The worker's fallback ladder caught it (advance stage →
truncate content) and still produced an **accurate 4.6 KB doc** with correct types and purpose.
`fail=0` for the whole run.

If this becomes frequent on big files, the levers are: raise `LLM_THINK_MIN_TOKENS` / `num_predict`,
or run big files against a higher-context tag (`qwen3.6:27b-96k`). Not necessary at current volume.

## Cost

| Backend / model            | Marginal API cost | Notes                                        |
| -------------------------- | ----------------- | -------------------------------------------- |
| ollama / qwen3.6:27B       | $0 (homelab GPU)  | thinking pass every call; `Jobs` forced to 1 |
| vllm / qwen3-coder-30b     | $0 (homelab GPU)  | non-thinking; fast (~1s/call)                |
| claude / haiku             | paid per token    | fastest wall-clock; polished prose           |

Wall-clock for reference (speed was explicitly not a criterion): qwen36_min ran 59 files in
**~1h46m** (sequential — ollama forces `Jobs=1` so parallel requests don't split `num_ctx`).

## Conclusion / recommendation

For **accuracy + cost** with speed not a concern, **`qwen3.6:27B` (32k) with the minimized prompt**
is the best value: free, coverage-equal to haiku, at least as accurate on the sample, and clean
(no CoT). `qwen3-coder-30b` (vllm) is also free and more verbose per-function but missed some
entities here. `claude` haiku remains the fastest and produces polished prose, at API cost, and is
still a first-class backend — the minimization leaves its path byte-for-byte unchanged.

## Reproducing

The prompt-capture hook (committed; env-gated, no-op when unset):

```powershell
# Dump the literal assembled prompt for every file to a directory:
$env:ARCHGEN_DUMP_PROMPT = "C:\path\to\dump"
.\llm_scripts\archgen.ps1 -Preset unreal -Jobs 1 -TargetDir Engine/Source/Runtime/RHI/Public
$env:ARCHGEN_DUMP_PROMPT = $null   # disable
```

A run on a backend is selected entirely by `.env` (`LLM_BACKEND`, `LLM_DEFAULT_MODEL`,
`LLM_NUM_CTX`). Before an `ollama` run, load the model once via the gateway so Ollama owns the GPU:

```powershell
$body = @{ server='ollama'; model='qwen3.6:27B'; lane='primary' } | ConvertTo-Json
Invoke-RestMethod 'http://192.168.1.40:11430/api/load' -Method Post -ContentType 'application/json' -Body $body
```

A/B doc sets from this benchmark are kept under `ab_rhi/` (`qwen36_min`, `haiku`, `coder30`, and
the pre-fix `qwen36`) for before/after inspection.

## Related

- [[Optimizations.md]] — the full optimization catalogue; prompt-bloating opts are tagged online-only.
- `CLAUDE.md` → "Prompt policy" — the one-paragraph statement of online-keeps-all / local-minimized.
