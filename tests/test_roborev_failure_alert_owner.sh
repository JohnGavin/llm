#!/usr/bin/env bash
# tests/test_roborev_failure_alert_owner.sh — Tests for check (d) in
# .claude/scripts/roborev-failure-alert: is the port-7373 listener actually
# launchd's supervised com.roborev.daemon, or a rival auto-started by a
# client (`roborev stream`, an interactive shell)? llm#984 (item 4),
# llm#1136.
#
# Verified live on this machine (2026-09-24): from at least 2026-09-14 to
# 2026-09-24 the port-7373 listener was NOT com.roborev.daemon -- it was a
# client-spawned daemon, invisible to every existing check because
# `roborev status` still reported healthy. This test covers the new check
# that would have caught it.
#
# Uses stub lsof/ps binaries and a fake HOME/state dir so this test NEVER
# touches the real roborev daemon, never pops a real macOS notification,
# and never inspects the real port 7373 or process table (lsof/ps are
# fully stubbed, not just the daemon).
#
# Usage:
#   bash tests/test_roborev_failure_alert_owner.sh

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
    echo "        actual: ${haystack:0:500}"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== roborev-failure-alert check (d): listener-ownership Tests ==="

TMP="$(mktemp -d /tmp/roborev_failure_alert_owner_test_XXXXXX)"
FAKE_HOME="$TMP/home"
OWNER_STATE="$TMP/owner_state"        # not under FAKE_HOME -- exercises ROBOREV_ALERT_OWNER_STATE override
OWNER_CONTROL_FILE="$TMP/owner_control"

# -- Stub lsof: prints a fixed listener PID unless OWNER_CONTROL_FILE says
#    "NONE" (no listener), in which case it prints nothing.
FAKE_LSOF="$TMP/lsof.sh"
cat > "$FAKE_LSOF" <<EOF
#!/usr/bin/env bash
owner="\$(cat "$OWNER_CONTROL_FILE" 2>/dev/null || echo com.roborev.daemon)"
[ "\$owner" = "NONE" ] && exit 0
echo "12345"
EOF
chmod +x "$FAKE_LSOF"

# -- Stub ps: emits a command line carrying XPC_SERVICE_NAME=<owner from
#    control file>, mimicking `ps eww -o command=` for the listener pid.
FAKE_PS="$TMP/ps.sh"
cat > "$FAKE_PS" <<EOF
#!/usr/bin/env bash
owner="\$(cat "$OWNER_CONTROL_FILE" 2>/dev/null || echo com.roborev.daemon)"
echo "/usr/local/bin/roborev daemon run XPC_SERVICE_NAME=\$owner"
EOF
chmod +x "$FAKE_PS"

# -- roborev/osascript stubs, same pattern as test_roborev_failure_alert.sh
#    so the rest of the script (checks a/b/c) runs to completion quietly.
FAKE_ROBOREV="$TMP/roborev.sh"
cat > "$FAKE_ROBOREV" <<'EOF'
#!/usr/bin/env bash
echo "roborev: running"
echo "Jobs:    0 queued, 0 running, 5 completed, 0 failed, 0 skipped"
exit 0
EOF
chmod +x "$FAKE_ROBOREV"

FAKE_OSASCRIPT="$TMP/osascript.sh"
cat > "$FAKE_OSASCRIPT" <<EOF
#!/usr/bin/env bash
echo "osascript invoked: \$*" >> "$TMP/osascript_calls.log"
exit 0
EOF
chmod +x "$FAKE_OSASCRIPT"

setup_home() {
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.config"
  printf 'SIGNAL_ACCOUNT="+15550001111"\n' > "$FAKE_HOME/.config/secrets.env"
  chmod 600 "$FAKE_HOME/.config/secrets.env"
}

read_log() { cat "$FAKE_HOME/.claude/logs/roborev_failure_alert.log" 2>/dev/null || echo ""; }
read_osascript() { cat "$TMP/osascript_calls.log" 2>/dev/null || echo ""; }
osascript_call_count() { grep -c "osascript invoked" "$TMP/osascript_calls.log" 2>/dev/null || echo 0; }

run_script() {
  env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" ROBOREV_BIN="$FAKE_ROBOREV" \
    OSASCRIPT_BIN="$FAKE_OSASCRIPT" LSOF_BIN="$FAKE_LSOF" PS_BIN="$FAKE_PS" \
    ROBOREV_ALERT_OWNER_STATE="$OWNER_STATE" \
    bash "$SCRIPT" >/dev/null 2>&1
}

# ── Scenario 1: owner == com.roborev.daemon -> OK, no note, state=ok.

echo ""
echo "-- Test: owner=com.roborev.daemon -> no alert, no note, state=ok"
setup_home
rm -f "$TMP/osascript_calls.log" "$OWNER_STATE"
echo "com.roborev.daemon" > "$OWNER_CONTROL_FILE"

run_script
log1=$(read_log)
osa1=$(read_osascript)
assert_not_contains "no ALERT logged for listener ownership" "ALERT: port" "$log1"
assert_not_contains "no 'daemon hijacked' note fired" "roborev daemon hijacked" "$osa1"
assert_eq "state file records ok" "ok" "$(cat "$OWNER_STATE" 2>/dev/null)"

# ── Scenario 2: owner == 0 (not launchd's daemon) -> ALERT + note once,
#    then dedup (no second note) on an immediate re-run.

echo ""
echo "-- Test: owner=0 -> ALERT + one note on first run, deduped on second run"
setup_home
rm -f "$TMP/osascript_calls.log" "$OWNER_STATE"
echo "0" > "$OWNER_CONTROL_FILE"

run_script
log2a=$(read_log)
osa2a=$(read_osascript)
assert_contains "ALERT logged naming the pid" "pid=12345" "$log2a"
assert_contains "ALERT logged naming the wrong owner" "XPC_SERVICE_NAME=0, expected com.roborev.daemon" "$log2a"
assert_contains "note fired naming the pid" "pid 12345" "$osa2a"
assert_contains "note gives bootout+kill+bootout+bootstrap remediation (never kickstart)" "launchctl bootout gui/\$(id -u)/com.roborev.daemon; launchctl bootstrap" "$osa2a"
assert_contains "note names auto-refine bootout" "launchctl bootout gui/\$(id -u)/com.roborev.auto-refine" "$osa2a"
assert_contains "note names kill of the rival pid" "kill 12345" "$osa2a"
assert_eq "exactly one note fired on first ALERT" "1" "$(osascript_call_count)"
assert_eq "state file records alert" "alert" "$(cat "$OWNER_STATE" 2>/dev/null)"

run_script
log2b=$(read_log)
assert_contains "second run logs 'still hijacked' (visible, not silent)" "still hijacked: pid=12345" "$log2b"
assert_eq "second run does NOT fire a second note (dedup)" "1" "$(osascript_call_count)"

# ── Scenario 3: recovery (owner back to com.roborev.daemon) then ALERT
#    again -> a fresh note fires on the new transition, not suppressed by
#    the earlier dedup state.

echo ""
echo "-- Test: recovery then re-alert -> note fires again on the new transition"
echo "com.roborev.daemon" > "$OWNER_CONTROL_FILE"
run_script
log3a=$(read_log)
assert_contains "recovery logged" "listener ownership back to launchd" "$log3a"
assert_eq "recovery does not fire a note" "1" "$(osascript_call_count)"
assert_eq "state file back to ok" "ok" "$(cat "$OWNER_STATE" 2>/dev/null)"

echo "0" > "$OWNER_CONTROL_FILE"
run_script
osa3b=$(read_osascript)
assert_eq "re-alert after recovery fires a second note" "2" "$(osascript_call_count)"
assert_eq "state file back to alert" "alert" "$(cat "$OWNER_STATE" 2>/dev/null)"

# ── Scenario 4: lsof missing -> INDETERMINATE, logged distinctly, no note,
#    state file NOT marked ok (check was skipped, not passed).

echo ""
echo "-- Test: lsof missing -> INDETERMINATE logged, no note, state untouched (not marked ok)"
setup_home
rm -f "$TMP/osascript_calls.log" "$OWNER_STATE"
echo "com.roborev.daemon" > "$OWNER_CONTROL_FILE"

env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" ROBOREV_BIN="$FAKE_ROBOREV" \
  OSASCRIPT_BIN="$FAKE_OSASCRIPT" LSOF_BIN="$TMP/no-such-lsof" PS_BIN="$FAKE_PS" \
  ROBOREV_ALERT_OWNER_STATE="$OWNER_STATE" \
  bash "$SCRIPT" >/dev/null 2>&1
log4=$(read_log)
osa4=$(read_osascript)
assert_contains "INDETERMINATE logged distinctly (names the missing binary)" "indeterminate: listener-ownership check skipped -- $TMP/no-such-lsof not found" "$log4"
assert_not_contains "no ALERT logged" "ALERT: port" "$log4"
assert_not_contains "no note fired" "roborev daemon hijacked" "$osa4"
if [ -f "$OWNER_STATE" ]; then
  echo "  FAIL: state file was created despite the check being skipped (indeterminate treated as a verdict)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: state file was NOT created -- indeterminate is never silently treated as ok"
  PASS=$((PASS + 1))
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
