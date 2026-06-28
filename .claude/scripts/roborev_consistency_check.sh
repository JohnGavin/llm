#!/usr/bin/env bash
# roborev_consistency_check.sh
# Cross-counter consistency check for roborev — asserts that the numbers in
# `roborev summary --json` do not contradict each other, which is the earliest
# cheap signal that the review pipeline is broken (llm#679, meta-fix for #676).
#
# Usage:
#   roborev_consistency_check.sh [--verbose] [--json]
#   roborev_consistency_check.sh --fixture <summary.json> [--backlog-count <n>] [--verbose] [--json]
#
# Exit codes:
#   0 — all invariants pass (or check skipped due to missing tooling)
#   1 — at least one invariant INCONSISTENT
#
# Emits on failure:
#   roborev:INCONSISTENT(<which>) <short reason with numbers>
# Silent on success unless --verbose is given.
#
# Wired into session_init.sh banner (Phase 8) and /bye (session-end.md).
# See: llm#679

set -euo pipefail

# ── Thresholds (tune here) ───────────────────────────────────────────────────
BACKLOG_THRESHOLD=10          # open backlog items above which we expect verdicts
VERDICTS_LOW_THRESHOLD=1      # verdict count at-or-below which we flag if backlog large
CRASH_RATE_THRESHOLD="0.5"    # fraction of overview.total that is crash+quota → flag
AGENT_ERROR_RATE_THRESHOLD="0.5"  # per-agent errors/total fraction → flag

# ── Argument parsing ──────────────────────────────────────────────────────────
VERBOSE=0
JSON_OUT=0
FIXTURE_FILE=""
FIXTURE_BACKLOG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose)    VERBOSE=1; shift ;;
    --json)       JSON_OUT=1; shift ;;
    --fixture)    FIXTURE_FILE="$2"; shift 2 ;;
    --backlog-count) FIXTURE_BACKLOG="$2"; shift 2 ;;
    *)            shift ;;  # ignore unknown flags
  esac
done

# ── Tooling checks ────────────────────────────────────────────────────────────
ROBOREV_BIN="${ROBOREV_BIN:-/usr/local/bin/roborev}"

if [ -z "$FIXTURE_FILE" ]; then
  if ! command -v "$ROBOREV_BIN" >/dev/null 2>&1 && [ ! -x "$ROBOREV_BIN" ]; then
    echo "roborev:consistency-skipped (roborev not installed)"
    exit 0
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "roborev:consistency-skipped (jq not installed)"
  exit 0
fi

# ── Gather summary JSON ───────────────────────────────────────────────────────
if [ -n "$FIXTURE_FILE" ]; then
  if [ ! -f "$FIXTURE_FILE" ]; then
    echo "roborev:consistency-skipped (fixture file not found: $FIXTURE_FILE)"
    exit 0
  fi
  SUMMARY_JSON=$(cat "$FIXTURE_FILE")
else
  SUMMARY_JSON=$(timeout 5 "$ROBOREV_BIN" summary --json 2>/dev/null) || SUMMARY_JSON=""
fi

if [ -z "$SUMMARY_JSON" ]; then
  echo "roborev:consistency-skipped (summary --json returned empty)"
  exit 0
fi

# Validate it's valid JSON
if ! echo "$SUMMARY_JSON" | jq . >/dev/null 2>&1; then
  echo "roborev:consistency-skipped (summary --json returned invalid JSON)"
  exit 0
fi

# ── Extract counters via jq ───────────────────────────────────────────────────
OV_TOTAL=$(echo "$SUMMARY_JSON"    | jq -r '.overview.total         // 0')
OV_FAILED=$(echo "$SUMMARY_JSON"   | jq -r '.overview.failed        // 0')
VD_TOTAL=$(echo "$SUMMARY_JSON"    | jq -r '.verdicts.total         // 0')
VD_PASS_RATE=$(echo "$SUMMARY_JSON"| jq -r '.verdicts.pass_rate     // 0')
CR_CRASH=$(echo "$SUMMARY_JSON"    | jq -r '.failures.errors.crash  // 0')
CR_QUOTA=$(echo "$SUMMARY_JSON"    | jq -r '.failures.errors.quota  // 0')

# Integer-safe coercions (jq -r can return null if field absent)
OV_TOTAL="${OV_TOTAL:-0}";   OV_TOTAL="${OV_TOTAL/null/0}"
OV_FAILED="${OV_FAILED:-0}"; OV_FAILED="${OV_FAILED/null/0}"
VD_TOTAL="${VD_TOTAL:-0}";   VD_TOTAL="${VD_TOTAL/null/0}"
VD_PASS_RATE="${VD_PASS_RATE:-0}"; VD_PASS_RATE="${VD_PASS_RATE/null/0}"
CR_CRASH="${CR_CRASH:-0}";   CR_CRASH="${CR_CRASH/null/0}"
CR_QUOTA="${CR_QUOTA:-0}";   CR_QUOTA="${CR_QUOTA/null/0}"

# ── Backlog count ─────────────────────────────────────────────────────────────
# In fixture mode: use --backlog-count N (or 0 if not provided)
# In live mode: query sqlite DB
if [ -n "$FIXTURE_BACKLOG" ]; then
  BACKLOG_OPEN="$FIXTURE_BACKLOG"
else
  BACKLOG_OPEN=0
  _RB_DB="${HOME}/.roborev/reviews.db"
  if [ -f "$_RB_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    BACKLOG_OPEN=$(sqlite3 "$_RB_DB" \
      "SELECT COUNT(*) FROM reviews WHERE closed=0" 2>/dev/null) || BACKLOG_OPEN=0
    BACKLOG_OPEN="${BACKLOG_OPEN:-0}"
  fi
fi

# ── Invariant checks ──────────────────────────────────────────────────────────
INCONSISTENCIES=""
FIRED_WHICH=""

# Helper: append a finding
_flag() {
  local which="$1"; local reason="$2"
  INCONSISTENCIES="${INCONSISTENCIES}roborev:INCONSISTENT(${which}) ${reason}"$'\n'
  FIRED_WHICH="${FIRED_WHICH}${which} "
}

# Invariant 1: Large backlog with near-zero verdicts
# If we have many open reviews but almost no verdicts, reviews aren't producing outputs
if [ "$BACKLOG_OPEN" -gt "$BACKLOG_THRESHOLD" ] 2>/dev/null; then
  if [ "$VD_TOTAL" -le "$VERDICTS_LOW_THRESHOLD" ] 2>/dev/null; then
    _flag "backlog-vs-verdicts" \
      "backlog.open=${BACKLOG_OPEN} but verdicts.total=${VD_TOTAL} (>$BACKLOG_THRESHOLD open reviews, <=$VERDICTS_LOW_THRESHOLD verdicts suggests reviews not completing)"
  fi
fi

# Invariant 2: Jobs exist but zero verdicts — every job failed before verdict
if [ "$OV_TOTAL" -gt 0 ] 2>/dev/null; then
  if [ "$VD_TOTAL" -eq 0 ] 2>/dev/null; then
    _flag "jobs-no-verdicts" \
      "overview.total=${OV_TOTAL} but verdicts.total=0 (all jobs failed before producing a verdict)"
  fi
fi

# Invariant 3: High crash+quota rate
# Use jq for float arithmetic: (crash+quota)/total > threshold
if [ "$OV_TOTAL" -gt 0 ] 2>/dev/null; then
  CR_HIGH=$(echo "$SUMMARY_JSON" | jq --argjson threshold "$CRASH_RATE_THRESHOLD" \
    --argjson total "$OV_TOTAL" \
    '((.failures.errors.crash // 0) + (.failures.errors.quota // 0)) as $errors |
     if $total > 0 and ($errors / $total) > $threshold then 1 else 0 end' 2>/dev/null) || CR_HIGH=0
  if [ "${CR_HIGH:-0}" = "1" ]; then
    CR_TOTAL=$((CR_CRASH + CR_QUOTA))
    _flag "high-crash-rate" \
      "crash+quota=${CR_TOTAL}/${OV_TOTAL} jobs ($(echo "$SUMMARY_JSON" | \
        jq -r "(((.failures.errors.crash // 0) + (.failures.errors.quota // 0)) / $OV_TOTAL * 100 | round | tostring) + \"%\"" 2>/dev/null || echo "?%") > threshold ${CRASH_RATE_THRESHOLD})"
  fi
fi

# Invariant 4: Per-agent error rate above threshold
# Iterate over agents[] where errors/total > threshold
if echo "$SUMMARY_JSON" | jq -e '.agents | type == "array"' >/dev/null 2>&1; then
  BAD_AGENTS=$(echo "$SUMMARY_JSON" | jq -r \
    --argjson threshold "$AGENT_ERROR_RATE_THRESHOLD" \
    '.agents[] |
     select(.total > 0 and ((.errors // 0) / .total) > $threshold) |
     .agent + "=" + ((.errors // 0) | tostring) + "/" + (.total | tostring)' \
    2>/dev/null) || BAD_AGENTS=""
  if [ -n "$BAD_AGENTS" ]; then
    while IFS= read -r agent_stat; do
      [ -z "$agent_stat" ] && continue
      agent_name=$(echo "$agent_stat" | cut -d= -f1)
      agent_nums=$(echo "$agent_stat" | cut -d= -f2)
      _flag "agent:${agent_name}" \
        "agent ${agent_name} errors=${agent_nums} (>${AGENT_ERROR_RATE_THRESHOLD} rate)"
    done <<< "$BAD_AGENTS"
  fi
fi

# Invariant 5: 100% pass_rate but overview.failed > 0 — pass_rate masks crashes
# Pass rate is computed only over verdicts; if jobs crash they don't reach verdict,
# so pass_rate can appear 1.0 while overview.failed is high.
if [ "$OV_FAILED" -gt 0 ] 2>/dev/null; then
  # Compare float: pass_rate == 1.0
  RATE_IS_ONE=$(echo "$VD_PASS_RATE" | awk '{print ($1 == 1.0) ? "1" : "0"}')
  if [ "${RATE_IS_ONE:-0}" = "1" ]; then
    _flag "passrate-masks-crashes" \
      "verdicts.pass_rate=1.0 but overview.failed=${OV_FAILED} (\"100% pass\" is hiding job-level failures)"
  fi
fi

# ── JSON output mode ──────────────────────────────────────────────────────────
if [ "$JSON_OUT" = "1" ]; then
  jq -n \
    --argjson ov_total    "$OV_TOTAL" \
    --argjson ov_failed   "$OV_FAILED" \
    --argjson vd_total    "$VD_TOTAL" \
    --arg     vd_rate     "$VD_PASS_RATE" \
    --argjson cr_crash    "$CR_CRASH" \
    --argjson cr_quota    "$CR_QUOTA" \
    --argjson backlog     "$BACKLOG_OPEN" \
    --arg     fired       "${FIRED_WHICH% }" \
    --argjson bt          "$BACKLOG_THRESHOLD" \
    --argjson vt          "$VERDICTS_LOW_THRESHOLD" \
    --arg     ct          "$CRASH_RATE_THRESHOLD" \
    --arg     at          "$AGENT_ERROR_RATE_THRESHOLD" \
    '{
      counters: {
        overview_total: $ov_total,
        overview_failed: $ov_failed,
        verdicts_total: $vd_total,
        verdicts_pass_rate: ($vd_rate | tonumber),
        crash: $cr_crash,
        quota: $cr_quota,
        backlog_open: $backlog
      },
      thresholds: {
        backlog_open_gt: $bt,
        verdicts_total_lte: $vt,
        crash_rate_gt: ($ct | tonumber),
        agent_error_rate_gt: ($at | tonumber)
      },
      inconsistencies_fired: (if $fired == "" then [] else ($fired | split(" ") | map(select(. != ""))) end)
    }' 2>/dev/null || true
fi

# ── Emit results ──────────────────────────────────────────────────────────────
if [ -n "$INCONSISTENCIES" ]; then
  printf '%s' "$INCONSISTENCIES"
  exit 1
fi

if [ "$VERBOSE" = "1" ]; then
  echo "roborev:consistent (backlog=${BACKLOG_OPEN}, overview_total=${OV_TOTAL}, verdicts=${VD_TOTAL}, crash+quota=$((CR_CRASH+CR_QUOTA)))"
fi

exit 0
