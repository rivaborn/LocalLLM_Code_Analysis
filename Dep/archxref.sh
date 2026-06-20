#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# archxref.sh — Cross-Reference Index Generator
#
# Parses per-file architecture docs (from archgen.sh) to build:
#   architecture/xref_index.md
#
# Contains:
# - Function → file mapping (where is each function defined?)
# - Caller → callee edges (who calls whom?)
# - Global state ownership (which file owns which globals?)
# - Header dependency graph (who includes what?)
# - Subsystem interface summary (what each directory exports)
#
# This is pure text processing — no Claude calls required.
# Run after archgen.sh, before arch_overview.sh or archpass2.sh.
# ============================================================

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ARCH_DIR="${ARCH_DIR:-$REPO_ROOT/architecture}"
TARGET="${1:-.}"

if [[ "$TARGET" != "." && "$TARGET" != "all" ]]; then
  DOC_ROOT="$ARCH_DIR/$TARGET"
  OUT_PREFIX="$(basename "$TARGET") "
else
  DOC_ROOT="$ARCH_DIR"
  OUT_PREFIX=""
fi

OUT_XREF="$ARCH_DIR/${OUT_PREFIX}xref_index.md"

echo "============================================"
echo "  archxref.sh — Cross-Reference Index"
echo "============================================"
echo "Doc root:  $DOC_ROOT"
echo "Output:    $OUT_XREF"
echo

# Gather all per-file docs
mapfile -t DOCS < <(
  find "$DOC_ROOT" -type f -name "*.md" \
    ! -path "*/.archgen_state/*" \
    ! -path "*/.overview_state/*" \
    ! -name "architecture.md" \
    ! -name "diagram_data.md" \
    ! -name "xref_index.md" \
    ! -name "*architecture.md" \
    ! -name "*diagram_data.md" \
    ! -name "*xref_index.md" \
    2>/dev/null \
    | sort
)

if [[ "${#DOCS[@]}" -eq 0 ]]; then
  echo "No per-file docs found. Run archgen.sh first." >&2
  exit 1
fi

echo "Parsing ${#DOCS[@]} per-file docs..."

# Temp files for intermediate data
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FUNC_MAP="$TMP_DIR/functions.tsv"       # function_name \t file_path
CALL_EDGES="$TMP_DIR/call_edges.tsv"    # caller_func \t caller_file \t callee_func
GLOBALS="$TMP_DIR/globals.tsv"           # name \t type \t scope \t file
EXTERN_DEPS="$TMP_DIR/extern_deps.tsv"  # file \t symbol
INCLUDE_DEPS="$TMP_DIR/includes.tsv"    # file \t included_header

: > "$FUNC_MAP"
: > "$CALL_EDGES"
: > "$GLOBALS"
: > "$EXTERN_DEPS"
: > "$INCLUDE_DEPS"
parsed=0

for doc in "${DOCS[@]}"; do
  awk '
    BEGIN { file_path=""; section=""; current_func="" }

    # First line: extract file path from # heading
    NR==1 && /^# / { file_path = substr($0, 3); next }

    # Track sections — match all variations Claude might use
    /^## Key Functions/ { section="functions"; current_func=""; next }
    /^## Key Methods/ { section="functions"; current_func=""; next }
    /^## Global/ { section="globals"; next }
    /^## File-Static/ { section="globals"; next }
    /^## External Dep/ { section="deps"; next }
    /^## Control Flow/ { section=""; next }
    /^## Notable/ { section=""; next }
    /^## File Purpose/ { section=""; next }
    /^## Core Resp/ { section=""; next }
    /^## Key Types/ { section=""; next }

    # If we see a ### heading and we are not in a known section,
    # assume we are in the functions section (Claude sometimes omits the ## heading)
    /^### / && section != "globals" && section != "deps" {
      section = "functions"
    }

    # ── Functions: extract ### headings ──
    section=="functions" && /^### / {
      current_func = substr($0, 5)
      gsub(/ *$/, "", current_func)
      # Strip backticks or bold markers from function names
      gsub(/`/, "", current_func)
      gsub(/\*/, "", current_func)
      print current_func "\t" file_path >> "'"$FUNC_MAP"'"
      next
    }

    # ── Functions: extract Calls/calls lines ──
    # Match: "- Calls:", "- **Calls:**", "- **Calls (direct...)**:", etc.
    section=="functions" && current_func != "" && /[Cc]alls?[^a-z]/ && /^- / {
      line = $0
      while (match(line, /`[A-Za-z_][A-Za-z0-9_]*`/)) {
        callee = substr(line, RSTART+1, RLENGTH-2)
        print current_func "\t" file_path "\t" callee >> "'"$CALL_EDGES"'"
        line = substr(line, RSTART+RLENGTH)
      }
      next
    }

    # ── Globals: parse table rows ──
    section=="globals" && /^\|/ && !/^\| *Name/ && !/^\|[-—]+/ && !/^\| *-/ {
      n = split($0, cols, "|")
      if (n >= 5) {
        name = cols[2]; type = cols[3]; scope = cols[4]
        gsub(/^ *| *$/, "", name); gsub(/^ *| *$/, "", type); gsub(/^ *| *$/, "", scope)
        gsub(/`/, "", name); gsub(/`/, "", type)
        if (name != "" && name != "None" && name !~ /^-+$/) {
          print name "\t" type "\t" scope "\t" file_path >> "'"$GLOBALS"'"
        }
      }
      next
    }

    # ── External deps: extract backtick-wrapped identifiers ──
    section=="deps" && /`/ {
      line = $0
      while (match(line, /`[A-Za-z_][A-Za-z0-9_\/]*\.[a-z]+`/)) {
        inc = substr(line, RSTART+1, RLENGTH-2)
        print file_path "\t" inc >> "'"$INCLUDE_DEPS"'"
        line = substr(line, RSTART+RLENGTH)
      }
      line = $0
      while (match(line, /`[A-Za-z_][A-Za-z0-9_]*`/)) {
        sym = substr(line, RSTART+1, RLENGTH-2)
        if (index(sym, ".") == 0) {
          print file_path "\t" sym >> "'"$EXTERN_DEPS"'"
        }
        line = substr(line, RSTART+RLENGTH)
      }
      next
    }
  ' "$doc"

  # Progress indicator every 100 files
  parsed=$((parsed + 1))
  if (( parsed % 100 == 0 )); then
    echo "  ...parsed $parsed/${#DOCS[@]}" >&2
  fi
done

echo "Extracted:"
echo "  Functions:     $(wc -l < "$FUNC_MAP")"
echo "  Call edges:    $(wc -l < "$CALL_EDGES")"
echo "  Globals:       $(wc -l < "$GLOBALS")"
echo "  Include deps:  $(wc -l < "$INCLUDE_DEPS")"
echo "  Extern refs:   $(wc -l < "$EXTERN_DEPS")"
echo

# ── Build the xref_index.md ──
{
  echo "# Cross-Reference Index"
  echo
  echo "Auto-generated from per-file architecture docs."
  echo

  # ── Function → File Map ──
  echo "## Function Definition Map"
  echo
  echo "| Function | Defined In |"
  echo "|----------|-----------|"
  sort -t$'\t' -k1,1 "$FUNC_MAP" | while IFS=$'\t' read -r func file; do
    echo "| \`$func\` | \`$file\` |"
  done
  echo

  # ── Call Graph (top callers) ──
  echo "## Call Graph — Most Connected Functions"
  echo
  echo "Functions sorted by number of outgoing calls."
  echo
  echo "| Caller | File | Callees (count) |"
  echo "|--------|------|-----------------|"
  awk -F'\t' '{key=$1"\t"$2; count[key]++; callees[key]=callees[key]" "$3} END {for(k in count) print count[k]"\t"k"\t"callees[k]}' "$CALL_EDGES" \
    | sort -t$'\t' -k1,1 -rn | head -40 | while IFS=$'\t' read -r cnt caller file callees; do
      # Deduplicate callee list
      unique="$(echo "$callees" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')"
      echo "| \`$caller\` | \`$file\` | $cnt: $unique|"
    done
  echo

  # ── Reverse Call Map (most called functions) ──
  echo "## Most Called Functions"
  echo
  echo "| Function | Called By (count) | Callers |"
  echo "|----------|-------------------|---------|"
  awk -F'\t' '{print $3"\t"$1"\t"$2}' "$CALL_EDGES" \
    | awk -F'\t' '{key=$1; count[key]++; callers[key]=callers[key]" "$2"("$3")"} END {for(k in count) print count[k]"\t"k"\t"callers[k]}' \
    | sort -t$'\t' -k1,1 -rn | head -30 | while IFS=$'\t' read -r cnt func callers; do
      # Show just caller names (not file paths) for readability
      caller_names="$(echo "$callers" | grep -oP '[A-Za-z_][A-Za-z0-9_]*(?=\()' | sort -u | tr '\n' ' ')"
      echo "| \`$func\` | $cnt | $caller_names|"
    done
  echo

  # ── Global State Ownership ──
  global_count="$(wc -l < "$GLOBALS")"
  if [[ "$global_count" -gt 0 ]]; then
    echo "## Global State Ownership"
    echo
    echo "| Name | Type | Scope | Owner File |"
    echo "|------|------|-------|-----------|"
    sort -t$'\t' -k1,1 "$GLOBALS" | while IFS=$'\t' read -r name type scope file; do
      echo "| \`$name\` | \`$type\` | $scope | \`$file\` |"
    done
    echo
  fi

  # ── Include Dependency Graph ──
  include_count="$(wc -l < "$INCLUDE_DEPS")"
  if [[ "$include_count" -gt 0 ]]; then
    echo "## Header Dependencies"
    echo
    echo "Most-included headers (by number of dependents)."
    echo
    echo "| Header | Included By (count) |"
    echo "|--------|---------------------|"
    awk -F'\t' '{print $2}' "$INCLUDE_DEPS" | sort | uniq -c | sort -rn | head -25 | while read -r cnt hdr; do
      echo "| \`$hdr\` | $cnt |"
    done
    echo
  fi

  # ── Subsystem Interface Summary ──
  echo "## Subsystem Interfaces"
  echo
  echo "Functions exported by each top-level directory."
  echo
  awk -F'\t' '{
    split($2, parts, "/")
    if (length(parts) >= 2) dir = parts[1]
    else dir = "(root)"
    print dir"\t"$1
  }' "$FUNC_MAP" | sort -t$'\t' -k1,1 -k2,2 | awk -F'\t' '
    BEGIN { prev="" }
    {
      if ($1 != prev) {
        if (prev != "") print ""
        print "### " $1
        print ""
        prev = $1
      }
      print "- `" $2 "`"
    }
  '
  echo

} > "$OUT_XREF"

echo "Wrote: $OUT_XREF ($(wc -l < "$OUT_XREF") lines)"
echo "Done."
