# archpass2_worker.ps1 - per-file worker for archpass2.ps1
# Dispatched via Start-Job -FilePath (NOT -ScriptBlock).
# Pure ASCII - no Unicode characters anywhere.

param(
    [string]$rel,
    [string]$repoRoot,
    [string]$archDir,
    [string]$stateDir,
    [string]$claudeCfgDir,
    [string]$model,
    [string]$maxTurns,
    [string]$outputFmt,
    [string]$promptFileP2,
    [int]   $maxRetries,
    [int]   $retryDelay,
    [string]$defaultFence,
    [string]$hashDbPath,
    [string]$counterPath,
    [string]$fatalFlag,
    [string]$fatalMsg,
    [string]$errorLog,
    [string]$rateLimitFile,
    [string]$archContext,
    [string]$xrefContext,
    [string]$llmBackend = "claude",
    [string]$llmEndpoint = "",
    [string]$llmModel = "",
    [double]$llmTemp = 0.1,
    [int]   $llmMaxTokens = 1000,
    [int]   $llmTimeout = 900,
    [int]   $llmNumCtx = 0,
    [bool]  $llmThink = $false,
    [string]$toolkitDir = "",
    [string]$fallbackModel = ""    # non-empty (e.g. 'sonnet') = escalate this file to claude on local degrade
)

# Local-LLM backend helpers. Start-Job runs this in a fresh runspace where
# $PSScriptRoot is EMPTY, so the parent passes the toolkit dir explicitly.
$toolkitRoot = if ($toolkitDir -ne '') { $toolkitDir } else { (Get-Location).Path }
. (Join-Path $toolkitRoot 'llm_core.ps1')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-FenceLang($file, $def) {
    $ext = [System.IO.Path]::GetExtension($file).TrimStart('.').ToLower()
    switch ($ext) {
        { $_ -in @('c','h','inc') }                              { return 'c' }
        { $_ -in @('cpp','cc','cxx','hpp','hh','hxx','inl') }    { return 'cpp' }
        'cs'    { return 'csharp' }   'java'  { return 'java' }
        'py'    { return 'python' }   'rs'    { return 'rust' }
        'lua'   { return 'lua' }
        { $_ -in @('gd','gdscript') } { return 'gdscript' }
        'swift' { return 'swift' }
        { $_ -in @('m','mm') }        { return 'objectivec' }
        { $_ -in @('shader','cginc','hlsl','glsl','compute') } { return 'hlsl' }
        'toml'  { return 'toml' }
        { $_ -in @('tscn','tres') }   { return 'ini' }
        default { return $def }
    }
}

function Test-RateLimit($text) {
    # A valid pass-2 doc starts with a markdown heading - never an error message.
    if ($text -match '(?m)^#\s+\S') { return $false }
    if ($text -match '(?m)^\s*429\b')           { return $true }
    if ($text -match '"status"\s*:\s*429')       { return $true }
    if ($text -match '(?im)^error:.*\b(rate.?limit|usage.?limit|quota|overloaded)\b') { return $true }
    if ($text -match '(?im)^claude:\s*(rate.?limit|usage.?limit)')                    { return $true }
    if ($text -match '(?im)^\s*too many requests\s*$')                                { return $true }
    if ($text -match "(?im)^\s*you.ve hit your (usage |message |daily )?limit")       { return $true }
    return $false
}

function Test-TooLong($text) {
    if ($text -match '(?i)prompt is too long')              { return $true }
    if ($text -match '(?i)context.{0,20}(length|limit|window)') { return $true }
    if ($text -match '(?i)maximum context')                 { return $true }
    if ($text -match '(?i)too many tokens')                 { return $true }
    return $false
}

function Write-ErrorLog($path, $type, $rel, $exitCode, $rawStdout, $rawStderr) {
    $divider = '=' * 60
    $entry   = @"
$divider
Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Type      : $type
File      : $rel
Exit code : $exitCode
$divider
--- STDERR (verbatim) ---
$rawStderr
--- STDOUT (verbatim) ---
$rawStdout
$divider

"@
    [System.IO.File]::AppendAllText($path, $entry)
}

function Get-RateLimitResetTime($text) {
    # Bare 12-hour time: "resets 6pm", "resets at 6:30pm (America/New_York)"
    if ($text -match "(?i)resets?\s+(?:at\s+)?(\d{1,2}(?::\d{2})?\s*[ap]m)(?:\s*\([^)]+\))?") {
        $timeStr = $Matches[1].Trim()
        try {
            $candidate = [datetime]::Parse($timeStr)
            if ($candidate -lt [datetime]::Now) { $candidate = $candidate.AddDays(1) }
            return $candidate
        } catch {}
    }
    # ISO 8601: "resets at 2024-01-15T13:00:00Z"
    if ($text -match "resets?\s+at\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?)") {
        try { return [datetime]::Parse($Matches[1]).ToLocalTime() } catch {}
    }
    # "resets on 2024-01-15 at 1:00 PM UTC"
    if ($text -match "resets?\s+on\s+(\d{4}-\d{2}-\d{2})\s+at\s+([\d:]+\s*[APap][Mm])\s*(UTC|GMT)?") {
        try { return [datetime]::Parse("$($Matches[1]) $($Matches[2]) UTC").ToLocalTime() } catch {}
    }
    # JSON Unix timestamp: "reset_at":1705320000
    if ($text -match """reset_at""\s*:\s*(\d{10})") {
        try {
            $epoch = [datetime]"1970-01-01T00:00:00Z"
            return $epoch.AddSeconds([long]$Matches[1]).ToLocalTime()
        } catch {}
    }
    return $null
}

function Format-LocalTime($dt) { return $dt.ToString("h:mm tt") }

function Wait-UntilResumeTime($resumeAt, $label) {
    while ([datetime]::Now -lt $resumeAt) {
        $remaining = ($resumeAt - [datetime]::Now).TotalSeconds
        if ($remaining -le 0) { break }
        $mins    = [math]::Ceiling($remaining / 60)
        $ts      = Format-LocalTime $resumeAt
        Write-Host "  [rate-limit] $label -- paused, resuming in ~${mins}m (at $ts)" -ForegroundColor Yellow
        $sleepSec = [math]::Max(1, [math]::Min(60, $remaining))
        Start-Sleep -Seconds $sleepSec
    }
}

function Update-Counter($path, $key) {
    $mtx = [System.Threading.Mutex]::new($false, "archpass2_counter_mutex")
    try {
        $mtx.WaitOne() | Out-Null
        $obj = (Get-Content $path -Raw -ErrorAction Stop) | ConvertFrom-Json
        $obj.$key++
        $obj | ConvertTo-Json -Compress | Set-Content $path -Encoding UTF8
    } catch {}
    finally { $mtx.ReleaseMutex(); $mtx.Dispose() }
}

# ---------------------------------------------------------------------------
# Check fatal flag
# ---------------------------------------------------------------------------

if (Test-Path $fatalFlag) { exit 0 }

# ---------------------------------------------------------------------------
# Build payload - called with decreasing context on "too long" retries
#   stage 0: source (truncated at 500) + pass1 doc + arch context + xref context  (normal)
#   stage 1: source (truncated at 500) + pass1 doc + arch context  (drop xref)
#   stage 2: source (truncated at 200) + pass1 doc only            (drop arch context)
#   stage 3: source (truncated at 100) only                        (last resort)
# ---------------------------------------------------------------------------

function Build-Pass2Payload($stage, $rel, $fence, $srcLines, $pass1Content, $archContext, $xrefContext) {
    $lineCount = $srcLines.Count

    $srcLimit = switch ($stage) {
        0 { 500 }
        1 { 500 }
        2 { 200 }
        3 { 100 }
        default { 500 }
    }

    $srcContent = if ($lineCount -gt $srcLimit) {
        ($srcLines | Select-Object -First $srcLimit) -join "`n" +
        "`n`n... [truncated at $srcLimit/$lineCount lines] ..."
    } else { $srcLines -join "`n" }

    # Opt v4#4: Embed prompt schema in user message for prompt caching
    $schemaContent = ""
    if (Test-Path $promptFileP2) {
        $schemaContent = Get-Content $promptFileP2 -Raw -ErrorAction SilentlyContinue
        if ($schemaContent) { $schemaContent = "OUTPUT SCHEMA:`n$schemaContent`n`n" }
        else { $schemaContent = "" }
    }

    $payload = "${schemaContent}FILE PATH (relative): $rel`n`nFILE CONTENT ($lineCount lines total):`n``````$fence`n$srcContent`n``````" +
               "`n`nFIRST-PASS ANALYSIS:`n$pass1Content"

    # Opt #4: Use targeted context if available, otherwise fall back to global truncated blobs
    $targetedCtxDir = Join-Path (Split-Path $stateDir -Parent) '.pass2_context'
    $targetedCtxFile = Join-Path $targetedCtxDir (($rel -replace '/','\') + '.ctx.txt')
    $hasTargeted = Test-Path $targetedCtxFile

    if ($hasTargeted) {
        $targetedContent = Get-Content $targetedCtxFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($targetedContent -and $stage -le 1) {
            $payload += "`n`nTARGETED ARCHITECTURE + CROSS-REFERENCE CONTEXT:`n$targetedContent"
        }
    } else {
        # Fall back to original global context (empty on local backends -> sections omitted)
        if ($stage -le 1 -and $archContext -ne '') { $payload += "`n`nARCHITECTURE CONTEXT:`n$archContext" }
        if ($stage -le 0 -and $xrefContext -ne '') { $payload += "`n`nCROSS-REFERENCE CONTEXT (excerpt):`n$xrefContext" }
    }

    return $payload
}

# ---------------------------------------------------------------------------
# Derive file paths from parameters
# ---------------------------------------------------------------------------

$src     = Join-Path $repoRoot ($rel -replace '/', '\')
$outPath = Join-Path $archDir  (($rel -replace '/', '\') + '.pass2.md')
$pass1   = Join-Path $archDir  (($rel -replace '/', '\') + '.md')
$fence   = Get-FenceLang $rel $defaultFence

$outDir = Split-Path $outPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# ---------------------------------------------------------------------------
# Load source and first-pass content
# ---------------------------------------------------------------------------

$srcLines     = @(Get-Content $src -ErrorAction SilentlyContinue)
$lineCount    = $srcLines.Count
$pass1Content = if (Test-Path $pass1) { Get-Content $pass1 -Raw } else { '(no first-pass doc found)' }

# ---------------------------------------------------------------------------
# Retry loop with staged fallback for "prompt too long"
# ---------------------------------------------------------------------------

$attempt  = 0
$stage    = 0
$maxStage = 3
$success  = $false
$claudeFallbackTried = $false   # one-shot claude escalation on local degrade (see fallbackModel)

while ($true) {
    if (Test-Path $fatalFlag) { exit 0 }

    # Honour shared rate-limit pause written by any worker
    if (Test-Path $rateLimitFile) {
        try {
            $resumeAt = [datetime]::Parse((Get-Content $rateLimitFile -Raw -ErrorAction Stop).Trim())
            if ([datetime]::Now -lt $resumeAt) {
                $ts = Format-LocalTime $resumeAt
                Write-Host "  [rate-limit] $rel -- waiting for shared pause to expire at $ts" -ForegroundColor DarkYellow
                Wait-UntilResumeTime $resumeAt $rel
            }
        } catch {}
    }

    $payload = Build-Pass2Payload $stage $rel $fence $srcLines $pass1Content $archContext $xrefContext

    try {
        # Opt v4#4: Use fixed system prompt for prompt caching
        $sysPromptFile = Join-Path (Split-Path $promptFileP2 -Parent) 'file_doc_system_prompt.txt'
        if (-not (Test-Path $sysPromptFile)) { $sysPromptFile = $promptFileP2 }
        if ($llmBackend -eq 'claude') {
            $env:CLAUDE_CONFIG_DIR = $claudeCfgDir
            $stderrFile = [System.IO.Path]::GetTempFileName()
            $stdoutRaw  = $payload | & claude -p `
                --model $model `
                --max-turns $maxTurns `
                --output-format $outputFmt `
                --append-system-prompt-file $sysPromptFile 2>$stderrFile
            $exitCode  = $LASTEXITCODE
            $stderrRaw = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } else { '' }
            Remove-Item $stderrFile -ErrorAction SilentlyContinue
        } else {
            # Local LLM (vLLM gateway / Ollama) via LLMConfig
            $sysPrompt = Get-Content $sysPromptFile -Raw -Encoding UTF8
            $stdoutRaw = Invoke-LocalLLM -SystemPrompt $sysPrompt -UserPrompt $payload `
                -Backend $llmBackend -Endpoint $llmEndpoint -Model $llmModel `
                -Temperature $llmTemp -MaxTokens $llmMaxTokens -Timeout $llmTimeout -NumCtx $llmNumCtx -Think $llmThink
            $exitCode  = 0
            $stderrRaw = ''
        }
    } catch {
        $stdoutRaw = ''
        $stderrRaw = $_.Exception.Message
        $exitCode  = 1
    }

    $stdoutText = if ($stdoutRaw -is [array]) { $stdoutRaw -join "`n" } else { [string]$stdoutRaw }
    $stderrText = if ($stderrRaw -is [array]) { $stderrRaw -join "`n" } else { [string]$stderrRaw }
    $respText   = ($stdoutText + "`n" + $stderrText).Trim()

    # Success
    if ($exitCode -eq 0 -and -not (Test-RateLimit $respText)) {
        $success = $true
        break
    }

    # Prompt too long, or a local-backend degrade (thinking-exhaustion / empty / context) -
    # drop context and retry. Local backends signal these via a 400/context error or empty/
    # short/thinking-exhausted output rather than a clean "too long" message.
    $localTooLong = ($llmBackend -ne 'claude') -and ($exitCode -ne 0) -and ($respText -match '400|context length|maximum context|context window|exceed|too long|too large|exhausted budget|[Ee]mpty response|suspiciously short')
    if ((Test-TooLong $respText) -or $localTooLong) {
        # On a local degrade, escalate this file to a Claude model (e.g. sonnet) ONCE with the
        # full untruncated payload instead of emitting a truncated doc, then continue locally.
        # No-op if fallbackModel/claudeCfgDir unset.
        if ($fallbackModel -ne '' -and $claudeCfgDir -ne '' -and -not $claudeFallbackTried) {
            $claudeFallbackTried = $true
            Write-Host "  [degrade->claude] $rel -- local degrade; escalating to $fallbackModel" -ForegroundColor Magenta
            $prevCfg = $env:CLAUDE_CONFIG_DIR
            try {
                $env:CLAUDE_CONFIG_DIR = $claudeCfgDir
                $fbStderr = [System.IO.Path]::GetTempFileName()
                $fbResp = $payload | & claude -p --model $fallbackModel --max-turns $maxTurns --output-format $outputFmt --append-system-prompt-file $sysPromptFile 2>$fbStderr
                $fbExit = $LASTEXITCODE
                Remove-Item $fbStderr -ErrorAction SilentlyContinue
                $fbText = if ($fbResp -is [array]) { $fbResp -join "`n" } else { [string]$fbResp }
                if ($fbExit -eq 0 -and -not (Test-RateLimit $fbText) -and -not (Test-TooLong $fbText) -and $fbText.Trim().Length -ge 200) {
                    $stdoutText = $fbText
                    $success    = $true
                    $env:CLAUDE_CONFIG_DIR = $prevCfg
                    Write-Host "  [degrade->claude] $rel -- recovered via $fallbackModel" -ForegroundColor Green
                    break
                }
                Write-Host "  [degrade->claude] $rel -- $fallbackModel unusable (exit=$fbExit); continuing local degrade" -ForegroundColor Yellow
            } catch {
                Write-Host "  [degrade->claude] $rel -- $fallbackModel error: $($_.Exception.Message); continuing local degrade" -ForegroundColor Yellow
            }
            $env:CLAUDE_CONFIG_DIR = $prevCfg
        }
        $stage++
        if ($stage -le $maxStage) {
            $stageLabel = switch ($stage) {
                1 { "dropping xref context" }
                2 { "dropping arch context, truncating source harder" }
                3 { "source only, minimal truncation" }
            }
            Write-Host "  [too-long] $rel -- $stageLabel (stage $stage)" -ForegroundColor DarkCyan
            continue
        }
        Write-ErrorLog $errorLog 'TOO_LONG (all stages exhausted)' $rel $exitCode $stdoutText $stderrText
        Update-Counter $counterPath "fail"
        if ($env:ARCH_CONTINUE_ON_ERROR) {
            # Orchestrated run: record the failure and keep going so the stage completes.
            $failsFile = Join-Path (Split-Path $errorLog -Parent) 'failures.tsv'
            [System.IO.File]::AppendAllText($failsFile, "$rel`tTOO_LONG`tPrompt too long after all fallback stages (degrade/truncation exhausted)`n")
            exit 0
        }
        "Prompt too long after all fallback stages: $rel" | Set-Content $fatalMsg -Encoding UTF8
        "fatal" | Set-Content $fatalFlag -Encoding UTF8
        exit 1
    }

    # Rate limit
    if (Test-RateLimit $respText) {
        Write-ErrorLog $errorLog 'RATE_LIMIT' $rel $exitCode $stdoutText $stderrText

        $resetTime  = Get-RateLimitResetTime $respText
        $resumeTime = if ($resetTime) { $resetTime.AddMinutes(10) } else { [datetime]::Now.AddMinutes(70) }
        $resetStr   = if ($resetTime) { Format-LocalTime $resetTime } else { "unknown" }

        Write-Host ""
        Write-Host "  [rate-limit] You've hit your limit, resets at $resetStr. Thread paused till $(Format-LocalTime $resumeTime)." -ForegroundColor Yellow
        Write-Host ""

        $resumeTime.ToString("o") | Set-Content $rateLimitFile -Encoding UTF8
        Wait-UntilResumeTime $resumeTime $rel
        Remove-Item $rateLimitFile -ErrorAction SilentlyContinue
        $attempt = 0
        continue
    }

    # Transient failure
    $attempt++
    if ($attempt -le $maxRetries) {
        Update-Counter $counterPath "retries"
        Start-Sleep -Seconds $retryDelay
        continue
    }

    Write-ErrorLog $errorLog 'PERSISTENT_FAILURE' $rel $exitCode $stdoutText $stderrText
    Update-Counter $counterPath "fail"
    if ($env:ARCH_CONTINUE_ON_ERROR) {
        # Orchestrated run: record the failure and keep going so the stage completes.
        $failsFile = Join-Path (Split-Path $errorLog -Parent) 'failures.tsv'
        $reason = ([string]$respText -replace '\s+',' ').Trim(); if ($reason.Length -gt 200) { $reason = $reason.Substring(0,200) }
        [System.IO.File]::AppendAllText($failsFile, "$rel`tPERSISTENT_FAILURE`t$reason`n")
        exit 0
    }
    "Claude failed after $attempt attempts on: $rel`nSee error log for exact output." | Set-Content $fatalMsg -Encoding UTF8
    "fatal" | Set-Content $fatalFlag -Encoding UTF8
    exit 1
}

# ---------------------------------------------------------------------------
# Write output and record hash
# ---------------------------------------------------------------------------

if ($success) {
    $stdoutText | Set-Content -Path $outPath -Encoding UTF8

    $sha     = [System.Security.Cryptography.SHA1]::Create()
    $bytes   = [System.IO.File]::ReadAllBytes($src)
    $hashStr = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    [System.IO.File]::AppendAllText($hashDbPath, "$hashStr`t$rel`n")

    Update-Counter $counterPath "done"
}
