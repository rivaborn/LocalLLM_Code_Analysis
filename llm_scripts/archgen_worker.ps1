# archgen_worker.ps1 - Per-file worker called by archgen.ps1
# Do not run directly. Called via Start-Job -FilePath by archgen.ps1.

param(
    [string]$rel,               # Single file OR pipe-separated batch: "file1|file2|file3"
    [string]$repoRoot,
    [string]$archDir,
    [string]$claudeCfgDir,
    [string]$model,
    [string]$maxTurns,
    [string]$outputFmt,
    [string]$promptFile,
    [int]   $maxRetries,
    [int]   $retryDelay,
    [string]$defaultFence,
    [string]$bundleHeaders,
    [int]   $maxBundled,
    [string]$hashDbPath,
    [int]   $maxFileLines,
    [string]$counterPath,
    [string]$fatalFlag,
    [string]$fatalMsg,
    [string]$errorLog,
    [string]$serenaContextDir = "",
    [string]$bundleHeaderDocs = "0",
    [string]$outputBudget = "~1000 tokens",
    [string]$preambleContent = "",
    [string]$elideSource = "0",
    [string]$maxOutputTokens = "0",
    [string]$dirContextDir = "",
    [string]$sharedHeaderDir = "",
    [string]$jsonOutput = "0",
    [string]$llmBackend = "claude",
    [string]$llmEndpoint = "",
    [string]$llmModel = "",
    [double]$llmTemp = 0.1,
    [int]   $llmMaxTokens = 1000,
    [int]   $llmTimeout = 900,
    [int]   $llmNumCtx = 0,
    [bool]  $llmThink = $false,
    [string]$toolkitDir = ""
)

# Local-LLM backend helpers. Start-Job runs this in a fresh runspace where
# $PSScriptRoot is EMPTY, so the parent passes the toolkit dir explicitly.
$toolkitRoot = if ($toolkitDir -ne '') { $toolkitDir } else { (Get-Location).Path }
. (Join-Path $toolkitRoot 'llm_core.ps1')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-FenceLang($file, $def) {
    $ext = [System.IO.Path]::GetExtension($file).TrimStart(".").ToLower()
    switch ($ext) {
        { $_ -in @("c","h","inc") }                             { return "c" }
        { $_ -in @("cpp","cc","cxx","hpp","hh","hxx","inl") }   { return "cpp" }
        "cs"     { return "csharp" }
        "java"   { return "java" }
        "py"     { return "python" }
        "rs"     { return "rust" }
        "lua"    { return "lua" }
        { $_ -in @("gd","gdscript") }                           { return "gdscript" }
        "swift"  { return "swift" }
        { $_ -in @("m","mm") }                                  { return "objectivec" }
        { $_ -in @("shader","cginc","hlsl","glsl","compute") }  { return "hlsl" }
        "toml"   { return "toml" }
        { $_ -in @("tscn","tres") }                             { return "ini" }
        default  { return $def }
    }
}

function Test-RateLimit($text) {
    # Check the whole response, not just first 3 lines -
    # Claude's usage limit message is a single plain-text line.
    if ($text -match "^#") { return $false }
    if ($text -match "429") { return $true }
    if ($text -match "(?i)rate.?limit|usage.?limit|too many requests") { return $true }
    if ($text -match "(?i)hit your limit") { return $true }
    if ($text -match "(?i)^error:.*(overloaded|quota)") { return $true }
    return $false
}

function Test-TooLong($text) {
    if ($text -match "(?i)prompt is too long") { return $true }
    if ($text -match "(?i)context.{0,20}(length|limit|window)") { return $true }
    if ($text -match "(?i)maximum context") { return $true }
    if ($text -match "(?i)too many tokens") { return $true }
    return $false
}

# Parse a reset timestamp from Claude's rate-limit error text.
# Handles formats actually seen in the wild:
#   "resets 6pm (America/New_York)"
#   "resets at 6pm (America/New_York)"
#   "resets at 6:30pm (America/New_York)"
#   "resets at 2024-01-15T13:00:00Z"
#   "resets on 2024-01-15 at 1:00 PM UTC"
#   "reset_at":1705320000
# Returns a [datetime] in local time, or $null if not found.
function Get-RateLimitResetTime($text) {
    # Pattern 1: bare 12-hour time with optional colon + optional timezone
    # e.g. "resets 6pm", "resets at 6:30pm (America/New_York)"
    if ($text -match "(?i)resets?\s+(?:at\s+)?(\d{1,2}(?::\d{2})?\s*[ap]m)(?:\s*\([^)]+\))?") {
        $timeStr = $Matches[1].Trim()
        try {
            # Parse as today's date at that time, local
            $candidate = [datetime]::Parse($timeStr)
            # If that time has already passed today, assume it means tomorrow
            if ($candidate -lt [datetime]::Now) { $candidate = $candidate.AddDays(1) }
            return $candidate
        } catch {}
    }
    # Pattern 2: ISO 8601 e.g. "resets at 2024-01-15T13:00:00Z"
    if ($text -match "resets?\s+at\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?)") {
        try { return [datetime]::Parse($Matches[1]).ToLocalTime() } catch {}
    }
    # Pattern 3: "resets on 2024-01-15 at 1:00 PM UTC"
    if ($text -match "resets?\s+on\s+(\d{4}-\d{2}-\d{2})\s+at\s+([\d:]+\s*[APap][Mm])\s*(UTC|GMT)?") {
        try { return [datetime]::Parse("$($Matches[1]) $($Matches[2]) UTC").ToLocalTime() } catch {}
    }
    # Pattern 4: Unix timestamp in JSON e.g. "reset_at":1705320000
    if ($text -match """reset_at""\s*:\s*(\d{10})") {
        try {
            $epoch = [datetime]"1970-01-01T00:00:00Z"
            return $epoch.AddSeconds([long]$Matches[1]).ToLocalTime()
        } catch {}
    }
    return $null
}

function Format-LocalTime($dt) {
    return $dt.ToString("h:mm tt")
}

# Sleep until $resumeAt, printing status every 60 seconds.
function Wait-UntilResumeTime($resumeAt, $label) {
    while ([datetime]::Now -lt $resumeAt) {
        $remaining = ($resumeAt - [datetime]::Now).TotalSeconds
        if ($remaining -le 0) { break }
        $mins = [math]::Ceiling($remaining / 60)
        $ts   = Format-LocalTime $resumeAt
        Write-Host "  [rate-limit] $label -- paused, resuming in ~${mins}m (at $ts)" -ForegroundColor Yellow
        $sleepSec = [math]::Max(1, [math]::Min(60, $remaining))
        Start-Sleep -Seconds $sleepSec
    }
}

function Read-Counter($path) {
    try {
        return (Get-Content $path -Raw -ErrorAction Stop) | ConvertFrom-Json
    } catch { return $null }
}

function Update-Counter($path, $key) {
    $mtx = [System.Threading.Mutex]::new($false, "archgen_counter_mutex")
    try {
        $mtx.WaitOne(5000) | Out-Null
        $obj = Read-Counter $path
        if ($obj) {
            $obj.$key = $obj.$key + 1
            $obj | ConvertTo-Json | Set-Content $path -Encoding UTF8
        }
    } finally {
        $mtx.ReleaseMutex()
        $mtx.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Guard: abort if fatal flag already set
# ---------------------------------------------------------------------------

if (Test-Path $fatalFlag) { exit 0 }

# ---------------------------------------------------------------------------
# Detect batch mode (pipe-separated rel paths)
# ---------------------------------------------------------------------------

$isBatch = $rel -match '\|'
$relList = @(if ($isBatch) { $rel -split '\|' } else { $rel })

# For single-file mode, use the first (only) entry
$rel = $relList[0]

# ---------------------------------------------------------------------------
# Build output path (for single file; batch handled below)
# ---------------------------------------------------------------------------

$src     = Join-Path $repoRoot ($rel -replace "/","\\")
$outPath = Join-Path $archDir  (($rel -replace "/","\\") + ".md")
$outDir  = Split-Path $outPath -Parent
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$fence = Get-FenceLang $rel $defaultFence

# ---------------------------------------------------------------------------
# Build prompt payload — called with decreasing context on "too long" retries
#   $stage 0 = full content + headers (normal)
#   $stage 1 = full content, no headers
#   $stage 2 = aggressively truncated content (25% of maxFileLines), no headers
# ---------------------------------------------------------------------------

function Build-Payload($stage, $rel, $src, $repoRoot, $fence, $srcLines, $maxFileLines,
                       $bundleHeaders, $maxBundled, $defaultFence, $serenaContext,
                       $bundleHeaderDocs, $archDir, $outputBudget) {

    $lineCount = $srcLines.Count

    # Determine truncation limit for this stage
    $limit = switch ($stage) {
        0 { $maxFileLines }
        1 { $maxFileLines }
        2 { [math]::Max(100, [int]($maxFileLines * 0.25)) }
        default { $maxFileLines }
    }

    # Opt #3: Use LSP trimmed source for large files if available
    $usedTrimmed = $false
    if ($limit -gt 0 -and $lineCount -gt $limit -and $stage -le 1 -and $serenaContext -match '## Trimmed Source') {
        # Extract trimmed source from LSP context
        $trimMatch = [regex]::Match($serenaContext, '## Trimmed Source \(key sections only\)\s*```cpp\s*([\s\S]*?)```')
        if ($trimMatch.Success) {
            $content = $trimMatch.Groups[1].Value.Trim()
            $content = "/* LSP-TRIMMED: key sections from $lineCount total lines */`n$content"
            $usedTrimmed = $true
        }
    }

    if (-not $usedTrimmed) {
        if ($limit -gt 0 -and $lineCount -gt $limit) {
            $half      = [int]($limit / 2)
            $head      = $srcLines | Select-Object -First $half
            $tail      = $srcLines | Select-Object -Last  $half
            $truncNote = "/* ... TRUNCATED: showing first $half and last $half of $lineCount lines ... */"
            $content   = ($head -join "`n") + "`n`n" + $truncNote + "`n`n" + ($tail -join "`n")
        } else {
            $content = $srcLines -join "`n"
        }
    }

    # Opt v3#5: Load shared directory headers if available
    $headerSection = ""
    if ($stage -eq 0 -and $sharedHeaderDir -ne "") {
        $relDir = Split-Path $rel -Parent
        $sharedPath = Join-Path $sharedHeaderDir (($relDir -replace '/','\') + '.headers.txt')
        if (Test-Path $sharedPath) {
            $sharedContent = Get-Content $sharedPath -Raw -ErrorAction SilentlyContinue
            if ($sharedContent) {
                $headerSection = "`nSHARED DIRECTORY HEADERS:`n$sharedContent"
            }
        }
    }

    # Bundle per-file unique headers at stage 0
    if ($stage -eq 0 -and $bundleHeaders -eq "1") {
        $srcDir     = Split-Path $src -Parent
        $rawContent = Get-Content $src -ErrorAction SilentlyContinue
        $incs       = @()
        if ($rawContent) {
            $incPat = [System.Text.RegularExpressions.Regex]::new("#\s*include\s+`"([^`"]+)`"")
            $incs = $rawContent | ForEach-Object {
                $m = $incPat.Match($_)
                if ($m.Success) { $m.Groups[1].Value }
            } | Where-Object { $_ } | Select-Object -First 20
        }

        $hdrCount = 0
        foreach ($inc in $incs) {
            if ($hdrCount -ge $maxBundled) { break }
            $candidates = @((Join-Path $srcDir $inc), (Join-Path $repoRoot $inc))
            $resolved = $null
            foreach ($c in $candidates) { if (Test-Path $c) { $resolved = $c; break } }
            if (-not $resolved) {
                $leaf     = Split-Path $inc -Leaf
                $resolved = Get-ChildItem -Path $repoRoot -Filter $leaf -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
                            Select-Object -First 1 -ExpandProperty FullName
            }
            if ($resolved -and (Test-Path $resolved)) {
                $localPath  = $resolved.Substring($repoRoot.Length).TrimStart("\").TrimStart("/") -replace "\\","/"
                # Opt #2: Bundle header doc instead of raw source if available
                $hdrDocPath = Join-Path $archDir (($localPath -replace "/","\\") + ".md")
                if ($bundleHeaderDocs -eq "1" -and (Test-Path $hdrDocPath)) {
                    $hdrContent = Get-Content $hdrDocPath -Raw -ErrorAction SilentlyContinue
                    if ($hdrContent) {
                        $headerSection += "`n--- $localPath (analyzed doc) ---`n$hdrContent"
                        $hdrCount++
                        continue
                    }
                }
                # Fall back to raw header content
                $hdrFence   = Get-FenceLang $localPath $defaultFence
                $hdrContent = Get-Content $resolved -Raw -ErrorAction SilentlyContinue
                if (-not $hdrContent) { $hdrContent = "" }
                $headerSection += "`n--- $localPath ---`n``````$hdrFence`n$hdrContent`n``````"
                $hdrCount++
            }
        }
        if ($hdrCount -gt 0) {
            $headerSection = "`nBUNDLED HEADERS (included for context):`n" + $headerSection
        }
    }

    # Inject Serena LSP context at stages 0 and 1 (drop at stage 2 for truncation)
    $lspSection = ""
    if ($stage -le 1 -and $serenaContext -ne "") {
        $lspSection = "`n`nLSP ANALYSIS CONTEXT:`n$serenaContext`n"
    }

    # Opt v2#5: Source elision — skip FILE CONTENT when LSP context has symbols + trimmed source
    if ($elideSource -eq "1" -and $stage -le 1 -and $serenaContext -match '## Symbol Overview' -and $serenaContext -match '## Trimmed Source') {
        $content = "/* Full source elided - see LSP context for symbols and key sections ($lineCount lines total) */"
    }

    # Opt v2#2: Inject engine knowledge preamble
    $preambleSection = ""
    if ($preambleContent -ne "") {
        $preambleSection = "ENGINE CONVENTIONS:`n$preambleContent`n`n"
    }

    # Opt v3#2: Inject directory-level architectural context
    $dirSection = ""
    if ($dirContextDir -ne "") {
        $relDir = Split-Path $rel -Parent
        $dirCtxPath = Join-Path $dirContextDir (($relDir -replace '/','\') + '.dir.md')
        if (Test-Path $dirCtxPath) {
            $dirCtx = Get-Content $dirCtxPath -Raw -ErrorAction SilentlyContinue
            if ($dirCtx) { $dirSection = "`n`nDIRECTORY CONTEXT:`n$dirCtx`n" }
        }
    }

    # Load the prompt schema into the user message (for prompt caching — keeps system prompt fixed)
    $schemaSection = ""
    if (Test-Path $promptFile) {
        $schemaSection = (Get-Content $promptFile -Raw -ErrorAction SilentlyContinue)
        if ($schemaSection) { $schemaSection = "OUTPUT SCHEMA:`n$schemaSection`n`n" }
        else { $schemaSection = "" }
    }

    # Opt #8: Append output budget instruction
    $budgetLine = "`n`nOUTPUT BUDGET: $outputBudget"

    return "${preambleSection}${schemaSection}FILE PATH (relative): $rel`n$dirSection$lspSection`nFILE CONTENT:`n``````$fence`n$content`n``````$headerSection$budgetLine"
}

# ---------------------------------------------------------------------------
# Load source lines once — Build-Payload uses them at each stage
# ---------------------------------------------------------------------------

$srcLines = Get-Content $src -ErrorAction SilentlyContinue
if (-not $srcLines) { $srcLines = @() }

# ---------------------------------------------------------------------------
# Load Serena LSP context if available
# ---------------------------------------------------------------------------

$serenaContext = ""
if ($serenaContextDir -ne "") {
    $serenaPath = Join-Path $serenaContextDir (($rel -replace "/","\\") + ".serena_context.txt")
    if (Test-Path $serenaPath) {
        $serenaContext = Get-Content $serenaPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $serenaContext) { $serenaContext = "" }
    }
}

# ---------------------------------------------------------------------------
# Shared rate-limit resume file path
# ---------------------------------------------------------------------------

$rateLimitFile = Join-Path (Split-Path $errorLog -Parent) "ratelimit_resume.txt"

# ---------------------------------------------------------------------------
# Call Claude - retry loop with staged fallback for "prompt too long"
# ---------------------------------------------------------------------------

$attempt  = 0
$stage    = 0          # 0=full+headers, 1=full no headers, 2=truncated no headers
$success  = $false
$maxStage = 2

while ($true) {
    if (Test-Path $fatalFlag) { exit 0 }

    # Honour a rate-limit pause set by any thread
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

    if ($isBatch) {
        # Opt v2#1: Build multi-file batch payload
        $preambleSection = ""
        if ($preambleContent -ne "") {
            $preambleSection = "ENGINE CONVENTIONS:`n$preambleContent`n`n"
        }
        # Load schema for batch payload (prompt caching — schema in user message)
        $batchSchema = ""
        if (Test-Path $promptFile) {
            $batchSchema = Get-Content $promptFile -Raw -ErrorAction SilentlyContinue
            if ($batchSchema) { $batchSchema = "OUTPUT SCHEMA:`n$batchSchema`n`n" }
            else { $batchSchema = "" }
        }
        $batchPayload = "${preambleSection}${batchSchema}Analyze each file separately. Output one doc per file using the schema.`nSeparate each doc with a line containing ONLY: === END FILE ===`n`n"
        $fileNum = 1
        foreach ($bRel in $relList) {
            $bSrc   = Join-Path $repoRoot ($bRel -replace "/","\\")
            $bFence = Get-FenceLang $bRel $defaultFence
            $bLines = @(Get-Content $bSrc -ErrorAction SilentlyContinue)
            $bContent = $bLines -join "`n"
            # Load LSP context if available
            $bLsp = ""
            if ($serenaContextDir -ne "") {
                $bCtxPath = Join-Path $serenaContextDir (($bRel -replace "/","\\") + ".serena_context.txt")
                if (Test-Path $bCtxPath) {
                    $bLsp = Get-Content $bCtxPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not $bLsp) { $bLsp = "" }
                }
            }
            $bLspSection = if ($bLsp -ne "") { "`nLSP CONTEXT:`n$bLsp`n" } else { "" }
            $batchPayload += "FILE $fileNum PATH: $bRel`n$bLspSection`nFILE $fileNum CONTENT:`n``````$bFence`n$bContent`n```````n`n"
            $fileNum++
        }
        $batchPayload += "OUTPUT BUDGET: ~200 tokens per file"
        $payload = $batchPayload
    } else {
        $payload = Build-Payload $stage $rel $src $repoRoot $fence $srcLines $maxFileLines `
                                 $bundleHeaders $maxBundled $defaultFence $serenaContext `
                                 $bundleHeaderDocs $archDir $outputBudget
    }

    # Opt v3#4: JSON output format
    $fmtArg = if ($jsonOutput -eq "1") { 'json' } else { $outputFmt }

    try {
        # Opt v4#4: Use fixed system prompt for prompt caching
        # The per-file schema is now in the user message (payload)
        $sysPromptFile = Join-Path (Split-Path $promptFile -Parent) 'file_doc_system_prompt.txt'
        if (-not (Test-Path $sysPromptFile)) { $sysPromptFile = $promptFile }
        if ($llmBackend -eq 'claude') {
            $env:CLAUDE_CONFIG_DIR = $claudeCfgDir
            $claudeArgs = @('-p', '--model', $model, '--max-turns', $maxTurns,
                            '--output-format', $fmtArg,
                            '--append-system-prompt-file', $sysPromptFile)
            # Opt v3#1: Hard output cap
            if ([int]$maxOutputTokens -gt 0) {
                $claudeArgs += @('--max-tokens', $maxOutputTokens)
            }
            $resp = $payload | & claude @claudeArgs 2>&1
            $exitCode = $LASTEXITCODE
        } else {
            # Local LLM (vLLM gateway / Ollama) via LLMConfig
            $localMax  = if ([int]$maxOutputTokens -gt 0) { [int]$maxOutputTokens } else { $llmMaxTokens }
            $sysPrompt = Get-Content $sysPromptFile -Raw -Encoding UTF8
            $resp = Invoke-LocalLLM -SystemPrompt $sysPrompt -UserPrompt $payload `
                -Backend $llmBackend -Endpoint $llmEndpoint -Model $llmModel `
                -Temperature $llmTemp -MaxTokens $localMax -Timeout $llmTimeout -NumCtx $llmNumCtx -Think $llmThink
            $exitCode = 0
        }
    } catch {
        $resp     = $_.Exception.Message
        $exitCode = 1
    }

    $respText = if ($resp -is [array]) { $resp -join "`n" } else { [string]$resp }

    # Success
    if ($exitCode -eq 0 -and -not (Test-RateLimit $respText)) {
        $success = $true
        break
    }

    # Prompt too long — degrade context and retry immediately (no attempt increment).
    # Local backends (ollama/vllm) signal an oversized/overwhelming prompt several ways:
    # a 400/"context length" error (overflow), OR empty/short/thinking-exhausted output
    # when a huge prompt (e.g. file + many bundled headers) drives the model to emit
    # nothing. Treat all of these like "too long" -> drop headers, then truncate, instead
    # of fatal-aborting the run. (A genuinely small file that still fails will exhaust all
    # stages and fail as before.)
    $localTooLong = ($llmBackend -ne 'claude') -and ($exitCode -ne 0) -and ($respText -match '400|context length|maximum context|context window|exceed|too long|too large|exhausted budget|[Ee]mpty response|suspiciously short')
    if ((Test-TooLong $respText) -or $localTooLong) {
        $stage++
        if ($stage -le $maxStage) {
            $stageLabel = switch ($stage) {
                1 { "dropping headers" }
                2 { "aggressively truncating content" }
            }
            Write-Host "  [too-long] $rel -- $stageLabel (stage $stage)" -ForegroundColor DarkCyan
            continue
        }
        # All stages exhausted — log and fail
        $errEntry = "====`nTimestamp: $(Get-Date -Format u)`nFile: $rel`nType: TOO_LONG (all $maxStage stages exhausted)`n----`n$respText`n"
        [System.IO.File]::AppendAllText($errorLog, $errEntry)
        "Prompt too long after all fallback stages: $rel" | Set-Content $fatalMsg -Encoding UTF8
        "fatal" | Set-Content $fatalFlag -Encoding UTF8
        Update-Counter $counterPath "fail"
        exit 1
    }

    # Rate limit
    if (Test-RateLimit $respText) {
        $errEntry = "====`nTimestamp: $(Get-Date -Format u)`nFile: $rel`nType: RATE_LIMIT`n----`n$respText`n"
        [System.IO.File]::AppendAllText($errorLog, $errEntry)

        $resetTime  = Get-RateLimitResetTime $respText
        $resumeTime = if ($resetTime) { $resetTime.AddMinutes(10) } else { [datetime]::Now.AddMinutes(70) }
        $resetStr   = if ($resetTime) { Format-LocalTime $resetTime } else { "unknown" }
        $resumeStr  = Format-LocalTime $resumeTime

        Write-Host ""
        Write-Host "  [rate-limit] You've hit your limit, resets at $resetStr. Thread paused till $resumeStr." -ForegroundColor Yellow
        Write-Host ""

        $resumeTime.ToString("o") | Set-Content $rateLimitFile -Encoding UTF8
        Wait-UntilResumeTime $resumeTime $rel
        Remove-Item $rateLimitFile -ErrorAction SilentlyContinue
        $attempt = 0
        continue
    }

    # Transient failure — retry up to maxRetries, then fatal
    $attempt++
    if ($attempt -le $maxRetries) {
        Update-Counter $counterPath "retries"
        Start-Sleep -Seconds $retryDelay
        continue
    }

    $errEntry = "====`nTimestamp: $(Get-Date -Format u)`nFile: $rel`nExit: $exitCode`nType: PERSISTENT_FAILURE`n----`n$respText`n"
    [System.IO.File]::AppendAllText($errorLog, $errEntry)
    "Claude failed after $attempt attempts on: $rel" | Set-Content $fatalMsg -Encoding UTF8
    "fatal" | Set-Content $fatalFlag -Encoding UTF8
    Update-Counter $counterPath "fail"
    exit 1
}
# Write output and record hash
# ---------------------------------------------------------------------------

if ($success -and -not $isBatch) {
    try {
        $respText | Set-Content -Path $outPath -Encoding UTF8
    } catch {
        $errMsg = "WRITE_FAIL: $outPath -- $($_.Exception.Message)"
        [System.IO.File]::AppendAllText($errorLog, "$errMsg`n")
    }

    $sha     = [System.Security.Cryptography.SHA1]::Create()
    $bytes   = [System.IO.File]::ReadAllBytes($src)
    $hashStr = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    $line    = "$hashStr`t$rel"
    [System.IO.File]::AppendAllText($hashDbPath, $line + "`n")

    Update-Counter $counterPath "done"
}

# ---------------------------------------------------------------------------
# Opt v2#1: Batch mode — split response into individual docs
# ---------------------------------------------------------------------------

if ($success -and $isBatch) {
    # Split response on the separator marker
    $docs = $respText -split '=== END FILE ==='

    for ($i = 0; $i -lt $relList.Count; $i++) {
        $batchRel = $relList[$i]
        $batchSrc = Join-Path $repoRoot ($batchRel -replace "/","\\")
        $batchOut = Join-Path $archDir  (($batchRel -replace "/","\\") + ".md")
        $batchDir = Split-Path $batchOut -Parent
        New-Item -ItemType Directory -Force -Path $batchDir | Out-Null

        $doc = if ($i -lt $docs.Count) { $docs[$i].Trim() } else { "# $batchRel`n`n## File Purpose`nAnalysis not available (batch split error).`n" }

        # Write doc
        $doc | Set-Content -Path $batchOut -Encoding UTF8

        # Record hash
        if (Test-Path $batchSrc) {
            $sha     = [System.Security.Cryptography.SHA1]::Create()
            $bytes   = [System.IO.File]::ReadAllBytes($batchSrc)
            $hashStr = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
            [System.IO.File]::AppendAllText($hashDbPath, "$hashStr`t$batchRel`n")
        }

        Update-Counter $counterPath "done"
    }
}
