#!/bin/bash
# Check if any skill/agent files exceed the Claude character budget

# Default to 15,000 characters if env var not set
LIMIT=${SLASH_COMMAND_TOOL_CHAR_BUDGET:-15000}

echo "Checking for files larger than $LIMIT bytes in .claude/..."

# Find files larger than LIMIT bytes
# -size +Nc matches files > N bytes
OVERSIZED=$(find .claude -type f \( -name "*.md" -o -name "*.txt" \) -size +${LIMIT}c)

if [ -n "$OVERSIZED" ]; then
  echo "❌ ERROR: The following files exceed the character budget ($LIMIT):"
  echo "$OVERSIZED" | xargs ls -lh
  echo "These files may be truncated or ignored by Claude."
  echo "Refactor them into smaller sub-files."
  exit 1
else
  echo "✅ All skill/agent files are within the limit ($LIMIT bytes)."
  exit 0
fi
