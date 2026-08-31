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
  # SIGNAL_ACCOUNT is forced to the fixture value so these scenarios (which
  # predate llm#946's runtime-account-read requirement) exercise their
  # intended behaviour rather than tripping the fail-closed guard. The
  # fail-closed/secrets-sourcing behaviour itself is covered separately below.
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME"
  HOME="$FAKE_HOME" LSOF_BIN="$1" PGREP_BIN="$2" SIGNAL_CLI="$3" \
    SIGNAL_ACCOUNT="+12025550111" \
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
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+12025550111","message":"hello from fallback path"}}}}
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
  printf '%s\n' '{"exception":{"message":"getServerGuid(...) must not be null","type":"NullPointerException"},"envelope":{"source":null,"sourceNumber":null,"sourceUuid":null,"sourceName":null,"sourceDevice":null,"timestamp":1787335255053,"serverReceivedTimestamp":1787335253948,"serverDeliveredTimestamp":1787335253996},"account":"+12025550111"}'
  printf '%s\n' '{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+12025550111","message":"hello from daemon tail"}}}}'
} > "$FIXTURE_LOG"

HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  SIGNAL_ACCOUNT="+12025550111" \
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
printf '%s\n' '{"envelope":{"timestamp":1750000100000,"syncMessage":{"sentMessage":{"destinationNumber":"+12025550111","message":"post-truncation message"}}}}' > "$FIXTURE_LOG"
echo 999999 > "$pos_file"   # bogus large offset simulating a pre-truncation position

HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  SIGNAL_ACCOUNT="+12025550111" \
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
printf '%s\n' '{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+12025550111","message":"hello from custom plist path"}}}}' > "$FIXTURE_CUSTOM_LOG"

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
  SIGNAL_ACCOUNT="+12025550111" \
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

# ── Scenario 9: SIGNAL_ACCOUNT unset, no secrets.env present -> fails closed
#    (llm#946: the real account literal was scrubbed from git history after
#    a 4-month public exposure; the script must be structurally unable to
#    run against an unset/placeholder account).

echo ""
echo "-- Test: SIGNAL_ACCOUNT unset and no secrets.env present -> fails closed before any receive attempt"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME"
env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_DOWN" PGREP_BIN="$FAKE_PGREP_NONE" \
  SIGNAL_CLI="$TMP/unused_cli.sh" \
  bash "$SCRIPT" >/dev/null 2>&1
rc9=$?
log9=$(read_log)
assert_contains "logs a FATAL naming the unset account" "FATAL: SIGNAL_ACCOUNT is unset/empty" "$log9"
assert_contains "FATAL log names secrets.env" "secrets.env" "$log9"
assert_contains "FATAL log references llm#946" "llm#946" "$log9"
if [ "$rc9" != "0" ]; then
  echo "  PASS: script exits non-zero when SIGNAL_ACCOUNT is unset and no secrets.env exists (rc=$rc9)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit non-zero, got rc=$rc9"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 10: SIGNAL_ACCOUNT unset, but a fixture secrets.env supplies it
#    -> the script self-sources it and succeeds (direct-invocation path).

echo ""
echo "-- Test: SIGNAL_ACCOUNT unset but a fixture secrets.env supplies it -> sourced and succeeds"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.config"
printf 'SIGNAL_ACCOUNT="+12025550111"\n' > "$FAKE_HOME/.config/secrets.env"
chmod 600 "$FAKE_HOME/.config/secrets.env"

FAKE_SIGNAL_CLI_EMPTY_AFTER_SECRETS="$TMP/empty_after_secrets.sh"
cat > "$FAKE_SIGNAL_CLI_EMPTY_AFTER_SECRETS" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_EMPTY_AFTER_SECRETS"

env -u SIGNAL_ACCOUNT HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_DOWN" PGREP_BIN="$FAKE_PGREP_NONE" \
  SIGNAL_CLI="$FAKE_SIGNAL_CLI_EMPTY_AFTER_SECRETS" \
  bash "$SCRIPT" >/dev/null 2>&1
rc10=$?
log10=$(read_log)
assert_not_contains "does not log a FATAL when secrets.env supplies the account" "FATAL: SIGNAL_ACCOUNT" "$log10"
if [ "$rc10" = "0" ]; then
  echo "  PASS: script exits 0 when SIGNAL_ACCOUNT is sourced from a fixture secrets.env (rc=$rc10)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script should exit 0 when secrets.env supplies the account, got rc=$rc10"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 11: a message with attachments and NO text body -> accounted for
#    in the log, with its content type and group (llm#1001).
#
#    This is the regression that made a ten-week outage invisible: such a
#    message hit no branch, produced no log line, and left no trace that
#    anything had arrived. The group name is only present in the envelope —
#    the on-disk attachment scan cannot recover it — so the assertion below
#    checks that it survives into the log.

echo ""
echo "-- Test: attachment-only message (no text body) -> logged with content type and group, not silently dropped"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.claude/logs"
ATT_ONLY_LOG="$FAKE_HOME/.claude/logs/signal_cli_daemon_stdout.log"
# Both fixture messages are in the target group ("Notes to llm") deliberately
# — this scenario tests the llm#1001 accounting (attachment-only / fully-empty
# messages are logged, not silently dropped), not the llm#1113 group filter.
# The filter itself is covered separately below (Scenario 14).
{
  printf '%s\n' '{"envelope":{"timestamp":1755855939000,"syncMessage":{"sentMessage":{"message":null,"attachments":[{"contentType":"application/pdf","id":"FIXTUREattachment01","filename":"Scanned_20260822-0945.pdf"}],"groupInfo":{"groupId":"Z3JwMQ==","groupName":"Notes to llm"}}}}}'
  printf '%s\n' '{"envelope":{"timestamp":1755856050000,"syncMessage":{"sentMessage":{"message":null,"attachments":[],"groupInfo":{"groupName":"Notes to llm"}}}}}'
} > "$ATT_ONLY_LOG"

HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  SIGNAL_ACCOUNT="+12025550111" \
  bash "$SCRIPT" >/dev/null 2>&1
log11=$(read_log)

assert_contains "attachment-only message produces a log line at all (llm#1001)" \
  "ATTACHMENT-ONLY message" "$log11"
assert_contains "log line names the attachment's content type" "application/pdf" "$log11"
assert_contains "log line names the attachment's filename" "Scanned_20260822-0945.pdf" "$log11"
assert_contains "log line names the group the message arrived in" "Notes to llm" "$log11"
assert_contains "a message with neither body nor attachments is also accounted for" \
  "EMPTY message" "$log11"

dump_dir11="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
if find "$dump_dir11" -name "*-signal.md" 2>/dev/null | grep -q .; then
  echo "  FAIL: attachment-only message was written as if it were a text braindump"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: attachment-only message did not produce a bogus empty text braindump"
  PASS=$((PASS + 1))
fi

# ── Scenario 12: the handler actually invokes signal_attachment_ingest.sh, and
#    a PDF sitting in the attachments directory comes out the other side as a
#    braindump note. Proves the wiring, not just the processor in isolation.

echo ""
echo "-- Test: a PDF in the attachments directory is ingested via signal_attachment_ingest.sh"
GS_FOR_FIXTURE=$(command -v gs 2>/dev/null || echo /opt/homebrew/bin/gs)
if [ ! -x "$GS_FOR_FIXTURE" ]; then
  echo "  SKIP: ghostscript not available — cannot build a PDF fixture"
else
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME/.claude/logs" "$FAKE_HOME/.local/share/signal-cli/attachments"
  printf '%%!PS\n/Helvetica findfont 24 scalefont setfont\n72 700 moveto (WIRING FIXTURE EMBEDDED TEXT LAYER) show\n72 660 moveto (SECOND LINE TO CLEAR THE MIN CHARS THRESHOLD) show\nshowpage\n' > "$TMP/wiring.ps"
  "$GS_FOR_FIXTURE" -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite \
    -o "$FAKE_HOME/.local/share/signal-cli/attachments/statement.pdf" "$TMP/wiring.ps" >/dev/null 2>&1

  # Pin the cutoff rather than relying on the fixture being newer than the
  # ingest script's default — otherwise this test would start failing on a
  # machine whose clock disagrees, for reasons unrelated to the wiring.
  HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
    SIGNAL_ACCOUNT="+12025550111" SIGNAL_INGEST_SINCE="2000-01-01" \
    bash "$SCRIPT" >/dev/null 2>&1
  log12=$(read_log)

  assert_not_contains "no GAP warning — the ingest script was found and run" \
    "signal_attachment_ingest.sh not found" "$log12"
  assert_contains "PDF text-layer extraction was logged" "PDF text-layer: statement.pdf" "$log12"

  dump_dir12="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
  pdf_note=$(find "$dump_dir12" -name "*-pdf-statement.md" 2>/dev/null)
  if [ -n "$pdf_note" ] && grep -ql "WIRING FIXTURE EMBEDDED TEXT LAYER" $pdf_note 2>/dev/null; then
    echo "  PASS: PDF content reached a braindump note end-to-end"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: PDF content did NOT reach a braindump note (wiring broken)"
    FAIL=$((FAIL + 1))
  fi
fi

# ── Scenario 13: if signal_attachment_ingest.sh is absent, the handler says so
#    loudly. Without this the GAP branch is untested and could rot into the
#    same silent no-op it exists to prevent.

echo ""
echo "-- Test: signal_attachment_ingest.sh missing -> loud GAP line, handler still exits 0"
ISOLATED="$TMP/isolated_scripts"
mkdir -p "$ISOLATED"
cp "$SCRIPT" "$ISOLATED/"
cp "$REPO_ROOT/.claude/scripts/lib_signal_process_guard.sh" "$ISOLATED/"
# deliberately NOT copying signal_attachment_ingest.sh
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.claude/logs"
HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  SIGNAL_ACCOUNT="+12025550111" \
  bash "$ISOLATED/signal_braindump_handler.sh" >/dev/null 2>&1
rc13=$?
log13=$(read_log)
assert_contains "missing ingest script produces a GAP line naming llm#1001" \
  "PDF/image attachments are NOT being ingested" "$log13"
if [ "$rc13" = "0" ]; then
  echo "  PASS: handler still exits 0 — a missing processor does not break audio transcription (rc=$rc13)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: handler exited $rc13 when the ingest script was missing"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 14: group filtering (llm#1113) — only "Notes to llm" messages
#    are captured; other groups are skipped and logged (never silently
#    dropped); the match is case-insensitive; direct/'Note to Self' messages
#    (no groupInfo at all) are unaffected by the filter.

echo ""
echo "-- Test: group filter (llm#1113) -- target group captured, off-channel group skipped+logged, case-insensitive match, direct messages unaffected"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.claude/logs"
GROUP_FILTER_LOG="$FAKE_HOME/.claude/logs/signal_cli_daemon_stdout.log"
{
  printf '%s\n' '{"envelope":{"timestamp":1755900000000,"syncMessage":{"sentMessage":{"message":"message from target group","groupInfo":{"groupId":"Z3JwMQ==","groupName":"Notes to llm"}}}}}'
  printf '%s\n' '{"envelope":{"timestamp":1755900100000,"syncMessage":{"sentMessage":{"message":"message from off-channel group","groupInfo":{"groupId":"ZmFtaWx5","groupName":"family chat"}}}}}'
  printf '%s\n' '{"envelope":{"timestamp":1755900200000,"syncMessage":{"sentMessage":{"message":"message from lowercase target group","groupInfo":{"groupId":"Z3JwMQ==","groupName":"notes to llm"}}}}}'
  printf '%s\n' '{"envelope":{"timestamp":1755900300000,"syncMessage":{"sentMessage":{"message":"message from direct chat unaffected by filter"}}}}'
} > "$GROUP_FILTER_LOG"

HOME="$FAKE_HOME" LSOF_BIN="$FAKE_LSOF_UP" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$TMP/unused_cli.sh" \
  SIGNAL_ACCOUNT="+12025550111" \
  bash "$SCRIPT" >/dev/null 2>&1
log14=$(read_log)
dump_dir14="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved14=$(find "$dump_dir14" -name "*-signal.md" 2>/dev/null)
saved14_content=$(cat $saved14 2>/dev/null)

if [ -n "$saved14" ] && [[ "$saved14_content" == *"message from target group"* ]]; then
  echo "  PASS: message from the target group ('Notes to llm') was captured"
  PASS=$((PASS + 1))
else
  echo "  FAIL: message from the target group was NOT captured"
  FAIL=$((FAIL + 1))
fi

if [[ "$saved14_content" != *"message from off-channel group"* ]]; then
  echo "  PASS: message from an off-channel group ('family chat') was NOT captured"
  PASS=$((PASS + 1))
else
  echo "  FAIL: message from an off-channel group was captured — filter did not apply"
  FAIL=$((FAIL + 1))
fi

assert_contains "off-channel message is logged as skipped, not silently dropped" \
  "SKIPPED (off-channel group)" "$log14"
assert_contains "skip log line names the actual (rejected) group" \
  "family chat" "$log14"
assert_contains "skip log line names the target group it was compared against" \
  "Notes to llm" "$log14"

if [[ "$saved14_content" == *"message from lowercase target group"* ]]; then
  echo "  PASS: group-name match is case-insensitive ('notes to llm' matched 'Notes to llm')"
  PASS=$((PASS + 1))
else
  echo "  FAIL: lowercase group name 'notes to llm' was NOT matched case-insensitively"
  FAIL=$((FAIL + 1))
fi

if [[ "$saved14_content" == *"message from direct chat unaffected by filter"* ]]; then
  echo "  PASS: a direct message (no groupInfo) is unaffected by the group filter"
  PASS=$((PASS + 1))
else
  echo "  FAIL: a direct message (no groupInfo) was incorrectly filtered out"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
