#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# archgraph.sh — Call Graph & Dependency Diagram Generator
#
# Parses per-file architecture docs (from archgen.sh) and produces
# Mermaid diagrams:
#   architecture/callgraph.mermaid        — function-level call graph
#   architecture/subsystems.mermaid       — subsystem dependency diagram
#
# No Claude calls required — pure text processing.
# Run after archgen.sh (and optionally archxref.sh).
# ============================================================

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ARCH_DIR="${ARCH_DIR:-$REPO_ROOT/architecture}"
TARGET="${1:-.}"

# Max edges to include in the call graph (too many = unreadable)
MAX_CALL_EDGES="${MAX_CALL_EDGES:-150}"
# Minimum call count for a function to appear in the call graph
MIN_CALL_SIGNIFICANCE="${MIN_CALL_SIGNIFICANCE:-2}"

if [[ "$TARGET" != "." && "$TARGET" != "all" ]]; then
  DOC_ROOT="$ARCH_DIR/$TARGET"
  OUT_PREFIX="$(basename "$TARGET") "
else
  DOC_ROOT="$ARCH_DIR"
  OUT_PREFIX=""
fi

OUT_CALLGRAPH="$ARCH_DIR/${OUT_PREFIX}callgraph.mermaid"
OUT_SUBSYSTEMS="$ARCH_DIR/${OUT_PREFIX}subsystems.mermaid"
OUT_CALLGRAPH_MD="$ARCH_DIR/${OUT_PREFIX}callgraph.md"

echo "============================================"
echo "  archgraph.sh — Call Graph Generator"
echo "============================================"
echo "Doc root:  $DOC_ROOT"
echo "Max edges: $MAX_CALL_EDGES"
echo

mapfile -t DOCS < <(
  find "$DOC_ROOT" -type f -name "*.md" \
    ! -path "*/.archgen_state/*" \
    ! -path "*/.overview_state/*" \
    ! -name "architecture.md" \
    ! -name "diagram_data.md" \
    ! -name "xref_index.md" \
    ! -name "callgraph.md" \
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FUNC_FILE="$TMP_DIR/func_file.tsv"     # func \t file \t directory
EDGES="$TMP_DIR/edges.tsv"              # caller \t callee \t caller_dir
: > "$FUNC_FILE"
: > "$EDGES"

parsed=0
for doc in "${DOCS[@]}"; do
  awk '
    BEGIN { file_path=""; section=""; current_func="" }

    NR==1 && /^# / {
      file_path = substr($0, 3)
      n = split(file_path, parts, "/")
      if (n >= 2) subsystem = parts[1]
      else subsystem = "root"
      next
    }

    /^## Key Functions/ { section="functions"; current_func=""; next }
    /^## Key Methods/ { section="functions"; current_func=""; next }
    /^## Global/ { section=""; next }
    /^## External/ { section=""; next }
    /^## Control/ { section=""; next }
    /^## File Purpose/ { section=""; next }
    /^## Core Resp/ { section=""; next }
    /^## Key Types/ { section=""; next }

    # Detect functions by ### heading even without section header
    /^### / && section != "globals" && section != "deps" {
      section = "functions"
    }

    section=="functions" && /^### / {
      current_func = substr($0, 5)
      gsub(/ *$/, "", current_func)
      gsub(/`/, "", current_func)
      gsub(/\*/, "", current_func)
      print current_func "\t" file_path "\t" subsystem >> "'"$FUNC_FILE"'"
      next
    }

    section=="functions" && current_func != "" && /[Cc]alls?[^a-z]/ && /^- / {
      line = $0
      while (match(line, /`[A-Za-z_][A-Za-z0-9_]*`/)) {
        callee = substr(line, RSTART+1, RLENGTH-2)
        print current_func "\t" callee "\t" subsystem >> "'"$EDGES"'"
        line = substr(line, RSTART+RLENGTH)
      }
      next
    }
  ' "$doc"

  parsed=$((parsed + 1))
  if (( parsed % 100 == 0 )); then
    echo "  ...parsed $parsed/${#DOCS[@]}" >&2
  fi
done

total_funcs="$(wc -l < "$FUNC_FILE")"
total_edges="$(wc -l < "$EDGES")"
echo "Found $total_funcs functions, $total_edges call edges."

# ── Build function-level call graph ──
# Filter to most significant edges (functions called by or calling multiple others)
{
  echo "%%{ init: { 'theme': 'dark', 'flowchart': { 'curve': 'basis' } } }%%"
  echo "graph LR"
  echo

  # Build subgraphs by subsystem
  # First, collect all subsystems
  subsystems="$(awk -F'\t' '{print $3}' "$FUNC_FILE" | sort -u)"

  # Count how many times each function appears as a callee (significance)
  callee_counts="$TMP_DIR/callee_counts.tsv"
  awk -F'\t' '{print $2}' "$EDGES" | sort | uniq -c | sort -rn > "$callee_counts"

  # Build set of significant functions (called >= MIN_CALL_SIGNIFICANCE times OR is a caller)
  significant="$TMP_DIR/significant.txt"
  awk -v min="$MIN_CALL_SIGNIFICANCE" '$1 >= min {print $2}' "$callee_counts" > "$significant"
  # Also add all callers that call significant functions
  awk -F'\t' '{print $1}' "$EDGES" | sort -u >> "$significant"
  sort -u "$significant" -o "$significant"

  # Emit subgraphs
  for sub in $subsystems; do
    echo "  subgraph ${sub}"
    awk -F'\t' -v s="$sub" '$3==s {print $1}' "$FUNC_FILE" | sort -u | while read -r func; do
      if grep -qxF "$func" "$significant"; then
        # Sanitize node ID (Mermaid doesn't like some chars)
        node_id="$(echo "$func" | tr -c 'A-Za-z0-9_' '_')"
        echo "    ${node_id}[\"${func}\"]"
      fi
    done
    echo "  end"
    echo
  done

  # Emit edges (only between significant functions, limited to MAX_CALL_EDGES)
  edge_count=0
  sort -u "$EDGES" | while IFS=$'\t' read -r caller callee _sub; do
    if grep -qxF "$caller" "$significant" && grep -qxF "$callee" "$significant"; then
      caller_id="$(echo "$caller" | tr -c 'A-Za-z0-9_' '_')"
      callee_id="$(echo "$callee" | tr -c 'A-Za-z0-9_' '_')"
      if [[ "$caller_id" != "$callee_id" ]]; then
        echo "  ${caller_id} --> ${callee_id}"
        edge_count=$((edge_count + 1))
        if [[ "$edge_count" -ge "$MAX_CALL_EDGES" ]]; then
          break
        fi
      fi
    fi
  done

} > "$OUT_CALLGRAPH"

echo "Wrote: $OUT_CALLGRAPH"

# ── Build subsystem dependency diagram ──
{
  echo "%%{ init: { 'theme': 'dark' } }%%"
  echo "graph TD"
  echo

  # Count functions per subsystem for node labels
  awk -F'\t' '{print $3}' "$FUNC_FILE" | sort | uniq -c | sort -rn | while read -r cnt sub; do
    sub_id="$(echo "$sub" | tr -c 'A-Za-z0-9_' '_')"
    echo "  ${sub_id}[\"${sub} (${cnt} funcs)\"]"
  done
  echo

  # Cross-subsystem call edges
  awk -F'\t' '{print $1"\t"$2"\t"$3}' "$EDGES" | while IFS=$'\t' read -r caller callee caller_sub; do
    # Look up callee's subsystem
    callee_sub="$(grep -P "^${callee}\t" "$FUNC_FILE" | head -1 | awk -F'\t' '{print $3}')"
    if [[ -n "$callee_sub" && "$caller_sub" != "$callee_sub" ]]; then
      echo "${caller_sub}\t${callee_sub}"
    fi
  done | sort | uniq -c | sort -rn | head -50 | while read -r cnt from_sub to_sub; do
    from_id="$(echo "$from_sub" | tr -c 'A-Za-z0-9_' '_')"
    to_id="$(echo "$to_sub" | tr -c 'A-Za-z0-9_' '_')"
    if [[ "$from_id" != "$to_id" ]]; then
      echo "  ${from_id} -->|${cnt} calls| ${to_id}"
    fi
  done

} > "$OUT_SUBSYSTEMS"

echo "Wrote: $OUT_SUBSYSTEMS"

# ── Build a combined markdown doc ──
{
  echo "# Call Graph & Dependency Diagrams"
  echo
  echo "Auto-generated from per-file architecture docs."
  echo
  echo "## Function Call Graph"
  echo
  echo "Showing functions with $MIN_CALL_SIGNIFICANCE+ incoming calls and their callers."
  echo "Grouped by subsystem (directory). Limited to $MAX_CALL_EDGES edges."
  echo
  echo '```mermaid'
  cat "$OUT_CALLGRAPH"
  echo '```'
  echo
  echo "## Subsystem Dependencies"
  echo
  echo "Cross-subsystem call edges. Arrow labels show number of cross-boundary calls."
  echo
  echo '```mermaid'
  cat "$OUT_SUBSYSTEMS"
  echo '```'
  echo
  echo "## Statistics"
  echo
  echo "- Total functions documented: $total_funcs"
  echo "- Total call edges: $total_edges"
  echo "- Subsystems: $(echo "$subsystems" | wc -w)"
  echo

} > "$OUT_CALLGRAPH_MD"

echo "Wrote: $OUT_CALLGRAPH_MD"
echo
echo "Done. View the Mermaid diagrams in any Mermaid-compatible viewer, or"
echo "open $OUT_CALLGRAPH_MD in a markdown editor that supports Mermaid."
