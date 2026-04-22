#!/usr/bin/env bash
# post_push_qa.sh - After git push, check deployed URLs for error patterns
# Hook: PostToolUse:Bash — inspects command for git push
# Non-blocking (exit 0 always) — prints QA results into Claude's context

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | sed -n 's/.*"command":[[:space:]]*"\(.*\)".*/\1/p' | head -1)
[ -z "$CMD" ] && exit 0

# Only trigger on git push commands
if ! echo "$CMD" | grep -qE 'git.*push|git -C .* push'; then
  exit 0
fi

# Find repo root
REPO_DIR=$(echo "$CMD" | sed -n 's/.*git -C \([^ ]*\).*/\1/p' | head -1)
[ -z "$REPO_DIR" ] && REPO_DIR="."
[ ! -f "${REPO_DIR}/_pkgdown.yml" ] && exit 0

# Extract GitHub Pages URL from DESCRIPTION
DESC="${REPO_DIR}/DESCRIPTION"
if [ -f "$DESC" ]; then
  BASE_URL=$(grep -m1 'URL:' "$DESC" | sed 's/URL:[[:space:]]*//' | cut -d',' -f1 | tr -d ' ')
else
  exit 0
fi
[ -z "$BASE_URL" ] && exit 0
BASE_URL="${BASE_URL%/}"

# Quick check — don't wait for CI, just curl current deployed content
echo "Post-push QA: checking deployed content at ${BASE_URL}"
ERRORS=0
ARTICLES=$(grep -o 'articles/[a-z_-]*\.html' "${REPO_DIR}/_pkgdown.yml" | sort -u)
for article in $ARTICLES; do
  CONTENT=$(curl -s --max-time 10 "${BASE_URL}/${article}" 2>/dev/null)
  [ -z "$CONTENT" ] && continue
  for pattern in "not available" "not found in targets" "MISSING EVIDENCE"; do
    COUNT=$(echo "$CONTENT" | grep -ci "$pattern" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ]; then
      echo "  FAIL: ${article}: ${COUNT} hits for '${pattern}'"
      ERRORS=$((ERRORS + COUNT))
    fi
  done
done

if [ "$ERRORS" -gt 0 ]; then
  echo "WARNING: ${ERRORS} error pattern(s) in deployed HTML. Site may be stale — check after CI deploys."
else
  echo "OK: All deployed articles pass QA (or site not yet propagated)."
fi

exit 0
