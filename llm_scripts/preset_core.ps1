# preset_core.ps1 - single source of truth for presets and language profiles.
#
# Dot-sourced by serena_extract.ps1, archgen.ps1, archgen_dirs.ps1,
# archpass2.ps1 and run_pipeline.ps1. Replaces the two divergent Get-Preset
# copies that used to live in serena_extract.ps1 and archgen.ps1.
#
# PRESET  = codebase-level (unreal, quake, koreader, ...): file regexes,
#           codebase description, fence, preamble, and which language
#           PROFILE the codebase uses.
# PROFILE = language-level (cpp, lua, python, typescript, go): JSON files
#           in llm_profiles\ describing the LSP server, extraction and
#           doc-gen behavior for that language. Read by BOTH this
#           PowerShell layer and serena_extract.py.
#
# Preset shape (every key always present, uniform across presets):
#   Include      doc-gen file include regex        (archgen enumeration)
#   Exclude      doc-gen dir exclude regex
#   LspInclude   extraction file include regex     (serena_extract; may be
#                narrower than Include, e.g. unreal excludes .cs which
#                clangd cannot parse)
#   LspExclude   extraction dir exclude regex
#   Desc         codebase description injected into prompts
#   Fence        default code-fence language for doc output
#   Profile      language profile name ('' = resolve via .env PROFILE)
#   PreambleFile preamble template in llm_prompts\ ('' = none)

function Get-Preset($name) {
    switch ($name.ToLower()) {
        { $_ -in @('quake','quake2','quake3','doom','idtech') } {
            return @{
                Include      = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
                Exclude      = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|x64|Win32|\.vs|\.vscode|baseq2|baseq3|base)([/\\]|$)'
                LspInclude   = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
                LspExclude   = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|x64|Win32|\.vs|\.vscode|baseq2|baseq3|base)([/\\]|$)'
                Desc         = 'C game engine codebase (id Software / Quake-family)'
                Fence        = 'c'
                Profile      = 'cpp'
                PreambleFile = ''
            }
        }
        { $_ -in @('unreal','ue4','ue5') } {
            return @{
                Include      = '\.(cpp|h|hpp|cc|cxx|inl|cs)$'
                Exclude      = '[/\\](\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|ThirdParty|GeneratedFiles|AutomationTool)([/\\]|$)'
                LspInclude   = '\.(cpp|h|hpp|cc|cxx|inl)$'
                LspExclude   = '[/\\](\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|ThirdParty|GeneratedFiles|AutomationTool)([/\\]|$)'
                Desc         = 'Unreal Engine C++/C# source (Epic Games). Core, CoreUObject, Engine, Renderer, PhysicsCore/Chaos, AudioMixerCore, AIModule, GameplayAbilities (GAS), Slate/UMG, NetworkCore.'
                Fence        = 'cpp'
                Profile      = 'cpp'
                PreambleFile = 'ue_preamble.txt'
            }
        }
        'godot' {
            return @{
                Include      = '\.(cpp|h|hpp|c|cc|gd|gdscript|tscn|tres|cs)$'
                Exclude      = '[/\\](\.git|architecture|\.godot|\.import|build|export)([/\\]|$)'
                LspInclude   = '\.(cpp|h|hpp|c|cc)$'
                LspExclude   = '[/\\](\.git|architecture|\.godot|\.import|build|export)([/\\]|$)'
                Desc         = 'Godot engine codebase (C++/GDScript/C#)'
                Fence        = 'cpp'
                Profile      = 'cpp'
                PreambleFile = ''
            }
        }
        'unity' {
            return @{
                Include      = '\.(cs|shader|cginc|hlsl|compute|glsl|cpp|c|h)$'
                Exclude      = '[/\\](\.git|architecture|Library|Temp|Obj|Build|Builds|Logs|UserSettings|\.vs)([/\\]|$)'
                LspInclude   = '\.(cpp|c|h)$'
                LspExclude   = '[/\\](\.git|architecture|Library|Temp|Obj|Build|Builds|Logs|UserSettings|\.vs)([/\\]|$)'
                Desc         = 'Unity game codebase (C#/shader)'
                Fence        = 'csharp'
                Profile      = 'cpp'
                PreambleFile = ''
            }
        }
        { $_ -in @('source','valve') } {
            return @{
                Include      = '\.(cpp|h|hpp|c|cc|cxx|inl|inc|vpc|vgc)$'
                Exclude      = '[/\\](\.git|architecture|build|out|obj|bin|Debug|Release|lib|thirdparty)([/\\]|$)'
                LspInclude   = '\.(cpp|h|hpp|c|cc|cxx|inl|inc)$'
                LspExclude   = '[/\\](\.git|architecture|build|out|obj|bin|Debug|Release|lib|thirdparty)([/\\]|$)'
                Desc         = 'Source Engine codebase (Valve / C++)'
                Fence        = 'cpp'
                Profile      = 'cpp'
                PreambleFile = ''
            }
        }
        'rust' {
            return @{
                Include      = '\.(rs|toml)$'
                Exclude      = '[/\\](\.git|architecture|target|\.cargo)([/\\]|$)'
                LspInclude   = '\.(rs|toml)$'
                LspExclude   = '[/\\](\.git|architecture|target|\.cargo)([/\\]|$)'
                Desc         = 'Rust game engine codebase'
                Fence        = 'rust'
                Profile      = 'cpp'
                PreambleFile = ''
            }
        }
        'koreader' {
            return @{
                Include      = '\.lua$'
                Exclude      = '(^|[/\\])(\.git|architecture|base|spec|platform|l10n|resources|node_modules)([/\\]|$)'
                LspInclude   = '\.lua$'
                LspExclude   = '(^|[/\\])(\.git|architecture|base|spec|platform|l10n|resources|node_modules)([/\\]|$)'
                Desc         = 'KOReader e-reader application (Lua frontend + plugins on a LuaJIT/SDL runtime; event-driven UI via UIManager)'
                Fence        = 'lua'
                Profile      = 'lua'
                PreambleFile = ''
            }
        }
        'lua' {
            return @{
                Include      = '\.lua$'
                Exclude      = '(^|[/\\])(\.git|architecture|node_modules|build|dist|out)([/\\]|$)'
                LspInclude   = '\.lua$'
                LspExclude   = '(^|[/\\])(\.git|architecture|node_modules|build|dist|out)([/\\]|$)'
                Desc         = 'Lua application codebase'
                Fence        = 'lua'
                Profile      = 'lua'
                PreambleFile = ''
            }
        }
        'python' {
            return @{
                Include      = '\.py$'
                Exclude      = '(^|[/\\])(\.git|architecture|__pycache__|\.venv|venv|node_modules|build|dist|\.mypy_cache|\.pytest_cache)([/\\]|$)'
                LspInclude   = '\.py$'
                LspExclude   = '(^|[/\\])(\.git|architecture|__pycache__|\.venv|venv|node_modules|build|dist|\.mypy_cache|\.pytest_cache)([/\\]|$)'
                Desc         = 'Python codebase'
                Fence        = 'python'
                Profile      = 'python'
                PreambleFile = ''
            }
        }
        { $_ -in @('typescript','ts') } {
            return @{
                Include      = '\.(ts|tsx|js|jsx|mts|cts)$'
                Exclude      = '(^|[/\\])(\.git|architecture|node_modules|dist|build|out|coverage)([/\\]|$)'
                LspInclude   = '\.(ts|tsx|js|jsx|mts|cts)$'
                LspExclude   = '(^|[/\\])(\.git|architecture|node_modules|dist|build|out|coverage)([/\\]|$)'
                Desc         = 'TypeScript/JavaScript codebase'
                Fence        = 'typescript'
                Profile      = 'typescript'
                PreambleFile = ''
            }
        }
        'go' {
            return @{
                Include      = '\.go$'
                Exclude      = '(^|[/\\])(\.git|architecture|vendor|testdata|node_modules)([/\\]|$)'
                LspInclude   = '\.go$'
                LspExclude   = '(^|[/\\])(\.git|architecture|vendor|testdata|node_modules)([/\\]|$)'
                Desc         = 'Go codebase'
                Fence        = 'go'
                Profile      = 'go'
                PreambleFile = ''
            }
        }
        '' {
            return @{
                Include      = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc|cs|java|py|rs|lua|gd|gdscript|m|mm|swift)$'
                Exclude      = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|\.vs|\.vscode|node_modules|\.godot|Library|Temp)([/\\]|$)'
                LspInclude   = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
                LspExclude   = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|\.vs)([/\\]|$)'
                Desc         = 'game engine / game codebase'
                Fence        = 'c'
                Profile      = ''
                PreambleFile = ''
            }
        }
        default {
            Write-Host "Unknown preset: $name. Available: quake, doom, unreal, godot, unity, source, rust, koreader, lua, python, typescript, go" -ForegroundColor Red
            exit 2
        }
    }
}

# Load a language profile JSON from llm_profiles\. Returns a PSCustomObject
# (PowerShell 5.1: property access only; wrap array fields in @() before
# using .Count).
function Get-LangProfile([string]$name, [string]$profilesDir = '') {
    if ($name -eq '') { $name = 'cpp' }
    if ($profilesDir -eq '') {
        $profilesDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'llm_profiles'
    }
    $path = Join-Path $profilesDir ($name.ToLower() + '.json')
    if (-not (Test-Path $path)) {
        $avail = ''
        if (Test-Path $profilesDir) {
            $avail = (@(Get-ChildItem -Path $profilesDir -Filter '*.json' | ForEach-Object { $_.BaseName }) -join ', ')
        }
        Write-Host "Unknown language profile: $name (available: $avail)" -ForegroundColor Red
        exit 2
    }
    return (Get-Content -Raw -Path $path | ConvertFrom-Json)
}

# Profile name precedence: explicit preset's Profile > .env PROFILE > cpp.
function Resolve-ProfileName($presetData, [string]$envProfile) {
    if ($null -ne $presetData -and "$($presetData.Profile)" -ne '') {
        return $presetData.Profile
    }
    if ($envProfile -ne '') { return $envProfile }
    return 'cpp'
}
