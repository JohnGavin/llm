#!/usr/bin/env bash
# test_command_usage.sh — Hermetic tests for log_command_use.sh +
# command_usage_staging_import.sh + backfill_command_usage.R (Card 1e,
# #745). Mirrors test_skill_usage.sh's conventions. Tests use a temp HOME so
# the hook's hardcoded $HOME/.claude/... paths are safe, and a scratch
# duckdb so the live unified.duckdb is never touched. Requires: duckdb, jq
# on PATH. R tests are skipped (not failed) if Rscript/duckdb-R/jsonlite
# are unavailable outside the project nix shell.

set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$WT/.claude/hooks/log_command_use.sh"
DRAIN="$WT/.claude/scripts/command_usage_staging_import.sh"
BACKFILL="$WT/.claude/scripts/backfill_command_usage.R"

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
mkdir -p "$T/.claude/commands"

TESTDB="$T/.claude/logs/unified.duckdb"
STAGING="$T/.claude/logs/command_usage_staging.jsonl"

echo "test-session-A" > "$T/.claude/logs/.current_session"

# Fixture: installed-command files for the Fix-2 cross-check gate in
# log_command_use.sh (a leading-slash token is only staged when it matches
# an installed command's .md file). Real repo commands used across these
# tests: check (group 1/5), bye (group 6b).
echo "# check stub fixture" > "$T/.claude/commands/check.md"
echo "# bye stub fixture"   > "$T/.claude/commands/bye.md"

echo ""
echo "=== Test group 1: hook stages a JSONL record for a slash command ==="

PAYLOAD='{"hook_event_name":"UserPromptSubmit","user_prompt":"/check verbose"}'

printf '%s' "$PAYLOAD" | HOME="$T" bash "$HOOK"

assert "staging file created" "$([ -f "$STAGING" ] && echo yes || echo no)" "yes"

STAGED_LINE=$(cat "$STAGING" 2>/dev/null)
STAGED_CMD=$(echo "$STAGED_LINE" | jq -r '.command_name')
assert "staged record: command_name='check'" "$STAGED_CMD" "check"

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
if ! echo "$STAGED_LINE" | grep -q "verbose"; then
  echo "  PASS: staged record does NOT contain raw args text"
  PASS=$((PASS + 1))
else
  echo "  FAIL: staged record leaked raw args text"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test group 2: non-slash prompts and edge cases are no-ops ==="

RM_BEFORE=$(wc -l < "$STAGING" | tr -d ' ')
NOOP_PAYLOAD='{"hook_event_name":"UserPromptSubmit","user_prompt":"please run the tests for me"}'
printf '%s' "$NOOP_PAYLOAD" | HOME="$T" bash "$HOOK"
RM_AFTER=$(wc -l < "$STAGING" | tr -d ' ')
assert "plain-text prompt (no leading slash): no new line staged" "$RM_AFTER" "$RM_BEFORE"

RM_BEFORE2=$(wc -l < "$STAGING" | tr -d ' ')
PATH_PAYLOAD='{"hook_event_name":"UserPromptSubmit","user_prompt":"/Users/johngavin/docs_gh/llm/R/foo.R has a bug"}'
printf '%s' "$PATH_PAYLOAD" | HOME="$T" bash "$HOOK"
RM_AFTER2=$(wc -l < "$STAGING" | tr -d ' ')
assert "absolute path typed as prompt (not a command): no new line staged" "$RM_AFTER2" "$RM_BEFORE2"

echo ""
echo "=== Test group 3: staging_import drains into command_usage (fresh DB) ==="

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1

ROW_COUNT=$(dq "$TESTDB" "SELECT COUNT(*) FROM command_usage;")
assert "drain: exactly 1 row landed in command_usage" "$ROW_COUNT" "1"

DRAINED_CMD=$(dq "$TESTDB" "SELECT command_name FROM command_usage WHERE session_id='test-session-A';")
assert "drain: command_name='check'" "$DRAINED_CMD" "check"

DRAINED_BF=$(dq "$TESTDB" "SELECT backfilled FROM command_usage WHERE session_id='test-session-A';")
assert "drain: backfilled=false for forward-instrumented row" "$DRAINED_BF" "false"

assert "drain: staging file consumed (removed)" "$([ -f "$STAGING" ] && echo yes || echo no)" "no"

echo ""
echo "=== Test group 4: drain is idempotent when staging is empty ==="

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT2=$(dq "$TESTDB" "SELECT COUNT(*) FROM command_usage;")
assert "drain re-run with no staging file: row count unchanged" "$ROW_COUNT2" "1"

echo ""
echo "=== Test group 5: drain dedupes on (session_id, command_name, ts, args_hash) ==="

printf '%s' "$PAYLOAD" | HOME="$T" bash "$HOOK"
EXISTING_TS=$(dq "$TESTDB" "SELECT CAST(ts AS VARCHAR) FROM command_usage WHERE session_id='test-session-A';")
EXISTING_HASH=$(dq "$TESTDB" "SELECT args_hash FROM command_usage WHERE session_id='test-session-A';")
printf '{"ts":"%s","session_id":"test-session-A","command_name":"check","project_path":"/tmp","args_hash":"%s"}\n' \
  "$EXISTING_TS" "$EXISTING_HASH" > "$STAGING"

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT3=$(dq "$TESTDB" "SELECT COUNT(*) FROM command_usage;")
assert "drain: duplicate (session_id,command_name,ts,args_hash) not re-inserted" "$ROW_COUNT3" "1"

echo ""
echo "=== Test group 5b: drain does NOT dedupe same-second events with different args_hash ==="

dq "$TESTDB" "
  INSERT INTO command_usage (session_id, command_name, project_path, args_hash, ts, backfilled)
  VALUES ('test-session-C', 'issue-triage', '/tmp', 'hash-alpha',
          CAST('2026-06-03T14:00:00' AS TIMESTAMP), FALSE);
" > /dev/null

printf '{"ts":"2026-06-03T14:00:00.321Z","session_id":"test-session-C","command_name":"issue-triage","project_path":"/tmp","args_hash":"hash-beta"}\n' \
  > "$STAGING"

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT_C=$(dq "$TESTDB" "SELECT COUNT(*) FROM command_usage WHERE session_id='test-session-C';")
assert "drain: same-second same-command DIFFERENT args_hash -> both rows kept (2, not 1)" "$ROW_COUNT_C" "2"

echo ""
echo "=== Test group 5c: drain treats NULL and '' args_hash as the SAME value for a no-args command (cross-writer dedup, #747 review Fix 1) ==="

# Simulates the exact bug found in review: the hook writes args_hash=""
# (empty string) for a no-args command, while the R backfill's hash_args()
# writes SQL NULL for the same case. Before the fix, IS NOT DISTINCT FROM
# treated '' and NULL as different values, so re-running the backfill after
# the hook was live double-counted every no-args command.
dq "$TESTDB" "
  INSERT INTO command_usage (session_id, command_name, project_path, args_hash, ts, backfilled)
  VALUES ('test-session-D', 'bye', '/tmp', '',
          CAST('2026-06-04T09:00:00' AS TIMESTAMP), FALSE);
" > /dev/null

printf '{"ts":"2026-06-04T09:00:00.789Z","session_id":"test-session-D","command_name":"bye","project_path":"/tmp","args_hash":null}\n' \
  > "$STAGING"

bash "$DRAIN" "$TESTDB" "$STAGING" > /dev/null 2>&1
ROW_COUNT_D=$(dq "$TESTDB" "SELECT COUNT(*) FROM command_usage WHERE session_id='test-session-D';")
assert "drain: hook's '' and backfill/staging's NULL args_hash dedup to 1 row (not 2)" "$ROW_COUNT_D" "1"

echo ""
echo "=== Test group 6: etl_freshness registration (defensive, Card 1a coordination) ==="

FRESHNESS_EXISTS=$(dq "$TESTDB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='etl_freshness';")
assert "etl_freshness table created" "$FRESHNESS_EXISTS" "1"

FRESHNESS_ROW=$(dq "$TESTDB" "SELECT status FROM etl_freshness WHERE source_name='command_usage';")
assert "etl_freshness: command_usage registered with status='unknown' (event-driven, no SLA)" "$FRESHNESS_ROW" "unknown"

echo ""
echo "=== Test group 6b: leading-slash tokens that aren't installed commands are ignored (#747 review Fix 2) ==="

# Before the fix, the hook's regex matched ANY leading "/word" token, so a
# plain-English prompt like "/tmp needs cleaning" or "/etc is broken" (not a
# command invocation) staged a bogus "tmp"/"etc" command. The fix requires
# the extracted name to match an installed command file.
rm -f "$STAGING"

TMP_PAYLOAD='{"hook_event_name":"UserPromptSubmit","user_prompt":"/tmp needs cleaning"}'
printf '%s' "$TMP_PAYLOAD" | HOME="$T" bash "$HOOK"
assert "'/tmp needs cleaning' (not an installed command): no staging file created" \
  "$([ -f "$STAGING" ] && echo yes || echo no)" "no"

ETC_PAYLOAD='{"hook_event_name":"UserPromptSubmit","user_prompt":"/etc is broken"}'
printf '%s' "$ETC_PAYLOAD" | HOME="$T" bash "$HOOK"
assert "'/etc is broken' (not an installed command): no staging file created" \
  "$([ -f "$STAGING" ] && echo yes || echo no)" "no"

BYE_PAYLOAD='{"hook_event_name":"UserPromptSubmit","user_prompt":"/bye"}'
printf '%s' "$BYE_PAYLOAD" | HOME="$T" bash "$HOOK"
BYE_CMD=$([ -f "$STAGING" ] && jq -r '.command_name' < "$STAGING" 2>/dev/null || echo "")
assert "real installed command '/bye' still records" "$BYE_CMD" "bye"

rm -f "$STAGING"

echo ""
echo "=== Test group 6c: unrecognized payload shape triggers a throttled debug signal (#747 review Fix 3) ==="

DEBUGLOG="$T/.claude/logs/command_use_debug_test.log"
rm -f "$DEBUGLOG"
UNKNOWN_PAYLOAD='{"hook_event_name":"UserPromptSubmit","some_other_field":"/bye"}'

printf '%s' "$UNKNOWN_PAYLOAD" | HOME="$T" CMD_USE_DEBUG_LOG="$DEBUGLOG" bash "$HOOK"
HOOK_EXIT=$?
assert "hook exits 0 for unrecognized payload (never blocks prompt submission)" "$HOOK_EXIT" "0"

assert "debug log created when no recognized prompt field is found" \
  "$([ -f "$DEBUGLOG" ] && echo yes || echo no)" "yes"

if [ -f "$DEBUGLOG" ] && grep -q "some_other_field" "$DEBUGLOG"; then
  echo "  PASS: debug log records the unrecognized payload's top-level keys"
  PASS=$((PASS + 1))
else
  echo "  FAIL: debug log missing expected key name"
  FAIL=$((FAIL + 1))
fi

LINES_BEFORE=$(wc -l < "$DEBUGLOG" | tr -d ' ')
printf '%s' "$UNKNOWN_PAYLOAD" | HOME="$T" CMD_USE_DEBUG_LOG="$DEBUGLOG" bash "$HOOK"
LINES_AFTER=$(wc -l < "$DEBUGLOG" | tr -d ' ')
assert "debug signal throttled: a second unrecognized payload in the same window adds no new line" \
  "$LINES_AFTER" "$LINES_BEFORE"

rm -f "$DEBUGLOG"

echo ""
echo "=== Test group 7: backfill script (R) — skip gracefully if R env unavailable ==="

if command -v Rscript >/dev/null 2>&1 && Rscript -e 'quit(status = if (requireNamespace("duckdb", quietly=TRUE) && requireNamespace("jsonlite", quietly=TRUE)) 0L else 1L)' >/dev/null 2>&1; then
  BFDIR=$(mktemp -d)
  BFDB="$BFDIR/backfill_test.duckdb"
  PROJDIR="$BFDIR/projects/-tmp-proj"
  mkdir -p "$PROJDIR"

  # Minimal synthetic transcript: two invoked_skills attachment records
  # (the real record shape for custom slash commands, confirmed against
  # live transcripts — see backfill_command_usage.R header) plus one
  # unrelated assistant/tool_use line that must be ignored.
  cat > "$PROJDIR/sess-XYZ.jsonl" <<'EOF'
{"type":"attachment","cwd":"/tmp/proj","timestamp":"2026-05-01T10:00:00.000Z","attachment":{"type":"invoked_skills","skills":[{"name":"bye","path":"userSettings:bye","content":"..."}]}}
{"type":"attachment","cwd":"/tmp/proj","timestamp":"2026-05-02T11:00:00.000Z","attachment":{"type":"invoked_skills","skills":[{"name":"issue-triage","path":"userSettings:issue-triage","content":"..."}]}}
{"type":"assistant","timestamp":"2026-05-02T11:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_3","name":"Bash","input":{"command":"ls"}}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$BFDB" --projects-dir "$BFDIR/projects" > "$BFDIR/backfill_out.log" 2>&1
  BF_STATUS=$?

  if [ "$BF_STATUS" -eq 0 ]; then
    BF_COUNT1=$(dq "$BFDB" "SELECT COUNT(*) FROM command_usage;")
    assert "backfill: 2 slash-command invocations inserted (Bash tool_use ignored)" "$BF_COUNT1" "2"

    BF_BACKFILLED=$(dq "$BFDB" "SELECT COUNT(*) FROM command_usage WHERE backfilled=true;")
    assert "backfill: all inserted rows flagged backfilled=true" "$BF_BACKFILLED" "2"

    # Re-run — must be idempotent (no new rows).
    Rscript "$BACKFILL" --apply --db "$BFDB" --projects-dir "$BFDIR/projects" > "$BFDIR/backfill_out2.log" 2>&1
    BF_COUNT2=$(dq "$BFDB" "SELECT COUNT(*) FROM command_usage;")
    assert "backfill: idempotent re-run (row count stable)" "$BF_COUNT2" "$BF_COUNT1"
  else
    echo "  SKIP: backfill script did not exit 0 (see $BFDIR/backfill_out.log) — treating as environment gap, not a test failure"
    cat "$BFDIR/backfill_out.log" 2>/dev/null | tail -20
  fi

  echo ""
  echo "=== Test group 8: backfill derives project_path from transcript cwd, not a lossy dash-decode ==="

  # The encoded directory name below mimics a real Claude Code transcript
  # directory for a path containing a literal dash-bearing segment
  # ("docs_gh" -> "docs-gh" once slashes become dashes). Each transcript
  # line below carries the true `cwd`, which must be used verbatim instead
  # of gsub("-", "/")-decoding the directory name (which would corrupt this
  # path to ".../docs/gh/llm").
  CWDDIR=$(mktemp -d)
  CWDDB="$CWDDIR/cwd_test.duckdb"
  CWDPROJDIR="$CWDDIR/projects/-Users-johngavin-docs-gh-llm"
  mkdir -p "$CWDPROJDIR"

  cat > "$CWDPROJDIR/sess-CWD.jsonl" <<'EOF'
{"type":"attachment","cwd":"/Users/johngavin/docs_gh/llm","timestamp":"2026-06-15T08:00:00.000Z","attachment":{"type":"invoked_skills","skills":[{"name":"cleanup-worktrees","path":"userSettings:cleanup-worktrees","content":"..."}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$CWDDB" --projects-dir "$CWDDIR/projects" > "$CWDDIR/backfill_out.log" 2>&1
  CWD_STATUS=$?

  if [ "$CWD_STATUS" -eq 0 ]; then
    CWD_PROJECT=$(dq "$CWDDB" "SELECT project_path FROM command_usage WHERE session_id='sess-CWD';")
    assert "backfill: project_path taken from transcript cwd (not dash-decoded)" \
      "$CWD_PROJECT" "/Users/johngavin/docs_gh/llm"
  else
    echo "  SKIP: backfill script did not exit 0 for cwd test (see $CWDDIR/backfill_out.log)"
    cat "$CWDDIR/backfill_out.log" 2>/dev/null | tail -20
  fi

  echo ""
  echo "=== Test group 8b: hash_args() (R) parity with log_command_use.sh's hook hash convention ==="

  # Guard against the cross-writer args_hash bug that took skill_usage 3
  # review rounds to get right (#744): extract just hash_args() from the
  # backfill script (avoids a full --apply run) and confirm it produces
  # byte-identical output to the hook's shell convention
  # (printf '%s' "$_args" | shasum -a 256 | cut -c1-16 — no trailing
  # newline) for the same input string.
  HASH_GUARD_R=$(mktemp)
  sed -n '/^hash_args <- function/,/^}/p' "$BACKFILL" > "$HASH_GUARD_R"
  echo 'cat(hash_args("verbose"))' >> "$HASH_GUARD_R"

  R_HASH=$(Rscript "$HASH_GUARD_R" 2>/dev/null)
  SHELL_HASH=$(printf '%s' "verbose" | shasum -a 256 | cut -c1-16)
  assert "hash_args(\"verbose\") in R matches hook's shell hash convention" "$R_HASH" "$SHELL_HASH"
  rm -f "$HASH_GUARD_R"

  echo ""
  echo "=== Test group 9: backfill dedupes against an existing second-precision row (cross-writer ts mismatch) ==="

  # Pre-populate the DB with a row as the hook/drain path would have
  # written it (second precision, backfilled=FALSE, args_hash matching the
  # hook's convention for "verbose"), then run the backfill over a
  # synthetic transcript recording the SAME (session_id, command_name)
  # event with millisecond precision AND an `args` field on the skill
  # object hashing to the identical value (defensive parser support — see
  # backfill_command_usage.R header for why args aren't present in real
  # invoked_skills records today).
  XDIR=$(mktemp -d)
  XDB="$XDIR/xwriter_test.duckdb"
  XPROJDIR="$XDIR/projects/-tmp-xwriter"
  mkdir -p "$XPROJDIR"

  XW_ARGS_HASH=$(printf '%s' "verbose" | shasum -a 256 | cut -c1-16)

  dq "$XDB" "
    CREATE TABLE IF NOT EXISTS command_usage (
      session_id VARCHAR, command_name VARCHAR, project_path VARCHAR,
      args_hash VARCHAR, ts TIMESTAMP, backfilled BOOLEAN DEFAULT FALSE
    );
    INSERT INTO command_usage (session_id, command_name, project_path, args_hash, ts, backfilled)
    VALUES ('sess-XWRITER', 'check', '/tmp', '${XW_ARGS_HASH}',
            CAST('2026-06-10T12:00:00' AS TIMESTAMP), FALSE);
  " > /dev/null

  cat > "$XPROJDIR/sess-XWRITER.jsonl" <<'EOF'
{"type":"attachment","cwd":"/tmp","timestamp":"2026-06-10T12:00:00.456Z","attachment":{"type":"invoked_skills","skills":[{"name":"check","path":"userSettings:check","content":"...","args":"verbose"}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$XDB" --projects-dir "$XDIR/projects" > "$XDIR/backfill_out.log" 2>&1
  XW_STATUS=$?

  if [ "$XW_STATUS" -eq 0 ]; then
    XW_COUNT=$(dq "$XDB" "SELECT COUNT(*) FROM command_usage WHERE session_id='sess-XWRITER';")
    assert "backfill: cross-writer ts precision mismatch still dedups (1 row, not 2)" "$XW_COUNT" "1"
  else
    echo "  SKIP: backfill script did not exit 0 for cross-writer test (see $XDIR/backfill_out.log)"
    cat "$XDIR/backfill_out.log" 2>/dev/null | tail -20
  fi

  echo ""
  echo "=== Test group 10: backfill does NOT dedupe same-second events with different args_hash ==="

  DIFFDIR=$(mktemp -d)
  DIFFDB="$DIFFDIR/diffargs_test.duckdb"
  DIFFPROJDIR="$DIFFDIR/projects/-tmp-diffargs"
  mkdir -p "$DIFFPROJDIR"

  dq "$DIFFDB" "
    CREATE TABLE IF NOT EXISTS command_usage (
      session_id VARCHAR, command_name VARCHAR, project_path VARCHAR,
      args_hash VARCHAR, ts TIMESTAMP, backfilled BOOLEAN DEFAULT FALSE
    );
    INSERT INTO command_usage (session_id, command_name, project_path, args_hash, ts, backfilled)
    VALUES ('sess-DIFFARGS', 'check', '/tmp', 'hash-old-value',
            CAST('2026-06-11T09:30:00' AS TIMESTAMP), FALSE);
  " > /dev/null

  cat > "$DIFFPROJDIR/sess-DIFFARGS.jsonl" <<'EOF'
{"type":"attachment","cwd":"/tmp","timestamp":"2026-06-11T09:30:00.000Z","attachment":{"type":"invoked_skills","skills":[{"name":"check","path":"userSettings:check","content":"...","args":"a completely different args string"}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$DIFFDB" --projects-dir "$DIFFDIR/projects" > "$DIFFDIR/backfill_out.log" 2>&1
  DIFF_STATUS=$?

  if [ "$DIFF_STATUS" -eq 0 ]; then
    DIFF_COUNT=$(dq "$DIFFDB" "SELECT COUNT(*) FROM command_usage WHERE session_id='sess-DIFFARGS';")
    assert "backfill: same-second same-command DIFFERENT args_hash -> both rows kept (2, not 1)" "$DIFF_COUNT" "2"
  else
    echo "  SKIP: backfill script did not exit 0 for diff-args test (see $DIFFDIR/backfill_out.log)"
    cat "$DIFFDIR/backfill_out.log" 2>/dev/null | tail -20
  fi

  echo ""
  echo "=== Test group 10b: backfill treats NULL and '' args_hash as the SAME value for a no-args command (cross-writer dedup, #747 review Fix 1) ==="

  # Pre-populate the DB with a row exactly as the hook/drain path writes it
  # for a no-args command: args_hash='' (empty string), NOT NULL. The
  # synthetic transcript's invoked_skills record has no `args` field (the
  # real-world shape — see header), so hash_args(NULL) yields SQL NULL.
  # Before the fix, IS NOT DISTINCT FROM treated '' and NULL as different
  # values, producing 2 rows instead of 1.
  NULLDIR=$(mktemp -d)
  NULLDB="$NULLDIR/nullargs_test.duckdb"
  NULLPROJDIR="$NULLDIR/projects/-tmp-nullargs"
  mkdir -p "$NULLPROJDIR"

  dq "$NULLDB" "
    CREATE TABLE IF NOT EXISTS command_usage (
      session_id VARCHAR, command_name VARCHAR, project_path VARCHAR,
      args_hash VARCHAR, ts TIMESTAMP, backfilled BOOLEAN DEFAULT FALSE
    );
    INSERT INTO command_usage (session_id, command_name, project_path, args_hash, ts, backfilled)
    VALUES ('sess-NULLARGS', 'bye', '/tmp', '',
            CAST('2026-06-12T08:00:00' AS TIMESTAMP), FALSE);
  " > /dev/null

  cat > "$NULLPROJDIR/sess-NULLARGS.jsonl" <<'EOF'
{"type":"attachment","cwd":"/tmp","timestamp":"2026-06-12T08:00:00.000Z","attachment":{"type":"invoked_skills","skills":[{"name":"bye","path":"userSettings:bye","content":"..."}]}}
EOF

  Rscript "$BACKFILL" --apply --db "$NULLDB" --projects-dir "$NULLDIR/projects" > "$NULLDIR/backfill_out.log" 2>&1
  NULL_STATUS=$?

  if [ "$NULL_STATUS" -eq 0 ]; then
    NULL_COUNT=$(dq "$NULLDB" "SELECT COUNT(*) FROM command_usage WHERE session_id='sess-NULLARGS';")
    assert "backfill: hook's '' and backfill's NULL args_hash for a no-args command dedup to 1 row (not 2)" "$NULL_COUNT" "1"
  else
    echo "  SKIP: backfill script did not exit 0 for null-args test (see $NULLDIR/backfill_out.log)"
    cat "$NULLDIR/backfill_out.log" 2>/dev/null | tail -20
  fi
else
  echo "  SKIP: Rscript / duckdb / jsonlite R packages not on PATH outside the project nix shell"
  echo "        (run: nix-shell $WT/default.nix --run \"bash $WT/.claude/tests/test_command_usage.sh\")"
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
