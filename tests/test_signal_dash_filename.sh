#!/usr/bin/env bash
# tests/test_signal_dash_filename.sh — processed-log check for dash-leading
# Signal attachment names (signal_braindump_handler.sh / signal_notes_sync.sh).
#
# Bug: `grep -qF "$base" "$PROCESSED_LOG" 2>/dev/null && return 0` — a base64url
# attachment ID starting with `-` is parsed by grep as options, grep exits 2,
# `2>/dev/null` hides it, and `&&` treats exit 2 as "not processed", so the
# note was re-transcribed on every run.
#
# Covers:
#   1. dash-leading name present in the log        -> rc 0 (processed)
#   2. dash-leading name absent from the log       -> rc 1 (new)
#   3. grep failing (shim returns 2)               -> rc >=2, NOT "new"
#   4. unreadable log                              -> rc >=2, NOT "new"
#   5. both scripts source the helper and bind its rc to three outcomes
#   6. the original line shape FAILS on the dash name (regression control)
#
# Usage: bash tests/test_signal_dash_filename.sh
# Optional: LIB_OVERRIDE=<path> to point at an alternative lib (used to show
# the test failing against the pre-fix code).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${LIB_OVERRIDE:-$REPO_ROOT/.claude/scripts/lib_signal_process_guard.sh}"
HANDLER="$REPO_ROOT/.claude/scripts/signal_braindump_handler.sh"
SYNC="$REPO_ROOT/.claude/scripts/signal_notes_sync.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

DASH="-ERDD6ss-1admctww_LH.aac"
OTHER="-ZZZZZZ-notinlog_XX.aac"

TMP="$(mktemp -d /tmp/signal_dash_filename_test_XXXXXX)"
trap 'chmod 600 "$TMP/unreadable.txt" 2>/dev/null; rm -rf "$TMP"' EXIT

LOGF="$TMP/processed.txt"
printf '%s\n' "plain.aac" "$DASH" > "$LOGF"

echo "=== signal dash-leading attachment name tests ==="

echo ""
echo "-- Test: bash -n on lib and both scripts"
for f in "$LIB" "$HANDLER" "$SYNC"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

# shellcheck disable=SC1090
. "$LIB"

echo ""
echo "-- Test: dash-leading name present in log -> processed (rc 0)"
_whisper_processed_status "$DASH" "$LOGF" 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "rc=0"; else bad "expected rc 0, got $rc"; fi

echo ""
echo "-- Test: dash-leading name absent from log -> new (rc 1)"
_whisper_processed_status "$OTHER" "$LOGF" 2>/dev/null; rc=$?
if [ "$rc" -eq 1 ]; then ok "rc=1"; else bad "expected rc 1, got $rc"; fi

echo ""
echo "-- Test: grep failure (shim exits 2) is NOT reported as new"
mkdir -p "$TMP/shim"
printf '#!/bin/sh\nexit 2\n' > "$TMP/shim/grep"
chmod +x "$TMP/shim/grep"
( PATH="$TMP/shim:$PATH"; _whisper_processed_status "$OTHER" "$LOGF" 2>/dev/null ); rc=$?
if [ "$rc" -ge 2 ]; then ok "rc=$rc (>=2, indeterminate)"; else bad "expected rc >=2, got $rc"; fi

echo ""
echo "-- Test: unreadable log is NOT reported as new"
cp "$LOGF" "$TMP/unreadable.txt"
chmod 000 "$TMP/unreadable.txt"
if [ -r "$TMP/unreadable.txt" ]; then
  echo "  SKIP: file still readable (running as root?)"
else
  _whisper_processed_status "$OTHER" "$TMP/unreadable.txt" 2>/dev/null; rc=$?
  if [ "$rc" -ge 2 ]; then ok "rc=$rc (>=2, indeterminate)"; else bad "expected rc >=2, got $rc"; fi
fi
chmod 600 "$TMP/unreadable.txt"

echo ""
echo "-- Test: both scripts use the helper, handle rc>=2 explicitly, no bare grep"
for f in "$HANDLER" "$SYNC"; do
  n=$(basename "$f")
  if grep -q '_whisper_processed_status' "$f"; then ok "$n calls helper"; else bad "$n does not call helper"; fi
  if grep -q 'INDETERMINATE' "$f"; then ok "$n logs INDETERMINATE"; else bad "$n lacks INDETERMINATE branch"; fi
  if grep -qE 'grep -qF "\$_?base" "\$PROCESSED_LOG"' "$f"; then bad "$n still has the bare grep"; else ok "$n has no bare grep"; fi
done

echo ""
echo "-- Control: the ORIGINAL line shape mishandles the dash name (proves the bug is real)"
orig_rc=0
grep -qF "$DASH" "$LOGF" 2>/dev/null || orig_rc=$?
if [ "$orig_rc" -ne 0 ]; then
  ok "original form returned rc=$orig_rc for a name that IS in the log"
else
  echo "  SKIP: this grep tolerates dash-leading patterns; bug not reproducible here"
fi

rm -rf "$TMP"
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
