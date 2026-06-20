#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# archgen.sh — File-Level Architecture Doc Generator
#
# Generates one .md doc per source file for any game engine codebase.
#
# Features:
# - Header bundling: #include directives are resolved and local
#   headers are sent alongside the source file for better analysis
# - Deterministic output (stable file ordering, consistent headers)
# - Resumable + skip unchanged (sha1 DB)
# - Parallelism (xargs -P) — default JOBS=2 for WSL stability
# - Per-file retry on transient failures (segfault, signal)
# - Fail-fast on confirmed rate limit / quota error
# - Progress reporting with ETA
# - Multi-account support (default: account #2, --claude1 for #1)
# - Presets for common engines (quake, doom, unreal, godot, unity)
# - Auto-detects code fence language from file extension
#
# Privacy:
# - No personal identifiers in this script.
# - Account config dirs set via .env (not committed to git).
# ============================================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need find
need sort
need sed
need grep
need sha1sum
need wc
need ps
need xargs
need flock
need claude

# Save any command-line overrides before sourcing .env
_CLI_JOBS="${JOBS:-}"

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

# Restore command-line overrides (they take priority over .env)
[[ -n "$_CLI_JOBS" ]] && JOBS="$_CLI_JOBS"

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ARCH_DIR="${ARCH_DIR:-$REPO_ROOT/architecture}"
STATE_DIR="$ARCH_DIR/.archgen_state"
mkdir -p "$ARCH_DIR" "$STATE_DIR"

MODEL="${CLAUDE_MODEL:-sonnet}"
MAX_TURNS="${CLAUDE_MAX_TURNS:-1}"
OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-text}"

JOBS="${JOBS:-2}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-1}"

MAX_RETRIES="${MAX_RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# Header bundling: include local headers alongside source files
# Set to 0 to disable, or limit max headers per file
BUNDLE_HEADERS="${BUNDLE_HEADERS:-1}"
MAX_BUNDLED_HEADERS="${MAX_BUNDLED_HEADERS:-5}"

# Maximum lines to send per source file. Files larger than this are truncated
# with a notice to Claude. 0 = no limit. Prevents "Prompt is too long" errors
# on monster files like Shadow Warrior's weapon.c (22,000+ lines).
MAX_FILE_LINES="${MAX_FILE_LINES:-4000}"

# ── Presets ──
PRESET="${PRESET:-}"

apply_preset() {
  case "$1" in
    quake|quake2|quake3|doom|idtech)
      _PRESET_INCLUDE='.*\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
      _PRESET_EXCLUDE='/(\.git|architecture|build|out|dist|obj|bin|Debug|Release|x64|Win32|\.vs|\.vscode|\.idea|\.cache|baseq2|baseq3|base|pak[0-9]|__MACOSX)/'
      _PRESET_DESC="C game engine codebase (id Software / Quake-family)"
      _PRESET_FENCE="c"
      ;;
    unreal|ue4|ue5)
      _PRESET_INCLUDE='.*\.(cpp|h|hpp|cc|cxx|inl|cs)$'
      _PRESET_EXCLUDE='/(\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|\.vscode|\.idea|ThirdParty|Plugins\/Runtime|GeneratedFiles|AutomationTool)/'
      _PRESET_DESC="Unreal Engine C++/C# source (Epic Games). Large-scale game engine: Core (memory/containers/math/logging), CoreUObject (UObject reflection/GC/CDO), Engine (actors/components/world), Renderer (deferred shading, RHI abstraction over D3D12/Vulkan/Metal), PhysicsCore/Chaos, AudioMixerCore, AIModule, GameplayAbilities (GAS), Slate/UMG UI, NetworkCore (replication/RPCs). UHT generates reflection code. Blueprint VM, delegates, TWeakObjectPtr, FName/FText/FString, UBT build system."
      _PRESET_FENCE="cpp"
      ;;
    godot)
      _PRESET_INCLUDE='.*\.(cpp|h|hpp|c|cc|gd|gdscript|tscn|tres|cs)$'
      _PRESET_EXCLUDE='/(\.git|architecture|\.godot|\.import|build|export|addons\/[^\/]+\/bin|__MACOSX)/'
      _PRESET_DESC="Godot engine codebase (C++/GDScript/C#)"
      _PRESET_FENCE="cpp"
      ;;
    unity)
      _PRESET_INCLUDE='.*\.(cs|shader|cginc|hlsl|compute|glsl|cpp|c|h|mm|m)$'
      _PRESET_EXCLUDE='/(\.git|architecture|Library|Temp|Obj|Build|Builds|Logs|UserSettings|\.vs|\.vscode|Packages\/com\.unity|__MACOSX)/'
      _PRESET_DESC="Unity game codebase (C#/shader)"
      _PRESET_FENCE="csharp"
      ;;
    source|valve)
      _PRESET_INCLUDE='.*\.(cpp|h|hpp|c|cc|cxx|inl|inc|vpc|vgc)$'
      _PRESET_EXCLUDE='/(\.git|architecture|build|out|obj|bin|Debug|Release|lib|thirdparty|__MACOSX)/'
      _PRESET_DESC="Source Engine codebase (Valve / C++)"
      _PRESET_FENCE="cpp"
      ;;
    rust)
      _PRESET_INCLUDE='.*\.(rs|toml)$'
      _PRESET_EXCLUDE='/(\.git|architecture|target|\.cargo|__MACOSX)/'
      _PRESET_DESC="Rust game engine codebase"
      _PRESET_FENCE="rust"
      ;;
    "")
      _PRESET_INCLUDE='.*\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc|cs|java|py|rs|lua|gd|gdscript|m|mm|swift)$'
      _PRESET_EXCLUDE='/(\.git|architecture|build|out|dist|obj|bin|Debug|Release|x64|Win32|\.vs|\.vscode|\.idea|\.cache|__MACOSX|node_modules|\.godot|Library|Temp)/'
      _PRESET_DESC="game engine / game codebase"
      _PRESET_FENCE="c"
      ;;
    *)
      echo "Unknown preset: $1" >&2
      echo "Available: quake, doom, unreal, godot, unity, source, rust" >&2
      exit 2
      ;;
  esac
}

apply_preset "$PRESET"

INCLUDE_EXT_REGEX="${INCLUDE_EXT_REGEX:-$_PRESET_INCLUDE}"
EXCLUDE_DIRS_REGEX="${EXCLUDE_DIRS_REGEX:-$_PRESET_EXCLUDE}"
EXTRA_EXCLUDE_REGEX="${EXTRA_EXCLUDE_REGEX:-}"
CODEBASE_DESC="${CODEBASE_DESC:-$_PRESET_DESC}"
DEFAULT_FENCE="${DEFAULT_FENCE:-$_PRESET_FENCE}"

PROMPT_FILE="${PROMPT_FILE:-$REPO_ROOT/file_doc_prompt.txt}"
[[ -f "$PROMPT_FILE" ]] || { echo "Missing prompt file: $PROMPT_FILE" >&2; exit 2; }

ACCOUNT="claude2"
TARGET_DIR="."
CLEAN="0"

usage() {
  cat <<'EOF'
Usage:
  ./archgen.sh [<target_dir>] [--preset <n>] [--claude1] [--clean] [--no-headers]

Presets:
  quake, doom     — C (id Software / Quake-family engines)
  unreal          — C++/C# (Unreal Engine 4/5)
  godot           — C++/GDScript/C# (Godot)
  unity           — C#/shaders (Unity)
  source          — C++ (Source Engine / Valve)
  rust            — Rust game engines (Bevy, etc.)
  (none)          — Broad default

Options:
  --no-headers    Disable header bundling (send source files alone)

Examples:
  ./archgen.sh --preset quake
  ./archgen.sh client --preset unreal
  JOBS=4 ./archgen.sh --preset godot
  ./archgen.sh --no-headers
  ./archgen.sh --clean
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --claude1)     ACCOUNT="claude1"; shift ;;
    --clean)       CLEAN="1"; shift ;;
    --no-headers)  BUNDLE_HEADERS="0"; shift ;;
    --preset)
      [[ $# -ge 2 ]] || { echo "--preset requires a value" >&2; exit 2; }
      PRESET="$2"
      apply_preset "$PRESET"
      INCLUDE_EXT_REGEX="${INCLUDE_EXT_REGEX_FROM_ENV:-$_PRESET_INCLUDE}"
      EXCLUDE_DIRS_REGEX="${EXCLUDE_DIRS_REGEX_FROM_ENV:-$_PRESET_EXCLUDE}"
      CODEBASE_DESC="${CODEBASE_DESC_FROM_ENV:-$_PRESET_DESC}"
      DEFAULT_FENCE="${DEFAULT_FENCE_FROM_ENV:-$_PRESET_FENCE}"
      shift 2
      ;;
    *)
      TARGET_DIR="$1"; shift ;;
  esac
done

# Resolve config dir
if [[ "$ACCOUNT" == "claude1" ]]; then
  CLAUDE_CONFIG_DIR="${CLAUDE1_CONFIG_DIR:-}"
else
  CLAUDE_CONFIG_DIR="${CLAUDE2_CONFIG_DIR:-}"
fi
if [[ -z "${CLAUDE_CONFIG_DIR:-}" && -n "${CLAUDE_CONFIG_DIRS:-}" ]]; then
  IFS=':' read -r dir1 dir2 _rest <<< "$CLAUDE_CONFIG_DIRS"
  if [[ "$ACCOUNT" == "claude1" ]]; then CLAUDE_CONFIG_DIR="$dir1"; else CLAUDE_CONFIG_DIR="$dir2"; fi
fi
[[ -n "${CLAUDE_CONFIG_DIR:-}" ]] || {
  echo "Missing Claude config dir for $ACCOUNT." >&2
  echo "Set CLAUDE1_CONFIG_DIR / CLAUDE2_CONFIG_DIR in .env" >&2
  exit 2
}
CLAUDE_CONFIG_DIR="$(eval echo "$CLAUDE_CONFIG_DIR")"
[[ -d "$CLAUDE_CONFIG_DIR" ]] || {
  echo "Claude config dir does not exist: $CLAUDE_CONFIG_DIR" >&2
  exit 2
}

LOCK="$STATE_DIR/lock"
PROGRESS_TXT="$STATE_DIR/progress.txt"
COUNT_FILE="$STATE_DIR/counts"
HASH_DB="$STATE_DIR/hashes.tsv"
ERROR_LOG="$STATE_DIR/last_claude_error.log"
FATAL_FLAG="$STATE_DIR/fatal.flag"
FATAL_MSG="$STATE_DIR/fatal.msg"

: > "$LOCK"
: > "$ERROR_LOG"
rm -f "$FATAL_FLAG" "$FATAL_MSG"
: > "$PROGRESS_TXT"
touch "$HASH_DB"

if [[ "$CLEAN" == "1" ]]; then
  echo "CLEAN: removing $ARCH_DIR (including state)..." >&2
  rm -rf "$ARCH_DIR"
  mkdir -p "$ARCH_DIR" "$STATE_DIR"
  : > "$LOCK"
  : > "$ERROR_LOG"
  rm -f "$FATAL_FLAG" "$FATAL_MSG"
  : > "$PROGRESS_TXT"
fi

declare -A OLD_SHA
if [[ -f "$HASH_DB" ]]; then
  while IFS=$'\t' read -r sha rel; do
    [[ -n "${rel:-}" ]] && OLD_SHA["$rel"]="$sha"
  done < "$HASH_DB"
fi

mapfile -t ALL_FILES < <(
  cd "$REPO_ROOT"
  find "$TARGET_DIR" -type f \
    ! -path "./architecture/*" \
    ! -path "*/architecture/*" \
    ! -name "*.ignore" \
    2>/dev/null \
    | sed 's|^\./||' \
    | sort
)

FILES=()
for rel in "${ALL_FILES[@]}"; do
  [[ "$rel" =~ $EXCLUDE_DIRS_REGEX ]] && continue
  [[ -n "$EXTRA_EXCLUDE_REGEX" && "$rel" =~ $EXTRA_EXCLUDE_REGEX ]] && continue
  [[ "$rel" =~ $INCLUDE_EXT_REGEX ]] || continue
  FILES+=("$rel")
done

TOTAL="${#FILES[@]}"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No matching source files under '$TARGET_DIR'" >&2
  echo "  INCLUDE_EXT_REGEX=$INCLUDE_EXT_REGEX" >&2
  exit 1
fi

QUEUE=()
SKIP_UNCHANGED=0
for rel in "${FILES[@]}"; do
  src="$REPO_ROOT/$rel"
  out="$ARCH_DIR/$rel.md"
  sha="$(sha1sum "$src" | awk '{print $1}')"
  old="${OLD_SHA[$rel]:-}"
  if [[ -n "$old" && "$old" == "$sha" && -f "$out" ]]; then
    SKIP_UNCHANGED=$((SKIP_UNCHANGED+1))
    continue
  fi
  QUEUE+=("$rel")
done
TO_DO="${#QUEUE[@]}"

echo "============================================"
echo "  archgen.sh — Architecture Doc Generator"
echo "============================================"
echo "Repo root:       $REPO_ROOT"
echo "Codebase:        $CODEBASE_DESC"
[[ -n "$PRESET" ]] && echo "Preset:          $PRESET"
echo "Target:          $TARGET_DIR"
echo "Account:         $ACCOUNT"
echo "Model:           $MODEL"
echo "Jobs:            $JOBS"
echo "Max retries:     $MAX_RETRIES (delay: ${RETRY_DELAY}s)"
echo "Header bundling: $(if [[ "$BUNDLE_HEADERS" == "1" ]]; then echo "ON (max $MAX_BUNDLED_HEADERS per file)"; else echo "OFF"; fi)"
echo "Max file lines:  $(if [[ "$MAX_FILE_LINES" -gt 0 ]]; then echo "$MAX_FILE_LINES (truncates larger files)"; else echo "unlimited"; fi)"
echo "Files:           $TOTAL (unchanged skipped: $SKIP_UNCHANGED, to process: $TO_DO)"
echo "Prompt:          $PROMPT_FILE"
echo "Progress:        $PROGRESS_TXT"
echo "Errors:          $ERROR_LOG"
echo

if [[ "$TO_DO" -eq 0 ]]; then
  echo "Nothing to do. All docs are up to date."
  exit 0
fi

cat > "$COUNT_FILE" <<EOF
done=0
fail=0
skip=$SKIP_UNCHANGED
total=$TOTAL
todo=$TO_DO
retries=0
EOF

PROGRESS_PID=""
cleanup() {
  echo >&2
  echo "Interrupted." >&2
  echo "Interrupted (signal)." > "$FATAL_MSG"
  : > "$FATAL_FLAG"
  [[ -n "$PROGRESS_PID" ]] && kill "$PROGRESS_PID" 2>/dev/null || true
  kill -- -$$ 2>/dev/null || kill 0 2>/dev/null || true
  exit 1
}
trap cleanup INT TERM

start_ts="$(date +%s)"

progress_tick() {
  local done_n total_n todo_n skip_n fail_n retries_n now elapsed rate eta remaining eta_sec
  flock "$LOCK" cat "$COUNT_FILE" > "$STATE_DIR/counts.snapshot" 2>/dev/null || return
  source "$STATE_DIR/counts.snapshot" 2>/dev/null || return
  done_n="${done:-0}"; total_n="${total:-0}"; todo_n="${todo:-0}"
  skip_n="${skip:-0}"; fail_n="${fail:-0}"; retries_n="${retries:-0}"
  now="$(date +%s)"
  elapsed=$((now - start_ts))
  if [[ "$elapsed" -le 0 ]]; then elapsed=1; fi
  rate="0.0"; eta="--"
  if [[ "$done_n" -gt 0 ]]; then
    rate="$(awk -v d="$done_n" -v e="$elapsed" 'BEGIN{printf "%.2f", d/e}')"
    remaining=$((todo_n - done_n))
    if [[ "$remaining" -lt 0 ]]; then remaining=0; fi
    eta_sec=$(( remaining * elapsed / done_n ))
    eta="${eta_sec}s"
  fi
  local retry_info=""
  if [[ "$retries_n" -gt 0 ]]; then retry_info="  retries=$retries_n"; fi
  local line="PROGRESS: $done_n/$todo_n done  skip=$skip_n  fail=$fail_n${retry_info}  rate=${rate}/s  eta=$eta"
  printf "\r%-80s" "$line" >&2
  echo "$line" > "$PROGRESS_TXT"
}

(
  while true; do
    [[ -f "$FATAL_FLAG" ]] && exit 0
    progress_tick
    sleep "$PROGRESS_INTERVAL"
  done
) &
PROGRESS_PID=$!
disown "$PROGRESS_PID" 2>/dev/null || true

# ── Worker script ──
WORKER_SCRIPT="$STATE_DIR/worker.sh"
cat > "$WORKER_SCRIPT" << 'WORKEREOF'
#!/usr/bin/env bash
set -euo pipefail

rel="$1"
REPO_ROOT="$2"
ARCH_DIR="$3"
STATE_DIR="$4"
LOCK="$5"
COUNT_FILE="$6"
ERROR_LOG="$7"
FATAL_FLAG="$8"
FATAL_MSG="$9"
MODEL="${10}"
MAX_TURNS="${11}"
OUTPUT_FORMAT="${12}"
PROMPT_FILE="${13}"
CLAUDE_CONFIG_DIR="${14}"
MAX_RETRIES="${15}"
RETRY_DELAY="${16}"
DEFAULT_FENCE="${17}"
BUNDLE_HEADERS="${18}"
MAX_BUNDLED_HEADERS="${19}"
HASH_DB="${20}"
MAX_FILE_LINES="${21}"

bump_count() {
  local field="$1"
  flock "$LOCK" bash -c "
    awk -F= 'BEGIN{OFS=FS} \$1==\"$field\"{ \$2=\$2+1 } {print}' '$COUNT_FILE' > '${COUNT_FILE}.tmp' \
      && mv '${COUNT_FILE}.tmp' '$COUNT_FILE'
  " 2>/dev/null || true
}

is_rate_limit() {
  local text="$1"
  local first3
  first3="$(echo "$text" | head -3)"
  echo "$first3" | grep -qE '^#' && return 1
  echo "$first3" | grep -qiE '(^|[^0-9])429([^0-9]|$)' && return 0
  echo "$first3" | grep -qiE 'rate.?limit|usage.?limit|too many requests' && return 0
  echo "$first3" | grep -qiE '^error:.*overloaded|^error:.*quota' && return 0
  return 1
}

# Parse an ISO-8601 or human-readable reset timestamp from Claude's error text.
# Prints a Unix epoch integer, or empty string if not found.
parse_reset_epoch() {
  local text="$1"
  local ts=""

  # Pattern 1: ISO 8601 — "resets at 2024-01-15T13:00:00Z"
  ts="$(echo "$text" | grep -oiP 'resets?\s+at\s+\K\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?' | head -1)"
  if [[ -n "$ts" ]]; then
    date -d "$ts" +%s 2>/dev/null && return
  fi

  # Pattern 2: "resets on 2024-01-15 at 1:00 PM UTC"
  ts="$(echo "$text" | grep -oiP 'resets?\s+on\s+\K\d{4}-\d{2}-\d{2}\s+at\s+[\d:]+\s*[APap][Mm]\s*(UTC|GMT)?' | head -1)"
  if [[ -n "$ts" ]]; then
    date -d "$ts" +%s 2>/dev/null && return
  fi

  # Pattern 3: Unix timestamp in JSON — "reset_at":1705320000
  ts="$(echo "$text" | grep -oP '"reset_at"\s*:\s*\K\d{10}' | head -1)"
  if [[ -n "$ts" ]]; then
    echo "$ts" && return
  fi
}

# Format a Unix epoch as local time for display, e.g. "1:00 PM"
format_local_time() {
  local epoch="$1"
  date -d "@$epoch" '+%-I:%M %p' 2>/dev/null || date -r "$epoch" '+%-I:%M %p' 2>/dev/null || echo "unknown"
}

# Sleep until $resume_epoch, printing status every 60 seconds.
wait_until_resume() {
  local resume_epoch="$1" label="$2"
  local resume_str
  resume_str="$(format_local_time "$resume_epoch")"
  while true; do
    local now
    now="$(date +%s)"
    local remaining=$(( resume_epoch - now ))
    [[ $remaining -le 0 ]] && break
    local mins=$(( (remaining + 59) / 60 ))
    echo "  [rate-limit] $label — paused, resuming in ~${mins}m (at $resume_str)" >&2
    local sleep_sec=$(( remaining < 60 ? remaining : 60 ))
    sleep "$sleep_sec"
  done
}

log_error() {
  local etype="$1" code="$2" attempt="$3" resp="$4"
  flock "$LOCK" bash -c "
    {
      echo '===================================================='
      echo \"Timestamp: \$(date)\"
      echo \"File: $rel\"
      echo \"Exit Code: $code\"
      echo \"Attempt: $attempt\"
      echo \"Type: $etype\"
      echo '----------------------------------------------------'
    } >> '$ERROR_LOG'
    cat >> '$ERROR_LOG' <<'RESPEOF'
$resp
RESPEOF
    echo >> '$ERROR_LOG'
  " 2>/dev/null || true
}

ext_to_fence() {
  local file="$1"
  case "${file##*.}" in
    c|h|inc)           echo "c" ;;
    cpp|cc|cxx|hpp|hh|hxx|inl) echo "cpp" ;;
    cs)                echo "csharp" ;;
    java)              echo "java" ;;
    py)                echo "python" ;;
    rs)                echo "rust" ;;
    lua)               echo "lua" ;;
    gd|gdscript)       echo "gdscript" ;;
    swift)             echo "swift" ;;
    m|mm)              echo "objectivec" ;;
    shader|cginc|hlsl|glsl|compute) echo "hlsl" ;;
    toml)              echo "toml" ;;
    tscn|tres)         echo "ini" ;;
    *)                 echo "$DEFAULT_FENCE" ;;
  esac
}

# ── Resolve local #include headers ──
# Extracts #include "..." directives, searches the source file's directory
# and the repo root for matching headers, returns up to MAX_BUNDLED_HEADERS.
resolve_local_headers() {
  local src_file="$1" repo_root="$2" max_headers="$3"
  local src_dir
  src_dir="$(dirname "$src_file")"

  # Extract #include "file.h" (not <file.h> — those are system headers)
  grep -oP '#\s*include\s+"\K[^"]+' "$src_file" 2>/dev/null | head -20 | while read -r inc; do
    # Search order: same directory, then repo root
    local found=""
    if [[ -f "$src_dir/$inc" ]]; then
      found="$src_dir/$inc"
    elif [[ -f "$repo_root/$inc" ]]; then
      found="$repo_root/$inc"
    else
      # Try find in repo (limited depth to avoid slowness)
      found="$(find "$repo_root" -maxdepth 4 -name "$(basename "$inc")" -type f 2>/dev/null | head -1)"
    fi
    if [[ -n "$found" && -f "$found" ]]; then
      echo "$found"
    fi
  done | head -"$max_headers"
}

if [[ -f "$FATAL_FLAG" ]]; then exit 1; fi

src="$REPO_ROOT/$rel"
out="$ARCH_DIR/$rel.md"
mkdir -p "$(dirname "$out")"

fence_lang="$(ext_to_fence "$rel")"

# ── Build payload with optional header bundling ──
header_section=""
if [[ "$BUNDLE_HEADERS" == "1" ]]; then
  mapfile -t headers < <(resolve_local_headers "$src" "$REPO_ROOT" "$MAX_BUNDLED_HEADERS")
  if [[ "${#headers[@]}" -gt 0 ]]; then
    header_section="
BUNDLED HEADERS (included for context — these are the local headers this file depends on):
"
    for hdr in "${headers[@]}"; do
      # Get path relative to repo root
      local_path="${hdr#$REPO_ROOT/}"
      hdr_fence="$(ext_to_fence "$local_path")"
      header_section+="
--- ${local_path} ---
\`\`\`${hdr_fence}
$(cat "$hdr")
\`\`\`
"
    done
  fi
fi

payload="FILE PATH (relative): ${rel}

FILE CONTENT:
\`\`\`${fence_lang}
$(
  total_lines="$(wc -l < "$src")"
  if [[ "$MAX_FILE_LINES" -gt 0 && "$total_lines" -gt "$MAX_FILE_LINES" ]]; then
    half=$(( MAX_FILE_LINES / 2 ))
    head -"$half" "$src"
    echo ""
    echo "/* ... TRUNCATED: showing first $half and last $half of $total_lines lines (file too large for full analysis) ... */"
    echo ""
    tail -"$half" "$src"
  else
    cat "$src"
  fi
)
\`\`\`
${header_section}"

attempt=0
while true; do
  if [[ -f "$FATAL_FLAG" ]]; then exit 1; fi

  # Respect a rate-limit pause set by any thread in this run
  if [[ -f "$STATE_DIR/ratelimit_resume.txt" ]]; then
    resume_epoch="$(cat "$STATE_DIR/ratelimit_resume.txt" 2>/dev/null || true)"
    if [[ -n "$resume_epoch" && "$resume_epoch" =~ ^[0-9]+$ ]]; then
      now="$(date +%s)"
      if [[ "$now" -lt "$resume_epoch" ]]; then
        echo "  [rate-limit] $rel — waiting for shared pause to expire at $(format_local_time "$resume_epoch")" >&2
        wait_until_resume "$resume_epoch" "$rel"
      fi
    fi
  fi

  set +e
  resp="$(printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" claude -p \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --output-format "$OUTPUT_FORMAT" \
    --append-system-prompt-file "$PROMPT_FILE" \
    2>&1)"
  code=$?
  set -e

  if [[ $code -eq 0 ]]; then
    if is_rate_limit "$resp"; then
      code=429
    else
      break
    fi
  fi

  if is_rate_limit "$resp"; then
    log_error "RATE_LIMIT" "$code" "$((attempt+1))" "$resp"
    bump_count fail

    # Parse reset time and compute resume time (reset + 10 min)
    reset_epoch="$(parse_reset_epoch "$resp")"
    if [[ -n "$reset_epoch" && "$reset_epoch" =~ ^[0-9]+$ ]]; then
      resume_epoch=$(( reset_epoch + 600 ))
    else
      resume_epoch=$(( $(date +%s) + 4200 ))  # fallback: 70 min from now
    fi

    reset_str="$(format_local_time "${reset_epoch:-$resume_epoch}")"
    resume_str="$(format_local_time "$resume_epoch")"

    echo "" >&2
    echo "  [rate-limit] You've hit your limit, resets at $reset_str. Thread paused till $resume_str." >&2
    echo "" >&2

    # Write shared resume file so other threads can honour the same pause
    echo "$resume_epoch" > "$STATE_DIR/ratelimit_resume.txt"

    wait_until_resume "$resume_epoch" "$rel"

    rm -f "$STATE_DIR/ratelimit_resume.txt"
    attempt=0
    continue
  fi

  attempt=$((attempt + 1))
  if [[ $attempt -le $MAX_RETRIES ]]; then
    bump_count retries
    echo "  [retry $attempt/$MAX_RETRIES] exit=$code on: $rel (waiting ${RETRY_DELAY}s)" >&2
    sleep "$RETRY_DELAY"
    continue
  fi

  log_error "PERSISTENT_FAILURE" "$code" "$attempt" "$resp"
  bump_count fail
  echo "Claude failed (exit=$code) after $attempt attempts on: $rel" > "$FATAL_MSG"
  : > "$FATAL_FLAG"
  exit 1
done

tmp="$(mktemp "$STATE_DIR/tmp.XXXXXX")"
printf '%s\n' "$resp" > "$tmp"
mv -f "$tmp" "$out"

# Immediately record this file's hash so interrupted runs skip it
file_sha="$(sha1sum "$src" | awk '{print $1}')"
(
  flock 9
  printf '%s\t%s\n' "$file_sha" "$rel" >> "$HASH_DB"
) 9>>"$LOCK"

bump_count done
WORKEREOF
chmod +x "$WORKER_SCRIPT"

# ── Run workers ──
set +e
printf "%s\n" "${QUEUE[@]}" | xargs -P "$JOBS" -I {} \
  bash "$WORKER_SCRIPT" {} \
    "$REPO_ROOT" "$ARCH_DIR" "$STATE_DIR" "$LOCK" "$COUNT_FILE" \
    "$ERROR_LOG" "$FATAL_FLAG" "$FATAL_MSG" "$MODEL" "$MAX_TURNS" \
    "$OUTPUT_FORMAT" "$PROMPT_FILE" "$CLAUDE_CONFIG_DIR" \
    "$MAX_RETRIES" "$RETRY_DELAY" "$DEFAULT_FENCE" \
    "$BUNDLE_HEADERS" "$MAX_BUNDLED_HEADERS" "$HASH_DB" "$MAX_FILE_LINES"
xargs_rc=$?
set -e

kill "$PROGRESS_PID" 2>/dev/null || true
wait "$PROGRESS_PID" 2>/dev/null || true
echo >&2

progress_tick
echo >&2

if [[ -f "$FATAL_FLAG" ]]; then
  echo >&2
  echo "FATAL: $(cat "$FATAL_MSG" 2>/dev/null || echo 'Unknown fatal condition.')" >&2
  echo "Last error saved to: $ERROR_LOG" >&2
  echo >&2
  echo "Tip: Re-run the same command to resume (completed files are skipped)." >&2
  exit 1
fi

if [[ "$xargs_rc" -ne 0 ]]; then
  echo "Non-zero worker exit detected. See: $ERROR_LOG" >&2
  exit 1
fi

# Deduplicate and sort the incrementally-built hash DB.
# Workers append entries as they complete; this cleans up any duplicates
# (e.g., from a resumed run where a file was re-processed).
if [[ -f "$HASH_DB" ]]; then
  tmpdb="$(mktemp "$STATE_DIR/hashes.XXXXXX")"
  # Keep only the LAST entry for each file (latest hash wins)
  tac "$HASH_DB" | awk -F'\t' '!seen[$2]++' | sort -t$'\t' -k2,2 > "$tmpdb"
  mv -f "$tmpdb" "$HASH_DB"
fi

echo "Done. Per-file docs are in: $ARCH_DIR" >&2
