#!/usr/bin/env bash
# decision_log_reminder.sh - Remind to log decisions at session end
# Hook: Stop (runs after every response)
# Lightweight check: warns if CURRENT_WORK.md has no Decisions section
# for the current session date.

set -euo pipefail

CURRENT_WORK="${CLAUDE_PROJECT_DIR:-.}/.claude/CURRENT_WORK.md"
TODAY=$(date +%Y-%m-%d)

# Skip if no CURRENT_WORK.md
[ -f "$CURRENT_WORK" ] || exit 0

# Check if today's session has a Decisions section
if ! grep -q "### Decisions" "$CURRENT_WORK" 2>/dev/null; then
  # Only remind if there's been substantial work (file has today's date)
  if grep -q "$TODAY" "$CURRENT_WORK" 2>/dev/null; then
    echo "Reminder: CURRENT_WORK.md has no ### Decisions section for today."
    echo "Log key design decisions (why, not just what) before ending session."
  fi
fi

exit 0
