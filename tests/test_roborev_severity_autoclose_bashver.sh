#!/usr/bin/env bash
# test_roborev_severity_autoclose_bashver.sh -- JohnGavin/llm#1445
#
# roborev_severity_autoclose.sh uses `declare -A` (bash >= 4). Under macOS
# /bin/bash 3.2 it must print a clear message and exit 3 (INDETERMINATE)
# instead of dying with rc=2 from `declare`.
#
# Usage: bash tests/test_roborev_severity_autoclose_bashver.sh [SCRIPT]
# Exit:  0 all asserted pass, 1 any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/.claude/scripts/roborev_severity_autoclose.sh}"
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# (a) old bash: message + exit 3
OLD=/bin/bash
oldver=""
[ -x "$OLD" ] && oldver=$("$OLD" -c 'echo "${BASH_VERSINFO[0]}"')
if [ "$oldver" = "3" ]; then
  out=$("$OLD" "$SCRIPT" --help 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 3 ]; then ok "(a1) bash 3.x exits 3"; else bad "(a1) bash 3.x exit=$rc, want 3"; fi
  case "$out" in
    *"needs bash >= 4"*"3.2"*) ok "(a2) message names required and running bash version" ;;
    *) bad "(a2) message missing/incomplete: $out" ;;
  esac
else
  echo "SKIP: (a) $OLD is bash '${oldver:-absent}', not 3.x; old-bash assertions not run"
fi

# (b) modern bash: guard does not trigger, --help behaves as before
NEW=$(command -v bash)
newver=$("$NEW" -c 'echo "${BASH_VERSINFO[0]}"')
if [ "$newver" -ge 4 ]; then
  out=$("$NEW" "$SCRIPT" --help 2>&1)
  rc=$?
  case "$out" in
    *"needs bash >= 4"*) bad "(b1) guard fired under bash $newver" ;;
    *) ok "(b1) guard silent under bash $newver" ;;
  esac
  if [ "$rc" -ne 3 ]; then ok "(b2) --help rc=$rc (not 3)"; else bad "(b2) --help rc=3 under bash $newver"; fi
else
  echo "SKIP: (b) $NEW is bash $newver (< 4); modern-bash assertions not run"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
