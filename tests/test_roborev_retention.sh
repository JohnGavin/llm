#!/usr/bin/env bash
# tests/test_roborev_retention.sh — runs roborev_retention.sh's in-file
# fixture SELFTEST (always a temp dir; never touches the real ~/.roborev) so
# CI exercises the quarantine / search-index-backup expiry policy.
#
# RETENTION_SCRIPT overrides the script under test (used to falsify: point it
# at a copy with the age comparison flipped and this test must go red).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${RETENTION_SCRIPT:-$REPO_ROOT/.claude/scripts/roborev_retention.sh}"

out=$(SELFTEST=1 bash "$SCRIPT" 2>&1)
rc=$?
printf '%s\n' "$out"

# The selftest must have actually run the expiry cases (a selftest that
# silently runs nothing must not pass).
if ! printf '%s\n' "$out" | grep -q 'apply removes old quarantine dir'; then
  echo "FAIL: selftest did not exercise quarantine expiry" >&2
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "FAIL: roborev_retention.sh SELFTEST exited $rc" >&2
  exit 1
fi
echo "OK: roborev_retention selftest passed"
