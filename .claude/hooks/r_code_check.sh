#!/usr/bin/env bash
# R Code Quality Check Hook
# Usage: bash .claude/hooks/r_code_check.sh [directory]
# Checks for anti-patterns in R code:
#   1. suppressWarnings(as.*) — silent type coercion
#   2. read.csv() without na.strings — missing NA handling

set -euo pipefail

DIR="${1:-.}"
EXIT_CODE=0

# --- Check 1: suppressWarnings(as.*) pattern ---
echo "=== Checking for suppressWarnings(as.*) anti-pattern ==="

# Exclude: dev/issues/ scripts, comments (grep output has file:line: prefix)
SUPPRESS_HITS=$(grep -rn 'suppressWarnings(as\.' "$DIR" --include='*.R' 2>/dev/null \
  | grep -v 'lubridate::' \
  | grep -v 'dev/issues/' \
  | grep -v ':#' \
  | grep -v 'pattern = ' \
  | grep -v 'cat(' \
  || true)

if [ -n "$SUPPRESS_HITS" ]; then
  echo "FAIL: Found suppressWarnings(as.*) anti-pattern:"
  echo "$SUPPRESS_HITS"
  echo ""
  echo "Use readr col_types or explicit validation instead."
  echo "See: missing-data-handling skill"
  EXIT_CODE=1
else
  echo "OK"
fi

echo ""

# --- Check 2: read.csv() without na.strings ---
echo "=== Checking for read.csv() without na.strings ==="

BARE_CSV=$(grep -rn 'read\.csv(' "$DIR" --include='*.R' 2>/dev/null \
  | grep -v 'na.strings' \
  | grep -v 'na =' \
  | grep -v 'dev/issues/' \
  | grep -v ':#' \
  | grep -v 'cat(' \
  || true)

if [ -n "$BARE_CSV" ]; then
  echo "WARN: Found read.csv() without na.strings:"
  echo "$BARE_CSV"
  echo ""
  echo "Consider using readr::read_csv() with explicit na parameter."
else
  echo "OK"
fi

echo ""
echo "=== R Code Quality Check Complete ==="
exit $EXIT_CODE
