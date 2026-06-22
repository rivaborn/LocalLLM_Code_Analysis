#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# arch_overview.sh — Subsystem Architecture Overview Generator
#
# Modes:
#   Single-pass (default):
#     Sends all diagram_data to Claude in one shot.
#     Fine for small codebases (<1500 lines of diagram_data).
#
#   Chunked (--chunked):
#     Two-tier approach for large codebases:
#       Tier 1: Auto-detects subdirectories in architecture/,
#               generates a per-subsystem overview for each.
#       Tier 2: Synthesizes a final overview from the subsystem
#               overviews (much smaller input, much better quality).
#     Automatically triggered if diagram_data exceeds CHUNK_THRESHOLD
#     lines (default 1500), unless --single is forced.
#
# Generates:
#   architecture/diagram_data.md        (extracted signal from all per-file docs)
#   architecture/architecture.md        (final overview)
#   architecture/<sub> diagram_data.md  (per-subsystem, chunked mode only)
#   architecture/<sub> architecture.md  (per-subsystem, chunked mode only)
#
# If invoked with a directory target:
#   ./arch_overview.sh client  =>
#     architecture/client diagram_data.md
#     architecture/client architecture.md
#
# Account selection:
# - default uses account #2
# - use account #1 with --claude1
#
# Privacy:
# - No personal identifiers in this script.
# ============================================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need find
need sort
need awk
need grep
need wc
need claude

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ARCH_DIR="${ARCH_DIR:-$REPO_ROOT/architecture}"
STATE_DIR="$ARCH_DIR/.overview_state"
mkdir -p "$STATE_DIR"

MODEL="${CLAUDE_MODEL:-sonnet}"
MAX_TURNS="${CLAUDE_MAX_TURNS:-1}"
OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-text}"

CODEBASE_DESC="${CODEBASE_DESC:-game engine / game codebase}"

# Lines of diagram_data above which --chunked is auto-enabled
CHUNK_THRESHOLD="${CHUNK_THRESHOLD:-1500}"

ACCOUNT="claude2"
TARGET="all"
MODE=""  # "", "chunked", or "single"

usage() {
  cat <<'EOF'
Usage:
  ./arch_overview.sh [all|<dir>] [--chunked] [--single] [--claude1]

Modes:
  (default)    Auto: uses single-pass if diagram_data < CHUNK_THRESHOLD lines,
               otherwise switches to chunked automatically.
  --chunked    Force two-tier chunked mode (per-subsystem → final synthesis).
  --single     Force single-pass mode even for large inputs.

Examples:
  ./arch_overview.sh                    # auto-detect mode
  ./arch_overview.sh --chunked          # force chunked for entire repo
  ./arch_overview.sh client             # single subsystem (always single-pass)
  ./arch_overview.sh --claude1          # use account #1
  CHUNK_THRESHOLD=2000 ./arch_overview.sh  # raise the auto-chunk threshold

Notes:
- Set CODEBASE_DESC in .env to describe your project.
- CHUNK_THRESHOLD (default 1500) controls when auto-chunking kicks in.
- Chunked mode produces better results for large codebases (200+ files).
EOF
}

# Parse args
if [[ $# -gt 0 ]]; then
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; shift ;;
    --chunked|--single|--claude1) ;;  # handled below
    *) TARGET="$1"; shift ;;
  esac
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude1)  ACCOUNT="claude1"; shift ;;
    --chunked)  MODE="chunked"; shift ;;
    --single)   MODE="single"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
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
  echo "Missing Claude config dir for $ACCOUNT. Set CLAUDE1_CONFIG_DIR/CLAUDE2_CONFIG_DIR in .env" >&2
  exit 2
}
CLAUDE_CONFIG_DIR="$(eval echo "$CLAUDE_CONFIG_DIR")"
[[ -d "$CLAUDE_CONFIG_DIR" ]] || {
  echo "Claude config dir does not exist: $CLAUDE_CONFIG_DIR" >&2
  exit 2
}

ERROR_LOG="$STATE_DIR/last_claude_error.log"
: > "$ERROR_LOG"

# ── Rate-limit detection ──
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

# ── Extract diagram data from per-file docs ──
# Args: $1=doc_root $2=output_file
build_diagram_data() {
  local doc_root="$1" out="$2"
  : > "$out"
  local f
  while IFS= read -r f; do
    awk '
      BEGIN{keep=0}
      NR==1 && $0 ~ /^# / {print $0; next}
      /^## File Purpose/ {keep=1; print; next}
      /^## Core Responsibilities/ {keep=1; print; next}
      /^## External Dependencies/ {keep=1; print; next}
      /^## / && $0 !~ /^## (File Purpose|Core Responsibilities|External Dependencies)/ {keep=0}
      keep==1 {print}
    ' "$f" >> "$out"
    echo >> "$out"
  done < <(
    find "$doc_root" -type f -name "*.md" \
      ! -path "*/.archgen_state/*" \
      ! -path "*/.overview_state/*" \
      ! -path "*/.pass2_state/*" \
      ! -name "*architecture.md" \
      ! -name "*diagram_data.md" \
      ! -name "*xref_index.md" \
      ! -name "*callgraph*" \
      ! -name "*.pass2.md" \
      2>/dev/null \
      | sort
  )
}

# ── Send a prompt to Claude, return response or exit on error ──
# Args: $1=prompt $2=context_label (for error messages)
call_claude() {
  local prompt="$1" label="$2"
  local resp code

  set +e
  resp="$(printf '%s' "$prompt" | CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" claude -p \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --output-format "$OUTPUT_FORMAT" \
    2>&1)"
  code=$?
  set -e

  if [[ $code -ne 0 ]] || is_rate_limit "$resp"; then
    {
      echo "===================================================="
      echo "Timestamp: $(date)"
      echo "Context: $label"
      echo "Exit Code: $code"
      echo "Model: $MODEL"
      echo "----------------------------------------------------"
      echo "$resp"
      echo
    } >> "$ERROR_LOG"
    echo "Claude call failed for: $label (exit=$code)" >&2
    echo "See: $ERROR_LOG" >&2
    exit 1
  fi

  printf '%s' "$resp"
}

# ── Subsystem overview prompt ──
subsystem_prompt() {
  local desc="$1" diagram_content="$2"
  cat <<PROMPT
You are generating a subsystem-level overview for part of a ${desc}.

Write deterministic markdown.

Rules:
- Do NOT speculate. If unknown, say "Not inferable from provided docs."
- Keep section order exactly as specified.
- Use consistent naming and bullet formatting.
- Prefer clear subsystem boundaries and flows.
- Use only the provided input (diagram_data).
- Infer the programming language(s) from the file paths and contents.

Output schema (exact order):

# Subsystem Overview

## Purpose
1–3 sentences describing what this subsystem does.

## Key Files
| File | Role |

## Core Responsibilities
- 3–8 bullets

## Key Interfaces & Data Flow
- What this subsystem exposes to others
- What it consumes from other subsystems

## Runtime Role
- How this subsystem participates in init / frame / shutdown (if inferable)

## Notable Implementation Details
- (only if inferable)

BEGIN INPUT DOC INDEX
${diagram_content}
END INPUT DOC INDEX
PROMPT
}

# ── Final synthesis prompt ──
synthesis_prompt() {
  local desc="$1" subsystem_overviews="$2"
  cat <<PROMPT
You are generating a top-level architecture overview for a ${desc}.

You are given per-subsystem overviews (already analyzed). Synthesize them into a unified architecture document.

Write deterministic markdown.

Rules:
- Do NOT speculate. If unknown, say "Not inferable from provided docs."
- Keep section order exactly as specified.
- Use consistent naming and bullet formatting.
- Prefer clear subsystem boundaries and flows.
- Cross-reference subsystems to show how they connect.

Output schema (exact order):

# Architecture Overview

## Repository Shape
- (high-level repo layout inferred from subsystem paths)

## Major Subsystems
For each subsystem:
### <Subsystem Name>
- Purpose:
- Key directories / files:
- Key responsibilities:
- Key dependencies (other subsystems):

## Key Runtime Flows
### Initialization
### Per-frame / Main Loop
### Shutdown

## Data & Control Boundaries
- (important ownership boundaries, global state, resource lifetimes, etc.)

## Notable Risks / Hotspots
- (only if inferable)

BEGIN SUBSYSTEM OVERVIEWS
${subsystem_overviews}
END SUBSYSTEM OVERVIEWS
PROMPT
}

# ── Single-pass overview prompt (original behavior) ──
single_pass_prompt() {
  local desc="$1" diagram_content="$2"
  cat <<PROMPT
You are generating a subsystem-level architecture overview for a ${desc}.

Write deterministic markdown.

Rules:
- Do NOT speculate. If unknown, say "Not inferable from provided docs."
- Keep section order exactly as specified.
- Use consistent naming and bullet formatting.
- Prefer clear subsystem boundaries and flows.
- Use only the provided input (diagram_data).
- Infer the programming language(s) and engine type from the file paths and contents.

Output schema (exact order):

# Architecture Overview

## Repository Shape
- (high-level repo layout inferred from file paths)

## Major Subsystems
For each subsystem:
### <Subsystem Name>
- Purpose:
- Key directories / files:
- Key responsibilities:
- Key dependencies (other subsystems):

## Key Runtime Flows
### Initialization
### Per-frame / Main Loop
### Shutdown

## Data & Control Boundaries
- (important ownership boundaries, global state, resource lifetimes, etc.)

## Notable Risks / Hotspots
- (only if inferable)

BEGIN INPUT DOC INDEX
${diagram_content}
END INPUT DOC INDEX
PROMPT
}

# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════

DOC_ROOT="$ARCH_DIR"
OUT_PREFIX=""
if [[ "$TARGET" != "all" ]]; then
  DOC_ROOT="$ARCH_DIR/$TARGET"
  OUT_PREFIX="$(basename "$TARGET") "
fi

OUT_ARCH="$ARCH_DIR/${OUT_PREFIX}architecture.md"
OUT_DIAGRAM="$ARCH_DIR/${OUT_PREFIX}diagram_data.md"

# Build the full diagram_data first (needed for both modes)
build_diagram_data "$DOC_ROOT" "$OUT_DIAGRAM"

DOC_COUNT="$(find "$DOC_ROOT" -type f -name "*.md" \
  ! -path "*/.archgen_state/*" ! -path "*/.overview_state/*" ! -path "*/.pass2_state/*" \
  ! -name "*architecture.md" ! -name "*diagram_data.md" \
  ! -name "*xref_index.md" ! -name "*callgraph*" ! -name "*.pass2.md" \
  2>/dev/null | wc -l)"

DIAGRAM_LINES="$(wc -l < "$OUT_DIAGRAM")"

if [[ "$DOC_COUNT" -eq 0 ]]; then
  echo "No per-file docs found under: $DOC_ROOT" >&2
  echo "Run archgen.sh first." >&2
  exit 1
fi

# Auto-detect mode if not explicitly set
if [[ -z "$MODE" ]]; then
  if [[ "$DIAGRAM_LINES" -gt "$CHUNK_THRESHOLD" && "$TARGET" == "all" ]]; then
    MODE="chunked"
  else
    MODE="single"
  fi
fi

echo "============================================"
echo "  arch_overview.sh — Architecture Overview"
echo "============================================"
echo "Codebase:       $CODEBASE_DESC"
echo "Account:        $ACCOUNT"
echo "Config:         $CLAUDE_CONFIG_DIR"
echo "Model:          $MODEL"
echo "Target:         $TARGET"
echo "Mode:           $MODE"
echo "Doc root:       $DOC_ROOT"
echo "Per-file docs:  $DOC_COUNT"
echo "Diagram lines:  $DIAGRAM_LINES (threshold: $CHUNK_THRESHOLD)"
echo "Output:         $OUT_ARCH"
echo "Diagram:        $OUT_DIAGRAM"
echo

# ─── SINGLE-PASS MODE ───────────────────────────────────────
if [[ "$MODE" == "single" ]]; then
  echo "Running single-pass overview..."
  prompt="$(single_pass_prompt "$CODEBASE_DESC" "$(cat "$OUT_DIAGRAM")")"
  resp="$(call_claude "$prompt" "single-pass overview")"
  printf '%s\n' "$resp" > "$OUT_ARCH"
  echo
  echo "Wrote: $OUT_DIAGRAM"
  echo "Wrote: $OUT_ARCH"
  echo "Done."
  exit 0
fi

# ─── CHUNKED MODE ───────────────────────────────────────────
echo "Running chunked two-tier overview..."
echo

# Tier 1: Discover subsystem directories
# Find all unique first-level subdirectories under DOC_ROOT that contain .md files
md_find_opts='! -path "*/.archgen_state/*" ! -path "*/.overview_state/*" ! -name "*architecture.md" ! -name "*diagram_data.md" ! -name "*xref_index.md" ! -name "*callgraph*"'

mapfile -t RAW_SUBSYSTEMS < <(
  eval find "$DOC_ROOT" -type f -name '"*.md"' $md_find_opts 2>/dev/null \
    | sed "s|^${DOC_ROOT}/||" \
    | awk -F/ 'NF>=2 {print $1}' \
    | sort -u
)

# Also check for top-level .md files (files not in any subdirectory)
TOP_LEVEL_COUNT="$(eval find "$DOC_ROOT" -maxdepth 1 -type f -name '"*.md"' $md_find_opts 2>/dev/null | wc -l)"

if [[ "${#RAW_SUBSYSTEMS[@]}" -eq 0 && "$TOP_LEVEL_COUNT" -eq 0 ]]; then
  echo "No subsystem directories found. Falling back to single-pass." >&2
  prompt="$(single_pass_prompt "$CODEBASE_DESC" "$(cat "$OUT_DIAGRAM")")"
  resp="$(call_claude "$prompt" "single-pass fallback")"
  printf '%s\n' "$resp" > "$OUT_ARCH"
  echo "Wrote: $OUT_ARCH"
  echo "Done (fallback to single-pass)."
  exit 0
fi

# For large subsystems, split into sub-directories (e.g., code/ → code/client, code/server)
# This gives Claude focused, manageable chunks instead of one giant subsystem.
SUBSYSTEMS=()
for sub in "${RAW_SUBSYSTEMS[@]}"; do
  sub_doc_root="$DOC_ROOT/$sub"
  sub_diagram_tmp="$(mktemp)"
  build_diagram_data "$sub_doc_root" "$sub_diagram_tmp"
  sub_lines="$(wc -l < "$sub_diagram_tmp")"
  rm -f "$sub_diagram_tmp"

  if [[ "$sub_lines" -gt "$CHUNK_THRESHOLD" ]]; then
    # This subsystem is too large — split into its sub-directories
    mapfile -t sub_children < <(
      eval find "$sub_doc_root" -type f -name '"*.md"' $md_find_opts 2>/dev/null \
        | sed "s|^${sub_doc_root}/||" \
        | awk -F/ 'NF>=2 {print $1}' \
        | sort -u
    )
    if [[ "${#sub_children[@]}" -gt 1 ]]; then
      for child in "${sub_children[@]}"; do
        SUBSYSTEMS+=("$sub/$child")
      done
      # Also check for files directly in the subsystem root (not in sub-dirs)
      direct_count="$(eval find "$sub_doc_root" -maxdepth 1 -type f -name '"*.md"' $md_find_opts 2>/dev/null | wc -l)"
      if [[ "$direct_count" -gt 0 ]]; then
        SUBSYSTEMS+=("$sub")  # will be handled as top-level of that subsystem
      fi
    else
      # Only one child or no children — keep as-is
      SUBSYSTEMS+=("$sub")
    fi
  else
    SUBSYSTEMS+=("$sub")
  fi
done

echo "Detected ${#SUBSYSTEMS[@]} subsystem(s):"
for sub in "${SUBSYSTEMS[@]}"; do
  sub_count="$(eval find "$DOC_ROOT/$sub" -type f -name '"*.md"' $md_find_opts 2>/dev/null | wc -l)"
  echo "  - $sub ($sub_count files)"
done
if [[ "$TOP_LEVEL_COUNT" -gt 0 ]]; then
  echo "  - (top-level) ($TOP_LEVEL_COUNT files)"
fi
echo

# Tier 1: Generate per-subsystem overviews
SUBSYSTEM_OVERVIEWS=""
tier1_count=0
tier1_total="${#SUBSYSTEMS[@]}"
if [[ "$TOP_LEVEL_COUNT" -gt 0 ]]; then
  tier1_total=$((tier1_total + 1))
fi

for sub in "${SUBSYSTEMS[@]}"; do
  tier1_count=$((tier1_count + 1))
  sub_doc_root="$DOC_ROOT/$sub"
  sub_diagram="$ARCH_DIR/${sub} diagram_data.md"
  sub_arch="$ARCH_DIR/${sub} architecture.md"

  echo "[Tier 1: $tier1_count/$tier1_total] Analyzing subsystem: $sub"

  # Build subsystem-specific diagram_data
  build_diagram_data "$sub_doc_root" "$sub_diagram"
  sub_lines="$(wc -l < "$sub_diagram")"
  echo "  diagram_data: $sub_lines lines"

  if [[ "$sub_lines" -eq 0 ]]; then
    echo "  (empty — skipping)"
    continue
  fi

  # Call Claude for subsystem overview
  prompt="$(subsystem_prompt "$CODEBASE_DESC — $sub subsystem" "$(cat "$sub_diagram")")"
  resp="$(call_claude "$prompt" "subsystem: $sub")"
  printf '%s\n' "$resp" > "$sub_arch"
  echo "  Wrote: $sub_arch"

  # Accumulate for tier 2
  SUBSYSTEM_OVERVIEWS+="
--- SUBSYSTEM: $sub ---
$resp
"
done

# Handle top-level files (not in any subdirectory)
if [[ "$TOP_LEVEL_COUNT" -gt 0 ]]; then
  tier1_count=$((tier1_count + 1))
  echo "[Tier 1: $tier1_count/$tier1_total] Analyzing: (top-level files)"

  top_diagram="$ARCH_DIR/top-level diagram_data.md"
  top_arch="$ARCH_DIR/top-level architecture.md"

  # Build diagram_data from only top-level .md files
  : > "$top_diagram"
  while IFS= read -r f; do
    awk '
      BEGIN{keep=0}
      NR==1 && $0 ~ /^# / {print $0; next}
      /^## File Purpose/ {keep=1; print; next}
      /^## Core Responsibilities/ {keep=1; print; next}
      /^## External Dependencies/ {keep=1; print; next}
      /^## / && $0 !~ /^## (File Purpose|Core Responsibilities|External Dependencies)/ {keep=0}
      keep==1 {print}
    ' "$f" >> "$top_diagram"
    echo >> "$top_diagram"
  done < <(find "$DOC_ROOT" -maxdepth 1 -type f -name "*.md" \
    ! -name "*architecture.md" ! -name "*diagram_data.md" \
    2>/dev/null | sort)

  top_lines="$(wc -l < "$top_diagram")"
  echo "  diagram_data: $top_lines lines"

  if [[ "$top_lines" -gt 0 ]]; then
    prompt="$(subsystem_prompt "$CODEBASE_DESC — top-level / root files" "$(cat "$top_diagram")")"
    resp="$(call_claude "$prompt" "subsystem: top-level")"
    printf '%s\n' "$resp" > "$top_arch"
    echo "  Wrote: $top_arch"

    SUBSYSTEM_OVERVIEWS+="
--- SUBSYSTEM: top-level ---
$resp
"
  fi
fi

echo
echo "[Tier 2] Synthesizing final architecture overview from ${tier1_count} subsystem overviews..."

# Tier 2: Synthesize final overview from subsystem overviews
prompt="$(synthesis_prompt "$CODEBASE_DESC" "$SUBSYSTEM_OVERVIEWS")"
resp="$(call_claude "$prompt" "final synthesis")"
printf '%s\n' "$resp" > "$OUT_ARCH"

echo
echo "Wrote: $OUT_DIAGRAM (full, $DIAGRAM_LINES lines)"
echo "Wrote: $OUT_ARCH (synthesized from $tier1_count subsystems)"
echo
echo "Subsystem overviews:"
for sub in "${SUBSYSTEMS[@]}"; do
  [[ -f "$ARCH_DIR/${sub} architecture.md" ]] && echo "  - $ARCH_DIR/${sub} architecture.md"
done
[[ -f "$ARCH_DIR/top-level architecture.md" ]] && echo "  - $ARCH_DIR/top-level architecture.md"
echo
echo "Done."
