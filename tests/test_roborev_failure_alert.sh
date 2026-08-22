#!/usr/bin/env bash
# tests/test_roborev_failure_alert.sh — Integration tests for
# .claude/scripts/roborev-failure-alert (llm#946).
#
# Focus: the SIGNAL_ACCOUNT runtime-read + fail-closed guard added by
# llm#946 (the real account literal was scrubbed from git history after a
# 4-month public exposure). Uses a fake $HOME, a fake ROBOREV_BIN, and a
# fake OSASCRIPT_BIN so this test NEVER touches the real roborev daemon,
# never pops a real macOS notification, and never touches the live Signal
# account.
#
# Usage:
#   bash tests/test_roborev_failure_alert.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/roborev-failure-alert"

PASS=0
FAIL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "        expected to find: $needle"
    echo "        actual log:       ${haystack:0:400}"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (unexpectedly present: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== roborev-failure-alert Tests ==="

echo ""
echo "-- Test: bash -n syntax check"
if bash -n "$SCRIPT" 2>/dev/null; then
  echo "  PASS: bash -n"
  PASS=$((PASS + 1))
else
  echo "  FAIL: bash -n"
  FAIL=$((FAIL + 1))
fi

TMP="$(mktemp -d /tmp/roborev_failure_alert_test_XXXXXX)"
FAKE_HOME="$TMP/home"

FAKE_ROBOREV_NOT_RUNNING="$TMP/roborev_not_running.sh"
cat > "$FAKE_ROBOREV_NOT_RUNNING" <<'EOF'
#!/usr/bin/env bash
echo "roborev: not running"
exit 1
EOF
chmod +x "$FAKE_ROBOREV_NOT_RUNNING"

FAKE_OSASCRIPT="$TMP/osascript.sh"
cat > "$FAKE_OSASCRIPT" <<EOF
#!/usr/bin/env bash
echo "osascript invoked: \$*" >> "$TMP/osascript_calls.log"
exit 0
EOF
chmod +x "$FAKE_OSASCRIPT"

read_log() {
  cat "$FAKE_HOME/.claude/logs/roborev_failure_alert.log" 2>/dev/null || echo ""
}

# ── Scenario 1: SIGNAL_ACCOUNT unset, no secrets.env present -> fails closed
#    before touching roborev status or osascript at all.

echo ""
echo "-- Test: SIGNAL_ACCOUNT unset and no secrets.env present -> fails closed, never calls roborev or osascript"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME"
rm -f "$TMP/osascript_calls.log"

env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" ROBOREV_BIN="$FAKE_ROBOREV_NOT_RUNNING" \
  OSASCRIPT_BIN="$FAKE_OSASCRIPT" \
  bash "$SCRIPT" >/dev/null 2>&1
rc1=$?
log1=$(read_log)
assert_contains "logs a FATAL naming the unset account" "FATAL: SIGNAL_ACCOUNT is unset/empty" "$log1"
assert_contains "FATAL log names secrets.env" "secrets.env" "$log1"
assert_contains "FATAL log references llm#946" "llm#946" "$log1"
if [ "$rc1" != "0" ]; then
  echo "  PASS: script exits non-zero when SIGNAL_ACCOUNT is unset and no secrets.env exists (rc=$rc1)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit non-zero, got rc=$rc1"
  FAIL=$((FAIL + 1))
fi
if [ -f "$TMP/osascript_calls.log" ]; then
  echo "  FAIL: osascript fake WAS invoked despite SIGNAL_ACCOUNT being unset"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: osascript fake was NOT invoked (fail-closed guard fired before any alert channel)"
  PASS=$((PASS + 1))
fi

# ── Scenario 2: SIGNAL_ACCOUNT unset, but a fixture secrets.env supplies it
#    -> the script self-sources it, proceeds past account resolution, and
#    reaches the (fake) roborev status check.

echo ""
echo "-- Test: SIGNAL_ACCOUNT unset but a fixture secrets.env supplies it -> sourced, proceeds past account resolution"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.config"
printf 'SIGNAL_ACCOUNT="+15550001111"\n' > "$FAKE_HOME/.config/secrets.env"
chmod 600 "$FAKE_HOME/.config/secrets.env"
rm -f "$TMP/osascript_calls.log"

env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" ROBOREV_BIN="$FAKE_ROBOREV_NOT_RUNNING" \
  OSASCRIPT_BIN="$FAKE_OSASCRIPT" \
  bash "$SCRIPT" >/dev/null 2>&1
rc2=$?
log2=$(read_log)
assert_not_contains "does not log a FATAL when secrets.env supplies the account" "FATAL: SIGNAL_ACCOUNT" "$log2"
assert_contains "reaches the daemon-down alert path using the fake roborev status" "ALERT: daemon not running" "$log2"
if [ "$rc2" = "0" ]; then
  echo "  PASS: script exits 0 on the (fake) daemon-down alert path once the account resolves (rc=$rc2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: unexpected exit code once account resolves, got rc=$rc2"
  FAIL=$((FAIL + 1))
fi
if [ -f "$TMP/osascript_calls.log" ] && grep -ql "roborev DOWN" "$TMP/osascript_calls.log"; then
  echo "  PASS: fake osascript was invoked with the daemon-down alert (account resolution reached the alert channel)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fake osascript was not invoked as expected"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
