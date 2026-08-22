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

# Group-restricted capture (llm#1001): the target group is pinned on
# groupId. This is a synthetic test ID — real deployment reads the actual
# ID from ~/.claude/config/signal_notes_group_id.txt via
# `signal-cli listGroups` (see signal_group_filter.py's module docstring).
TARGET_GROUP_ID="grp-target-abc123"

run_sync() {
  # $1 = PGREP_BIN, $2 = SIGNAL_CLI, $3 = LSOF_BIN (default: daemon DOWN)
  # $4 = group id to write into the fake config (default: TARGET_GROUP_ID;
  #      pass "" explicitly to leave the group-id file unconfigured)
  rm -rf "$FAKE_HOME"
  mkdir -p "$FAKE_HOME"
  local group_id="${4-$TARGET_GROUP_ID}"
  if [ -n "$group_id" ]; then
    mkdir -p "$FAKE_HOME/.claude/config"
    printf '%s' "$group_id" > "$FAKE_HOME/.claude/config/signal_notes_group_id.txt"
  fi
  HOME="$FAKE_HOME" PGREP_BIN="$1" SIGNAL_CLI="$2" LSOF_BIN="${3:-$FAKE_LSOF_DOWN}" \
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
echo "-- Test: receive returns a text message in the target group -> written to DUMP_DIR"
FAKE_SIGNAL_CLI_MSG="$TMP/msg_cli.sh"
cat > "$FAKE_SIGNAL_CLI_MSG" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+15550001111","message":"hello from notes sync","groupInfo":{"groupId":"$TARGET_GROUP_ID","groupName":"Notes to llm"}}}}}
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

# ── Scenario 6: message from a DIFFERENT group -> ignored, not captured (llm#1001)

echo ""
echo "-- Test: message from a different group ('pills') -> ignored, not captured, distinct log wording"
FAKE_SIGNAL_CLI_WRONG_GROUP="$TMP/wrong_group_cli.sh"
cat > "$FAKE_SIGNAL_CLI_WRONG_GROUP" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+15550001111","message":"a pills photo caption","groupInfo":{"groupId":"grp-pills-999","groupName":"pills"}}}}}
JSON
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_WRONG_GROUP"

run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_WRONG_GROUP" > /dev/null
log6=$(read_log)
assert_contains "logs an 'ignored:' line" "ignored:" "$log6"
assert_contains "reason names it a wrong group" "wrong group" "$log6"
dump_dir6="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved6=$(find "$dump_dir6" -name "*-signal.md" 2>/dev/null)
if [ -z "$saved6" ]; then
  echo "  PASS: no braindump file was written for the wrong-group message"
  PASS=$((PASS + 1))
else
  echo "  FAIL: a braindump file WAS written for a wrong-group message: $saved6"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 7: direct (non-group) message -> excluded, distinct reason (llm#1001)

echo ""
echo "-- Test: direct self-sent message (no groupInfo) -> excluded, reason names 'direct message'"
FAKE_SIGNAL_CLI_DIRECT="$TMP/direct_cli.sh"
cat > "$FAKE_SIGNAL_CLI_DIRECT" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+15550001111","message":"note to self, no group"}}}}
JSON
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_DIRECT"

run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_DIRECT" > /dev/null
log7=$(read_log)
assert_contains "logs an 'ignored:' line" "ignored:" "$log7"
assert_contains "reason names it a direct message" "direct message" "$log7"
dump_dir7="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved7=$(find "$dump_dir7" -name "*-signal.md" 2>/dev/null)
if [ -z "$saved7" ]; then
  echo "  PASS: no braindump file was written for the direct message"
  PASS=$((PASS + 1))
else
  echo "  FAIL: a braindump file WAS written for a direct message: $saved7"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 8: target group unconfigured -> fails closed, not open (llm#1001)

echo ""
echo "-- Test: group-id file unconfigured -> fails closed (nothing captured, loud reason)"
run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_MSG" "" "" > /dev/null
log8=$(read_log)
assert_contains "logs an 'ignored:' line even for what would be the target group" "ignored:" "$log8"
assert_contains "reason names the missing configuration" "not configured" "$log8"
dump_dir8="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved8=$(find "$dump_dir8" -name "*-signal.md" 2>/dev/null)
if [ -z "$saved8" ]; then
  echo "  PASS: nothing captured while unconfigured (fail-closed, not fail-open)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: a braindump file WAS written while the group id was unconfigured: $saved8"
  FAIL=$((FAIL + 1))
fi

# ── Scenario 9: unhandled attachment content type in the TARGET group -> logged distinctly (llm#1001)

echo ""
echo "-- Test: image/jpeg attachment in the target group -> logged as unhandled (not silently dropped, not 'ignored:')"
FAKE_SIGNAL_CLI_IMAGE="$TMP/image_cli.sh"
cat > "$FAKE_SIGNAL_CLI_IMAGE" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+15550001111","groupInfo":{"groupId":"$TARGET_GROUP_ID","groupName":"Notes to llm"},"attachments":[{"id":"7T7uODp736f0OkX2aEG9","contentType":"image/jpeg","filename":"photo.jpg"}]}}}}
JSON
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_IMAGE"

run_sync "$FAKE_PGREP_NONE" "$FAKE_SIGNAL_CLI_IMAGE" > /dev/null
log9=$(read_log)
assert_contains "logs 'unhandled: no processor for content type' with the actual type" \
  "unhandled: no processor for content type 'image/jpeg'" "$log9"
assert_not_contains "does NOT use the group-exclusion 'ignored:' wording for this case" \
  "ignored: " "$log9"

# ── Scenario 10: audio/aac attachment in the target group -> reaches the
#    audio dispatch branch (not swallowed by the new group/content-type
#    dispatch). Confirms real-world evidence (llm#1001): a real voice
#    message arrived 2026-08-22 10:21:30 in 'Notes to llm' as attachment
#    clag3fLXrK7q2NNe_3U6.aac, contentType audio/aac, and was transcribed
#    successfully — the group filter must not break that path.
#
#    Deliberately does NOT place a physical attachment file on disk and
#    does NOT invoke real (or even fake) whisper: this script always
#    resolves WHISPER_BIN itself (command -v / find /nix/store), with no
#    override hook, so any test that lets it reach the actual
#    transcribe_audio() call risks invoking a REAL whisper binary against
#    garbage bytes — which hung for 120s in an earlier version of this
#    test. Leaving the attachment file absent means the script's own
#    "Audio attachment not found" branch fires and returns before ever
#    calling transcribe_audio() — that is sufficient to prove the message
#    reached the audio-specific code path (not 'unhandled', not
#    'ignored') without any risk of a real subprocess call.

echo ""
echo "-- Test: audio/aac attachment in the target group -> reaches audio dispatch (not unhandled/ignored)"
FAKE_SIGNAL_CLI_AUDIO="$TMP/audio_cli.sh"
cat > "$FAKE_SIGNAL_CLI_AUDIO" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"envelope":{"timestamp":1750000000000,"syncMessage":{"sentMessage":{"destinationNumber":"+15550001111","groupInfo":{"groupId":"$TARGET_GROUP_ID","groupName":"Notes to llm"},"attachments":[{"id":"clag3fLXrK7q2NNe_3U6","contentType":"audio/aac","filename":"voice.aac"}]}}}}
JSON
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_AUDIO"

rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.claude/config"
printf '%s' "$TARGET_GROUP_ID" > "$FAKE_HOME/.claude/config/signal_notes_group_id.txt"
mkdir -p "$FAKE_HOME/.local/share/signal-cli/attachments"
HOME="$FAKE_HOME" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$FAKE_SIGNAL_CLI_AUDIO" LSOF_BIN="$FAKE_LSOF_DOWN" \
  timeout 30 bash "$SCRIPT" >/dev/null 2>&1
log10=$(read_log)
assert_contains "reaches the audio-specific lookup (attachment not found, since none was placed on disk)" \
  "Audio attachment not found: clag3fLXrK7q2NNe_3U6 (audio/aac)" "$log10"
assert_not_contains "does NOT log unhandled for the audio content type" \
  "unhandled: no processor for content type 'audio/aac'" "$log10"
assert_not_contains "does NOT log ignored (it IS the target group)" "ignored:" "$log10"

# ── Scenario 11: PDF attachment in the target group -> extracted end-to-end
#    through the real script (not just the shared module in isolation).

echo ""
echo "-- Test: application/pdf attachment in the target group -> extracted, note written, distinct log"
FIXTURE_PDF="$REPO_ROOT/tests/fixtures/pdf/text_layer_ok.pdf"
FAKE_SIGNAL_CLI_PDF="$TMP/pdf_cli.sh"
cat > "$FAKE_SIGNAL_CLI_PDF" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"envelope":{"timestamp":1755855900000,"syncMessage":{"sentMessage":{"destinationNumber":"+15550001111","groupInfo":{"groupId":"$TARGET_GROUP_ID","groupName":"Notes to llm"},"attachments":[{"id":"synth-pdf-fixture-001","contentType":"application/pdf","filename":"Scanned.pdf"}]}}}}
JSON
exit 0
EOF
chmod +x "$FAKE_SIGNAL_CLI_PDF"

rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME/.claude/config"
printf '%s' "$TARGET_GROUP_ID" > "$FAKE_HOME/.claude/config/signal_notes_group_id.txt"
mkdir -p "$FAKE_HOME/.local/share/signal-cli/attachments"
cp "$FIXTURE_PDF" "$FAKE_HOME/.local/share/signal-cli/attachments/synth-pdf-fixture-001.pdf"
HOME="$FAKE_HOME" PGREP_BIN="$FAKE_PGREP_NONE" SIGNAL_CLI="$FAKE_SIGNAL_CLI_PDF" LSOF_BIN="$FAKE_LSOF_DOWN" \
  bash "$SCRIPT" >/dev/null 2>&1
log11=$(read_log)
assert_contains "logs 'PDF extracted'" "PDF extracted" "$log11"
dump_dir11="$FAKE_HOME/docs_gh/llm/knowledge/raw/braindumps"
saved11=$(find "$dump_dir11" -name "*-pdf-*.md" 2>/dev/null)
if [ -n "$saved11" ] && grep -ql "synthetic test PDF page" $saved11 2>/dev/null; then
  echo "  PASS: PDF note file contains the extracted (synthetic) text"
  PASS=$((PASS + 1))
else
  echo "  FAIL: PDF note file missing or does not contain expected text: $saved11"
  FAIL=$((FAIL + 1))
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
