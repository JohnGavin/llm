#!/usr/bin/env bash
# llm#1435: run private_data_history_audit.sh --selftest in CI.
#
# The audit's selftest (hundreds of checks: ledger, heartbeat, all-public
# enumeration against a stub gh, the real scanner on synthetic repos) had no
# ci_test_map.tsv entry, so a regression sat unnoticed. This wrapper runs it
# with a bounded runtime and passes through its verdict:
#   selftest rc 0 -> PASS; rc 3 (INDETERMINATE: no duckdb) -> exit 3, never a
#   silent pass; anything else, or exceeding the bound -> FAIL.
# Needs bash, git, python3, duckdb (shell-tests.yml installs the duckdb CLI
# when this test is selected). Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../.claude/scripts/private_data_history_audit.sh"
BOUND_S="${PDHA_SELFTEST_BOUND_S:-540}"

OUT="$(mktemp "${TMPDIR:-/tmp}/pdha_selftest_ci.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

bash "$SCRIPT" --selftest >"$OUT" 2>&1 &
pid=$!
( sleep "$BOUND_S"; kill "$pid" 2>/dev/null ) &
watchdog=$!

wait "$pid"
rc=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null

summary="$(grep 'selftest: ' "$OUT" | tail -1)"
if [ "$rc" -eq 0 ]; then
    echo "PASS: private_data_history_audit --selftest (${summary})"
    exit 0
fi
grep -v '^PASS' "$OUT" | tail -40
if [ "$rc" -eq 3 ]; then
    echo "INDETERMINATE: selftest could not run (rc=3, e.g. duckdb missing)"
    exit 3
fi
echo "FAIL: private_data_history_audit --selftest rc=${rc} (${summary:-no summary line; killed at the ${BOUND_S}s bound?})"
exit 1
