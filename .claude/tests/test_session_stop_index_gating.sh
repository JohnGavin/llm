#!/usr/bin/env bash
# test_session_stop_index_gating.sh — Hermetic tests for llm#912: gating the
# session_index.log write in session_stop.sh on the one-shot `_bye_detected`
# sentinel, instead of writing on every Stop hook firing (every assistant
# response).
#
# Root cause (llm#912): the session-index block was ungated, so it appended
# one row to session_index.log per Stop hook firing. Measured impact: ~93%
# of rows on 2026-08-04 were duplicate per-turn appends (4326 lines for only
# 12 distinct (branch, slug) pairs across 3 days).
#
# Fix (this same commit): gate the write on the same `_bye_detected`
# sentinel already used by the llm#803 DB-stop-write and the llm#910
# telemetry-export/mem_pr blocks in this file — option 1 of the issue's
# three proposed options, chosen because this is an append-only flat log
# (not a DB row), so option 2's per-turn upsert would mean rewriting the
# whole file on every response.
#
# This test proves, against a scratch CLAUDE_RUNTIME_ROOT only (never the
# real ~/.claude):
#   1. Repeated non-/bye Stop firings for one session write ZERO rows
#      (previously: one row per firing).
#   2. A single real /bye-terminated stop (bye sentinel present) writes
#      EXACTLY ONE row for that session.
#   3. Further non-/bye Stop firings for the SAME already-ended session do
#      NOT add a second row (idempotent w.r.t. one real session — no
#      duplication).
#   4. A DIFFERENT session's real /bye stop still gets its OWN row (no
#      over-deduplication across distinct sessions).
#
# Requires: bash only (no duckdb dependency — session_index.log is a flat
# tab-separated text file, not a unified.duckdb table).

set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SESSION_STOP="$WT/.claude/hooks/session_stop.sh"
SESSION_SLUG="$WT/.claude/scripts/session_slug.sh"

PASS=0
FAIL=0

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

if [ ! -f "$SESSION_STOP" ]; then
  echo "SKIP: session_stop.sh not found at $SESSION_STOP"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# --------------------------------------------------------------------------
# Setup a hermetic CLAUDE_RUNTIME_ROOT — never touches ~/.claude.
# --------------------------------------------------------------------------
T=$(mktemp -d)
mkdir -p "$T/logs" "$T/scripts" "$T/project/.claude"

# session_index block resolves $CLAUDE_DIR/scripts/session_slug.sh, and
# $CLAUDE_DIR == $CLAUDE_RUNTIME_ROOT == $T in this test, so the real
# session_slug.sh must be reachable under $T/scripts.
cp "$SESSION_SLUG" "$T/scripts/session_slug.sh"
chmod +x "$T/scripts/session_slug.sh"

INDEX_LOG="$T/logs/session_index.log"

_run_stop() {
  local session_id="$1"
  CLAUDE_RUNTIME_ROOT="$T" \
  CLAUDE_CONTROL_PLANE_ROOT="$T" \
  CLAUDE_PROJECT_DIR="$T/project" \
  CLAUDE_SESSION_ID="$session_id" \
  bash "$SESSION_STOP" >"$T/stop_output.log" 2>&1
}

_line_count() {
  [ -f "$INDEX_LOG" ] || { echo 0; return; }
  wc -l < "$INDEX_LOG" | tr -d ' '
}

echo ""
echo "=== Test group 1: non-/bye Stop firings write ZERO rows ==="

# Fire the Stop hook 3x for sess-A with NO bye sentinel present — simulates
# 3 assistant responses within one session, none of them /bye.
_run_stop "sess-A"
_run_stop "sess-A"
_run_stop "sess-A"
assert "3 non-/bye firings write 0 session_index.log rows" "$(_line_count)" "0"

echo ""
echo "=== Test group 2: a real /bye stop writes exactly ONE row ==="

touch "$T/.bye-session-stop.sess-A"
_run_stop "sess-A"
assert "one /bye-gated firing writes exactly 1 row" "$(_line_count)" "1"

if [ -f "$INDEX_LOG" ]; then
  FIELD_COUNT=$(awk -F'\t' '{print NF; exit}' "$INDEX_LOG")
  assert "the written row has 3 tab-separated fields (ts, branch, slug)" "$FIELD_COUNT" "3"
fi

echo ""
echo "=== Test group 3: further non-/bye firings for the SAME session add no more rows ==="

# The bye sentinel was consumed (one-shot) by the previous firing, so these
# behave like ordinary per-response Stop events for an already-ended session.
_run_stop "sess-A"
_run_stop "sess-A"
assert "2 more non-/bye firings for sess-A still leave exactly 1 row" "$(_line_count)" "1"

echo ""
echo "=== Test group 4: a DIFFERENT session's real /bye stop gets its own row (no over-dedup) ==="

touch "$T/.bye-session-stop.sess-B"
_run_stop "sess-B"
assert "sess-B's /bye-gated firing adds a 2nd, distinct row" "$(_line_count)" "2"

# Non-/bye noise for sess-B afterward must not add a 3rd row either.
_run_stop "sess-B"
assert "further non-/bye firings for sess-B still leave exactly 2 rows total" "$(_line_count)" "2"

# --------------------------------------------------------------------------
# Cleanup + report
# --------------------------------------------------------------------------
rm -rf "$T"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
