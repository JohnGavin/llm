#!/usr/bin/env bash
# tests/test_launchd_run_record_timeout.sh — Integration tests for the
# timeout-enforcement half of bin/launchd_run_record.sh (llm#1190).
#
# Uses an isolated test ledger (LAUNCHD_LEDGER) and an isolated timeouts
# file (LAUNCHD_TIMEOUTS_FILE) so nothing here touches the real
# ~/.claude/logs/launchd_runs.duckdb or the real
# .claude/state/launchd-timeouts.txt.
#
# Usage:
#   bash tests/test_launchd_run_record_timeout.sh
#
# Returns exit code 0 on all pass, non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/launchd_run_record.sh"
TMP="$(mktemp -d /tmp/launchd_timeout_test_XXXXXX)"
LEDGER="$TMP/test_ledger.duckdb"
TIMEOUTS_FILE="$TMP/timeouts.txt"

DUCKDB_BIN="${DUCKDB_BIN:-duckdb}"
if ! command -v "$DUCKDB_BIN" >/dev/null 2>&1; then
  for cand in /opt/homebrew/bin/duckdb /usr/local/bin/duckdb; do
    if [ -x "$cand" ]; then DUCKDB_BIN="$cand"; break; fi
  done
fi

PASS=0
FAIL=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    echo "  PASS: $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc"
    FAIL=$(( FAIL + 1 ))
  fi
}

# query_ledger LABEL COLUMN — most recent row for LABEL, one column, or the
# literal string "NULL" for a SQL NULL.
#
# `-init /dev/null` skips any personal ~/.duckdbrc — on at least one
# development machine this repo runs on, that file sets `.timer on` and
# LOADs several extensions on every invocation, printing "Run Time (s): ..."
# and "loaded ..." banner lines to stdout that would otherwise corrupt the
# single-value result this function returns. This does not affect
# bin/launchd_run_record.sh itself in production (it never reads a value
# back from duckdb's stdout — only INSERTs), so it is a test-isolation fix
# only, not a behaviour change to the script under test.
query_ledger() {
  local label="$1" col="$2"
  "$DUCKDB_BIN" -init /dev/null "$LEDGER" -csv -noheader -c \
    "SELECT COALESCE(CAST(${col} AS VARCHAR), 'NULL') FROM runs WHERE label = '${label}' ORDER BY started_at DESC LIMIT 1;" \
    2>/dev/null
}

echo "=== tests/test_launchd_run_record_timeout.sh ==="
echo "ledger:  $LEDGER"
echo "timeouts file: $TIMEOUTS_FILE"
echo

# ── Fixture: timeouts file ───────────────────────────────────────────────────
cat > "$TIMEOUTS_FILE" <<'EOF'
# test fixture — not the real timeouts file
test.timeout.fires      5     # short bound, deliberately shorter than the sleep below
test.timeout.notfired   30    # generous bound a fast command will never hit
# Test 4 needs its OWN label. Sharing test.timeout.notfired with Test 2 made
# this suite non-deterministic: both wrote a row for that label within the same
# clock second, and query_ledger's `ORDER BY started_at DESC LIMIT 1` then broke
# the tie arbitrarily -- so Test 4 sometimes read Test 2's 'ok' row and failed,
# and could equally have read it and PASSED while the unenforced path was
# broken. Observed failing on one machine and passing on another (llm#1190).
test.timeout.unenforced 30    # same generous bound, distinct label
EOF

# ── Test 1: a configured bound actually fires and is recorded as 'killed' ───
echo "-- Test 1: a real timeout fires and is recorded distinguishably --"

SECONDS=0
LAUNCHD_LEDGER="$LEDGER" LAUNCHD_TIMEOUTS_FILE="$TIMEOUTS_FILE" \
  bash "$SCRIPT" "test.timeout.fires" -- sleep 60 \
  > "$TMP/fires.out" 2> "$TMP/fires.err"
WRAPPER_EXIT=$?
ELAPSED=$SECONDS

assert "wrapper propagates timeout's exit code (124)" "124" "$WRAPPER_EXIT"
# Must be killed at ~5s, nowhere near the full 60s sleep -- proves the bound
# actually bounded wall-clock time, not merely that the DB row looks right.
if [[ "$ELAPSED" -ge 3 && "$ELAPSED" -le 20 ]]; then
  assert_true "killed near the 5s bound, not after the 60s sleep (elapsed=${ELAPSED}s)" "1"
else
  assert_true "killed near the 5s bound, not after the 60s sleep (elapsed=${ELAPSED}s)" "0"
fi
assert "ledger records timeout_bound_s=5" "5" "$(query_ledger test.timeout.fires timeout_bound_s)"
assert "ledger records timeout_status='killed' (not merely exit_code=124)" "killed" "$(query_ledger test.timeout.fires timeout_status)"
assert "ledger records the wrapper's own exit_code=124" "124" "$(query_ledger test.timeout.fires exit_code)"

echo

# ── Test 2: a bound is configured but never hit ─────────────────────────────
echo "-- Test 2: a bounded job that finishes normally records 'ok', not 'killed' --"

LAUNCHD_LEDGER="$LEDGER" LAUNCHD_TIMEOUTS_FILE="$TIMEOUTS_FILE" \
  bash "$SCRIPT" "test.timeout.notfired" -- /bin/echo "hi" \
  > "$TMP/notfired.out" 2> "$TMP/notfired.err"
WRAPPER_EXIT=$?

assert "wrapper exits 0 for a normal fast command" "0" "$WRAPPER_EXIT"
assert "ledger records timeout_bound_s=30" "30" "$(query_ledger test.timeout.notfired timeout_bound_s)"
assert "ledger records timeout_status='ok' (bounded, not hit)" "ok" "$(query_ledger test.timeout.notfired timeout_status)"
assert "ledger records exit_code=0" "0" "$(query_ledger test.timeout.notfired exit_code)"

echo

# ── Test 3: no bound configured for this label — unbounded, exactly as before
echo "-- Test 3: a label with no timeouts-file entry runs unbounded --"

LAUNCHD_LEDGER="$LEDGER" LAUNCHD_TIMEOUTS_FILE="$TIMEOUTS_FILE" \
  bash "$SCRIPT" "test.timeout.none" -- /bin/echo "hi" \
  > "$TMP/none.out" 2> "$TMP/none.err"
WRAPPER_EXIT=$?

assert "wrapper exits 0 for the unbounded command" "0" "$WRAPPER_EXIT"
assert "ledger records timeout_bound_s IS NULL (no bound configured)" "NULL" "$(query_ledger test.timeout.none timeout_bound_s)"
assert "ledger records timeout_status IS NULL (never checked -- distinct from 'ok')" "NULL" "$(query_ledger test.timeout.none timeout_status)"

echo

# ── Test 4: a bound is configured but no timeout binary is available ───────
# Minimal PATH (verified: no `timeout`/`gtimeout` under /usr/bin:/bin on
# this machine) mirrors the real launchd environment's minimal PATH
# (see the existing DUCKDB_BIN fallback comment in the wrapper). duckdb
# itself is still found via the wrapper's hardcoded absolute-path fallback,
# so the ledger write still happens.
echo "-- Test 4: bound configured, no timeout binary -- runs unbounded, recorded as 'unenforced' --"

PATH=/usr/bin:/bin LAUNCHD_LEDGER="$LEDGER" LAUNCHD_TIMEOUTS_FILE="$TIMEOUTS_FILE" \
  bash "$SCRIPT" "test.timeout.unenforced" -- /bin/echo "hi, no timeout binary" \
  > "$TMP/unenforced.out" 2> "$TMP/unenforced.err"
WRAPPER_EXIT=$?

assert "wrapper still runs the job (exit 0) when no timeout binary exists" "0" "$WRAPPER_EXIT"
assert "ledger records timeout_status='unenforced' (never silently pretends the bound applied)" "unenforced" "$(query_ledger test.timeout.unenforced timeout_status)"
assert "ledger still records the configured bound (30) even though it could not be enforced" "30" "$(query_ledger test.timeout.unenforced timeout_bound_s)"
if grep -q "no timeout binary" "$TMP/unenforced.err"; then
  assert_true "a clear warning line was logged to stderr" "1"
else
  assert_true "a clear warning line was logged to stderr" "0"
fi

echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Results: $PASS passed, $FAIL failed ==="
rm -rf "$TMP"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
