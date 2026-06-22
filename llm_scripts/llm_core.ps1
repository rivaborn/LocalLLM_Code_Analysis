# ============================================================
# llm_core.ps1 -- opt-in local-LLM backend for the arch toolkit
#
# Routes LLM calls through the homelab LLMConfig gateway (vLLM OpenAI /v1)
# or a raw Ollama server, as an alternative to the `claude` CLI. Selected via
# the LLM_BACKEND key in .env (vllm | ollama | claude). Default: vllm.
#
# Ported and trimmed from LocalLLM_Pipeline/Common/llm_core.ps1. This file is
# deliberately STANDALONE: it does NOT redefine Read-EnvFile / Cfg (the toolkit
# scripts already define their own), and the resolvers take an explicit -Cfg
# hashtable instead of relying on a global. Dot-source it from a parent script
# (for the resolvers) and from each Start-Job worker (for Invoke-LocalLLM).
#
#   Get-LLMBackend   - resolve backend: vllm (default) | ollama | claude
#   Get-LLMEndpoint  - resolve backend base URL
#   Get-LLMModel     - resolve model via role key -> LLM_DEFAULT_MODEL -> fallback
#   Invoke-LocalLLM  - call the local LLM (vLLM gateway /v1 + Ollama native /api/chat)
# ============================================================

$script:LLM_GATEWAY_PORT = '11430'   # LLMConfig OpenAI /v1 gateway (vllm)
$script:LLM_OLLAMA_PORT  = '11434'   # native Ollama server (ollama)
$script:LLM_DEFAULT_HOST = '192.168.1.40'
$script:LLM_DEFAULT_MODEL_FALLBACK = 'qwen3.6:27B'
# Thinking models split num_predict between reasoning AND content; too small a
# budget yields empty/truncated content. Floor it when -Think is on. num_predict
# is a cap (not a target), so a generous floor only helps files that need it and
# does not slow files whose output finishes early.
$script:LLM_THINK_MIN_TOKENS = 8000

function Get-LLMCfgVal {
    # Lookup a key in an optional -Cfg hashtable; empty string counts as unset.
    param([hashtable]$Cfg, [string]$Key, [string]$Default = '')
    if ($Cfg -and $Cfg.ContainsKey($Key) -and $Cfg[$Key] -ne '') { return $Cfg[$Key] }
    return $Default
}

function Get-LLMBackend {
    # 'vllm' (default) | 'ollama' | 'claude'.
    # Precedence: $env:LLM_BACKEND -> -Cfg LLM_BACKEND -> 'vllm'.
    param([hashtable]$Cfg)
    $raw = if ($env:LLM_BACKEND) { $env:LLM_BACKEND } else { Get-LLMCfgVal $Cfg 'LLM_BACKEND' 'vllm' }
    $backend = $raw.Trim().ToLower()
    if ($backend -ne 'vllm' -and $backend -ne 'ollama' -and $backend -ne 'claude') {
        throw "LLM_BACKEND must be 'vllm', 'ollama', or 'claude', got '$raw'"
    }
    return $backend
}

function Get-LLMEndpoint {
    # vllm   -> LLMConfig OpenAI /v1 gateway (port 11430)
    # ollama -> native Ollama server (LLM_PORT, default 11434)
    # An explicit LLM_ENDPOINT (env or .env) overrides everything.
    param([hashtable]$Cfg, [string]$Backend = '')
    if ($Backend -eq '') { $Backend = Get-LLMBackend -Cfg $Cfg }
    if ($Backend -eq 'ollama' -and $env:OLLAMA_API_BASE) { return $env:OLLAMA_API_BASE.TrimEnd('/') }
    if ($env:LLM_ENDPOINT) { return $env:LLM_ENDPOINT.TrimEnd('/') }
    $ep = Get-LLMCfgVal $Cfg 'LLM_ENDPOINT' ''
    if ($ep -ne '') { return $ep.TrimEnd('/') }
    $host_ = Get-LLMCfgVal $Cfg 'LLM_HOST' $script:LLM_DEFAULT_HOST
    if ($Backend -eq 'vllm') { return "http://${host_}:$($script:LLM_GATEWAY_PORT)" }
    $port = Get-LLMCfgVal $Cfg 'LLM_PORT' $script:LLM_OLLAMA_PORT
    return "http://${host_}:${port}"
}

function Get-LLMModel {
    # role-specific key (if set) -> LLM_DEFAULT_MODEL (if set) -> -Fallback.
    param([hashtable]$Cfg, [string]$RoleKey = '', [string]$Fallback = '')
    if ($Fallback -eq '') { $Fallback = $script:LLM_DEFAULT_MODEL_FALLBACK }
    if ($RoleKey) {
        $roleVal = Get-LLMCfgVal $Cfg $RoleKey ''
        if ($roleVal -ne '') { return $roleVal }
    }
    $defaultVal = Get-LLMCfgVal $Cfg 'LLM_DEFAULT_MODEL' ''
    if ($defaultVal -ne '') { return $defaultVal }
    return $Fallback
}

function Invoke-LocalLLM {
    # Single completion against the local backend. Returns the trimmed response
    # text, or throws after $MaxRetries. The caller supplies the resolved
    # Backend/Endpoint/Model (the parent script resolves these via the Get-LLM*
    # helpers from its parsed .env), so this function needs no global config.
    param(
        [string]$SystemPrompt,
        [string]$UserPrompt,
        [string]$Backend     = 'vllm',
        [string]$Endpoint    = '',
        [string]$Model       = 'qwen3.6:27B',
        [double]$Temperature = 0.1,
        [int]   $MaxTokens   = 800,
        [int]   $NumCtx      = 0,
        [int]   $Timeout     = 900,
        [int]   $MaxRetries  = 3,
        [int]   $RetryDelay  = 5,
        [bool]  $Think       = $false,
        [string]$ThinkingFile = ''
    )

    if ($Backend -eq '') { $Backend = 'vllm' }
    if (-not $Endpoint -or $Endpoint -eq '') {
        $Endpoint = Get-LLMEndpoint -Backend $Backend
    }
    $Endpoint = $Endpoint.TrimEnd('/')

    # Thinking models emit reasoning AND content from the same num_predict budget;
    # too small a budget returns empty content. Floor it ONLY on the ollama native
    # (thinking) path -- on vLLM/claude the floor would just inflate max_tokens and
    # risk context-overflow 400s on large files.
    if ($Think -and $Backend -eq 'ollama' -and $NumCtx -gt 0 -and $MaxTokens -lt $script:LLM_THINK_MIN_TOKENS) {
        $MaxTokens = $script:LLM_THINK_MIN_TOKENS
    }

    $messages = @()
    if ($SystemPrompt -and $SystemPrompt.Trim() -ne '') {
        $messages += @{ role = 'system'; content = $SystemPrompt }
    }
    $messages += @{ role = 'user'; content = $UserPrompt }

    # Native /api/chat (num_ctx + think) is an Ollama-only path; the vLLM gateway
    # is OpenAI-compatible and fixes context per alias at serve time.
    $native = ($Backend -eq 'ollama' -and $NumCtx -gt 0)
    if ($native) {
        $uri = "$Endpoint/api/chat"
        $bodyHash = @{
            model    = $Model
            messages = $messages
            stream   = $false
            options  = @{
                num_ctx     = $NumCtx
                temperature = $Temperature
                num_predict = $MaxTokens
            }
        }
        if ($Think) { $bodyHash.think = $true }
    }
    else {
        $uri = "$Endpoint/v1/chat/completions"
        $bodyHash = @{
            model       = $Model
            messages    = $messages
            stream      = $false
            temperature = $Temperature
            max_tokens  = $MaxTokens
        }
    }

    $body = $bodyHash | ConvertTo-Json -Depth 5

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $resp = Invoke-RestMethod -Uri $uri `
                -Method Post `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -TimeoutSec $Timeout `
                -ErrorAction Stop

            $thinking = $null
            if ($native) {
                $output = $resp.message.content
                if ($resp.message -and ($resp.message.PSObject.Properties.Name -contains 'thinking')) {
                    $thinking = $resp.message.thinking
                }
                if ($ThinkingFile -and $thinking -and $thinking.Trim() -ne '') {
                    try {
                        $thinking | Out-File -FilePath $ThinkingFile -Encoding utf8
                    } catch {
                        Write-Host "  [warn] Could not write thinking sidecar '$ThinkingFile': $($_.Exception.Message)" -ForegroundColor DarkYellow
                    }
                }
            }
            else {
                $output = $resp.choices[0].message.content
            }
            if (-not $output -or $output.Trim() -eq '') {
                if ($native -and $thinking -and $thinking.Trim() -ne '') {
                    $tLen = $thinking.Length
                    throw "Model exhausted budget inside <thinking> (thinking=$tLen chars, num_predict=$MaxTokens)."
                }
                throw "Empty response from LLM"
            }
            $trimmed = $output.Trim()
            $hasAscii = $trimmed -match '[A-Za-z0-9]'
            if ($trimmed.Length -lt 20 -or -not $hasAscii) {
                $preview = $trimmed.Substring(0, [Math]::Min(60, $trimmed.Length))
                $msg = "LLM returned suspiciously short/garbled content ($($trimmed.Length) chars: '$preview')"
                if ($native -and $thinking -and $thinking.Trim() -ne '') {
                    $msg += " -- thinking=$($thinking.Length) chars suggests budget exhaustion during reasoning."
                }
                throw $msg
            }
            return $trimmed
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                throw "LLM call failed after $MaxRetries attempts: $($_.Exception.Message)"
            }
            Write-Host "  [retry $attempt/$MaxRetries] $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelay
        }
    }
}
