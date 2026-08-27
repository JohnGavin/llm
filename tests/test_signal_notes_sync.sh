#!/usr/bin/env bash
# tests/test_signal_notes_sync.sh — Integration tests for
# .claude/scripts/signal_notes_sync.sh (llm#937/#957).
#
# Uses a fake pgrep/signal-cli and a fake $HOME so the script's real paths
# (~/docs_gh/llm/knowledge/raw/braindumps, ~/.claude/logs/*) are fully
# sandboxed. NEVER invokes real signal-cli and NEVER touches the live
# Signal account.
#
# Usage:
#   bash tests/test_signal_notes_sync.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/signal_notes_sync.sh"

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

echo "=== signal_notes_sync.sh Tests ==="

echo ""
echo "-- Test: bash -n syntax check"
if bash -n "$SCRIPT" 2>/dev/null; then
  echo "  PASS: bash -n"
  PASS=$((PASS + 1))
else
  echo "  FAIL: bash -n"
  FAIL=$((FAIL + 1))
fi

TMP="$(mktemp -d /tmp/signal_notes_sync_test_XXXXXX)"

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

# LSOF_BIN fakes so daemon-up/daemon-down are deterministic regardless of
# whether the real signal-cli daemon happens to be listening on this
# machine (llm#989) — every scenario below is about the direct-receive
# path, which only runs when the daemon is DOWN, so all of them force
# LSOF_BIN to the "down" fake unless the scenario is specifically testing
# the daemon-up skip.
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

FAKE_HOME="$TMP/home"

run_sync() {
  # $1 = PGREP_BIN, $2 = SIGNAL_CLI, $3 = LSOF_BIN (default: daemon DOWN)
  # SIGNAL_ACCOUNT is forced to the fixture value so these scenarios (which
  # predate llm#946's runtime-account-read requirement) exercise their
  # intended behaviour rather than tripping the fail-closed guard. The
  # fail-closed/secrets-sourcing behaviour itself is covered separately below.
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME"
  HOME="$FAKE_HOME" PGREP_BIN="$1" SIGNAL_CLI="$2" LSOF_BIN="${3:-$FAKE_LSOF_DOWN}" \
    SIGNAL_ACCOUNT="+15550001111" \
    bash "$SCRIPT" >/dev/null 2>&1
  echo "$?"
}

read_log() {
  cat "$FAKE_HOME/.claude/logs/signal_sync.log" 2>/dev/null || echo ""
}

# ── Scenario 1: stale signal-cli already running -> refuses, never invokes SIGNAL_CLI

echo ""
echo "-- Test: stale signal-cli running -> refuses to start a second receive"
FAKE_SIGNAL_CLI_SHOULD_NOT_RUN="$TMP/should_not_run.sh"
cat > "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN" <<EOF
#!/usr/bin/env bash
echo "I SHOULD NOT HAVE RUN" >> "$TMP/violation.log"
echo '{}'
EOF
chmod +x "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN"
rm -f "$TMP/violation.log"

run_sync "$FAKE_PGREP_MATCH" "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN" > /dev/null
log1=$(read_log)
assert_contains "refuses with a REFUSED log line" "REFUSED" "$log1"
if [ -f "$TMP/violation.log" ]; then
  echo "  FAIL: signal-cli fake WAS invoked despite the stale-process guard"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: signal-cli fake was NOT invoked (stale-process guard worked)"
  PASS=$((PASS + 1))
fi

# ── Scenario 2: receive fails -> distinguishable RECEIVE FAILED log, nonzero exit

echo ""
echo "-- Test: receive fails -> logs RECEIVE FAILED and exits non-zero"
FAKE_SIGNAL_CLI_FAIL="$TMP/fail_cli.sh"
cat > "$FAKE_SIGNAL_CLI_FAIL" <<'EOF'
#!/usr/bin/env bash
echo "boom: connection refused" >&2
exit 3
EOF
chmod +x "$FAKE_SIGNAL_CLI_FAIL"

rc2=$(run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_FAIL")
log2=$(read_log)
assert_contains "logs RECEIVE FAILED" "RECEIVE FAILED" "$log2"
if [ "$rc2" != "0" ]; then
  echo "  PASS: script exits non-zero on receive failure (rc=$rc2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit non-zero on receive failure, got rc=$rc2"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 3: receive succeeds with no messages -> clean exit, no RECEIVE FAILED

echo ""
echo "-- Test: receive succeeds with no messages -> clean exit, not logged as a failure"
FAKE_SIGNAL_CLI_EMPTY="$TMP/empty_cli.sh"
cat > "$FAKE_SIGNAL_CLI_EMPTY" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_EMPTY"

rc3=$(run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_EMPTY")
log3=$(read_log)
assert_not_contains "does not log RECEIVE FAILED for a clean empty receive" "RECEIVE FAILED" "$log3"
if [ "$rc3" = "0" ]; then
  echo "  PASS: script exits 0 on a clean empty receive (rc=$rc3)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit 0 on a clean empty receive, got rc=$rc3"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 4: receive returns a text message -> ingested into a braindump file

echo ""
echo "-- Test: receive returns a text message -> written to DUMP_DIR"
FAKE_SIGNAL_CLI_MSG="$TMP/msg_cli.sh"
cat > "$FAKE_SIGNAL_CLI_MSG" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+15550001111","message":"hello from notes sync"}}}}
JSON
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_MSG"

run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_MSG" > /dev/null
dump_dir="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved_files=$(find "$dump_dir" -name "*-signal.md" 2>/dev/null)
if [ -n "$saved_files" ] && grep -ql "hello from notes sync" $saved_files 2>/dev/null; then
  echo "  PASS: message content was written to a braindump file"
  PASS=$((PASS + 1))
else
  echo "  FAIL: message content was NOT found in any braindump file"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 5: daemon listening -> direct receive skipped entirely (llm#989)

echo ""
echo "-- Test: daemon listening on 7583 -> direct receive skipped (SKIP, not REFUSED/RECEIVE FAILED), signal-cli never invoked"
FAKE_SIGNAL_CLI_SHOULD_NOT_RUN2="$TMP/should_not_run2.sh"
cat > "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN2" <<EOF
#!/usr/bin/env bash
echo "I SHOULD NOT HAVE RUN (daemon was listening)" >> "$TMP/violation2.log"
echo '{}'
EOF
chmod +x "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN2"
rm -f "$TMP/violation2.log"

rc5=$(run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN2" "$FAKE_LSOF_UP")
log5=$(read_log)
assert_contains "logs a SKIP line naming the daemon" "SKIP: daemon listening on 7583" "$log5"
assert_not_contains "does not log REFUSED for the daemon-up case (that's a different guard)" "REFUSED" "$log5"
assert_not_contains "does not log RECEIVE FAILED — the receive call never happened" "RECEIVE FAILED" "$log5"
if [ -f "$TMP/violation2.log" ]; then
  echo "  FAIL: signal-cli fake WAS invoked despite the daemon-listening skip"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: signal-cli fake was NOT invoked (daemon-listening skip worked)"
  PASS=$((PASS + 1))
fi
if [ "$rc5" = "0" ]; then
  echo "  PASS: script exits 0 on a deliberate daemon-up skip (rc=$rc5)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit 0 on a deliberate skip, got rc=$rc5"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 6: SIGNAL_ACCOUNT unset, no secrets.env present -> fails closed
#    (llm#946: the real account literal was scrubbed from git history after
#    a 4-month public exposure; the script must be structurally unable to
#    run against an unset/placeholder account).

echo ""
echo "-- Test: SIGNAL_ACCOUNT unset and no secrets.env present -> fails closed, never invokes signal-cli"
FAKE_SIGNAL_CLI_SHOULD_NOT_RUN3="$TMP/should_not_run3.sh"
cat > "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN3" <<EOF
#!/usr/bin/env bash
echo "I SHOULD NOT HAVE RUN (SIGNAL_ACCOUNT unset)" >> "$TMP/violation3.log"
echo '{}'
EOF
chmod +x "$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN3"
rm -f "$TMP/violation3.log"

rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME"
env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" PGREP_BIN="$FAKE_PGREP_NONE" \
  SIGNAL_CLI="$FAKE_SIGNAL_CLI_SHOULD_NOT_RUN3" LSOF_BIN="$FAKE_LSOF_DOWN" \
  bash "$SCRIPT" >/dev/null 2>&1
rc6=$?
log6=$(read_log)
assert_contains "logs a FATAL naming the unset account" "FATAL: SIGNAL_ACCOUNT is unset/empty" "$log6"
assert_contains "FATAL log names secrets.env" "secrets.env" "$log6"
assert_contains "FATAL log references llm#946" "llm#946" "$log6"
if [ "$rc6" != "0" ]; then
  echo "  PASS: script exits non-zero when SIGNAL_ACCOUNT is unset and no secrets.env exists (rc=$rc6)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit non-zero, got rc=$rc6"
  FAIL=$((FAIL + 1))
fi
if [ -f "$TMP/violation3.log" ]; then
  echo "  FAIL: signal-cli fake WAS invoked despite SIGNAL_ACCOUNT being unset"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: signal-cli fake was NOT invoked (fail-closed guard worked)"
  PASS=$((PASS + 1))
fi

# ── Scenario 7: SIGNAL_ACCOUNT unset, but a fixture secrets.env supplies it
#    -> the script self-sources it and succeeds (direct-invocation path,
#    i.e. not via the with-secrets wrapper).

echo ""
echo "-- Test: SIGNAL_ACCOUNT unset but a fixture secrets.env supplies it -> sourced and succeeds"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.config"
printf 'SIGNAL_ACCOUNT="+15550001111"\n' > "$FAKE_HOME/.config/secrets.env"
chmod 600 "$FAKE_HOME/.config/secrets.env"

env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" PGREP_BIN="$FAKE_PGREP_NONE" \
  SIGNAL_CLI="$FAKE_SIGNAL_CLI_EMPTY" LSOF_BIN="$FAKE_LSOF_DOWN" \
  bash "$SCRIPT" >/dev/null 2>&1
rc7=$?
log7=$(read_log)
assert_not_contains "does not log a FATAL when secrets.env supplies the account" "FATAL: SIGNAL_ACCOUNT" "$log7"
if [ "$rc7" = "0" ]; then
  echo "  PASS: script exits 0 when SIGNAL_ACCOUNT is sourced from a fixture secrets.env (rc=$rc7)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit 0 when secrets.env supplies the account, got rc=$rc7"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
