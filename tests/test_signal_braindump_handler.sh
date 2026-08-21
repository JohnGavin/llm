#!/usr/bin/env bash
# tests/test_signal_braindump_handler.sh — Integration tests for
# .claude/scripts/signal_braindump_handler.sh (llm#937/#957).
#
# Uses fake lsof/pgrep/signal-cli binaries (via the LSOF_BIN/PGREP_BIN/
# SIGNAL_CLI overrides) and a fake $HOME so the script's real paths
# (~/docs_gh/llm/knowledge/raw/braindumps, ~/.claude/logs/*) are fully
# sandboxed. NEVER invokes real signal-cli and NEVER touches the live
# Signal account, the live signal-cli daemon, or the real ~/.claude/logs.
#
# Usage:
#   bash tests/test_signal_braindump_handler.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/signal_braindump_handler.sh"

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

echo "=== signal_braindump_handler.sh Tests ==="

echo ""
echo "-- Test: bash -n syntax check"
if bash -n "$SCRIPT" 2>/dev/null; then
  echo "  PASS: bash -n"
  PASS=$((PASS + 1))
else
  echo "  FAIL: bash -n"
  FAIL=$((FAIL + 1))
fi

TMP="$(mktemp -d /tmp/signal_handler_test_XXXXXX)"

# ── Fake binaries ────────────────────────────────────────────────────────

FAKE_LSOF_DOWN="$TMP/lsof_down.sh"
cat > "$FAKE_LSOF_DOWN" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_LSOF_DOWN"

FAKE_LSOF_UP="$TMP/lsof_up.sh"
cat > "$FAKE_LSOF_UP" <<'EOF'
#!/usr/bin/env bash
echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
echo "java 1 me 10u IPv4 0x0 0t0 TCP localhost:7583 (LISTEN)"
exit 0
EOF
chmod +x "$FAKE_LSOF_UP"

FAKE_PGREP_NONE="$TMP/pgrep_none.sh"
cat > "$FAKE_PGREP_NONE" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_PGREP_NONE"

FAKE_PGREP_MATCH="$TMP/pgrep_match.sh"
cat > "$FAKE_PGREP_MATCH" <<'EOF'
#!/usr/bin/env bash
echo "99999"
exit 0
EOF
chmod +x "$FAKE_PGREP_MATCH"

FAKE_HOME="$TMP/home"

run_handler() {
  # $1 = LSOF_BIN, $2 = PGREP_BIN, $3 = SIGNAL_CLI
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME"
  HOME="$FAKE_HOME" LSOF_BIN="$1" PGREP_BIN="$2" SIGNAL_CLI="$3" \
    bash "$SCRIPT" >/dev/null 2>&1
  echo "$?"
}

read_log() {
  cat "$FAKE_HOME/.claude/logs/signal_sync.log" 2>/dev/null || echo ""
}

# ── Scenario 1: stale signal-cli already running -> refuses, never invokes SIGNAL_CLI

echo ""
echo "-- Test: daemon down + stale signal-cli running -> refuses to start a second receive"
FAKE_SIGNAL_CLI_SHOULD_NOT_RUN="$TMP/should_not_run.sh"
cat > "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN" <<EOF
#!/usr/bin/env bash
echo "I SHOULD NOT HAVE RUN" >> "$TMP/violation.log"
echo '{}'
EOF
chmod +x "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN"
rm -f "$TMP/violation.log"

run_handler "$FAKE_LSOF_DOWN" "$FAKE_PGREP_MATCH" "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN" > /dev/null
log1=$(read_log)
assert_contains "refuses with a REFUSED log line" "REFUSED" "$log1"
if [ -f "$TMP/violation.log" ]; then
  echo "  FAIL: signal-cli fake WAS invoked despite the stale-process guard"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: signal-cli fake was NOT invoked (stale-process guard worked)"
  PASS=$((PASS + 1))
fi

# ── Scenario 2: receive fails -> distinguishable RECEIVE FAILED log

echo ""
echo "-- Test: daemon down + receive fails -> logs RECEIVE FAILED, not silently treated as 'no messages'"
FAKE_SIGNAL_CLI_FAIL="$TMP/fail_cli.sh"
cat > "$FAKE_SIGNAL_CLI_FAIL" <<'EOF'
#!/usr/bin/env bash
echo "boom: connection refused" >&2
exit 3
EOF
chmod +x "$FAKE_SIGNAL_CLI_FAIL"

run_handler "$FAKE_LSOF_DOWN" "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_FAIL" > /dev/null
log2=$(read_log)
assert_contains "logs RECEIVE FAILED" "RECEIVE FAILED" "$log2"
assert_not_contains "does not also log the generic 'no new messages' line for this run" \
  "Direct receive: no new messages" "$log2"

# ── Scenario 3: receive succeeds with no messages -> distinguishable from a failure

echo ""
echo "-- Test: daemon down + receive succeeds with no messages -> distinguishable from a failure"
FAKE_SIGNAL_CLI_EMPTY="$TMP/empty_cli.sh"
cat > "$FAKE_SIGNAL_CLI_EMPTY" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_EMPTY"

run_handler "$FAKE_LSOF_DOWN" "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_EMPTY" > /dev/null
log3=$(read_log)
assert_contains "logs 'no new messages'" "Direct receive: no new messages" "$log3"
assert_not_contains "does not log RECEIVE FAILED for a clean empty receive" "RECEIVE FAILED" "$log3"

# ── Scenario 4: receive returns a text message -> actually ingested (llm#957 silent-drop fix)

echo ""
echo "-- Test: daemon down + receive returns a text message -> written to DUMP_DIR, not silently dropped"
FAKE_SIGNAL_CLI_MSG="$TMP/msg_cli.sh"
cat > "$FAKE_SIGNAL_CLI_MSG" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+447521254904","message":"hello from fallback path"}}}}
JSON
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_MSG"

run_handler "$FAKE_LSOF_DOWN" "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_MSG" > /dev/null
dump_dir="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved_files=$(find "$dump_dir" -name "*-signal.md" 2>/dev/null)
if [ -n "$saved_files" ] && grep -ql "hello from fallback path" $saved_files 2>/dev/null; then
  echo "  PASS: message content was written to a braindump file (silent-drop fixed)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: message content was NOT found in any braindump file — still silently dropped"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 5: daemon UP, no daemon stdout log present -> loud GAP warning, not silence

echo ""
echo "-- Test: daemon up + no daemon stdout log -> explicit else-branch log + loud GAP warning"
run_handler "$FAKE_LSOF_UP" "$FAKE_PGREP_NONE" "$TMP/unused_cli.sh" > /dev/null
log5=$(read_log)
assert_contains "logs an explicit else-branch daemon-up line (llm#957 missing-else fix)" \
  "Daemon listening on 7583" "$log5"
assert_contains "logs a loud GAP warning instead of a silent no-op" "GAP:" "$log5"

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
