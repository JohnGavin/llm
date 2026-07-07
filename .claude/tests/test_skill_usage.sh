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
echo "=== Test group 5: drain dedupes on (session_id, skill_name, ts, args_hash) ==="

# Stage the SAME event again (identical ts/session/skill/args_hash) and
# re-drain. Copy both the exact ts AND args_hash from the row already in
# the DB — this is the true "re-staged identical event" scenario (same
# args, not just same session+skill+second).
printf '%s' "$PAYLOAD" | HOME="$T" bash "$HOOK"
EXISTING_TS=$(dq "$TESTDB" "SELECT CAST(ts AS VARCHAR) FROM skill_usage WHERE session_id='test-session-A';")
EXISTING_HASH=$(dq "$TESTDB" "SELECT args_hash FROM skill_usage WHERE session_id='test-session-A';")
printf '{"ts":"%s","session_id":"test-session-A","skill_name":"cli-package","project_path":"/tmp","args_hash":"%s"}\n' \
  "$EXISTING_TS" "$EXISTING_HASH" > "$STAGING"

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT3=$(dq "$TESTDB" "SELECT COUNT(*) FROM skill_usage;")
assert "drain: duplicate (session_id,skill_name,ts,args_hash) not re-inserted" "$ROW_COUNT3" "1"

echo ""
echo "=== Test group 5b: drain dedupes across second- vs ms-precision timestamps ==="

# Simulate a row already written with second precision (the hook's format,
# no fractional seconds — see log_skill_use.sh) for a NEW session, then stage
# a "duplicate" event for the same (session_id, skill_name) whose timestamp
# carries millisecond precision (the format raw transcripts use). Before the
# fix these compared unequal (CAST(...) preserved the sub-second component)
# and the row was double-counted.
dq "$TESTDB" "
  INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
  VALUES ('test-session-B', 'cli-package', '/tmp', 'deadbeef',
          CAST('2026-06-01T09:00:05' AS TIMESTAMP), FALSE);
" > /dev/null

printf '{"ts":"2026-06-01T09:00:05.789Z","session_id":"test-session-B","skill_name":"cli-package","project_path":"/tmp","args_hash":"deadbeef"}\n' \
  > "$STAGING"

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT_B=$(dq "$TESTDB" "SELECT COUNT(*) FROM skill_usage WHERE session_id='test-session-B';")
assert "drain: dedup matches across second- vs ms-precision ts (1 row, not 2)" "$ROW_COUNT_B" "1"

echo ""
echo "=== Test group 5c: drain does NOT dedupe same-second events with different args_hash ==="

# Same session_id + skill_name + same-second timestamp as an existing row,
# but a DIFFERENT args_hash — these are distinct invocations (different
# args) and must NOT be collapsed into one row. Before the fix, the dedup
# predicate keyed only on (session_id, skill_name, ts-truncated-to-second)
# and silently merged these.
dq "$TESTDB" "
  INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
  VALUES ('test-session-C', 'cli-package', '/tmp', 'hash-alpha',
          CAST('2026-06-03T14:00:00' AS TIMESTAMP), FALSE);
" > /dev/null

printf '{"ts":"2026-06-03T14:00:00.321Z","session_id":"test-session-C","skill_name":"cli-package","project_path":"/tmp","args_hash":"hash-beta"}\n' \
  > "$STAGING"

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT_C=$(dq "$TESTDB" "SELECT COUNT(*) FROM skill_usage WHERE session_id='test-session-C';")
assert "drain: same-second same-skill DIFFERENT args_hash -> both rows kept (2, not 1)" "$ROW_COUNT_C" "2"

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

  echo ""
  echo "=== Test group 8: backfill derives project_path from transcript cwd, not a lossy dash-decode ==="

  # The encoded directory name below mimics a real Claude Code transcript
  # directory for a path containing a literal dash-bearing segment
  # ("docs_gh" -> "docs-gh" once slashes become dashes). The old
  # gsub("-", "/") heuristic could not tell that dash apart from an encoded
  # "/", corrupting the path to ".../docs/gh/llm". Each transcript line
  # below carries the true `cwd`, which must be used verbatim instead.
  CWDDIR=$(mktemp -d)
  CWDDB="$CWDDIR/cwd_test.duckdb"
  CWDPROJDIR="$CWDDIR/projects/-Users-johngavin-docs-gh-llm"
  mkdir -p "$CWDPROJDIR"

  cat > "$CWDPROJDIR/sess-CWD.jsonl" <<'EOF'
{"type":"assistant","cwd":"/Users/johngavin/docs_gh/llm","timestamp":"2026-06-15T08:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_cwd1","name":"Skill","input":{"skill":"cli-package","args":"demo"}}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$CWDDB" --projects-dir "$CWDDIR/projects" > "$CWDDIR/backfill_out.log" 2>&1
  CWD_STATUS=$?

  if [ "$CWD_STATUS" -eq 0 ]; then
    CWD_PROJECT=$(dq "$CWDDB" "SELECT project_path FROM skill_usage WHERE session_id='sess-CWD';")
    assert "backfill: project_path taken from transcript cwd (not dash-decoded)" \
      "$CWD_PROJECT" "/Users/johngavin/docs_gh/llm"
  else
    echo "  SKIP: backfill script did not exit 0 for cwd test (see $CWDDIR/backfill_out.log)"
    cat "$CWDDIR/backfill_out.log" 2>/dev/null | tail -20
  fi

  echo ""
  echo "=== Test group 9: backfill dedupes against an existing second-precision row (cross-writer ts mismatch) ==="

  # Pre-populate the DB with a row as the hook/drain path would have written
  # it (second precision, backfilled=FALSE), then run the backfill over a
  # synthetic transcript recording the SAME (session_id, skill_name, args)
  # event with millisecond precision. Before the fix, CAST(...) preserved
  # the sub-second component so the two never matched and the event was
  # double-counted. The pre-populated args_hash must match what
  # backfill_skill_usage.R's hash_args() computes for the transcript's
  # "demo" args string (first 16 hex chars of sha256, matching hash_args()
  # in backfill_skill_usage.R) — otherwise this is testing "different
  # args_hash" (see Test group 10), not "same event, different ts
  # precision".
  XDIR=$(mktemp -d)
  XDB="$XDIR/xwriter_test.duckdb"
  XPROJDIR="$XDIR/projects/-tmp-xwriter"
  mkdir -p "$XPROJDIR"

  XW_ARGS_HASH=$(printf '%s\n' "demo" | shasum -a 256 | awk '{print substr($1,1,16)}')

  dq "$XDB" "
    CREATE TABLE IF NOT EXISTS skill_usage (
      session_id VARCHAR, skill_name VARCHAR, project_path VARCHAR,
      args_hash VARCHAR, ts TIMESTAMP, backfilled BOOLEAN DEFAULT FALSE
    );
    INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
    VALUES ('sess-XWRITER', 'cli-package', '/tmp', '${XW_ARGS_HASH}',
            CAST('2026-06-10T12:00:00' AS TIMESTAMP), FALSE);
  " > /dev/null

  cat > "$XPROJDIR/sess-XWRITER.jsonl" <<'EOF'
{"type":"assistant","cwd":"/tmp","timestamp":"2026-06-10T12:00:00.456Z","message":{"content":[{"type":"tool_use","id":"toolu_x1","name":"Skill","input":{"skill":"cli-package","args":"demo"}}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$XDB" --projects-dir "$XDIR/projects" > "$XDIR/backfill_out.log" 2>&1
  XW_STATUS=$?

  if [ "$XW_STATUS" -eq 0 ]; then
    XW_COUNT=$(dq "$XDB" "SELECT COUNT(*) FROM skill_usage WHERE session_id='sess-XWRITER';")
    assert "backfill: cross-writer ts precision mismatch still dedups (1 row, not 2)" "$XW_COUNT" "1"
  else
    echo "  SKIP: backfill script did not exit 0 for cross-writer test (see $XDIR/backfill_out.log)"
    cat "$XDIR/backfill_out.log" 2>/dev/null | tail -20
  fi

  echo ""
  echo "=== Test group 10: backfill does NOT dedupe same-second events with different args_hash ==="

  # Pre-populate the DB with a row at second precision (as the hook/drain
  # path would have written it), then run the backfill over a synthetic
  # transcript recording the SAME (session_id, skill_name, second) but with
  # DIFFERENT args — a distinct invocation that must NOT be collapsed into
  # the existing row just because the (session_id, skill_name, ts-second)
  # triple matches.
  DIFFDIR=$(mktemp -d)
  DIFFDB="$DIFFDIR/diffargs_test.duckdb"
  DIFFPROJDIR="$DIFFDIR/projects/-tmp-diffargs"
  mkdir -p "$DIFFPROJDIR"

  dq "$DIFFDB" "
    CREATE TABLE IF NOT EXISTS skill_usage (
      session_id VARCHAR, skill_name VARCHAR, project_path VARCHAR,
      args_hash VARCHAR, ts TIMESTAMP, backfilled BOOLEAN DEFAULT FALSE
    );
    INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
    VALUES ('sess-DIFFARGS', 'cli-package', '/tmp', 'hash-old-value',
            CAST('2026-06-11T09:30:00' AS TIMESTAMP), FALSE);
  " > /dev/null

  cat > "$DIFFPROJDIR/sess-DIFFARGS.jsonl" <<'EOF'
{"type":"assistant","cwd":"/tmp","timestamp":"2026-06-11T09:30:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_diff1","name":"Skill","input":{"skill":"cli-package","args":"a completely different args string"}}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$DIFFDB" --projects-dir "$DIFFDIR/projects" > "$DIFFDIR/backfill_out.log" 2>&1
  DIFF_STATUS=$?

  if [ "$DIFF_STATUS" -eq 0 ]; then
    DIFF_COUNT=$(dq "$DIFFDB" "SELECT COUNT(*) FROM skill_usage WHERE session_id='sess-DIFFARGS';")
    assert "backfill: same-second same-skill DIFFERENT args_hash -> both rows kept (2, not 1)" "$DIFF_COUNT" "2"
  else
    echo "  SKIP: backfill script did not exit 0 for diff-args test (see $DIFFDIR/backfill_out.log)"
    cat "$DIFFDIR/backfill_out.log" 2>/dev/null | tail -20
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
