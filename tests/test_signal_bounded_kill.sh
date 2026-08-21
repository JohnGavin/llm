#!/usr/bin/env bash
# tests/test_signal_bounded_kill.sh — Unit tests for _bounded_kill() in
# .claude/scripts/lib_signal_process_guard.sh (llm#937/#957).
#
# Proves the actual bug and its fix:
#   - A `timeout <N>` call WITHOUT -k does not merely "return while the
#     child survives" — verified empirically (2026-08-21) that GNU timeout
#     genuinely BLOCKS until the child exits when the child ignores SIGTERM,
#     which means the wrapper itself can hang indefinitely too. `-k <grace>`
#     (or the pure-shell fallback) is what actually guarantees termination.
#
# Safety: every fixture process here is SELF-BOUNDING (a finite retry loop,
# never `while true`) so this test can NEVER leave an orphaned process
# behind even if _bounded_kill's own kill logic is broken — the fixture
# will exit on its own within FIXTURE_CAP_S regardless. This test does NOT
# use kill/pkill directly; termination is exercised only via _bounded_kill's
# own internal kill calls (the thing under test), never via a direct Bash
# kill/pkill from this test's own top-level commands.
#
# Usage:
#   bash tests/test_signal_bounded_kill.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/.claude/scripts/lib_signal_process_guard.sh"

PASS=0
FAIL=0

echo "=== lib_signal_process_guard.sh: _bounded_kill Tests ==="

echo ""
echo "-- Test: bash -n syntax check"
if bash -n "$LIB" 2>/dev/null; then
  echo "  PASS: bash -n"; PASS=$((PASS + 1))
else
  echo "  FAIL: bash -n"; FAIL=$((FAIL + 1))
fi

TMP="$(mktemp -d /tmp/signal_bounded_kill_test_XXXXXX)"

# Self-bounding fixture: ignores SIGTERM (like real signal-cli under
# llm#937/#957) but ALWAYS exits on its own after FIXTURE_CAP_S seconds —
# this cap is a safety net, not the thing under test.
FIXTURE_CAP_S=15
make_fixture() {
  local path="$1"
  cat > "$path" <<FIXTURE
#!/usr/bin/env bash
trap 'echo "got SIGTERM, ignoring" >> "$TMP/fixture.log"' TERM
for _i in \$(seq 1 $FIXTURE_CAP_S); do sleep 1; done
FIXTURE
  chmod +x "$path"
}

# ── Test 1: GNU timeout branch (timeout/gtimeout present) truly kills ──────
echo ""
echo "-- Test: _bounded_kill terminates a SIGTERM-ignoring process well before its self-bound cap (GNU timeout branch)"
FIXTURE1="$TMP/fixture1.sh"
make_fixture "$FIXTURE1"

start_ts=$(date +%s)
(
  . "$LIB"
  _bounded_kill 2 2 "$FIXTURE1"
)
rc1=$?
end_ts=$(date +%s)
elapsed1=$((end_ts - start_ts))

# Expect termination well under the fixture's own 15s self-bound cap —
# generous upper bound (10s) to absorb CI/scheduling jitter around the
# 2s timeout + 2s kill-grace budget.
if [ "$elapsed1" -lt 10 ]; then
  echo "  PASS: returned in ${elapsed1}s (< 10s), well before the ${FIXTURE_CAP_S}s self-bound cap (rc=$rc1)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: took ${elapsed1}s — expected _bounded_kill to force termination well before ${FIXTURE_CAP_S}s (rc=$rc1)"
  FAIL=$((FAIL + 1))
fi

# ── Test 2: pure-shell fallback branch (no timeout/gtimeout on PATH) ───────
echo ""
echo "-- Test: _bounded_kill terminates via the pure-shell fallback (no timeout/gtimeout on PATH)"
FIXTURE2="$TMP/fixture2.sh"
make_fixture "$FIXTURE2"

start_ts2=$(date +%s)
(
  . "$LIB"
  export PATH="/bin:/usr/bin"
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    echo "SETUP-SKIP: timeout/gtimeout still visible on restricted PATH in this environment" >&2
    exit 99
  fi
  _bounded_kill 2 2 "$FIXTURE2"
)
rc2=$?
end_ts2=$(date +%s)
elapsed2=$((end_ts2 - start_ts2))

if [ "$rc2" -eq 99 ]; then
  echo "  SKIP: could not isolate PATH from timeout/gtimeout in this environment"
elif [ "$elapsed2" -lt 10 ]; then
  echo "  PASS: fallback branch returned in ${elapsed2}s (< 10s), well before the ${FIXTURE_CAP_S}s self-bound cap (rc=$rc2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fallback branch took ${elapsed2}s — expected forced termination well before ${FIXTURE_CAP_S}s (rc=$rc2)"
  FAIL=$((FAIL + 1))
fi

# ── Test 3: a well-behaved process returns its own exit code untouched ────
echo ""
echo "-- Test: _bounded_kill passes through a well-behaved process's own exit code"
FAST_CLI="$TMP/fast-cli.sh"
cat > "$FAST_CLI" <<'FAST'
#!/usr/bin/env bash
exit 0
FAST
chmod +x "$FAST_CLI"
(
  . "$LIB"
  _bounded_kill 5 2 "$FAST_CLI"
)
fast_rc=$?
if [ "$fast_rc" -eq 0 ]; then
  echo "  PASS: well-behaved process returns its own exit code (rc=$fast_rc)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: well-behaved process should return 0, got rc=$fast_rc"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
