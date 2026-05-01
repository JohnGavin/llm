#!/usr/bin/env bash
# skill_quality_onwrite.sh — PostToolUse:Edit|Write hook for skill files
# T1 quality check: fires on every skill SKILL.md write
# Never blocks (exit 0 always) — warns only

set -uo pipefail

# Only process skill files
FILE="${CLAUDE_TOOL_INPUT_FILE:-}"
if [ -z "$FILE" ]; then
  exit 0
fi

# Match only SKILL.md files in skills/ directories
case "$FILE" in
  */skills/*/SKILL.md|*/skills/*/skill.md) ;;
  *) exit 0 ;;
esac

if [ ! -f "$FILE" ]; then
  exit 0
fi

ERRORS=0
WARNINGS=0
SKILL_NAME=$(basename "$(dirname "$FILE")")

# 1. Check YAML frontmatter exists
if ! head -1 "$FILE" | grep -q '^---'; then
  echo "SKILL WARN [$SKILL_NAME]: Missing YAML frontmatter (---)"
  ERRORS=$((ERRORS + 1))
fi

# 2. Check name field in frontmatter
if ! sed -n '/^---$/,/^---$/p' "$FILE" | grep -q '^name:'; then
  echo "SKILL WARN [$SKILL_NAME]: Missing 'name:' in frontmatter"
  ERRORS=$((ERRORS + 1))
fi

# 3. Check description field with trigger phrases
DESC=$(sed -n '/^---$/,/^---$/p' "$FILE" | grep '^description:' | sed 's/^description:\s*//')
if [ -z "$DESC" ]; then
  echo "SKILL WARN [$SKILL_NAME]: Missing 'description:' in frontmatter"
  ERRORS=$((ERRORS + 1))
else
  # Count trigger verbs
  TRIGGERS=$(echo "$DESC" | grep -oiE '\b(use when|create|build|implement|debug|configure|add|write|set up|deploy|fix|test|review)\b' | wc -l | tr -d ' ')
  if [ "$TRIGGERS" -lt 2 ]; then
    echo "SKILL WARN [$SKILL_NAME]: Description has few trigger phrases ($TRIGGERS found, want >= 3)"
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# 4. Check body has section headers (not a wall of text)
HEADERS=$(grep -c '^##' "$FILE" 2>/dev/null || echo "0")
if [ "$HEADERS" -lt 2 ]; then
  echo "SKILL WARN [$SKILL_NAME]: Only $HEADERS section headers (## ...) — consider adding structure"
  WARNINGS=$((WARNINGS + 1))
fi

# 5. Check word count
WORDS=$(wc -w < "$FILE" | tr -d ' ')
if [ "$WORDS" -lt 100 ]; then
  echo "SKILL WARN [$SKILL_NAME]: Only $WORDS words — skills should be 500-3000 words"
  WARNINGS=$((WARNINGS + 1))
elif [ "$WORDS" -gt 3500 ]; then
  echo "SKILL WARN [$SKILL_NAME]: $WORDS words — consider moving detail to references/"
  WARNINGS=$((WARNINGS + 1))
fi

# 6. Check MANIFEST entry
MANIFEST="$(dirname "$(dirname "$FILE")")/MANIFEST.md"
if [ -f "$MANIFEST" ]; then
  if ! grep -q "$SKILL_NAME" "$MANIFEST"; then
    echo "SKILL WARN [$SKILL_NAME]: No entry in MANIFEST.md — add one"
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# Report
if [ "$ERRORS" -gt 0 ] || [ "$WARNINGS" -gt 0 ]; then
  echo "SKILL CHECK [$SKILL_NAME]: $ERRORS errors, $WARNINGS warnings"
fi

# Never block — exit 0 always
exit 0
