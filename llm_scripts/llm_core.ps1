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

function Set-GpuGateEnv {
    # Copy the GPU idle-gate keys from parsed .env into process env vars so
    # Start-Job workers (separate processes that don't read .env) inherit them.
    # Call once from each parent script after Read-EnvFile.
    param([hashtable]$Cfg)
    foreach ($k in @('GPU_IDLE_CHECK', 'GPU_BUSY_THRESHOLD', 'GPU_CHECK_INTERVAL', 'GPU_STATUS_URL')) {
        $v = Get-LLMCfgVal $Cfg $k ''
        if ($v -ne '') { Set-Item -Path "env:$k" -Value $v }
    }
}

function Wait-GpuIdle {
    # GPU idle gate: before touching the local backend, ask the LLMConfig
    # gateway whether the primary GPU (RTX 3090 lane) is busy - a model swap
    # in progress, an active gateway job, or utilization above threshold -
    # and if so wait GPU_CHECK_INTERVAL seconds (default 300) and re-check
    # until it is idle. Applies only to local backends (claude never calls
    # this). An unreachable gateway does NOT block: we return and let the
    # actual LLM call surface the error.
    #
    # .env / env keys (exported to workers via Set-GpuGateEnv):
    #   GPU_IDLE_CHECK     1 (default) = on, 0 = off
    #   GPU_BUSY_THRESHOLD utilization % that counts as busy (default 10)
    #   GPU_CHECK_INTERVAL seconds between re-checks (default 300)
    #   GPU_STATUS_URL     override; default http://<endpoint-host>:11430/api/status
    param([string]$Endpoint)
    if ($env:GPU_IDLE_CHECK -eq '0') { return }
    if (-not $Endpoint -or $Endpoint -eq '') { return }
    $m = [regex]::Match($Endpoint, '^(https?)://([^:/]+)')
    if (-not $m.Success) { return }
    $statusUrl = if ($env:GPU_STATUS_URL) { $env:GPU_STATUS_URL }
                 else { "$($m.Groups[1].Value)://$($m.Groups[2].Value):$($script:LLM_GATEWAY_PORT)/api/status" }
    $threshold = 10.0
    if ($env:GPU_BUSY_THRESHOLD) { $threshold = [double]$env:GPU_BUSY_THRESHOLD }
    $interval = 300
    if ($env:GPU_CHECK_INTERVAL) { $interval = [int]$env:GPU_CHECK_INTERVAL }

    $waited = $false
    while ($true) {
        $st = $null
        try {
            $st = Invoke-RestMethod -Uri $statusUrl -TimeoutSec 10 -ErrorAction Stop
        } catch {
            if ($waited) { Write-Host "[gpu-idle] status endpoint unreachable - proceeding" -ForegroundColor Yellow }
            return
        }
        # Prefer the primary lane (the 3090) when the gateway reports lanes.
        $g = $st
        if (($st.PSObject.Properties.Name -contains 'lanes') -and @($st.lanes).Count -gt 0) {
            $g = @($st.lanes)[0]
        }
        $busy = $false
        $reason = ''
        $util = 0.0
        try { $util = [double]$g.gpu.utilization_pct } catch {}
        if ($g.swap_in_progress) {
            $busy = $true; $reason = 'model swap in progress'
        } elseif (($g.PSObject.Properties.Name -contains 'active_job_id') -and $null -ne $g.active_job_id -and "$($g.active_job_id)" -ne '') {
            $busy = $true; $reason = "gateway job $($g.active_job_id) active"
        } elseif ($util -ge $threshold) {
            $busy = $true; $reason = ('GPU at {0:N0}% utilization (threshold {1:N0}%)' -f $util, $threshold)
        }
        if (-not $busy) {
            if ($waited) { Write-Host "[gpu-idle] GPU idle again - resuming" -ForegroundColor Green }
            return
        }
        Write-Host ("[gpu-idle] {0:HH:mm:ss} RTX busy: {1} - waiting {2}s" -f (Get-Date), $reason, $interval) -ForegroundColor Yellow
        $waited = $true
        Start-Sleep -Seconds $interval
    }
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

    # Yield to other GPU users: only fire this request when the card is idle.
    Wait-GpuIdle -Endpoint $Endpoint

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
