#!/usr/bin/env bash
# test_agent_runs_capture_1423.sh — llm#1423: agent_runs duration_sec,
# dispatch_id and outcome must be real values or NULL, never ~1 s / always NULL.
#
# Root cause under test: a BACKGROUND Agent dispatch returns from PostToolUse
# at launch (tool_response.status = "async_launched"), so the old hook wrote
# status='done' and duration ~1 s at launch; SubagentStop (the real completion
# event) was not logged; dispatch_id and outcome were never populated.
#
# Hermetic: temp HOME and a SCHEMA-ONLY DuckDB fixture built by the repo's own
# importer (it creates agent_runs when absent). Never opens or copies the live
# ~/.claude/logs/unified.duckdb (llm#1405). Requires duckdb and jq on PATH.
#
# Falsification: set HOOK_SH / LOG_SCRIPT / IMPORT_SCRIPT to pre-fix copies of
# the three scripts; the async and end-event groups must then FAIL.

set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_SH="${HOOK_SH:-$WT/.claude/hooks/log_agent_run.sh}"
LOG_SCRIPT="${LOG_SCRIPT:-$WT/.claude/scripts/log_session.sh}"
IMPORT_SCRIPT="${IMPORT_SCRIPT:-$WT/.claude/scripts/agent_events_staging_import.sh}"

PASS=0
FAIL=0

dq() { duckdb -init /dev/null "$1" -noheader -list -c "$2" 2>/dev/null; }

assert() {
  if [ "$2" = "$3" ]; then
    echo "  PASS: $1"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $1"; echo "        expected: [$3]"; echo "        got:      [$2]"
    FAIL=$((FAIL + 1))
  fi
}

T=$(mktemp -d)
mkdir -p "$T/.claude/logs" "$T/.claude/scripts" "$T/.claude/hooks"
cp "$LOG_SCRIPT" "$T/.claude/scripts/log_session.sh"
cp "$IMPORT_SCRIPT" "$T/.claude/scripts/agent_events_staging_import.sh"
cp "$HOOK_SH" "$T/.claude/hooks/log_agent_run.sh"
chmod +x "$T/.claude/scripts/"*.sh "$T/.claude/hooks/"*.sh

DB="$T/.claude/logs/unified.duckdb"
STAGING="$T/.claude/logs/agent_events_staging.jsonl"
PVLOG="$T/.claude/logs/worktree_post_verify.log"
: > "$PVLOG"

# Schema-only fixture: an empty DB file; the importer creates agent_runs.
duckdb -init /dev/null "$DB" -c "SELECT 1;" >/dev/null 2>&1
drain() { bash "$T/.claude/scripts/agent_events_staging_import.sh" "$DB" "$STAGING" "$PVLOG" >/dev/null 2>&1; }
hook()  { printf '%s' "$1" | HOME="$T" bash "$T/.claude/hooks/log_agent_run.sh"; }
drain   # creates the schema (staging empty -> SKIP path)

DID="1eadb91f-3351-46f7-a640-f8f32f3a6e5e"
PROMPT="TASK SCOPE (dispatch_id=${DID}, expires=2026-10-13T17:30:00Z): do work"

echo ""
echo "=== Group 1: dispatch_id extracted from the dispatch prompt, NULL when absent ==="
hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_use_id":"toolu_A","tool_input":{"subagent_type":"fixer","model":"sonnet","description":"with id","prompt":"'"$PROMPT"'"}}'
hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_use_id":"toolu_B","tool_input":{"subagent_type":"fixer","model":"sonnet","description":"no id","prompt":"just do it"}}'
drain
assert "dispatch_id stored for the prompt that carries one" \
  "$(dq "$DB" "SELECT dispatch_id FROM agent_runs WHERE tool_use_id='toolu_A';")" "$DID"
assert "dispatch_id NULL (not invented) when the prompt has none" \
  "$(dq "$DB" "SELECT CAST(dispatch_id AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_B';")" "NULL"

echo ""
echo "=== Group 2: async launch is NOT a completion ==="
hook '{"hook_event_name":"PostToolUse","session_id":"s1","tool_use_id":"toolu_A","tool_input":{"subagent_type":"fixer","description":"with id"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"agent_AAA"}}'
drain
assert "after async launch the run is still 'running'" \
  "$(dq "$DB" "SELECT status FROM agent_runs WHERE tool_use_id='toolu_A';")" "running"
assert "after async launch duration_sec is NULL (not a ~1 s launch latency)" \
  "$(dq "$DB" "SELECT CAST(duration_sec AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_A';")" "NULL"
assert "after async launch exactly one row for the dispatch (no orphan duplicate)" \
  "$(dq "$DB" "SELECT count(*) FROM agent_runs WHERE tool_use_id='toolu_A';")" "1"

echo ""
echo "=== Group 3: SubagentStop closes the run with the real end ==="
hook '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"agent_AAA","agent_type":"fixer"}'
drain
assert "SubagentStop sets status 'done'" \
  "$(dq "$DB" "SELECT status FROM agent_runs WHERE tool_use_id='toolu_A';")" "done"
assert "SubagentStop sets ended_at" \
  "$(dq "$DB" "SELECT ended_at IS NOT NULL FROM agent_runs WHERE tool_use_id='toolu_A';")" "true"
assert "duration_sec is end minus start (non-negative)" \
  "$(dq "$DB" "SELECT duration_sec >= 0 AND duration_sec = epoch(ended_at - started_at) FROM agent_runs WHERE tool_use_id='toolu_A';")" "true"
assert "the other (never-ended) run keeps duration_sec NULL" \
  "$(dq "$DB" "SELECT CAST(duration_sec AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_B';")" "NULL"

echo ""
echo "=== Group 4: duration is the true span, not ~1 s (controlled timestamps) ==="
cat > "$STAGING" <<EOF
{"type":"agent_start","ts":"2026-10-13T12:00:00Z","session_id":"s2","agent_type":"fixer","model":"sonnet","prompt_preview":"long run","status":"running","tool_use_id":"toolu_L","dispatch_id":""}
{"type":"agent_launch","ts":"2026-10-13T12:00:01Z","session_id":"s2","tool_use_id":"toolu_L","agent_id":"agent_LLL"}
{"type":"agent_end","ts":"2026-10-13T12:05:07Z","session_id":"s2","agent_type":"fixer","status":"done","agent_id":"agent_LLL"}
EOF
drain
assert "a 307 s run records duration_sec = 307" \
  "$(dq "$DB" "SELECT CAST(duration_sec AS INTEGER) FROM agent_runs WHERE tool_use_id='toolu_L';")" "307"
assert "an empty dispatch_id in the event is stored as NULL" \
  "$(dq "$DB" "SELECT CAST(dispatch_id AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_L';")" "NULL"

echo ""
echo "=== Group 5: outcome from the post-verify log, three-valued ==="
cat > "$STAGING" <<EOF
{"type":"agent_start","ts":"2026-10-13T13:00:00Z","session_id":"s3","agent_type":"fixer","model":"sonnet","prompt_preview":"p","status":"running","tool_use_id":"toolu_P","dispatch_id":"aaaaaaaa-0000-0000-0000-000000000001"}
{"type":"agent_start","ts":"2026-10-13T13:00:01Z","session_id":"s3","agent_type":"fixer","model":"sonnet","prompt_preview":"p","status":"running","tool_use_id":"toolu_F","dispatch_id":"aaaaaaaa-0000-0000-0000-000000000002"}
{"type":"agent_start","ts":"2026-10-13T13:00:02Z","session_id":"s3","agent_type":"fixer","model":"sonnet","prompt_preview":"p","status":"running","tool_use_id":"toolu_I","dispatch_id":"aaaaaaaa-0000-0000-0000-000000000003"}
{"type":"agent_start","ts":"2026-10-13T13:00:03Z","session_id":"s3","agent_type":"fixer","model":"sonnet","prompt_preview":"p","status":"running","tool_use_id":"toolu_N","dispatch_id":"aaaaaaaa-0000-0000-0000-000000000004"}
EOF
cat > "$PVLOG" <<EOF
2026-10-13 13:10:00 CAPTURE id=aaaaaaaa-0000-0000-0000-000000000001 repo=/r head=abc
2026-10-13 13:11:00 CHECK id=aaaaaaaa-0000-0000-0000-000000000001 OK head=abc branch=main
2026-10-13 13:11:01 CHECK id=aaaaaaaa-0000-0000-0000-000000000002 DRIFT verdict=UNCOMMITTED_WRITES head_before=a
2026-10-13 13:11:02 CHECK id=aaaaaaaa-0000-0000-0000-000000000003 INDETERMINATE head_before=a head_after=b
EOF
drain
assert "post-verify OK -> outcome 'pass'" \
  "$(dq "$DB" "SELECT outcome FROM agent_runs WHERE tool_use_id='toolu_P';")" "pass"
assert "post-verify DRIFT -> outcome 'fail'" \
  "$(dq "$DB" "SELECT outcome FROM agent_runs WHERE tool_use_id='toolu_F';")" "fail"
assert "post-verify INDETERMINATE -> outcome 'indeterminate' (not pass, not fail)" \
  "$(dq "$DB" "SELECT outcome FROM agent_runs WHERE tool_use_id='toolu_I';")" "indeterminate"
assert "no post-verify line -> outcome stays NULL" \
  "$(dq "$DB" "SELECT CAST(outcome AS VARCHAR) FROM agent_runs WHERE tool_use_id='toolu_N';")" "NULL"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
rm -rf "$T"
[ "$FAIL" -eq 0 ]
