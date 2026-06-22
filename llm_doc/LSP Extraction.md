> Can i run serena_extract.ps1 on the whole codebase before running the rest of the project on targeted subsystems?

● Yes, absolutely. The LSP extraction is independent of everything else and the output is reusable across any scope.

  # Extract LSP context for the entire codebase (free, clangd only, ~2-4 hours)
  .\llm_scripts\serena_extract.ps1 -Preset unreal

  # Then later, run targeted subsystems — they'll pick up the existing context
  .\llm_scripts\archgen.ps1 -TargetDir Engine\Source\Runtime\Core -Preset unreal -Jobs 8
  .\llm_scripts\archgen.ps1 -TargetDir Engine\Source\Runtime\Renderer -Preset unreal -Jobs 8
  # etc.

  This works because:

  1. llm_scripts\serena_extract.ps1 writes to architecture/.serena_context/ using the full relative path (e.g.,
  Engine/Source/Runtime/Core/Private/Math/UnrealMath.cpp.serena_context.txt)
  2. llm_scripts\archgen.ps1 checks for matching .serena_context.txt files per-file, not per-run
  3. The context files are incremental — if you later run extraction on a different subdirectory, existing files aren't
  touched

  So you build the full LSP context once, then draw from it as you work through subsystems at your own pace. The
  extraction (Step 0 / serena_extract) is the cheapest step — it costs zero LLM tokens because it talks directly to
  clangd, not the LLM backend (the downstream archgen / arch_overview / archpass2 stages do call the configured
  LLM_BACKEND, default local Ollama qwen3.6:27B). Having extraction done upfront means every subsequent
  llm_scripts\archgen.ps1 run gets the best possible input from the start.
