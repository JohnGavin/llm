#!/usr/bin/env bash
# test_session_agent_error_staging.sh — Hermetic tests for llm#956: the
# durable-write fix that extends #710 (originally applied only to the `hook`
# case in log_session.sh) to the `start`/`stop`/`agent_start`/`agent_stop`/
# `error` cases.
#
# Root cause (verified by the orchestrator on a throwaway DB, NOT reproduced
# here — do not attempt to reproduce lock contention in this test): the
# duckdb CLI takes an exclusive whole-file lock on unified.duckdb, which has
# many concurrent writers. 12 concurrent CLI writers landed only 1; the other
# 11 failed with "Could not set lock on file ... Conflicting lock is held".
# That error was suppressed 3x over: `2>/dev/null`, `|| true`, and the
# caller backgrounding the whole hook with `nohup ... &`.
#
# Fix: log_session.sh's start/stop/agent_start/agent_stop/error cases now
# append lock-free JSONL to staging files instead of calling the duckdb CLI.
# session_events_staging_import.sh / agent_events_staging_import.sh /
# error_events_staging_import.sh drain those files into sessions/agent_runs/
# errors respectively, at ETL cadence (called from roborev_metrics_etl.sh).
#
# This test proves, against a scratch DB only:
#   1. log_session.sh no longer touches unified.duckdb at all for any case
#      (proven by watching the DB file's byte size stay constant across all
#      5 non-hook actions).
#   2. Each import script correctly drains its staging file.
#   3. No-clobber: a `stop`/`agent_stop` event with a blank model/summary
#      never overwrites a value recorded by an earlier start/stop.
#   4. Idempotency: replaying an identical staging batch twice produces the
#      same row count and the same column values (no duplication, no drift).
#   5. Errors are NOT silenced: a forced write failure surfaces real detail
#      on stderr/log and preserves the batch instead of deleting it.
#
# Requires: duckdb on PATH.

set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_SCRIPT="$WT/.claude/scripts/log_session.sh"
SESSIONS_IMPORT="$WT/.claude/scripts/session_events_staging_import.sh"
AGENT_IMPORT="$WT/.claude/scripts/agent_events_staging_import.sh"
ERROR_IMPORT="$WT/.claude/scripts/error_events_staging_import.sh"
FRESHNESS_SCRIPT="$WT/.claude/scripts/etl_freshness_upsert.sh"

PASS=0
FAIL=0

dq() {
  local db="$1" sql="$2"
  duckdb -init /dev/null "$db" -noheader -list -c "$sql" 2>/dev/null
}

assert() {
  local desc="$1" result="$2" expected="$3"
  if [ "$result" = "$expected" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        expected: [$expected]"
    echo "        got:      [$result]"
    FAIL=$((FAIL + 1))
  fi
}

if ! command -v duckdb >/dev/null 2>&1; then
  echo "SKIP: duckdb not on PATH — cannot run test_session_agent_error_staging.sh"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# --------------------------------------------------------------------------
# Setup temp HOME
# --------------------------------------------------------------------------
T=$(mktemp -d)
mkdir -p "$T/.claude/logs"
mkdir -p "$T/.claude/scripts"

cp "$LOG_SCRIPT" "$T/.claude/scripts/log_session.sh"
chmod +x "$T/.claude/scripts/log_session.sh"
cp "$SESSIONS_IMPORT" "$T/.claude/scripts/session_events_staging_import.sh"
chmod +x "$T/.claude/scripts/session_events_staging_import.sh"
cp "$AGENT_IMPORT" "$T/.claude/scripts/agent_events_staging_import.sh"
chmod +x "$T/.claude/scripts/agent_events_staging_import.sh"
cp "$ERROR_IMPORT" "$T/.claude/scripts/error_events_staging_import.sh"
chmod +x "$T/.claude/scripts/error_events_staging_import.sh"
[ -f "$FRESHNESS_SCRIPT" ] && cp "$FRESHNESS_SCRIPT" "$T/.claude/scripts/etl_freshness_upsert.sh" && chmod +x "$T/.claude/scripts/etl_freshness_upsert.sh"

TESTDB="$T/.claude/logs/unified.duckdb"

duckdb -init /dev/null "$TESTDB" -c "
  CREATE SEQUENCE IF NOT EXISTS agent_seq START 1;
  CREATE SEQUENCE IF NOT EXISTS error_seq START 1;
  CREATE TABLE IF NOT EXISTS sessions (
    session_id VARCHAR PRIMARY KEY, project VARCHAR,
    started_at TIMESTAMP DEFAULT current_timestamp, ended_at TIMESTAMP,
    duration_min DOUBLE, model VARCHAR, burn_status VARCHAR,
    orphans_killed INTEGER DEFAULT 0, summary VARCHAR
  );
  CREATE TABLE IF NOT EXISTS agent_runs (
    id INTEGER PRIMARY KEY DEFAULT nextval('agent_seq'),
    session_id VARCHAR, agent_type VARCHAR, model VARCHAR,
    started_at TIMESTAMP DEFAULT current_timestamp, ended_at TIMESTAMP,
    duration_sec DOUBLE, prompt_preview VARCHAR,
    status VARCHAR DEFAULT 'running', tool_use_id VARCHAR,
    backfilled BOOLEAN DEFAULT false
  );
  CREATE TABLE IF NOT EXISTS errors (
    id INTEGER PRIMARY KEY DEFAULT nextval('error_seq'),
    session_id VARCHAR, source VARCHAR, error_text VARCHAR,
    context VARCHAR, logged_at TIMESTAMP DEFAULT current_timestamp
  );
" 2>/dev/null

_run() { HOME="$T" bash "$T/.claude/scripts/log_session.sh" "$@"; }
_db_size() { wc -c < "$TESTDB" | tr -d ' '; }

echo ""
echo "=== Test group 1: log_session.sh never touches unified.duckdb directly ==="

SIZE_BEFORE=$(_db_size)
_run start sess-A projA "start summary"
_run stop sess-A projA "stop summary" "claude-sonnet-5"
_run agent_start sess-A projA "do a thing" fixer sonnet tu-A
_run agent_stop sess-A projA "do a thing" fixer done tu-A
_run error sess-A projA "something broke" compound_guard
SIZE_AFTER=$(_db_size)
assert "unified.duckdb byte size unchanged after 5 staging calls (no duckdb CLI touch)" "$SIZE_AFTER" "$SIZE_BEFORE"

assert "session_events_staging.jsonl has 2 lines (start+stop)" \
  "$(wc -l < "$T/.claude/logs/session_events_staging.jsonl" | tr -d ' ')" "2"
assert "agent_events_staging.jsonl has 2 lines (agent_start+agent_stop)" \
  "$(wc -l < "$T/.claude/logs/agent_events_staging.jsonl" | tr -d ' ')" "2"
assert "error_events_staging.jsonl has 1 line" \
  "$(wc -l < "$T/.claude/logs/error_events_staging.jsonl" | tr -d ' ')" "1"

echo ""
echo "=== Test group 2: import drains staging into the real tables ==="

bash "$T/.claude/scripts/session_events_staging_import.sh" "$TESTDB" "$T/.claude/logs/session_events_staging.jsonl" > /dev/null 2>&1
bash "$T/.claude/scripts/agent_events_staging_import.sh" "$TESTDB" "$T/.claude/logs/agent_events_staging.jsonl" > /dev/null 2>&1
bash "$T/.claude/scripts/error_events_staging_import.sh" "$TESTDB" "$T/.claude/logs/error_events_staging.jsonl" > /dev/null 2>&1

assert "sessions: 1 row for sess-A" "$(dq "$TESTDB" "SELECT COUNT(*) FROM sessions WHERE session_id='sess-A';")" "1"
assert "sessions: model from stop event" "$(dq "$TESTDB" "SELECT model FROM sessions WHERE session_id='sess-A';")" "claude-sonnet-5"
assert "sessions: summary from stop event (stop's non-blank summary wins)" \
  "$(dq "$TESTDB" "SELECT summary FROM sessions WHERE session_id='sess-A';")" "stop summary"
assert "sessions: ended_at NOT NULL" \
  "$([ "$(dq "$TESTDB" "SELECT CAST(ended_at AS VARCHAR) FROM sessions WHERE session_id='sess-A';")" != "NULL" ] && echo yes)" "yes"

assert "agent_runs: 1 row for tu-A" "$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs WHERE tool_use_id='tu-A';")" "1"
assert "agent_runs: status='done'" "$(dq "$TESTDB" "SELECT status FROM agent_runs WHERE tool_use_id='tu-A';")" "done"
assert "agent_runs: duration_sec NOT NULL" \
  "$([ "$(dq "$TESTDB" "SELECT CAST(duration_sec AS VARCHAR) FROM agent_runs WHERE tool_use_id='tu-A';")" != "NULL" ] && echo yes)" "yes"

assert "errors: 1 row for sess-A" "$(dq "$TESTDB" "SELECT COUNT(*) FROM errors WHERE session_id='sess-A';")" "1"
assert "errors: source='compound_guard'" "$(dq "$TESTDB" "SELECT source FROM errors WHERE session_id='sess-A';")" "compound_guard"

assert "session staging file consumed after import" "$([ -f "$T/.claude/logs/session_events_staging.jsonl" ] && echo yes || echo no)" "no"
assert "agent staging file consumed after import" "$([ -f "$T/.claude/logs/agent_events_staging.jsonl" ] && echo yes || echo no)" "no"
assert "error staging file consumed after import" "$([ -f "$T/.claude/logs/error_events_staging.jsonl" ] && echo yes || echo no)" "no"

echo ""
echo "=== Test group 3: etl_freshness reflects reality AFTER the write lands ==="

assert "etl_freshness: sessions row exists with non-NULL last_row_ts" \
  "$(dq "$TESTDB" "SELECT COUNT(*) FROM etl_freshness WHERE source_name='sessions' AND last_row_ts IS NOT NULL;")" "1"
assert "etl_freshness: agent_runs row exists with non-NULL last_row_ts" \
  "$(dq "$TESTDB" "SELECT COUNT(*) FROM etl_freshness WHERE source_name='agent_runs' AND last_row_ts IS NOT NULL;")" "1"
assert "etl_freshness: errors row exists with non-NULL last_row_ts" \
  "$(dq "$TESTDB" "SELECT COUNT(*) FROM etl_freshness WHERE source_name='errors' AND last_row_ts IS NOT NULL;")" "1"

echo ""
echo "=== Test group 4: no-clobber — a blank model/summary in a later stop never wipes an earlier value ==="

_run start sess-B projB "" "claude-opus-5"
bash "$T/.claude/scripts/session_events_staging_import.sh" "$TESTDB" "$T/.claude/logs/session_events_staging.jsonl" > /dev/null 2>&1
MODEL_BEFORE=$(dq "$TESTDB" "SELECT model FROM sessions WHERE session_id='sess-B';")
assert "no-clobber setup: sess-B has model='claude-opus-5' after start" "$MODEL_BEFORE" "claude-opus-5"

# Separate later ETL cycle: a stop event with BLANK model/summary.
_run stop sess-B projB "" ""
bash "$T/.claude/scripts/session_events_staging_import.sh" "$TESTDB" "$T/.claude/logs/session_events_staging.jsonl" > /dev/null 2>&1
MODEL_AFTER=$(dq "$TESTDB" "SELECT model FROM sessions WHERE session_id='sess-B';")
assert "no-clobber: model survives a blank-model stop" "$MODEL_AFTER" "claude-opus-5"

DURATION_B=$(dq "$TESTDB" "SELECT CAST(ended_at AS VARCHAR) FROM sessions WHERE session_id='sess-B';")
if [ "$DURATION_B" != "NULL" ] && [ -n "$DURATION_B" ]; then
  echo "  PASS: no-clobber: ended_at still gets set by the blank-model stop"
  PASS=$((PASS + 1))
else
  echo "  FAIL: no-clobber: ended_at still gets set by the blank-model stop (got: $DURATION_B)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test group 5: idempotency — replaying an identical batch twice is a no-op ==="

IDEM_STAGING="$T/.claude/logs/session_events_staging.jsonl"
printf '{"type":"start","ts":"2026-01-01T00:00:00Z","session_id":"sess-idem","project":"p","summary":"s1","model":"sonnet"}\n' > "$IDEM_STAGING"
printf '{"type":"stop","ts":"2026-01-01T00:10:00Z","session_id":"sess-idem","summary":"","model":""}\n' >> "$IDEM_STAGING"
cp "$IDEM_STAGING" "$T/idem_copy.jsonl"

bash "$T/.claude/scripts/session_events_staging_import.sh" "$TESTDB" "$IDEM_STAGING" > /dev/null 2>&1
ROW1=$(dq "$TESTDB" "SELECT COUNT(*) FROM sessions WHERE session_id='sess-idem';")
STATE1=$(dq "$TESTDB" "SELECT started_at, ended_at, duration_min, summary FROM sessions WHERE session_id='sess-idem';")

cp "$T/idem_copy.jsonl" "$IDEM_STAGING"
bash "$T/.claude/scripts/session_events_staging_import.sh" "$TESTDB" "$IDEM_STAGING" > /dev/null 2>&1
ROW2=$(dq "$TESTDB" "SELECT COUNT(*) FROM sessions WHERE session_id='sess-idem';")
STATE2=$(dq "$TESTDB" "SELECT started_at, ended_at, duration_min, summary FROM sessions WHERE session_id='sess-idem';")

assert "idempotent replay: sessions row count unchanged (1)" "$ROW2" "1"
assert "idempotent replay: sessions row count matches first import" "$ROW2" "$ROW1"
assert "idempotent replay: sessions column values unchanged" "$STATE2" "$STATE1"

# Same proof for agent_runs (tool_use_id-matched path).
AGENT_IDEM_STAGING="$T/.claude/logs/agent_events_staging.jsonl"
printf '{"type":"agent_start","ts":"2026-01-01T01:00:00Z","session_id":"sess-idem","agent_type":"critic","model":"sonnet","prompt_preview":"p","status":"running","tool_use_id":"tu-idem"}\n' > "$AGENT_IDEM_STAGING"
printf '{"type":"agent_stop","ts":"2026-01-01T01:01:00Z","session_id":"sess-idem","agent_type":"critic","model":"","prompt_preview":"p","status":"done","tool_use_id":"tu-idem"}\n' >> "$AGENT_IDEM_STAGING"
cp "$AGENT_IDEM_STAGING" "$T/agent_idem_copy.jsonl"

bash "$T/.claude/scripts/agent_events_staging_import.sh" "$TESTDB" "$AGENT_IDEM_STAGING" > /dev/null 2>&1
AROW1=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs WHERE tool_use_id='tu-idem';")

cp "$T/agent_idem_copy.jsonl" "$AGENT_IDEM_STAGING"
bash "$T/.claude/scripts/agent_events_staging_import.sh" "$TESTDB" "$AGENT_IDEM_STAGING" > /dev/null 2>&1
AROW2=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs WHERE tool_use_id='tu-idem';")

assert "idempotent replay: agent_runs row count unchanged (1)" "$AROW2" "1"
assert "idempotent replay: agent_runs row count matches first import" "$AROW2" "$AROW1"

# Same proof for errors (content-dedup path).
ERR_IDEM_STAGING="$T/.claude/logs/error_events_staging.jsonl"
printf '{"ts":"2026-01-01T02:00:00Z","session_id":"sess-idem","source":"agent_push_guard","error_text":"blocked","context":"p"}\n' > "$ERR_IDEM_STAGING"
cp "$ERR_IDEM_STAGING" "$T/err_idem_copy.jsonl"

bash "$T/.claude/scripts/error_events_staging_import.sh" "$TESTDB" "$ERR_IDEM_STAGING" > /dev/null 2>&1
EROW1=$(dq "$TESTDB" "SELECT COUNT(*) FROM errors WHERE session_id='sess-idem';")

cp "$T/err_idem_copy.jsonl" "$ERR_IDEM_STAGING"
bash "$T/.claude/scripts/error_events_staging_import.sh" "$TESTDB" "$ERR_IDEM_STAGING" > /dev/null 2>&1
EROW2=$(dq "$TESTDB" "SELECT COUNT(*) FROM errors WHERE session_id='sess-idem';")

assert "idempotent replay: errors row count unchanged (1)" "$EROW2" "1"
assert "idempotent replay: errors row count matches first import" "$EROW2" "$EROW1"

echo ""
echo "=== Test group 6: agent_runs orphan-stop fallback (no matching start) is also idempotent ==="

ORPHAN_STAGING="$T/.claude/logs/agent_events_staging.jsonl"
printf '{"type":"agent_stop","ts":"2026-01-01T03:00:00Z","session_id":"sess-idem","agent_type":"critic","model":"","prompt_preview":"orphaned","status":"done","tool_use_id":"tu-orphan"}\n' > "$ORPHAN_STAGING"
cp "$ORPHAN_STAGING" "$T/orphan_copy.jsonl"

bash "$T/.claude/scripts/agent_events_staging_import.sh" "$TESTDB" "$ORPHAN_STAGING" > /dev/null 2>&1
OROW1=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs WHERE tool_use_id='tu-orphan';")
assert "orphan-stop fallback inserts a row when no start exists" "$OROW1" "1"

cp "$T/orphan_copy.jsonl" "$ORPHAN_STAGING"
bash "$T/.claude/scripts/agent_events_staging_import.sh" "$TESTDB" "$ORPHAN_STAGING" > /dev/null 2>&1
OROW2=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs WHERE tool_use_id='tu-orphan';")
assert "orphan-stop fallback replay does not duplicate (idempotent)" "$OROW2" "1"

echo ""
echo "=== Test group 7: errors NOT silenced — a forced write failure surfaces real detail ==="

BAD_DB="$T/bad_db_dir/unified.duckdb"
mkdir -p "$BAD_DB"   # a directory where duckdb expects a file -> forces a real write error
FAIL_STAGING="$T/fail_staging.jsonl"
printf '{"type":"start","ts":"2026-01-01T04:00:00Z","session_id":"sess-fail","project":"p","summary":"s","model":"m"}\n' > "$FAIL_STAGING"

FAIL_OUT=$(bash "$T/.claude/scripts/session_events_staging_import.sh" "$BAD_DB" "$FAIL_STAGING" 2>&1)
FAIL_RC=$?

assert "forced failure: import script exits non-zero" "$([ "$FAIL_RC" -ne 0 ] && echo yes)" "yes"

if echo "$FAIL_OUT" | grep -q "ERROR:"; then
  echo "  PASS: forced failure: output contains an ERROR: line (not silently swallowed)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: forced failure: output contains an ERROR: line (not silently swallowed)"
  echo "        got: $FAIL_OUT"
  FAIL=$((FAIL + 1))
fi

if echo "$FAIL_OUT" | grep -qi "IO Error\|Is a directory\|unable to open database"; then
  echo "  PASS: forced failure: real duckdb error text is present (not discarded via 2>/dev/null)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: forced failure: real duckdb error text is present (not discarded via 2>/dev/null)"
  echo "        got: $FAIL_OUT"
  FAIL=$((FAIL + 1))
fi

FAILED_FILE_COUNT=$(find "$T" -maxdepth 1 -name "fail_staging.jsonl.import_*.failed" 2>/dev/null | wc -l | tr -d ' ')
assert "forced failure: batch preserved as a .failed file (not deleted)" "$FAILED_FILE_COUNT" "1"

if [ "$FAILED_FILE_COUNT" = "1" ]; then
  PRESERVED_CONTENT=$(cat "$T"/fail_staging.jsonl.import_*.failed)
  assert "forced failure: preserved batch content is intact" "$PRESERVED_CONTENT" \
    '{"type":"start","ts":"2026-01-01T04:00:00Z","session_id":"sess-fail","project":"p","summary":"s","model":"m"}'
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
