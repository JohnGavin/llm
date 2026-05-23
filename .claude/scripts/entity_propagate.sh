#!/usr/bin/env bash
# entity_propagate.sh — minimal entity propagation (#137 Phase 3)
#
# Portability fixes (#181 Theme 2 — roborev id 848):
#   - BSD grep /usr/bin/grep on macOS does NOT support \b word-boundary
#     assertions in ERE mode (-E). All word-boundary matches now use
#     POSIX character-class anchors: (^|[^[:alnum:]_])PATTERN([^[:alnum:]_]|$)
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

# Grep configuration.
# BSD grep (/usr/bin/grep on macOS) does NOT support \b word-boundary
# assertions in ERE mode (-E). We use POSIX character-class anchors instead:
#   (^|[^[:alnum:]_])PATTERN([^[:alnum:]_]|$)
# This is portable across BSD grep, GNU grep, and toybox grep.
# Do NOT use \b — it silently matches nothing on BSD grep with -E.
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
  #
  # PORTABILITY: \b is NOT supported by BSD grep (macOS /usr/bin/grep) in ERE
  # mode. Use POSIX character-class boundary instead:
  #   (^|[^[:alnum:]_])  = start of string OR non-word char before match
  #   ([^[:alnum:]_]|$)  = non-word char after match OR end of string
  # This correctly matches "llm" in " llm " but not in "llmtelemetry".
  count=$("$GREP" -ciE "(^|[^[:alnum:]_])${project}([^[:alnum:]_]|$)" "$JSONL" 2>/dev/null)
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

# ── Self-test (run with ENTITY_PROPAGATE_SELFTEST=1) ─────────────────────────
# Tests the POSIX word-boundary regex pattern on known inputs.
# Usage: ENTITY_PROPAGATE_SELFTEST=1 bash entity_propagate.sh
# NOTE: placed before "exit 0" so the env-var gate can actually be reached.
if [ "${ENTITY_PROPAGATE_SELFTEST:-0}" = "1" ]; then
  echo "=== entity_propagate.sh self-test ===" >&2
  TMPF=$(mktemp)
  printf 'mention of llm project here\n' >> "$TMPF"
  printf 'llmtelemetry is a different project\n' >> "$TMPF"
  printf '"project":"llm","action":"test"\n' >> "$TMPF"
  printf 'no match in this line\n' >> "$TMPF"

  # "llm" should match lines 1 and 3 (count=2); NOT line 2 (llmtelemetry)
  c=$("$GREP" -ciE "(^|[^[:alnum:]_])llm([^[:alnum:]_]|$)" "$TMPF" 2>/dev/null || true)
  c=${c:-0}
  if [ "$c" = "2" ]; then
    echo "PASS: 'llm' matched $c/2 expected lines (not llmtelemetry)" >&2
  else
    echo "FAIL: 'llm' matched $c lines (expected 2)" >&2
    rm -f "$TMPF"
    exit 1
  fi

  # "llmtelemetry" should match line 2 only (count=1)
  c2=$("$GREP" -ciE "(^|[^[:alnum:]_])llmtelemetry([^[:alnum:]_]|$)" "$TMPF" 2>/dev/null || true)
  c2=${c2:-0}
  if [ "$c2" = "1" ]; then
    echo "PASS: 'llmtelemetry' matched $c2/1 expected lines" >&2
  else
    echo "FAIL: 'llmtelemetry' matched $c2 lines (expected 1)" >&2
    rm -f "$TMPF"
    exit 1
  fi

  rm -f "$TMPF"
  echo "=== all self-tests passed ===" >&2
fi

exit 0
