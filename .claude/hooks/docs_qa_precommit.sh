#!/usr/bin/env bash
# docs_qa_precommit.sh - Block git commit/add of docs/ HTML with error patterns
# Hook: PreToolUse:Bash — inspects command for git add/commit touching docs/
# Exit 2 = BLOCK. Exit 0 = allow.

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | sed -n 's/.*"command":[[:space:]]*"\(.*\)".*/\1/p' | head -1)
[ -z "$CMD" ] && exit 0

# Only trigger on git add or git commit touching docs/
if ! echo "$CMD" | grep -qE 'git (add|commit).*docs/|git -C .* (add|commit).*docs/'; then
  exit 0
fi

# Find the repo root from the command (git -C path or cwd)
REPO_DIR=$(echo "$CMD" | sed -n 's/.*git -C \([^ ]*\).*/\1/p' | head -1)
[ -z "$REPO_DIR" ] && REPO_DIR="."
DOCS_DIR="${REPO_DIR}/docs/articles"
[ ! -d "$DOCS_DIR" ] && exit 0

# Check all HTML files in docs/articles/ for error patterns
ERROR_PATTERNS=("not available" "not found in targets" "MISSING EVIDENCE")
TOTAL=0
DETAILS=""
for html in "$DOCS_DIR"/*.html; do
  [ ! -f "$html" ] && continue
  BASENAME=$(basename "$html")
  for ep in "${ERROR_PATTERNS[@]}"; do
    COUNT=$(grep -ci "$ep" "$html" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ]; then
      DETAILS="${DETAILS}\n  ${BASENAME}: ${COUNT} hits for '${ep}'"
      TOTAL=$((TOTAL + COUNT))
    fi
  done
done

if [ "$TOTAL" -gt 0 ]; then
  echo "BLOCKED: ${TOTAL} error pattern(s) found in docs/articles/ HTML:"
  echo -e "$DETAILS"
  echo ""
  echo "Fix rendering errors before committing. Rebuild affected articles."
  exit 2
fi

exit 0
