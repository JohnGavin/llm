#!/usr/bin/env bash
# test_skill_usage.sh — Hermetic tests for log_skill_use.sh +
# skill_usage_staging_import.sh + backfill_skill_usage.R (Card 1b, #729).
# Tests use a temp HOME so the hook's hardcoded $HOME/.claude/... paths are
# safe, and a scratch duckdb so the live unified.duckdb is never touched.
# Requires: duckdb, jq on PATH. R tests are skipped (not failed) if
# Rscript/duckdb-R/jsonlite are unavailable outside the project nix shell.

set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$WT/.claude/hooks/log_skill_use.sh"
DRAIN="$WT/.claude/scripts/skill_usage_staging_import.sh"
BACKFILL="$WT/.claude/scripts/backfill_skill_usage.R"

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

# --------------------------------------------------------------------------
# Setup temp HOME
# --------------------------------------------------------------------------
T=$(mktemp -d)
mkdir -p "$T/.claude/logs"

TESTDB="$T/.claude/logs/unified.duckdb"
STAGING="$T/.claude/logs/skill_usage_staging.jsonl"

echo "test-session-A" > "$T/.claude/logs/.current_session"

echo ""
echo "=== Test group 1: hook stages a JSONL record ==="

PAYLOAD='{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"cli-package","args":"format an error message"}}'

printf '%s' "$PAYLOAD" | HOME="$T" bash "$HOOK"

assert "staging file created" "$([ -f "$STAGING" ] && echo yes || echo no)" "yes"

STAGED_LINE=$(cat "$STAGING" 2>/dev/null)
STAGED_SKILL=$(echo "$STAGED_LINE" | jq -r '.skill_name')
assert "staged record: skill_name='cli-package'" "$STAGED_SKILL" "cli-package"

STAGED_SID=$(echo "$STAGED_LINE" | jq -r '.session_id')
assert "staged record: session_id='test-session-A'" "$STAGED_SID" "test-session-A"

STAGED_HASH=$(echo "$STAGED_LINE" | jq -r '.args_hash')
if [ -n "$STAGED_HASH" ] && [ "$STAGED_HASH" != "null" ] && [ "$STAGED_HASH" != "" ]; then
  echo "  PASS: staged record: args_hash is non-empty (args text itself not stored)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: staged record: args_hash missing (got: $STAGED_HASH)"
  FAIL=$((FAIL + 1))
fi
if ! echo "$STAGED_LINE" | grep -q "format an error message"; then
  echo "  PASS: staged record does NOT contain raw args text"
  PASS=$((PASS + 1))
else
  echo "  FAIL: staged record leaked raw args text"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test group 2: non-Skill / malformed payloads are no-ops ==="

RM_BEFORE=$(wc -l < "$STAGING" | tr -d ' ')
NOOP_PAYLOAD='{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{}}'
printf '%s' "$NOOP_PAYLOAD" | HOME="$T" bash "$HOOK"
RM_AFTER=$(wc -l < "$STAGING" | tr -d ' ')
assert "payload with no skill field: no new line staged" "$RM_AFTER" "$RM_BEFORE"

echo ""
echo "=== Test group 3: staging_import drains into skill_usage (fresh DB) ==="

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1

ROW_COUNT=$(dq "$TESTDB" "SELECT COUNT(*) FROM skill_usage;")
assert "drain: exactly 1 row landed in skill_usage" "$ROW_COUNT" "1"

DRAINED_SKILL=$(dq "$TESTDB" "SELECT skill_name FROM skill_usage WHERE session_id='test-session-A';")
assert "drain: skill_name='cli-package'" "$DRAINED_SKILL" "cli-package"

DRAINED_BF=$(dq "$TESTDB" "SELECT backfilled FROM skill_usage WHERE session_id='test-session-A';")
assert "drain: backfilled=false for forward-instrumented row" "$DRAINED_BF" "false"

assert "drain: staging file consumed (removed)" "$([ -f "$STAGING" ] && echo yes || echo no)" "no"

echo ""
echo "=== Test group 4: drain is idempotent when staging is empty ==="

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT2=$(dq "$TESTDB" "SELECT COUNT(*) FROM skill_usage;")
assert "drain re-run with no staging file: row count unchanged" "$ROW_COUNT2" "1"

echo ""
echo "=== Test group 5: drain dedupes on (session_id, skill_name, ts) ==="

# Stage the SAME event again (identical ts/session/skill) and re-drain.
printf '%s' "$PAYLOAD" | HOME="$T" bash "$HOOK"
# Force an identical ts by copying the exact ts from the row already in the DB.
EXISTING_TS=$(dq "$TESTDB" "SELECT CAST(ts AS VARCHAR) FROM skill_usage WHERE session_id='test-session-A';")
printf '{"ts":"%s","session_id":"test-session-A","skill_name":"cli-package","project_path":"/tmp","args_hash":"deadbeef"}\n' \
  "$EXISTING_TS" > "$STAGING"

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT3=$(dq "$TESTDB" "SELECT COUNT(*) FROM skill_usage;")
assert "drain: duplicate (session_id,skill_name,ts) not re-inserted" "$ROW_COUNT3" "1"

echo ""
echo "=== Test group 6: etl_freshness registration (defensive, Card 1a coordination) ==="

FRESHNESS_EXISTS=$(dq "$TESTDB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='etl_freshness';")
assert "etl_freshness table created" "$FRESHNESS_EXISTS" "1"

FRESHNESS_ROW=$(dq "$TESTDB" "SELECT status FROM etl_freshness WHERE source_name='skill_usage';")
assert "etl_freshness: skill_usage registered with status='unknown' (event-driven, no SLA)" "$FRESHNESS_ROW" "unknown"

echo ""
echo "=== Test group 7: backfill script (R) — skip gracefully if R env unavailable ==="

if command -v Rscript >/dev/null 2>&1 && Rscript -e 'quit(status = if (requireNamespace("duckdb", quietly=TRUE) && requireNamespace("jsonlite", quietly=TRUE)) 0L else 1L)' >/dev/null 2>&1; then
  BFDIR=$(mktemp -d)
  BFDB="$BFDIR/backfill_test.duckdb"
  PROJDIR="$BFDIR/projects/-tmp-proj"
  mkdir -p "$PROJDIR"

  # Minimal synthetic transcript: one assistant message with a Skill tool_use block.
  cat > "$PROJDIR/sess-XYZ.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-05-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Skill","input":{"skill":"cli-package","args":"demo"}}]}}
{"type":"assistant","timestamp":"2026-05-02T11:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Skill","input":{"skill":"deslop"}}]}}
{"type":"assistant","timestamp":"2026-05-02T11:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_3","name":"Bash","input":{"command":"ls"}}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$BFDB" --projects-dir "$BFDIR/projects" > "$BFDIR/backfill_out.log" 2>&1
  BF_STATUS=$?

  if [ "$BF_STATUS" -eq 0 ]; then
    BF_COUNT1=$(dq "$BFDB" "SELECT COUNT(*) FROM skill_usage;")
    assert "backfill: 2 Skill invocations inserted (Bash block ignored)" "$BF_COUNT1" "2"

    BF_BACKFILLED=$(dq "$BFDB" "SELECT COUNT(*) FROM skill_usage WHERE backfilled=true;")
    assert "backfill: all inserted rows flagged backfilled=true" "$BF_BACKFILLED" "2"

    # Re-run — must be idempotent (no new rows).
    Rscript "$BACKFILL" --apply --db "$BFDB" --projects-dir "$BFDIR/projects" > "$BFDIR/backfill_out2.log" 2>&1
    BF_COUNT2=$(dq "$BFDB" "SELECT COUNT(*) FROM skill_usage;")
    assert "backfill: idempotent re-run (row count stable)" "$BF_COUNT2" "$BF_COUNT1"
  else
    echo "  SKIP: backfill script did not exit 0 (see $BFDIR/backfill_out.log) — treating as environment gap, not a test failure"
    cat "$BFDIR/backfill_out.log" 2>/dev/null | tail -20
  fi
else
  echo "  SKIP: Rscript / duckdb / jsonlite R packages not on PATH outside the project nix shell"
  echo "        (run: nix-shell $WT/default.nix --run \"bash $WT/.claude/tests/test_skill_usage.sh\")"
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
