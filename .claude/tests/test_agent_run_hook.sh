#!/usr/bin/env bash
# test_agent_run_hook.sh — Hermetic tests for log_agent_run.sh + log_session.sh
#   + agent_events_staging_import.sh
# Tests use a temp HOME so the hook's hardcoded $HOME/.claude/... paths are safe.
# Requires: duckdb, jq on PATH.
#
# llm#956: log_session.sh's agent_start/agent_stop cases no longer write to
# `agent_runs` via the duckdb CLI directly (that write held an exclusive
# whole-file lock — see log_session.sh's #710/#956 header). They now append
# lock-free JSONL to agent_events_staging.jsonl; agent_events_staging_
# import.sh drains that file into `agent_runs`. Test groups 1-3 below were
# updated to reflect this: each hook call is followed by an explicit call to
# the import script before the DB is queried, and a new assertion in group 1
# proves the hook call itself does NOT touch agent_runs synchronously
# (the durability property this fix exists to provide).

set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$WT/.claude/hooks/log_agent_run.sh"
LOG_SCRIPT="$WT/.claude/scripts/log_session.sh"
IMPORT_SCRIPT="$WT/.claude/scripts/agent_events_staging_import.sh"
FRESHNESS_SCRIPT="$WT/.claude/scripts/etl_freshness_upsert.sh"
BACKFILL="$WT/.claude/scripts/backfill_agent_runs_270.sh"

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

assert_nonempty() {
  local desc="$1" result="$2"
  if [ -n "$result" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected non-empty, got empty)"
    FAIL=$((FAIL + 1))
  fi
}

assert_empty() {
  local desc="$1" result="$2"
  if [ -z "$result" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected empty, got [$result])"
    FAIL=$((FAIL + 1))
  fi
}

# --------------------------------------------------------------------------
# Setup temp HOME
# --------------------------------------------------------------------------
T=$(mktemp -d)
mkdir -p "$T/.claude/logs"
mkdir -p "$T/.claude/scripts"
mkdir -p "$T/.claude/hooks"

cp "$LOG_SCRIPT" "$T/.claude/scripts/log_session.sh"
chmod +x "$T/.claude/scripts/log_session.sh"
cp "$IMPORT_SCRIPT" "$T/.claude/scripts/agent_events_staging_import.sh"
chmod +x "$T/.claude/scripts/agent_events_staging_import.sh"
[ -f "$FRESHNESS_SCRIPT" ] && cp "$FRESHNESS_SCRIPT" "$T/.claude/scripts/etl_freshness_upsert.sh" && chmod +x "$T/.claude/scripts/etl_freshness_upsert.sh"
cp "$HOOK" "$T/.claude/hooks/log_agent_run.sh"
chmod +x "$T/.claude/hooks/log_agent_run.sh"

TESTDB="$T/.claude/logs/unified.duckdb"
STAGING="$T/.claude/logs/agent_events_staging.jsonl"
_drain() { bash "$T/.claude/scripts/agent_events_staging_import.sh" "$TESTDB" "$STAGING" > /dev/null 2>&1; }

# Create minimal schema
duckdb -init /dev/null "$TESTDB" -c "
  CREATE SEQUENCE IF NOT EXISTS agent_seq START 1;
  CREATE TABLE IF NOT EXISTS agent_runs (
    id INTEGER DEFAULT nextval('agent_seq'),
    session_id VARCHAR,
    agent_type VARCHAR DEFAULT 'unknown',
    model VARCHAR DEFAULT 'inherited',
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status VARCHAR DEFAULT 'running',
    tool_use_id VARCHAR,
    backfilled BOOLEAN DEFAULT false
  );
  CREATE TABLE IF NOT EXISTS sessions (
    session_id VARCHAR PRIMARY KEY,
    project VARCHAR,
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    duration_min DOUBLE,
    summary VARCHAR
  );
  INSERT INTO sessions (session_id, project, started_at)
  VALUES ('test-session', 'test-proj', current_timestamp);
" 2>/dev/null

echo "test-session" > "$T/.claude/logs/.current_session"

echo ""
echo "=== Test group 1: PreToolUse -> agent_start ==="

PRE_PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_use_id":"toolu_TEST1","tool_input":{"subagent_type":"fixer","model":"sonnet","description":"demo"}}'

printf '%s' "$PRE_PAYLOAD" | HOME="$T" bash "$T/.claude/hooks/log_agent_run.sh"

# llm#956: the hook call above only appends to the staging JSONL — it must
# NOT touch agent_runs synchronously (that's the whole point of the fix:
# no duckdb CLI call on the hot path, so no lock contention).
ROW_COUNT_PRE_DRAIN=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs;")
assert "PreToolUse: agent_runs untouched before drain (durability property)" "$ROW_COUNT_PRE_DRAIN" "0"

assert_nonempty "PreToolUse: staging file has a pending record" "$([ -s "$STAGING" ] && echo yes)"

_drain

ROW_COUNT=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs;")
assert "PreToolUse: exactly 1 row inserted (after drain)" "$ROW_COUNT" "1"

AGENT_TYPE=$(dq "$TESTDB" "SELECT agent_type FROM agent_runs WHERE tool_use_id='toolu_TEST1';")
assert "PreToolUse: agent_type='fixer'" "$AGENT_TYPE" "fixer"

STATUS=$(dq "$TESTDB" "SELECT status FROM agent_runs WHERE tool_use_id='toolu_TEST1';")
assert "PreToolUse: status='running'" "$STATUS" "running"

TUID=$(dq "$TESTDB" "SELECT tool_use_id FROM agent_runs WHERE tool_use_id='toolu_TEST1';")
assert "PreToolUse: tool_use_id='toolu_TEST1'" "$TUID" "toolu_TEST1"

# ended_at should be NULL — duckdb prints NULL for null values in -list mode
ENDED_RAW=$(dq "$TESTDB" "SELECT CAST(ended_at AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_TEST1';")
assert "PreToolUse: ended_at IS NULL" "$ENDED_RAW" "NULL"

echo ""
echo "=== Test group 2: PostToolUse -> agent_stop (same tool_use_id, no error) ==="

POST_PAYLOAD='{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_use_id":"toolu_TEST1","tool_input":{"subagent_type":"fixer","model":"sonnet","description":"demo"},"tool_response":{"is_error":false}}'

printf '%s' "$POST_PAYLOAD" | HOME="$T" bash "$T/.claude/hooks/log_agent_run.sh"
_drain

ROW_COUNT2=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs;")
assert "PostToolUse: still exactly 1 row (updated, not inserted)" "$ROW_COUNT2" "1"

STATUS2=$(dq "$TESTDB" "SELECT status FROM agent_runs WHERE tool_use_id='toolu_TEST1';")
assert "PostToolUse: status='done'" "$STATUS2" "done"

ENDED2=$(dq "$TESTDB" "SELECT CAST(ended_at AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_TEST1';")
# ended_at should be a timestamp string, not NULL
if [ "$ENDED2" != "NULL" ] && [ -n "$ENDED2" ]; then
  echo "  PASS: PostToolUse: ended_at NOT NULL"
  PASS=$((PASS + 1))
else
  echo "  FAIL: PostToolUse: ended_at NOT NULL (got: $ENDED2)"
  FAIL=$((FAIL + 1))
fi

DURATION=$(dq "$TESTDB" "SELECT CAST(duration_sec AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_TEST1';")
if [ "$DURATION" != "NULL" ] && [ -n "$DURATION" ]; then
  echo "  PASS: PostToolUse: duration_sec NOT NULL"
  PASS=$((PASS + 1))
else
  echo "  FAIL: PostToolUse: duration_sec NOT NULL (got: $DURATION)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test group 3: PostToolUse with NEW tool_use_id + is_error=true (self-contained INSERT) ==="

POST_ERR='{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_use_id":"toolu_NEWERR","tool_input":{"subagent_type":"r-debugger","model":"sonnet","description":"error run"},"tool_response":{"is_error":true}}'

printf '%s' "$POST_ERR" | HOME="$T" bash "$T/.claude/hooks/log_agent_run.sh"
_drain

ROW_COUNT3=$(dq "$TESTDB" "SELECT COUNT(*) FROM agent_runs;")
assert "Error PostToolUse: 2 rows total (new INSERT via orphan-stop fallback)" "$ROW_COUNT3" "2"

STATUS3=$(dq "$TESTDB" "SELECT status FROM agent_runs WHERE tool_use_id='toolu_NEWERR';")
assert "Error PostToolUse: status='failed'" "$STATUS3" "failed"

ENDED3=$(dq "$TESTDB" "SELECT CAST(ended_at AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_NEWERR';")
if [ "$ENDED3" != "NULL" ] && [ -n "$ENDED3" ]; then
  echo "  PASS: Error PostToolUse: ended_at NOT NULL"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Error PostToolUse: ended_at NOT NULL (got: $ENDED3)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test group 4: backfill script ==="

BFDIR=$(mktemp -d)
BFDB="$BFDIR/backfill_test.duckdb"

duckdb -init /dev/null "$BFDB" -c "
  CREATE SEQUENCE IF NOT EXISTS agent_seq2 START 1;
  CREATE TABLE agent_runs (
    id INTEGER DEFAULT nextval('agent_seq2'),
    session_id VARCHAR,
    agent_type VARCHAR DEFAULT 'unknown',
    model VARCHAR DEFAULT 'inherited',
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status VARCHAR DEFAULT 'running',
    tool_use_id VARCHAR,
    backfilled BOOLEAN DEFAULT false
  );
  CREATE TABLE sessions (
    session_id VARCHAR PRIMARY KEY,
    project VARCHAR,
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    duration_min DOUBLE,
    summary VARCHAR
  );
  INSERT INTO sessions VALUES ('sess-A','proj',current_timestamp - INTERVAL 3600 SECOND, current_timestamp - INTERVAL 60 SECOND, 59, 'done');
  INSERT INTO agent_runs (session_id, agent_type, started_at, status)
  VALUES
    ('sess-A','fixer',   current_timestamp - INTERVAL 3600 SECOND, 'running'),
    ('sess-A','critic',  current_timestamp - INTERVAL 1800 SECOND, 'running'),
    ('sess-A','reviewer',current_timestamp - INTERVAL 900 SECOND,  'running');
  INSERT INTO sessions VALUES ('sess-B','proj2',current_timestamp - INTERVAL 500 SECOND, NULL, NULL, NULL);
  INSERT INTO agent_runs (session_id, agent_type, started_at, status)
  VALUES ('sess-B','quick-fix', current_timestamp - INTERVAL 500 SECOND, 'running');
" 2>/dev/null

bash "$BACKFILL" "$BFDB" > /dev/null 2>&1

BF_DONE=$(dq "$BFDB" "SELECT COUNT(*) FROM agent_runs WHERE status='done' AND backfilled=true;")
assert "Backfill: all 4 rows become done+backfilled" "$BF_DONE" "4"

BF_RUNNING=$(dq "$BFDB" "SELECT COUNT(*) FROM agent_runs WHERE status='running';")
assert "Backfill: 0 rows still running" "$BF_RUNNING" "0"

BF_ENDED=$(dq "$BFDB" "SELECT COUNT(*) FROM agent_runs WHERE ended_at IS NOT NULL;")
assert "Backfill: all 4 rows have ended_at NOT NULL" "$BF_ENDED" "4"

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
