#!/usr/bin/env bash
# pre_compact.sh - Save context state before auto-compaction
# Hook: PreCompact
# Saves plan path, current task, and recent decisions to a cache file
# so they can be restored after compaction.

set -euo pipefail

CACHE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude"
CACHE_FILE="$CACHE_DIR/.context_state.json"
CURRENT_WORK="$CACHE_DIR/CURRENT_WORK.md"

echo "Context Survival: saving state before compaction..."

# Extract current state from CURRENT_WORK.md
plan_path=""
current_task=""
recent_decisions=""

if [ -f "$CURRENT_WORK" ]; then
  # Find most recent plan reference
  plan_path=$(grep -oP 'plans?/\S+\.md' "$CURRENT_WORK" 2>/dev/null | tail -1 || echo "")

  # Find current task (first unchecked item)
  current_task=$(grep -m1 '^\- \[ \]' "$CURRENT_WORK" 2>/dev/null || echo "")

  # Find recent decisions (last 3 lines starting with "- Decision:" or "### ")
  recent_decisions=$(grep -E '^\- Decision:|^### ' "$CURRENT_WORK" 2>/dev/null | tail -3 | tr '\n' '|' || echo "")
fi

# Save state as JSON
cat > "$CACHE_FILE" <<ENDJSON
{
  "saved_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "plan_path": "$plan_path",
  "current_task": "$(echo "$current_task" | sed 's/"/\\"/g')",
  "recent_decisions": "$(echo "$recent_decisions" | sed 's/"/\\"/g')",
  "branch": "$(git branch --show-current 2>/dev/null || echo 'unknown')",
  "uncommitted_files": $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
}
ENDJSON

echo "Context state saved to $CACHE_FILE"
exit 0
