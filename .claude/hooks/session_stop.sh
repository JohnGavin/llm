#!/usr/bin/env bash
# session_stop.sh - Unified session-end checks
# Merges: session_tidy.sh + decision_log_reminder.sh
# Hook: Stop (fires after every Claude response)

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
CURRENT_WORK="${CLAUDE_PROJECT_DIR:-.}/.claude/CURRENT_WORK.md"
TODAY=$(date +%Y-%m-%d)

# ── Memory health ─────────────────────────────────────────────────────
MEMORY_DIR=""
for d in "$CLAUDE_DIR"/projects/*/memory; do
  [ -d "$d" ] && MEMORY_DIR="$d" && break
done

if [ -n "$MEMORY_DIR" ] && [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  mem_lines=$(timeout 5 wc -l < "$MEMORY_DIR/MEMORY.md" 2>/dev/null || echo 0)
  if [ "$mem_lines" -gt 180 ]; then
    echo "MEMORY.md: $mem_lines lines - WARN: approaching 200-line truncation limit!"
  fi

  # Stale memory files (>30 days)
  stale_count=0
  stale_files=""
  for f in "$MEMORY_DIR"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "MEMORY.md" ] && continue
    if [ "$(find "$f" -mtime +30 2>/dev/null)" ]; then
      stale_count=$((stale_count + 1))
      stale_files="$stale_files $(basename "$f")"
    fi
  done
  [ "$stale_count" -gt 0 ] && echo "Memory: $stale_count stale files (>30 days):$stale_files"
fi

# ── Uncommitted config ────────────────────────────────────────────────
if [ -d "$CLAUDE_DIR/.git" ] || git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  changes=$(git -C "$CLAUDE_DIR" status -s 2>/dev/null | head -5)
  if [ -n "$changes" ]; then
    n_changes=$(echo "$changes" | wc -l | tr -d ' ')
    echo "Config: $n_changes uncommitted changes in ~/.claude/"
  fi
fi

# ── Skill audit (only if skills changed) ─────────────────────────────
AUDIT_WRAPPER="$HOME/docs_gh/llm/.claude/scripts/audit_skills_if_changed.sh"
if [ -x "$AUDIT_WRAPPER" ]; then
  timeout 15 "$AUDIT_WRAPPER" 2>/dev/null || true
fi

# ── Decision log reminder ─────────────────────────────────────────────
if [ -f "$CURRENT_WORK" ]; then
  if ! grep -q "### Decisions" "$CURRENT_WORK" 2>/dev/null; then
    if grep -q "$TODAY" "$CURRENT_WORK" 2>/dev/null; then
      echo "Reminder: CURRENT_WORK.md has no ### Decisions section for today."
    fi
  fi
fi

exit 0
