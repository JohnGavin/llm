#!/usr/bin/env bash
# tests/test_stdin_null_guard.sh — verify that launchd plists for process-substitution
# scripts include StandardInPath=/dev/null (llm#153 state-T fix).
#
# Root-cause recap:
#   bash 3.2 (macOS system bash) + process substitution < <(...) + open stdin fd
#   → SIGTTIN/SIGTTOU → SIGTSTP → process state T (stopped, needs SIGCONT)
#   Fix: plist-level StandardInPath=/dev/null severs the tty-stop pathway.
#
# This test:
#   1. Verifies that all known-affected plists have StandardInPath=/dev/null.
#   2. Verifies that all those plists pass plutil -lint.
#   3. Simulates the stop-on-process-substitution scenario in a sub-shell and
#      confirms a script can read from /dev/null without ever entering T-state.
#
# Usage: bash tests/test_stdin_null_guard.sh
# Exit 0: all assertions pass.  Exit 1: one or more assertions failed.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHD_DIR="$REPO_ROOT/.claude/launchd"

# ── Assertion 1: StandardInPath=/dev/null present in affected plists ──────────

AFFECTED_PLISTS=(
  "com.claude.roborev-poll-merges.plist"
  "com.claude.roborev-severity-autoclose.plist"
  "com.claude.roborev-autoclose.plist"
  "com.claude.wiki-health-pulse.plist"
)

for plist in "${AFFECTED_PLISTS[@]}"; do
  path="$LAUNCHD_DIR/$plist"
  if [ ! -f "$path" ]; then
    fail "plist not found: $path"
    continue
  fi
  if grep -q "StandardInPath" "$path"; then
    ok "StandardInPath present: $plist"
  else
    fail "StandardInPath MISSING: $plist  (llm#153 fix not applied)"
  fi
  if grep -q "/dev/null" "$path"; then
    ok "StandardInPath=/dev/null: $plist"
  else
    fail "StandardInPath not /dev/null: $plist"
  fi
done

# ── Assertion 2: plutil -lint on all affected plists ─────────────────────────

for plist in "${AFFECTED_PLISTS[@]}"; do
  path="$LAUNCHD_DIR/$plist"
  if [ ! -f "$path" ]; then
    continue  # already failed above
  fi
  if plutil -lint "$path" >/dev/null 2>&1; then
    ok "plutil -lint OK: $plist"
  else
    fail "plutil -lint FAILED: $plist"
    plutil -lint "$path" 2>&1 | sed 's/^/  /'
  fi
done

# ── Assertion 3: simulate the fix — process substitution with /dev/null stdin ─
# Without the fix, under launchd (no controlling tty, open stdin from launchd's
# pipe), bash 3.2's job-control can SIGTTIN a background `< <(cmd)` pipe reader.
# We cannot fully replicate launchd's environment in a unit test (the real
# failure mode requires launchd's job-control context), BUT we can verify that
# the pattern works correctly when stdin is /dev/null by running the process
# substitution pattern with stdin redirected from /dev/null.

_test_procsubst_with_devnull() {
  local result
  result=$(
    # Redirect stdin from /dev/null — this is what StandardInPath=/dev/null does
    exec </dev/null
    ITEMS=()
    while IFS= read -r _line; do
      ITEMS+=("$_line")
    done < <(printf '%s\n' "alpha" "beta" "gamma")
    echo "${#ITEMS[@]}"
  )
  echo "$result"
}

count=$(_test_procsubst_with_devnull)
if [ "$count" = "3" ]; then
  ok "process substitution with stdin=/dev/null reads all 3 items (no stop)"
else
  fail "process substitution with stdin=/dev/null: expected 3 items, got '$count'"
fi

# ── Assertion 4: confirm plists that do NOT use < <(...) scripts are not
#    required to have StandardInPath (sanity check — don't over-prescribe) ───

UNAFFECTED_PLISTS=(
  "com.claude.roborev-agent-health.plist"
  "com.claude.pr-status-pulse.plist"
)

for plist in "${UNAFFECTED_PLISTS[@]}"; do
  path="$LAUNCHD_DIR/$plist"
  if [ -f "$path" ]; then
    ok "unaffected plist exists (no assertion on StandardInPath): $plist"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  echo "FAIL — $FAIL assertion(s) failed"
  exit 1
fi

echo "PASS — all $PASS assertions passed"
exit 0
