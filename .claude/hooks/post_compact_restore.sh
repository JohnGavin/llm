#!/usr/bin/env bash
# post_compact_restore.sh - Restore context state after compaction or resume
# Hook: SessionStart (compact|resume)
# Reads saved state and prints a context summary for Claude to pick up.

set -euo pipefail

CACHE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude"
CACHE_FILE="$CACHE_DIR/.context_state.json"
CURRENT_WORK="$CACHE_DIR/CURRENT_WORK.md"

# Only restore if state was previously saved
if [ ! -f "$CACHE_FILE" ]; then
  exit 0
fi

echo "Context Restoration"
echo "==================="

# Parse saved state
saved_at=$(grep -oP '"saved_at":\s*"\K[^"]+' "$CACHE_FILE" 2>/dev/null || echo "unknown")
plan_path=$(grep -oP '"plan_path":\s*"\K[^"]+' "$CACHE_FILE" 2>/dev/null || echo "")
current_task=$(grep -oP '"current_task":\s*"\K[^"]+' "$CACHE_FILE" 2>/dev/null || echo "")
recent_decisions=$(grep -oP '"recent_decisions":\s*"\K[^"]+' "$CACHE_FILE" 2>/dev/null || echo "")
branch=$(grep -oP '"branch":\s*"\K[^"]+' "$CACHE_FILE" 2>/dev/null || echo "unknown")
uncommitted=$(grep -oP '"uncommitted_files":\s*\K[0-9]+' "$CACHE_FILE" 2>/dev/null || echo "0")

echo "State saved at: $saved_at"
echo "Branch: $branch"
echo "Uncommitted files: $uncommitted"

if [ -n "$plan_path" ]; then
  echo "Active plan: $plan_path"
fi

if [ -n "$current_task" ]; then
  echo "Current task: $current_task"
fi

if [ -n "$recent_decisions" ]; then
  echo "Recent decisions:"
  echo "$recent_decisions" | tr '|' '\n' | while read -r line; do
    [ -n "$line" ] && echo "  - $line"
  done
fi

# Print CURRENT_WORK.md summary if it exists
if [ -f "$CURRENT_WORK" ]; then
  echo ""
  echo "CURRENT_WORK.md:"
  head -20 "$CURRENT_WORK"
fi

# Clean up (state has been restored)
rm -f "$CACHE_FILE"

exit 0
