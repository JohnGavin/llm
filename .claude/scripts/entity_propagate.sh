#!/usr/bin/env bash
# entity_propagate.sh — minimal entity propagation (#137 Phase 3)
#
# Scans the current session's JSONL transcript for mentions of curated
# project names and appends one-line entries to
# knowledge/mentions/<project>.md per occurrence.
#
# Only project mentions are tracked — people / concepts / generic
# entities are deferred (ambiguity tax without an entity registry).
#
# Usage:
#   entity_propagate.sh                 # current session (uses $CLAUDE_CODE_SESSION_ID)
#   entity_propagate.sh <session_id>    # specific session
#
# Exit codes:
#   0  ok (including "no JSONL found" — silent)
#   1  unexpected error

set -o pipefail  # no -e — single project lookup must not kill the pass
                  # no -u either — interacts badly with some snapshot/init scripts

# Use BSD grep explicitly: the nix shell's PATH puts toybox grep first,
# and toybox grep does not support `\b` word boundaries.
GREP="${GREP:-/usr/bin/grep}"
SESSION_ID="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
KNOWLEDGE_ROOT="${KNOWLEDGE_ROOT:-$HOME/docs_gh/llm/knowledge}"
JSONL_BASE="$HOME/.claude/projects/-Users-johngavin-docs-gh-llm"

if [ -z "$SESSION_ID" ]; then
  echo "entity_propagate: no session id (set CLAUDE_CODE_SESSION_ID or pass as arg)" >&2
  exit 0
fi

JSONL="$JSONL_BASE/${SESSION_ID}.jsonl"
[ -f "$JSONL" ] || { echo "entity_propagate: no transcript at $JSONL" >&2; exit 0; }

MENTIONS_DIR="$KNOWLEDGE_ROOT/mentions"
mkdir -p "$MENTIONS_DIR"

# Curated project list — high-signal names that appear often in this
# stack. Keep narrow to avoid false positives ("R" matches everything).
# Add new entries here as the relevant projects come into rotation.
PROJECTS=(
  "llm"
  "llmtelemetry"
  "randomwalk"
  "irishbuoys"
  "mycare"
  "footbet"
  "historicaldata"
  "urban_planning"
  "acd_area_climate_design"
  "coMMpass"
  "gdc-genomics"
  "JohnGavin.github.io"
  "rix.setup"
)

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_PREFIX="$NOW  session=${SESSION_ID:0:8}"

for project in "${PROJECTS[@]}"; do
  # Word-boundary match on the project name. Lowercase compare via grep -i.
  # Count occurrences in the JSONL — each line is a JSON event.
  # `grep -c` exits 1 with output "0" when nothing matches; coerce to int safely.
  count=$("$GREP" -ciE "\\b${project}\\b" "$JSONL" 2>/dev/null)
  count=${count:-0}
  [ "$count" -gt 0 ] || continue

  target="$MENTIONS_DIR/${project}.md"
  if [ ! -f "$target" ]; then
    cat > "$target" <<HEADER
# Mentions of \`${project}\`

Per-session mentions extracted by \`.claude/scripts/entity_propagate.sh\` (#137 Phase 3 minimal cut).
Each line: ISO timestamp, session id prefix, mention count.

---

HEADER
  fi

  echo "${LOG_PREFIX}  count=${count}" >> "$target"
done

exit 0
