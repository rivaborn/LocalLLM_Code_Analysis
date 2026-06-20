#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# archpass2.sh — Context-Aware Second-Pass Analysis
#
# Re-analyzes source files with architecture context injected.
# Claude now knows:
# - Which subsystem this file belongs to
# - The architecture overview (how subsystems connect)
# - The cross-reference index (who calls whom)
# - What the file's callers and callees are
#
# Output goes to architecture/<path>.pass2.md alongside the
# original .md files. Does NOT overwrite pass-1 docs.
#
# Recommended workflow:
#   1. archgen.sh          (pass 1: per-file docs)
#   2. archxref.sh         (cross-reference index)
#   3. arch_overview.sh    (architecture overview)
#   4. archpass2.sh        (pass 2: context-aware re-analysis)
#
# Supports all the same flags as archgen.sh:
#   --claude1, --preset, JOBS=N, resumable via hash DB
#
# Privacy: No personal identifiers in this script.
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
  set -a; source "$ENV_FILE"; set +a
fi

# Restore command-line overrides (they take priority over .env)
[[ -n "$_CLI_JOBS" ]] && JOBS="$_CLI_JOBS"

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ARCH_DIR="${ARCH_DIR:-$REPO_ROOT/architecture}"
STATE_DIR="$ARCH_DIR/.pass2_state"
mkdir -p "$STATE_DIR"

MODEL="${CLAUDE_MODEL:-sonnet}"
MAX_TURNS="${CLAUDE_MAX_TURNS:-1}"
OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-text}"
JOBS="${JOBS:-2}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-1}"
MAX_RETRIES="${MAX_RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY:-5}"

INCLUDE_EXT_REGEX="${INCLUDE_EXT_REGEX:-.*\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc|cs|java|py|rs|lua|gd|m|mm|swift)$}"
EXCLUDE_DIRS_REGEX="${EXCLUDE_DIRS_REGEX:-/(\.git|architecture|build|out|dist|obj|bin|__MACOSX)/}"
EXTRA_EXCLUDE_REGEX="${EXTRA_EXCLUDE_REGEX:-}"
CODEBASE_DESC="${CODEBASE_DESC:-game engine / game codebase}"
DEFAULT_FENCE="${DEFAULT_FENCE:-c}"

# Pass-2 specific prompt
PROMPT_FILE_P2="${PROMPT_FILE_P2:-$REPO_ROOT/file_doc_prompt_pass2.txt}"

ACCOUNT="claude2"
TARGET_DIR="."
CLEAN="0"

# Optional: limit to specific files (space-separated relative paths)
ONLY_FILES="${ONLY_FILES:-}"

usage() {
  cat <<'EOF'
Usage:
  ./archpass2.sh [<target_dir>] [--claude1] [--clean] [--only <file1,file2,...>]

Options:
  --only <files>  Comma-separated list of files to re-analyze (skip all others)

Examples:
  ./archpass2.sh                          # re-analyze all files
  ./archpass2.sh client                   # re-analyze only client/
  ./archpass2.sh --only server/sv_main.c,server/sv_send.c
  JOBS=4 ./archpass2.sh --claude1

Prerequisites (run these first):
  1. ./archgen.sh          (generates per-file docs)
  2. ./archxref.sh         (generates xref_index.md)
  3. ./arch_overview.sh    (generates architecture.md)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)  usage; exit 0 ;;
    --claude1)  ACCOUNT="claude1"; shift ;;
    --clean)    CLEAN="1"; shift ;;
    --only)     [[ $# -ge 2 ]] || { echo "--only requires a value" >&2; exit 2; }
                ONLY_FILES="$2"; shift 2 ;;
    *)          TARGET_DIR="$1"; shift ;;
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
[[ -n "${CLAUDE_CONFIG_DIR:-}" ]] || { echo "Missing Claude config dir for $ACCOUNT." >&2; exit 2; }
CLAUDE_CONFIG_DIR="$(eval echo "$CLAUDE_CONFIG_DIR")"
[[ -d "$CLAUDE_CONFIG_DIR" ]] || { echo "Claude config dir does not exist: $CLAUDE_CONFIG_DIR" >&2; exit 2; }

# Check prerequisites
ARCH_OVERVIEW="$ARCH_DIR/architecture.md"
XREF_INDEX="$ARCH_DIR/xref_index.md"

missing=""
[[ -f "$ARCH_OVERVIEW" ]] || missing+="  - architecture.md (run arch_overview.sh)\n"
[[ -f "$XREF_INDEX" ]] || missing+="  - xref_index.md (run archxref.sh)\n"
if [[ -n "$missing" ]]; then
  echo "Missing prerequisite files:" >&2
  printf "$missing" >&2
  echo "Run the prerequisite scripts first. See --help." >&2
  exit 2
fi

# Check for pass-2 prompt file; generate a default if missing
if [[ ! -f "$PROMPT_FILE_P2" ]]; then
  echo "No pass-2 prompt found at: $PROMPT_FILE_P2" >&2
  echo "Generating default pass-2 prompt..." >&2
  cat > "$PROMPT_FILE_P2" << 'PROMPT_EOF'
You are doing a SECOND-PASS architectural analysis of a game engine source file.

You have already seen the first-pass analysis. Now you also have:
- ARCHITECTURE CONTEXT: a subsystem-level overview of the full codebase
- CROSS-REFERENCE CONTEXT: who calls this file's functions, and what this file calls
- FIRST-PASS DOC: the initial per-file analysis

Your job is to ENRICH the analysis with cross-cutting insights that were impossible
in the first pass (when only this single file was visible).

Write deterministic markdown using this schema:

# <FILE PATH> — Enhanced Analysis

## Architectural Role
2–4 sentences explaining this file's role in the broader engine architecture.
Reference specific subsystems and data flows.

## Key Cross-References
### Incoming (who depends on this file)
- Which files/subsystems call functions defined here
- Which globals defined here are read elsewhere

### Outgoing (what this file depends on)
- Which subsystems this file calls into
- Which globals from other files it reads/writes

## Design Patterns & Rationale
- What design patterns are used (and why, if inferable)
- Why is the code structured this way?
- What tradeoffs were made?

## Data Flow Through This File
- What data enters (from where), how it's transformed, where it goes
- Key state transitions

## Learning Notes
- What would a developer studying this engine learn from this file?
- What's idiomatic to this engine/era that modern engines do differently?
- Connections to game engine programming concepts (ECS, scene graphs, etc.)

## Potential Issues
- Only if clearly inferable from the code + context

Rules:
- Use the provided context to make specific cross-references (not vague ones)
- Do NOT repeat the first-pass doc verbatim — add new insights
- If something is not inferable even with context, say so
- Keep output under ~1500 tokens
PROMPT_EOF
  echo "Wrote default prompt: $PROMPT_FILE_P2" >&2
fi

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
  echo "CLEAN: removing pass-2 state and docs..." >&2
  find "$ARCH_DIR" -name "*.pass2.md" -delete 2>/dev/null || true
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  : > "$LOCK"
fi

# Load old hashes
declare -A OLD_SHA
if [[ -f "$HASH_DB" ]]; then
  while IFS=$'\t' read -r sha rel; do
    [[ -n "${rel:-}" ]] && OLD_SHA["$rel"]="$sha"
  done < "$HASH_DB"
fi

# Build file list
mapfile -t ALL_FILES < <(
  cd "$REPO_ROOT"
  find "$TARGET_DIR" -type f \
    ! -path "./architecture/*" ! -path "*/architecture/*" ! -name "*.ignore" \
    2>/dev/null | sed 's|^\./||' | sort
)

FILES=()
for rel in "${ALL_FILES[@]}"; do
  [[ "$rel" =~ $EXCLUDE_DIRS_REGEX ]] && continue
  [[ -n "$EXTRA_EXCLUDE_REGEX" && "$rel" =~ $EXTRA_EXCLUDE_REGEX ]] && continue
  [[ "$rel" =~ $INCLUDE_EXT_REGEX ]] || continue
  # If --only is set, filter to just those files
  if [[ -n "$ONLY_FILES" ]]; then
    match=0
    IFS=',' read -ra only_list <<< "$ONLY_FILES"
    for ofile in "${only_list[@]}"; do
      [[ "$rel" == "$ofile" ]] && match=1
    done
    [[ "$match" -eq 0 ]] && continue
  fi
  FILES+=("$rel")
done

TOTAL="${#FILES[@]}"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No matching source files." >&2
  exit 1
fi

# Build queue (skip unchanged)
QUEUE=()
SKIP_UNCHANGED=0
for rel in "${FILES[@]}"; do
  src="$REPO_ROOT/$rel"
  out="$ARCH_DIR/$rel.pass2.md"
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
echo "  archpass2.sh — Second-Pass Analysis"
echo "============================================"
echo "Repo root:    $REPO_ROOT"
echo "Codebase:     $CODEBASE_DESC"
echo "Account:      $ACCOUNT"
echo "Model:        $MODEL"
echo "Jobs:         $JOBS"
echo "Files:        $TOTAL (skipped: $SKIP_UNCHANGED, to process: $TO_DO)"
echo "Prompt:       $PROMPT_FILE_P2"
echo "Context:      $ARCH_OVERVIEW, $XREF_INDEX"
echo

if [[ "$TO_DO" -eq 0 ]]; then
  echo "Nothing to do."
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
  local done_n todo_n skip_n fail_n retries_n now elapsed rate eta remaining eta_sec
  flock "$LOCK" cat "$COUNT_FILE" > "$STATE_DIR/counts.snapshot" 2>/dev/null || return
  source "$STATE_DIR/counts.snapshot" 2>/dev/null || return
  done_n="${done:-0}"; todo_n="${todo:-0}"; skip_n="${skip:-0}"; fail_n="${fail:-0}"; retries_n="${retries:-0}"
  now="$(date +%s)"; elapsed=$((now - start_ts))
  if [[ "$elapsed" -le 0 ]]; then elapsed=1; fi
  rate="0.0"; eta="--"
  if [[ "$done_n" -gt 0 ]]; then
    rate="$(awk -v d="$done_n" -v e="$elapsed" 'BEGIN{printf "%.2f", d/e}')"
    remaining=$((todo_n - done_n)); [[ "$remaining" -lt 0 ]] && remaining=0
    eta_sec=$(( remaining * elapsed / done_n )); eta="${eta_sec}s"
  fi
  local ri=""; [[ "$retries_n" -gt 0 ]] && ri="  retries=$retries_n"
  printf "\r%-80s" "PROGRESS: $done_n/$todo_n done  skip=$skip_n  fail=$fail_n${ri}  rate=${rate}/s  eta=$eta" >&2
  echo "PROGRESS: $done_n/$todo_n done  skip=$skip_n  fail=$fail_n${ri}  rate=${rate}/s  eta=$eta" > "$PROGRESS_TXT"
}

( while true; do [[ -f "$FATAL_FLAG" ]] && exit 0; progress_tick; sleep "$PROGRESS_INTERVAL"; done ) &
PROGRESS_PID=$!; disown "$PROGRESS_PID" 2>/dev/null || true

# Truncate context files to avoid exceeding context window
# Architecture overview: keep full (usually <500 lines)
# Xref index: take first 300 lines (most-connected functions)
echo "Loading architecture context..." >&2
ARCH_CONTEXT="$(head -200 "$ARCH_OVERVIEW")"
echo "  architecture.md: ${#ARCH_CONTEXT} chars" >&2
echo "Loading xref context..." >&2
XREF_CONTEXT="$(head -300 "$XREF_INDEX")"
echo "  xref_index.md: ${#XREF_CONTEXT} chars" >&2

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
PROMPT_FILE_P2="${13}"
CLAUDE_CONFIG_DIR="${14}"
MAX_RETRIES="${15}"
RETRY_DELAY="${16}"
DEFAULT_FENCE="${17}"
ARCH_CONTEXT_FILE="${18}"
XREF_CONTEXT_FILE="${19}"
HASH_DB="${20}"

bump_count() {
  flock "$LOCK" bash -c "
    awk -F= 'BEGIN{OFS=FS} \$1==\"$1\"{ \$2=\$2+1 } {print}' '$COUNT_FILE' > '${COUNT_FILE}.tmp' \
      && mv '${COUNT_FILE}.tmp' '$COUNT_FILE'
  " 2>/dev/null || true
}

is_rate_limit() {
  local first3; first3="$(echo "$1" | head -3)"
  echo "$first3" | grep -qE '^#' && return 1
  echo "$first3" | grep -qiE '(^|[^0-9])429([^0-9]|$)|rate.?limit|usage.?limit|too many requests' && return 0
  return 1
}

ext_to_fence() {
  case "${1##*.}" in
    c|h|inc) echo "c" ;; cpp|cc|cxx|hpp|hh|hxx|inl) echo "cpp" ;;
    cs) echo "csharp" ;; java) echo "java" ;; py) echo "python" ;;
    rs) echo "rust" ;; lua) echo "lua" ;; gd|gdscript) echo "gdscript" ;;
    swift) echo "swift" ;; m|mm) echo "objectivec" ;;
    *) echo "$DEFAULT_FENCE" ;;
  esac
}

if [[ -f "$FATAL_FLAG" ]]; then exit 1; fi

# Debug log file — one per worker
DBGLOG="$STATE_DIR/debug_${rel//\//_}.log"

echo "[$(date)] START: $rel" >> "$DBGLOG"

src="$REPO_ROOT/$rel"
out="$ARCH_DIR/$rel.pass2.md"
pass1="$ARCH_DIR/$rel.md"
mkdir -p "$(dirname "$out")"

fence="$(ext_to_fence "$rel")"
echo "[$(date)] fence=$fence src=$src" >> "$DBGLOG"

# Build enriched payload
# For pass 2, truncate very large source files — Claude has the pass-1 doc
# which already summarizes the entire file. We send the first 500 lines
# of source as a reference, plus the full pass-1 analysis.
pass1_content=""
if [[ -f "$pass1" ]]; then
  pass1_content="$(cat "$pass1")"
  echo "[$(date)] pass1 loaded: $(echo "$pass1_content" | wc -c) bytes" >> "$DBGLOG"
else
  echo "[$(date)] WARNING: no pass1 doc at $pass1" >> "$DBGLOG"
fi

src_lines="$(wc -l < "$src")"
echo "[$(date)] src_lines=$src_lines" >> "$DBGLOG"

if [[ "$src_lines" -gt 500 ]]; then
  src_content="$(head -500 "$src")

... [truncated at 500/$src_lines lines — see first-pass analysis for full coverage] ..."
  echo "[$(date)] source truncated to 500 lines" >> "$DBGLOG"
else
  src_content="$(cat "$src")"
fi

arch_ctx_size="$(wc -c < "$ARCH_CONTEXT_FILE" 2>/dev/null || echo 0)"
xref_ctx_size="$(wc -c < "$XREF_CONTEXT_FILE" 2>/dev/null || echo 0)"
echo "[$(date)] context sizes: arch=${arch_ctx_size}B xref=${xref_ctx_size}B" >> "$DBGLOG"

payload="FILE PATH (relative): ${rel}

FILE CONTENT (${src_lines} lines total):
\`\`\`${fence}
${src_content}
\`\`\`

FIRST-PASS ANALYSIS:
${pass1_content}

ARCHITECTURE CONTEXT:
$(cat "$ARCH_CONTEXT_FILE")

CROSS-REFERENCE CONTEXT (excerpt):
$(cat "$XREF_CONTEXT_FILE")"

payload_size="${#payload}"
echo "[$(date)] payload built: ${payload_size} chars" >> "$DBGLOG"
echo "[$(date)] calling claude -p --model $MODEL ..." >> "$DBGLOG"

attempt=0
while true; do
  if [[ -f "$FATAL_FLAG" ]]; then echo "[$(date)] FATAL_FLAG detected, exiting" >> "$DBGLOG"; exit 1; fi
  set +e
  echo "[$(date)] attempt $((attempt+1)): sending to claude..." >> "$DBGLOG"
  resp="$(printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" claude -p \
    --model "$MODEL" --max-turns "$MAX_TURNS" --output-format "$OUTPUT_FORMAT" \
    --append-system-prompt-file "$PROMPT_FILE_P2" 2>&1)"
  code=$?; set -e
  echo "[$(date)] claude returned: exit=$code resp_size=${#resp}" >> "$DBGLOG"

  if [[ $code -eq 0 ]]; then
    if is_rate_limit "$resp"; then
      echo "[$(date)] rate limit detected in response" >> "$DBGLOG"
      code=429
    else
      echo "[$(date)] success" >> "$DBGLOG"
      break
    fi
  fi
  if is_rate_limit "$resp"; then
    bump_count fail
    echo "Rate limit hit processing: $rel" > "$FATAL_MSG"; : > "$FATAL_FLAG"; exit 1
  fi
  attempt=$((attempt + 1))
  if [[ $attempt -le $MAX_RETRIES ]]; then
    bump_count retries
    echo "  [retry $attempt/$MAX_RETRIES] exit=$code on: $rel" >&2
    echo "[$(date)] retry $attempt/$MAX_RETRIES" >> "$DBGLOG"
    sleep "$RETRY_DELAY"; continue
  fi
  echo "[$(date)] FAILED after $attempt attempts" >> "$DBGLOG"
  bump_count fail
  echo "Failed (exit=$code) after $attempt attempts on: $rel" > "$FATAL_MSG"; : > "$FATAL_FLAG"; exit 1
done

tmp="$(mktemp "$STATE_DIR/tmp.XXXXXX")"
printf '%s\n' "$resp" > "$tmp"
mv -f "$tmp" "$out"

# Immediately record hash so interrupted runs skip this file
file_sha="$(sha1sum "$src" | awk '{print $1}')"
(
  flock 9
  printf '%s\t%s\n' "$file_sha" "$rel" >> "$HASH_DB"
) 9>>"$LOCK"

bump_count done
WORKEREOF
chmod +x "$WORKER_SCRIPT"

# Write context files for workers to read
ARCH_CTX_FILE="$STATE_DIR/arch_context.txt"
XREF_CTX_FILE="$STATE_DIR/xref_context.txt"
echo "Writing context files..." >&2
echo "$ARCH_CONTEXT" > "$ARCH_CTX_FILE"
echo "$XREF_CONTEXT" > "$XREF_CTX_FILE"
echo "  arch_context.txt: $(wc -c < "$ARCH_CTX_FILE") bytes" >&2
echo "  xref_context.txt: $(wc -c < "$XREF_CTX_FILE") bytes" >&2

echo "Launching workers (JOBS=$JOBS, files=${#QUEUE[@]})..." >&2
echo "Worker script: $WORKER_SCRIPT" >&2
echo "Queue: ${QUEUE[*]}" >&2

# Run workers
set +e
printf "%s\n" "${QUEUE[@]}" | xargs -P "$JOBS" -I {} \
  bash "$WORKER_SCRIPT" {} \
    "$REPO_ROOT" "$ARCH_DIR" "$STATE_DIR" "$LOCK" "$COUNT_FILE" \
    "$ERROR_LOG" "$FATAL_FLAG" "$FATAL_MSG" "$MODEL" "$MAX_TURNS" \
    "$OUTPUT_FORMAT" "$PROMPT_FILE_P2" "$CLAUDE_CONFIG_DIR" \
    "$MAX_RETRIES" "$RETRY_DELAY" "$DEFAULT_FENCE" \
    "$ARCH_CTX_FILE" "$XREF_CTX_FILE" "$HASH_DB"
xargs_rc=$?; set -e

kill "$PROGRESS_PID" 2>/dev/null || true
wait "$PROGRESS_PID" 2>/dev/null || true
echo >&2; progress_tick; echo >&2

if [[ -f "$FATAL_FLAG" ]]; then
  echo >&2; echo "FATAL: $(cat "$FATAL_MSG" 2>/dev/null)" >&2
  echo "See: $ERROR_LOG" >&2; exit 1
fi

# Deduplicate the incrementally-built hash DB
if [[ -f "$HASH_DB" ]]; then
  tmpdb="$(mktemp "$STATE_DIR/hashes.XXXXXX")"
  tac "$HASH_DB" | awk -F'\t' '!seen[$2]++' | sort -t$'\t' -k2,2 > "$tmpdb"
  mv -f "$tmpdb" "$HASH_DB"
fi

echo "Done. Pass-2 docs are: architecture/<path>.pass2.md" >&2
