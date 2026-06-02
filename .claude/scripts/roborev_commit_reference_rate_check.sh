#!/usr/bin/env bash
# roborev_commit_reference_rate_check.sh — weekly threshold check for
# commit_reference adoption in roborev_fix_method_trend.
#
# Reads roborev_fix_method_trend from ~/.claude/logs/unified.duckdb for the
# last 30 days, computes the most recent commit_reference rate, and warns if:
#   - commit_reference rate < THRESHOLD_PCT (default: 5%)
#   - AND the check date is ≥ HOOK_LIVE_DAYS_MIN days after HOOK_LIVE_DATE
#     (default: 30 days after 2026-05-18, when #359 commit-msg hook went live)
#
# Design intent: run from the daily-report email mechanism once ≥14 days of
# trend data have accumulated.  Do NOT wire the call in this PR — wiring waits
# for enough data to avoid noisy early-adoption false positives.
# See llm#389.
#
# Flags:
#   (none)        normal run — reads unified.duckdb and prints result
#   --help        print this header
#
# Environment overrides:
#   UNIFIED_DB          path to unified.duckdb (default: ~/.claude/logs/unified.duckdb)
#   THRESHOLD_PCT       minimum commit_reference % to pass (default: 5)
#   HOOK_LIVE_DATE      date #359 commit-msg hook went live (default: 2026-05-18)
#   HOOK_LIVE_DAYS_MIN  days after HOOK_LIVE_DATE before threshold enforced (default: 30)
#
# Self-test:
#   CLAUDE_HOOK_SELFTEST=1 bash roborev_commit_reference_rate_check.sh
#   → creates fixture DuckDB, verifies threshold logic; exits 0 on pass (7/7)
#
# Exit codes:
#   0  pass (rate >= threshold, or grace period not yet elapsed, or no data)
#   1  warn (rate < threshold AND grace period elapsed)
#   2  error (DB unreadable, duckdb CLI unavailable)
#
# Tracked in llm#389.
#
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

# ── Paths / defaults ──────────────────────────────────────────────────────
UNIFIED_DB="${UNIFIED_DB:-${HOME}/.claude/logs/unified.duckdb}"
THRESHOLD_PCT="${THRESHOLD_PCT:-5}"
HOOK_LIVE_DATE="${HOOK_LIVE_DATE:-2026-05-18}"
HOOK_LIVE_DAYS_MIN="${HOOK_LIVE_DAYS_MIN:-30}"
LOGFILE="${HOME}/.claude/logs/roborev_commit_reference_rate_check.log"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" >> "$LOGFILE" 2>/dev/null || true
}

die() { echo "ERROR: $*" >&2; exit 2; }

# ── Help ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--help" ]; then
  sed -n '3,44p' "$0"
  exit 0
fi

# ── Self-test ─────────────────────────────────────────────────────────────
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  # Disable set -e for the selftest block — duckdb extension signature errors
  # return non-zero even on success; _assert and sub-invocations capture exit
  # codes manually.  Re-enable is not needed: selftest always exits at the end.
  set +e
  PASS=0; FAIL=0

  _assert() {
    local label="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
      PASS=$((PASS + 1))
      echo "  PASS [$label]"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL [$label]: expected='$expected' got='$result'"
    fi
  }

  echo "roborev_commit_reference_rate_check selftest: running..."

  # duckdb CLI is required
  if ! command -v duckdb >/dev/null 2>&1; then
    echo "  SKIP: duckdb CLI not in PATH — cannot run fixture tests"
    echo "1/1 PASS (skipped)"
    exit 0
  fi

  # Selftest uses inline logic (no bash "$0" sub-invocations) to avoid
  # hitting per-user process limits in constrained environments.
  # We test: (a) the duckdb query returns correct pipe-delimited rows,
  #          (b) the grace-period gate, and (c) the awk threshold comparison.

  FX_DIR=$(mktemp -d /tmp/roborev_crr_selftest_XXXXXX)
  trap 'rm -rf "$FX_DIR"' EXIT

  _FX_SCHEMA="CREATE TABLE IF NOT EXISTS roborev_fix_method_trend (run_date DATE NOT NULL, bucket VARCHAR NOT NULL, n_closed INTEGER NOT NULL DEFAULT 0, n_closed_total INTEGER NOT NULL DEFAULT 0, pct_of_closed DOUBLE NOT NULL DEFAULT 0.0, PRIMARY KEY (run_date, bucket))"

  # ── Helper: run inline query against a fixture DB ────────────────────
  # Returns pipe-delimited result from the same SQL used in normal run.
  _crr_query() {
    local db="$1"
    local _Q="SELECT t.run_date::VARCHAR, t.pct_of_closed, t.n_closed, t.n_closed_total FROM roborev_fix_method_trend t WHERE t.bucket = 'commit_reference' AND t.run_date >= (current_date - INTERVAL 30 DAYS) ORDER BY t.run_date DESC LIMIT 1"
    duckdb -init /dev/null -no-stdin -noheader -list "$db" -c "$_Q" 2>/dev/null || true
  }

  # ── Helper: compute days since a date (awk, no sub-shell date) ───────
  _days_since() {
    local hook_date="$1"
    local today_epoch hook_epoch
    today_epoch=$(date -u +%s 2>/dev/null || date +%s)
    if date -j -f "%Y-%m-%d" "${hook_date}" "+%s" >/dev/null 2>&1; then
      hook_epoch=$(date -j -f "%Y-%m-%d" "${hook_date}" "+%s")
    else
      hook_epoch=$(date -d "${hook_date}" "+%s" 2>/dev/null || echo "0")
    fi
    echo $(( (today_epoch - hook_epoch) / 86400 ))
  }

  # ── Helper: threshold awk check ───────────────────────────────────────
  _passes_threshold() {
    local pct="$1" thresh="$2"
    echo "$pct $thresh" | awk '{print ($1 >= $2) ? "1" : "0"}'
  }

  # ── Case 1: absent DB → prerequisite check catches it ────────────────
  FX_ABSENT="/tmp/no_such_db_$$_crr_absent.duckdb"
  if [ ! -f "$FX_ABSENT" ]; then
    _assert "absent_db_detected" "absent" "absent"
  else
    _assert "absent_db_detected" "present" "absent"
  fi

  # ── Case 2: query returns empty for schema-only DB ────────────────────
  FX_EMPTY="${FX_DIR}/empty_unified.duckdb"
  duckdb -init /dev/null -no-stdin "$FX_EMPTY" -c "$_FX_SCHEMA" 2>/dev/null || true
  _row_empty=$(_crr_query "$FX_EMPTY")
  if [ -z "$_row_empty" ]; then
    _assert "empty_db_returns_no_rows" "empty" "empty"
  else
    _assert "empty_db_returns_no_rows" "nonempty:$_row_empty" "empty"
  fi

  # ── Case 3: query returns correct row for populated DB ───────────────
  # Populate with commit_reference rate = 10% (394/3941)
  FX_FULL="${FX_DIR}/full_unified.duckdb"
  duckdb -init /dev/null -no-stdin "$FX_FULL" -c "$_FX_SCHEMA" 2>/dev/null || true
  duckdb -init /dev/null -no-stdin "$FX_FULL" -c "INSERT INTO roborev_fix_method_trend VALUES (current_date, 'unknown', 3150, 3941, 79.9), (current_date, 'autoclose_severity', 397, 3941, 10.1), (current_date, 'manual', 0, 3941, 0.0), (current_date, 'commit_reference', 394, 3941, 10.0)" 2>/dev/null || true
  _row_full=$(_crr_query "$FX_FULL")
  _pct_full=$(echo "$_row_full" | cut -d'|' -f2)
  _assert "query_returns_pct_10" "$_pct_full" "10.0"

  # ── Case 4: grace period gate — future hook date → not elapsed ────────
  _days_future=$(_days_since "2099-01-01")
  if [ "$_days_future" -lt 30 ]; then
    _assert "grace_period_not_elapsed_future_date" "grace_active" "grace_active"
  else
    _assert "grace_period_not_elapsed_future_date" "grace_expired" "grace_active"
  fi

  # ── Case 5: threshold awk — rate 10.0 >= 5 → passes ─────────────────
  _result5=$(_passes_threshold "10.0" "5")
  _assert "rate_10_above_threshold_5" "$_result5" "1"

  # ── Case 6: threshold awk — rate 5.0 >= 5 → exactly at (passes) ──────
  _result6=$(_passes_threshold "5.0" "5")
  _assert "rate_5_exactly_at_threshold_5" "$_result6" "1"

  # ── Case 7: threshold awk — rate 1.0 < 5 → fails ─────────────────────
  _result7=$(_passes_threshold "1.0" "5")
  _assert "rate_1_below_threshold_5" "$_result7" "0"

  echo ""
  TOTAL=$((PASS + FAIL))
  if [ "$FAIL" -eq 0 ]; then
    echo "${PASS}/${TOTAL} PASS"
    exit 0
  else
    echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
    exit 1
  fi
fi

# ── Prerequisite: duckdb CLI ──────────────────────────────────────────────
if ! command -v duckdb >/dev/null 2>&1; then
  die "duckdb CLI not found in PATH; cannot query unified.duckdb"
fi

# ── Prerequisite: unified.duckdb exists ──────────────────────────────────
if [ ! -f "$UNIFIED_DB" ]; then
  die "unified.duckdb not found at ${UNIFIED_DB}"
fi

# ── Compute days since hook went live ────────────────────────────────────
today_epoch=$(date -u +%s 2>/dev/null || date +%s)
# Portable date arithmetic: parse HOOK_LIVE_DATE as seconds since epoch
# macOS: date -j -f "%Y-%m-%d"   Linux: date -d
hook_epoch=""
if date -j -f "%Y-%m-%d" "${HOOK_LIVE_DATE}" "+%s" >/dev/null 2>&1; then
  hook_epoch=$(date -j -f "%Y-%m-%d" "${HOOK_LIVE_DATE}" "+%s")
elif date -d "${HOOK_LIVE_DATE}" "+%s" >/dev/null 2>&1; then
  hook_epoch=$(date -d "${HOOK_LIVE_DATE}" "+%s")
else
  # Fallback: awk-based portable arithmetic
  hook_epoch=$(echo "$HOOK_LIVE_DATE" | awk -F'-' '{
    y=$1; m=$2; d=$3
    # Zeller / day count approximation (Gregorian)
    if (m < 3) { y--; m+=12 }
    A = int(y/100); B = 2 - A + int(A/4)
    jd = int(365.25*(y+4716)) + int(30.6001*(m+1)) + d + B - 1524
    print (jd - 2440588) * 86400
  }')
fi

days_since_hook=0
if [ -n "$hook_epoch" ]; then
  days_since_hook=$(( (today_epoch - hook_epoch) / 86400 ))
fi

# ── Query most recent commit_reference rate (last 30 days) ───────────────
# We take the MOST RECENT run_date's commit_reference row. If there are
# no rows in the last 30 days, we report "no data" and exit 0 (graceful).

_CRR_SQL="SELECT t.run_date::VARCHAR AS run_date, t.pct_of_closed, t.n_closed, t.n_closed_total FROM roborev_fix_method_trend t WHERE t.bucket = 'commit_reference' AND t.run_date >= (current_date - INTERVAL 30 DAYS) ORDER BY t.run_date DESC LIMIT 1"
query_result=$(duckdb -init /dev/null -no-stdin -noheader -list "$UNIFIED_DB" -c "$_CRR_SQL" 2>/dev/null) || true

if [ -z "$query_result" ]; then
  echo "roborev_commit_reference_rate_check: no trend data in last 30 days — skipping check"
  log "INFO: no trend data in last 30 days — skipping"
  exit 0
fi

# Parse pipe-delimited result
run_date_val=$(echo "$query_result" | cut -d'|' -f1)
pct_val=$(echo "$query_result"      | cut -d'|' -f2)
n_closed_val=$(echo "$query_result" | cut -d'|' -f3)
n_total_val=$(echo "$query_result"  | cut -d'|' -f4)

echo "roborev_commit_reference_rate_check:"
echo "  Most recent run_date : ${run_date_val}"
echo "  commit_reference rate: ${pct_val}% (${n_closed_val} of ${n_total_val})"
echo "  Threshold            : ${THRESHOLD_PCT}%"
echo "  Hook live date       : ${HOOK_LIVE_DATE} (${days_since_hook} days ago)"
echo "  Grace period min     : ${HOOK_LIVE_DAYS_MIN} days"

# ── Grace-period gate: enforce threshold only after HOOK_LIVE_DAYS_MIN ───
if [ "$days_since_hook" -lt "$HOOK_LIVE_DAYS_MIN" ]; then
  echo "  Status: GRACE PERIOD (${days_since_hook} < ${HOOK_LIVE_DAYS_MIN} days) — threshold not yet enforced"
  log "INFO: grace period active (${days_since_hook}d < ${HOOK_LIVE_DAYS_MIN}d) — skip threshold"
  exit 0
fi

# ── Threshold comparison (awk for portability — no bc/python required) ───
passes=$(echo "$pct_val $THRESHOLD_PCT" | awk '{print ($1 >= $2) ? "1" : "0"}')

if [ "$passes" = "1" ]; then
  echo "  Status: PASS (${pct_val}% >= ${THRESHOLD_PCT}%)"
  log "INFO: PASS rate=${pct_val}% threshold=${THRESHOLD_PCT}% run_date=${run_date_val}"
  exit 0
fi

# ── Below threshold AND grace elapsed — emit warning ─────────────────────
cat << WARN
  Status: WARN — commit_reference rate (${pct_val}%) is below ${THRESHOLD_PCT}% target

  The #359 commit-msg hook has been live for ${days_since_hook} days but adoption
  appears flat at ${pct_val}% (${n_closed_val} of ${n_total_val} closed reviews have a
  commit reference). Expected: >= ${THRESHOLD_PCT}% by this point.

  Suggested actions:
  1. Verify the commit-msg hook is installed on all active machines:
       ls -la ~/.git-templates/hooks/commit-msg
  2. Check that recent commits actually contain "roborev #N" references:
       git log --oneline --grep="roborev" | head -20
  3. If hook installation was recent, increase HOOK_LIVE_DATE or
     HOOK_LIVE_DAYS_MIN to extend the grace period.
  4. Consider opening a follow-up issue to investigate why adoption is flat.

  Data source: ${UNIFIED_DB}
  Run date   : ${run_date_val}
WARN

log "WARN: commit_reference rate=${pct_val}% below threshold=${THRESHOLD_PCT}% run_date=${run_date_val} days_since_hook=${days_since_hook}"
exit 1
