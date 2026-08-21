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

# ── Scenario 6: daemon up + real stdout log at the plist-resolved fallback
#    location (~/.claude/logs/signal_cli_daemon_stdout.log, no explicit
#    SIGNAL_DAEMON_PLIST) -> message ingested, exception logged distinctly
#    and NOT parsed as a message, byte offset advances to end of file
#    (llm#989: the historical bug was that this path resolved to
#    /tmp/signal_cli_daemon_stdout.log and so NEVER found this file).

echo ""
echo "-- Test: daemon up + stdout log at the real fallback path, containing an exception envelope AND a message -> message ingested, exception logged distinctly, no GAP"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.claude/logs"
FIXTURE_LOG="$FAKE_HOME/.claude/logs/signal_cli_daemon_stdout.log"
{
  printf '%s\n' '{"exception":{"message":"getServerGuid(...) must not be null","type":"NullPointerException"},"envelope":{"source":null,"sourceNumber":null,"sourceUuid":null,"sourceName":null,"sourceDevice":null,"timestamp":1787335255053,"serverReceivedTimestamp":1787335253948,"serverDeliveredTimestamp":1787335253996},"account":"+447521254904"}'
  printf '%s\n' '{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+447521254904","message":"hello from daemon tail"}}}}'
} > "$FIXTURE_LOG"

HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  bash "$SCRIPT" >/dev/null 2>&1
log6=$(read_log)

assert_contains "logs an explicit else-branch daemon-up line" "Daemon listening on 7583" "$log6"
assert_not_contains "does not log a GAP now that the real stdout log path resolves" "GAP:" "$log6"
assert_contains "logs the exception envelope distinctly (EXCEPTION marker)" "EXCEPTION" "$log6"
assert_contains "exception log line names the actual NPE type/message" "NullPointerException" "$log6"

dump_dir6="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved6=$(find "$dump_dir6" -name "*-signal.md" 2>/dev/null)
if [ -n "$saved6" ] && grep -ql "hello from daemon tail" $saved6 2>/dev/null; then
  echo "  PASS: normal message content ingested from daemon stdout tail (path-resolution fix works)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: normal message content NOT ingested from daemon stdout tail"
  FAIL=$((FAIL + 1))
fi
if [ -n "$saved6" ] && grep -ql "getServerGuid" $saved6 2>/dev/null; then
  echo "  FAIL: exception envelope was written to a braindump file as if it were a message"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: exception envelope was NOT written to a braindump file"
  PASS=$((PASS + 1))
fi

pos_file="$FAKE_HOME/.claude/logs/.signal_daemon_pos"
expected_size=$(wc -c < "$FIXTURE_LOG" | tr -d ' ')
actual_pos=$(cat "$pos_file" 2>/dev/null || echo "MISSING")
if [ "$actual_pos" = "$expected_size" ]; then
  echo "  PASS: byte offset advanced to end of fixture log ($actual_pos)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: byte offset mismatch (expected $expected_size, got $actual_pos)"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 7: log truncated since last run -> offset resets to 0 instead
#    of reading garbage or silently skipping the new content (llm#989).

echo ""
echo "-- Test: daemon stdout log truncated since last run -> offset resets to 0, new content still ingested"
printf '%s\n' '{"envelope":{"timestamp":1750000100000,"syncMessage":{"sentMessage":{"destinationNumber":"+447521254904","message":"post-truncation message"}}}}' > "$FIXTURE_LOG"
echo 999999 > "$pos_file"   # bogus large offset simulating a pre-truncation position

HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  bash "$SCRIPT" >/dev/null 2>&1
log7=$(read_log)
assert_contains "logs a truncation-detected line" "truncated" "$log7"

saved7=$(find "$dump_dir6" -name "*-signal.md" 2>/dev/null)
if [ -n "$saved7" ] && grep -ql "post-truncation message" $saved7 2>/dev/null; then
  echo "  PASS: message after truncation was re-read from offset 0, not skipped"
  PASS=$((PASS + 1))
else
  echo "  FAIL: message after truncation was NOT read — offset did not reset"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 8: SIGNAL_DAEMON_PLIST override with a custom StandardOutPath
#    -> resolution actually reads the plist (not just the hardcoded
#    fallback guess). This is the mutation-test target for the path
#    resolution fix: reverting to a hardcoded path makes this fail.

echo ""
echo "-- Test: SIGNAL_DAEMON_PLIST points at a fixture plist with a custom StandardOutPath -> that path is used, not the default fallback"
FIXTURE_CUSTOM_LOG="$FAKE_HOME/.claude/logs/custom_daemon_stdout.log"
printf '%s\n' '{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+447521254904","message":"hello from custom plist path"}}}}' > "$FIXTURE_CUSTOM_LOG"

FIXTURE_PLIST="$TMP/fixture_daemon.plist"
cat > "$FIXTURE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>StandardOutPath</key>
	<string>$FIXTURE_CUSTOM_LOG</string>
</dict>
</plist>
PLIST

# Remove the default-fallback file so a pass here can ONLY be explained by
# the plist actually being read (if resolution silently fell back, the
# fallback file wouldn't exist and this would hit the GAP branch instead).
rm -f "$FIXTURE_LOG"
rm -f "$pos_file"

# read_log() returns the FULL cumulative log across every scenario sharing
# $FAKE_HOME (deliberately not reset between scenarios 6-8, to model the
# daemon staying up across runs) — scenario 6 legitimately logged a
# FALLBACK: line, so asserting its absence against the cumulative log would
# be checking the wrong thing. Scope this scenario's assertions to only the
# lines appended by THIS run.
log_lines_before8=$(wc -l < "$FAKE_HOME/.claude/logs/signal_sync.log" 2>/dev/null | tr -d ' ')
log_lines_before8="${log_lines_before8:-0}"

HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  SIGNAL_DAEMON_PLIST="$FIXTURE_PLIST" bash "$SCRIPT" >/dev/null 2>&1
log8=$(tail -n "+$((log_lines_before8 + 1))" "$FAKE_HOME/.claude/logs/signal_sync.log" 2>/dev/null)
assert_not_contains "no GAP when plist resolves to a real file" "GAP:" "$log8"
assert_not_contains "no FALLBACK line when plist resolution succeeds" "FALLBACK:" "$log8"

saved8=$(find "$dump_dir6" -name "*-signal.md" 2>/dev/null)
if [ -n "$saved8" ] && grep -ql "hello from custom plist path" $saved8 2>/dev/null; then
  echo "  PASS: message ingested from the plist-resolved custom path (not the default fallback)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: message NOT ingested — plist resolution did not pick up the custom StandardOutPath"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
