#!/usr/bin/env bash
# tests/test_signal_attachment_ingest.sh — Tests for
# .claude/scripts/signal_attachment_ingest.sh (llm#1001).
#
# The processor carries its own --selftest, which builds every fixture it needs
# with ghostscript and redirects every path into a temp tree. This file is the
# repo-level entry point for it, plus the checks that belong outside the script:
# syntax, executable bit, and the guarantee that a bare invocation cannot touch
# real state.
#
# NEVER invokes signal-cli, never reads the live account, never writes to the
# real ~/.claude/logs or knowledge/raw/braindumps.
#
# Usage:
#   bash tests/test_signal_attachment_ingest.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/signal_attachment_ingest.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== signal_attachment_ingest.sh Tests ==="

echo ""
echo "-- Test: bash -n syntax check"
if bash -n "$SCRIPT" 2>/dev/null; then
  pass "bash -n"
else
  fail "bash -n"
fi

# The handler invokes this script by path with an -x guard; without the
# executable bit it would take the GAP branch and silently stop ingesting
# attachments — the llm#886 failure mode, applied to the llm#1001 fix.
echo ""
echo "-- Test: executable bit"
if [ -x "$SCRIPT" ]; then
  pass "script is executable (handler's -x guard will find it)"
else
  fail "script is missing the executable bit — the handler would skip it"
fi

echo ""
echo "-- Test: built-in --selftest (fixtures built with ghostscript, all paths sandboxed)"
SELFTEST_OUT=$(bash "$SCRIPT" --selftest 2>&1)
SELFTEST_RC=$?
echo "$SELFTEST_OUT" | sed 's/^/    /'
if [ "$SELFTEST_RC" -eq 0 ]; then
  pass "--selftest exits 0"
else
  fail "--selftest exits $SELFTEST_RC"
fi
case "$SELFTEST_OUT" in
  (*"0 failed"*) pass "--selftest reports 0 failed" ;;
  (*)            fail "--selftest did not report '0 failed'" ;;
esac
# A selftest that skipped everything would also report 0 failed. Require that
# the assertion that matters actually ran.
case "$SELFTEST_OUT" in
  (*"unknown type produced an UNHANDLED log line"*)
    pass "--selftest exercised the unhandled-type assertion (llm#1001's load-bearing case)" ;;
  (*)
    fail "--selftest did not run the unhandled-type assertion" ;;
esac

echo ""
echo "-- Test: bare run against an empty sandbox writes nothing and exits 0"
TMP="$(mktemp -d /tmp/signal_ingest_test_XXXXXX)"
mkdir -p "$TMP/attach" "$TMP/dump" "$TMP/logs"
SIGNAL_ATTACH_DIR="$TMP/attach" \
SIGNAL_DUMP_DIR="$TMP/dump" \
SIGNAL_INGEST_LOG="$TMP/logs/signal_sync.log" \
SIGNAL_ATTACH_PROCESSED_LOG="$TMP/logs/attachment_processed.txt" \
SIGNAL_INGEST_DB="$TMP/nonexistent.duckdb" \
  bash "$SCRIPT" >/dev/null 2>&1
rc_empty=$?
if [ "$rc_empty" -eq 0 ]; then
  pass "empty attachment dir exits 0 (rc=$rc_empty)"
else
  fail "empty attachment dir exited $rc_empty"
fi
if [ -z "$(ls -A "$TMP/dump" 2>/dev/null)" ]; then
  pass "empty attachment dir wrote no notes"
else
  fail "empty attachment dir wrote notes"
fi

# The default cutoff must not be so far back that wiring this in retro-ingests
# months of backlog into an append-only store. Guard the default explicitly:
# an old file gets recorded as skipped, not processed.
echo ""
echo "-- Test: default cutoff leaves a pre-cutoff file unprocessed"
printf 'BEGIN:VCARD\nEND:VCARD\n' > "$TMP/attach/old.vcf"
touch -t 202601010900 "$TMP/attach/old.vcf"
SIGNAL_ATTACH_DIR="$TMP/attach" \
SIGNAL_DUMP_DIR="$TMP/dump" \
SIGNAL_INGEST_LOG="$TMP/logs/signal_sync.log" \
SIGNAL_ATTACH_PROCESSED_LOG="$TMP/logs/attachment_processed.txt" \
SIGNAL_INGEST_DB="$TMP/nonexistent.duckdb" \
  bash "$SCRIPT" >/dev/null 2>&1
if grep -q "skipped-pre-cutoff" "$TMP/logs/attachment_processed.txt" 2>/dev/null; then
  pass "pre-cutoff file recorded as skipped-pre-cutoff under the default cutoff"
else
  fail "pre-cutoff file was not recorded as skipped — the default cutoff may have moved"
fi
if grep -q "SKIPPED pre-cutoff" "$TMP/logs/signal_sync.log" 2>/dev/null; then
  pass "the skip is visible in the log (never a silent drop)"
else
  fail "the skip produced no log line"
fi

rm -rf "$TMP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
