#!/usr/bin/env bash
# session_tidy.sh - Session-end tidy checks
# Runs at Stop and via /bye command.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"

echo "Session Tidy Check"
echo "=================="

# 1. MEMORY.md line check
MEMORY_DIR=""
for d in "$CLAUDE_DIR"/projects/*/memory; do
  [ -d "$d" ] && MEMORY_DIR="$d" && break
done

if [ -n "$MEMORY_DIR" ] && [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  mem_lines=$(timeout 5 wc -l < "$MEMORY_DIR/MEMORY.md" 2>/dev/null || echo 0)
  if [ "$mem_lines" -gt 180 ]; then
    echo "MEMORY.md: $mem_lines lines - WARN: approaching 200-line truncation limit!"
  else
    echo "MEMORY.md: $mem_lines lines - OK"
  fi
fi

# 2. Stale memory check (>30 days)
if [ -n "$MEMORY_DIR" ]; then
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
  if [ "$stale_count" -gt 0 ]; then
    echo "Memory:    $stale_count stale files (>30 days):$stale_files"
  else
    echo "Memory:    all files fresh"
  fi
fi

# 3. Uncommitted config changes
if [ -d "$CLAUDE_DIR/.git" ] || git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  changes=$(git -C "$CLAUDE_DIR" status -s 2>/dev/null | head -5)
  if [ -n "$changes" ]; then
    n_changes=$(echo "$changes" | wc -l | tr -d ' ')
    echo "Config:    $n_changes uncommitted changes in ~/.claude/"
  else
    echo "Config:    clean"
  fi
else
  echo "Config:    not a git repo"
fi

exit 0
