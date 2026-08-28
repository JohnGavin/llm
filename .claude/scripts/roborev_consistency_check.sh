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
# Window:
#   The live summary is scoped to a recent window (default 24h) via --since, so the
#   check reflects current pipeline health rather than re-flagging resolved incidents
#   for the 7-day roborev default.  Override via env var:
#     ROBOREV_CONSISTENCY_WINDOW=48h roborev_consistency_check.sh
#   Fixture mode is unaffected (canned JSON, no --since applied).
#
# Exit codes:
#   0 — all invariants pass, check skipped due to missing tooling, OR no reviews
#       in the window (nothing to assert — healthy by definition)
#   1 — at least one invariant INCONSISTENT
#
# Emits on failure:
#   roborev:INCONSISTENT(<which>) <short reason with numbers>
# Silent on success unless --verbose is given.
#
# Wired into session_init.sh banner (Phase 8) and /bye (session-end.md).
# See: llm#679
#
# crash/quota reclassification (llm#904):
#   roborev's own `summary --json` under-counts `.failures.errors.quota` —
#   verified 2026-08-21 against the real DB: it recognizes gemini's
#   TerminalQuotaError text as quota but NOT claude-code's "You've hit your
#   monthly spend limit" (every claude-code spend-limit failure in a
#   19-day/repo-scoped test landed in `crash`, none in `quota`). Since
#   roborev is a third-party binary we cannot fix its own classifier, this
#   script re-derives crash/quota straight from `review_jobs.error` using
#   the same vocabulary as `classify_failure()` in roborev_metrics_etl.R —
#   see the "DB reclassification" block below. `counters.reclassified` in
#   --json output tells a caller whether the live numbers or roborev's raw
#   (possibly under-counted) ones were used; `native_counters` always
#   carries roborev's own numbers for comparison. `--json`'s `per_agent[]`
#   gives the same quota/crash split PER AGENT plus a pass_rate_corrected
#   (= passed / (total - quota), null rather than a misleading 0 when every
#   job for that agent this window was quota-failed) -- use this instead of
#   `roborev summary --json .agents[].pass_rate`, whose denominator still
#   includes quota-failed jobs that never ran a review. Empty array in
#   --fixture mode (no live DB to query) and on a 0-reviews-in-window.

set -euo pipefail

# ── Thresholds (tune here) ───────────────────────────────────────────────────
BACKLOG_THRESHOLD=10          # open backlog items above which we expect verdicts
VERDICTS_LOW_THRESHOLD=1      # verdict count at-or-below which we flag if backlog large
CRASH_RATE_THRESHOLD="0.5"    # fraction of overview.total that is crash+quota → flag
AGENT_ERROR_RATE_THRESHOLD="0.5"  # per-agent errors/total fraction → flag

# Window for the health check. roborev summary defaults to 7d (good for trend
# analysis, wrong for a real-time gate — a 1-day outage would flag for a week).
# 24h reflects current pipeline health; bump to 48h/7d if you want a longer look-back.
CONSISTENCY_WINDOW="${ROBOREV_CONSISTENCY_WINDOW:-24h}"

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
  SUMMARY_JSON=$(timeout 5 "$ROBOREV_BIN" summary --json --since "$CONSISTENCY_WINDOW" 2>/dev/null) || SUMMARY_JSON=""
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

# Keep roborev's own (native) numbers around for comparison in --verbose /
# --json output, before any DB reclassification below overwrites CR_CRASH/CR_QUOTA.
CR_CRASH_NATIVE="$CR_CRASH"
CR_QUOTA_NATIVE="$CR_QUOTA"

# ── DB reclassification of crash vs quota (llm#904) ──────────────────────────
# roborev's own `summary --json` buckets a failure as "quota" only for certain
# error-string shapes (verified 2026-08-21: it recognizes gemini's
# TerminalQuotaError but NOT claude-code's "You've hit your monthly spend
# limit" — measured on the real DB, every claude-code spend-limit failure in
# a 19-day window landed in `crash`, 0 in `quota`). Since roborev is a
# third-party binary we cannot patch its classifier, so this block
# re-derives crash/quota straight from `review_jobs.error` text using the
# same vocabulary as `classify_failure()` in roborev_metrics_etl.R (that
# function's own header cites this exact defect as llm#904) — one canonical
# pattern shared across the ETL and this live gate instead of a third
# diverging copy.
#
# Only attempted when: not in --fixture mode (fixture JSON has no matching
# live DB to query against), sqlite3 is available, the DB file exists, and
# SUMMARY_JSON carries a `.repo_path` to scope the query to THIS repo (a
# global count would double-count other projects' failures into a single
# repo's gate). Any failure to satisfy these falls back to roborev's native
# CR_CRASH/CR_QUOTA — fail-open, matching this script's existing tolerant
# posture on every other counter.
RECLASSIFIED=0
if [ -z "$FIXTURE_FILE" ] && command -v sqlite3 >/dev/null 2>&1; then
  _rb_db="${HOME}/.roborev/reviews.db"
  _repo_path=$(echo "$SUMMARY_JSON" | jq -r '.repo_path // empty')
  if [ -f "$_rb_db" ] && [ -n "$_repo_path" ]; then
    # Convert CONSISTENCY_WINDOW ("24h"/"7d"/"90m") to a SQLite datetime()
    # modifier. Falls back to -24 hours on an unrecognized suffix so a typo
    # in ROBOREV_CONSISTENCY_WINDOW degrades to the documented default
    # rather than silently querying an unbounded window.
    case "$CONSISTENCY_WINDOW" in
      *h) _win_mod="-${CONSISTENCY_WINDOW%h} hours" ;;
      *d) _win_mod="-${CONSISTENCY_WINDOW%d} days" ;;
      *m) _win_mod="-${CONSISTENCY_WINDOW%m} minutes" ;;
      *)  _win_mod="-24 hours" ;;
    esac
    # Same vocabulary as classify_failure()'s `quota` regex in
    # roborev_metrics_etl.R: "spend limit|quota|rate limit|too many
    # requests|429" (case-insensitive — SQLite LIKE is ASCII
    # case-insensitive by default, matching R's ignore.case=TRUE).
    _quota_pattern_sql="(rj.error LIKE '%spend limit%' OR rj.error LIKE '%quota%' OR rj.error LIKE '%rate limit%' OR rj.error LIKE '%too many requests%' OR rj.error LIKE '%429%')"
    _repo_path_escaped=$(printf '%s' "$_repo_path" | sed "s/'/''/g")
    # COALESCE(...,0) — a zero-row match set makes SUM() return NULL, not 0
    # (standard SQL aggregate behaviour). Without COALESCE, a genuinely
    # zero-failure window would print "|" (both fields empty) and be
    # indistinguishable from a query failure, wrongly falling back to
    # roborev's native (possibly under-counted) numbers on the exact case
    # this reclassification is supposed to make authoritative: zero.
    _reclass_rc=0
    _reclass=$(sqlite3 -separator '|' "$_rb_db" "
      SELECT
        COALESCE(SUM(CASE WHEN ${_quota_pattern_sql} THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN NOT ${_quota_pattern_sql} THEN 1 ELSE 0 END), 0)
      FROM review_jobs rj
      JOIN repos r ON r.id = rj.repo_id
      WHERE r.root_path = '${_repo_path_escaped}'
        AND rj.status = 'failed'
        AND datetime(replace(replace(rj.enqueued_at, 'T', ' '), 'Z', '')) > datetime('now', '${_win_mod}');
    " 2>/dev/null) || _reclass_rc=$?
    if [ "$_reclass_rc" -eq 0 ] && [ -n "$_reclass" ]; then
      _reclass_quota="${_reclass%%|*}"
      _reclass_crash="${_reclass##*|}"
      CR_QUOTA="$_reclass_quota"
      CR_CRASH="$_reclass_crash"
      RECLASSIFIED=1
    fi

    # ── Per-agent corrected pass_rate (llm#904 "Known gap") ────────────────
    # roborev summary --json's .agents[].pass_rate denominator includes
    # quota-failed jobs that never actually ran a review, so a
    # quota-exhausted agent's pass_rate reads artificially low (e.g.
    # claude-code 0.14 vs gemini 0.71 during a claude-code billing outage,
    # neither number reflecting review quality). This mirrors the same
    # quota-pattern reclassification above, scoped per rj.agent, and
    # excludes quota-failed jobs from the denominator: pass_rate_corrected
    # = passed / (total - quota_failed), NULL (renders as JSON null, not a
    # misleading 0) when every job for that agent this window was
    # quota-failed. `reviews.verdict_bool` is only set for jobs that
    # actually reached a verdict (status='done'); a job that crashed or hit
    # quota has no matching reviews row, so the LEFT JOIN naturally excludes
    # it from passed/failed_verdict without an extra status filter.
    _per_agent_rc=0
    PER_AGENT_JSON=$(sqlite3 -json "$_rb_db" "
      SELECT
        rj.agent AS agent,
        COUNT(*) AS total,
        COALESCE(SUM(CASE WHEN rj.status = 'failed' AND ${_quota_pattern_sql} THEN 1 ELSE 0 END), 0) AS quota,
        COALESCE(SUM(CASE WHEN rj.status = 'failed' AND NOT ${_quota_pattern_sql} THEN 1 ELSE 0 END), 0) AS crash,
        COALESCE(SUM(CASE WHEN rv.verdict_bool = 1 THEN 1 ELSE 0 END), 0) AS passed,
        COALESCE(SUM(CASE WHEN rv.verdict_bool = 0 THEN 1 ELSE 0 END), 0) AS failed_verdict,
        ROUND(
          CAST(COALESCE(SUM(CASE WHEN rv.verdict_bool = 1 THEN 1 ELSE 0 END), 0) AS REAL) /
          NULLIF(COUNT(*) - COALESCE(SUM(CASE WHEN rj.status = 'failed' AND ${_quota_pattern_sql} THEN 1 ELSE 0 END), 0), 0),
        4) AS pass_rate_corrected
      FROM review_jobs rj
      JOIN repos r ON r.id = rj.repo_id
      LEFT JOIN reviews rv ON rv.job_id = rj.id
      WHERE r.root_path = '${_repo_path_escaped}'
        AND datetime(replace(replace(rj.enqueued_at, 'T', ' '), 'Z', '')) > datetime('now', '${_win_mod}')
      GROUP BY rj.agent;
    " 2>/dev/null) || _per_agent_rc=$?
    if [ "$_per_agent_rc" -ne 0 ] || [ -z "$PER_AGENT_JSON" ]; then
      PER_AGENT_JSON="[]"
    fi
  fi
fi
PER_AGENT_JSON="${PER_AGENT_JSON:-[]}"

# ── 0-reviews-in-window: nothing to assert → healthy ─────────────────────────
# When the summary window contains no reviews (e.g. --since 24h on a quiet day),
# every ratio invariant would divide by zero and the backlog-vs-verdicts check
# would spuriously fire.  Exit 0 early: no activity = no evidence of brokenness.
if [ "$OV_TOTAL" -eq 0 ] 2>/dev/null; then
  if [ "$JSON_OUT" = "1" ]; then
    jq -n \
      --argjson bt "$BACKLOG_THRESHOLD" \
      --argjson vt "$VERDICTS_LOW_THRESHOLD" \
      --arg     ct "$CRASH_RATE_THRESHOLD" \
      --arg     at "$AGENT_ERROR_RATE_THRESHOLD" \
      --arg     win "$CONSISTENCY_WINDOW" \
      '{counters:{overview_total:0,overview_failed:0,verdicts_total:0,verdicts_pass_rate:0,crash:0,quota:0,backlog_open:0},
        per_agent:[],
        thresholds:{backlog_open_gt:$bt,verdicts_total_lte:$vt,crash_rate_gt:($ct|tonumber),agent_error_rate_gt:($at|tonumber)},
        inconsistencies_fired:[],
        note:("0 reviews in window="+$win+" — healthy by definition")}' 2>/dev/null || true
  fi
  if [ "$VERBOSE" = "1" ]; then
    echo "roborev:consistent (0 reviews in window=${CONSISTENCY_WINDOW} — nothing to assert)"
  fi
  exit 0
fi

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
# llm#904: counters.crash/counters.quota are DB-reclassified from
# review_jobs.error when reclassified=true (roborev own summary --json
# under-counts quota — see the header comment above); native_counters is
# always what roborev itself reported, kept for comparison/debugging.
if [ "$JSON_OUT" = "1" ]; then
  jq -n \
    --argjson ov_total    "$OV_TOTAL" \
    --argjson ov_failed   "$OV_FAILED" \
    --argjson vd_total    "$VD_TOTAL" \
    --arg     vd_rate     "$VD_PASS_RATE" \
    --argjson cr_crash    "$CR_CRASH" \
    --argjson cr_quota    "$CR_QUOTA" \
    --argjson cr_crash_native "$CR_CRASH_NATIVE" \
    --argjson cr_quota_native "$CR_QUOTA_NATIVE" \
    --argjson reclassified "$RECLASSIFIED" \
    --argjson backlog     "$BACKLOG_OPEN" \
    --arg     fired       "${FIRED_WHICH% }" \
    --argjson bt          "$BACKLOG_THRESHOLD" \
    --argjson vt          "$VERDICTS_LOW_THRESHOLD" \
    --arg     ct          "$CRASH_RATE_THRESHOLD" \
    --arg     at          "$AGENT_ERROR_RATE_THRESHOLD" \
    --argjson per_agent   "${PER_AGENT_JSON:-[]}" \
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
      reclassified: ($reclassified == 1),
      native_counters: {
        crash: $cr_crash_native,
        quota: $cr_quota_native
      },
      per_agent: $per_agent,
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
  _reclass_note="native(crash=${CR_CRASH_NATIVE},quota=${CR_QUOTA_NATIVE})"
  [ "$RECLASSIFIED" = "1" ] && _reclass_note="reclassified from ${_reclass_note} (llm#904)"
  echo "roborev:consistent (backlog=${BACKLOG_OPEN}, overview_total=${OV_TOTAL}, verdicts=${VD_TOTAL}, crash=${CR_CRASH}, quota=${CR_QUOTA} [${_reclass_note}])"
fi

exit 0
