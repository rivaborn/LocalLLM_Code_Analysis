# Golden regression gate for the extraction stage.
#
# Re-extracts tests\fixtures\cpp with the current serena_extract.py and
# compares every *.serena_context.txt byte-for-byte against the committed
# golden output in tests\golden\cpp. Any diff = regression in the cpp path.
#
# Usage (from the toolkit repo root):
#   powershell -NoProfile -File tests\run_golden_gate.ps1
#   ... -ExtraArgs '--profile','cpp'     # exercise new CLI paths
#
# The fixture's compile_commands.json is machine-specific and regenerated
# on every run. The clangd background index (fixture .cache\) is warmed
# with a throwaway extraction the first time so reference queries are
# deterministic.

param(
    [string]$ClangdPath = '',
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'
# powershell -File can't bind arrays; accept space-joined entries too
# (-ExtraArgs '--profile cpp').
$ExtraArgs = @($ExtraArgs | ForEach-Object { "$_" -split ' ' } | Where-Object { $_ -ne '' })
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $repo 'tests\fixtures\cpp'
$golden = Join-Path $repo 'tests\golden\cpp'
$py = Join-Path $repo 'llm_scripts\serena_extract.py'

if ($ClangdPath -eq '') {
    $found = @(Get-ChildItem -Path (Join-Path $repo '.tools') -Filter clangd.exe -Recurse -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) {
        $onPath = Get-Command clangd -ErrorAction SilentlyContinue
        if ($null -eq $onPath) {
            Write-Host 'GATE SKIP: no clangd found (.tools\ or PATH)' -ForegroundColor Yellow
            exit 3
        }
        $ClangdPath = $onPath.Source
    } else {
        $ClangdPath = $found[0].FullName
    }
}

Write-Host "[gate] clangd: $ClangdPath"
& python (Join-Path $fixture 'gen_compile_commands.py') | Out-Null

$out = Join-Path $env:TEMP ("golden_gate_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $out | Out-Null

try {
    # Warm the background index once if the fixture cache is cold.
    if (-not (Test-Path (Join-Path $fixture '.cache\clangd\index'))) {
        Write-Host '[gate] warming clangd background index...'
        & python $py --repo-root $fixture --output-dir (Join-Path $out 'warm') `
            --clangd-path $ClangdPath --workers 1 --jobs 2 --force @ExtraArgs | Out-Null
    }

    & python $py --repo-root $fixture --output-dir (Join-Path $out 'run') `
        --clangd-path $ClangdPath --workers 1 --jobs 2 --force @ExtraArgs | Out-Null

    $fail = 0
    $goldenFiles = @(Get-ChildItem -Path $golden -Filter '*.serena_context.txt' -Recurse)
    foreach ($gf in $goldenFiles) {
        $rel = $gf.FullName.Substring($golden.Length + 1)
        $nf = Join-Path (Join-Path $out 'run') $rel
        if (-not (Test-Path $nf)) {
            Write-Host "GATE FAIL: missing output $rel" -ForegroundColor Red
            $fail = 1
            continue
        }
        $a = Get-Content -Raw $gf.FullName
        $b = Get-Content -Raw $nf
        if ($a -ne $b) {
            Write-Host "GATE FAIL: $rel differs from golden" -ForegroundColor Red
            & git --no-pager diff --no-index $gf.FullName $nf
            $fail = 1
        }
    }
    $newFiles = @(Get-ChildItem -Path (Join-Path $out 'run') -Filter '*.serena_context.txt' -Recurse)
    if ($newFiles.Count -ne $goldenFiles.Count) {
        Write-Host ("GATE FAIL: file count mismatch (golden {0}, new {1})" -f $goldenFiles.Count, $newFiles.Count) -ForegroundColor Red
        $fail = 1
    }

    if ($fail -eq 0) {
        Write-Host ("GATE PASS: {0} context files byte-identical to golden" -f $goldenFiles.Count) -ForegroundColor Green
        exit 0
    }
    exit 1
} finally {
    Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
}
