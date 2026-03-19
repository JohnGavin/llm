#!/usr/bin/env bash
# context_survival.sh - Save/restore context state across compaction
# Merges: pre_compact.sh + post_compact_restore.sh
# Usage: context_survival.sh save   (PreCompact hook)
#        context_survival.sh restore (SessionStart compact|resume hook)

set -euo pipefail

CACHE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude"
CACHE_FILE="$CACHE_DIR/.context_state.json"
CURRENT_WORK="$CACHE_DIR/CURRENT_WORK.md"

ACTION="${1:-restore}"

# ── SAVE ──────────────────────────────────────────────────────────────
do_save() {
  echo "Context Survival: saving state before compaction..."

  local plan_path="" current_task="" recent_decisions=""

  if [ -f "$CURRENT_WORK" ]; then
    plan_path=$(grep -oE 'plans?/[^[:space:]]+\.md' "$CURRENT_WORK" 2>/dev/null | tail -1 || echo "")
    current_task=$(grep -m1 '^\- \[ \]' "$CURRENT_WORK" 2>/dev/null || echo "")
    recent_decisions=$(grep -E '^\- Decision:|^### ' "$CURRENT_WORK" 2>/dev/null | tail -3 | tr '\n' '|' || echo "")
  fi

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
}

# ── RESTORE ───────────────────────────────────────────────────────────
do_restore() {
  [ -f "$CACHE_FILE" ] || exit 0

  echo "Context Restoration"
  echo "==================="

  # Parse JSON fields with sed (portable, no grep -P)
  jval() { sed -n "s/.*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CACHE_FILE" | head -1; }
  local saved_at plan_path current_task recent_decisions branch uncommitted
  saved_at=$(jval saved_at); saved_at="${saved_at:-unknown}"
  plan_path=$(jval plan_path)
  current_task=$(jval current_task)
  recent_decisions=$(jval recent_decisions)
  branch=$(jval branch); branch="${branch:-unknown}"
  uncommitted=$(sed -n 's/.*"uncommitted_files":[[:space:]]*\([0-9]*\).*/\1/p' "$CACHE_FILE" | head -1)
  uncommitted="${uncommitted:-0}"

  echo "State saved at: $saved_at"
  echo "Branch: $branch"
  echo "Uncommitted files: $uncommitted"
  [ -n "$plan_path" ] && echo "Active plan: $plan_path"
  [ -n "$current_task" ] && echo "Current task: $current_task"

  if [ -n "$recent_decisions" ]; then
    echo "Recent decisions:"
    echo "$recent_decisions" | tr '|' '\n' | while read -r line || [ -n "$line" ]; do
      [ -n "$line" ] && echo "  - $line"
    done || true
  fi

  if [ -f "$CURRENT_WORK" ]; then
    echo ""
    echo "CURRENT_WORK.md:"
    head -20 "$CURRENT_WORK"
  fi

  rm -f "$CACHE_FILE"
}

# ── Dispatch ──────────────────────────────────────────────────────────
case "$ACTION" in
  save)    do_save ;;
  restore) do_restore ;;
  *)       echo "Usage: context_survival.sh save|restore"; exit 1 ;;
esac

exit 0
