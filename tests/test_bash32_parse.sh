#!/usr/bin/env bash
# test_bash32_parse.sh -- JohnGavin/llm#1440
#
# macOS ships /bin/bash 3.2, which parses some constructs bash 5 accepts
# (a heredoc inside $(...), an unparenthesised `case` pattern inside $(...)).
# A hook that does not parse is not "fails open": bash exits 2 for a syntax
# error, and exit 2 is the BLOCK code for PreToolUse hooks.
#
# This test runs `/bin/bash -n` over every hook and script and fails on any
# parse error. Scripts whose shebang is not bash (python, Rscript, zsh, sh)
# are skipped. Override the interpreter with BASH32=/path for testing.
#
# Usage: bash tests/test_bash32_parse.sh [ROOT]
# Exit:  0 all parse, 1 any parse failure, 3 INDETERMINATE (no bash 3.2 found,
#        or no files matched -- a check that cannot run is not a pass).

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASH32="${BASH32:-/bin/bash}"

if [ ! -x "$BASH32" ]; then
  echo "INDETERMINATE: $BASH32 not found" >&2
  exit 3
fi

# Only meaningful when the interpreter really is a 3.x bash; otherwise the
# check cannot catch the bug it exists for. On non-macOS hosts /bin/bash is
# usually 5.x: still run it (catches plain syntax errors) but say so.
ver=$("$BASH32" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')
echo "interpreter: $BASH32 (bash $ver)"
case "$ver" in
  3.*) : ;;
  *) echo "NOTE: not bash 3.x; 3.2-only constructs will not be caught on this host" ;;
esac

checked=0
failed=0
for f in "$ROOT"/.claude/hooks/*.sh "$ROOT"/.claude/scripts/*.sh; do
  [ -f "$f" ] || continue
  first=$(head -n 1 "$f")
  case "$first" in
    *bash*) : ;;
    *) continue ;;
  esac
  checked=$((checked + 1))
  if ! err=$("$BASH32" -n "$f" 2>&1); then
    failed=$((failed + 1))
    echo "FAIL: ${f#"$ROOT"/}: $err"
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "INDETERMINATE: no bash scripts found under $ROOT" >&2
  exit 3
fi

echo "checked=$checked failed=$failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
echo "PASS: all $checked scripts parse under $BASH32"
exit 0
