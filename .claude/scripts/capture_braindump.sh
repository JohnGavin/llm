#!/usr/bin/env bash
# capture_braindump.sh — Quick brain dump capture from terminal
# Usage: capture_braindump.sh [optional title]
# Then type your thoughts, Ctrl-D to save
set -euo pipefail

DUMP_DIR="$HOME/docs_gh/llm/knowledge/raw/braindumps"
mkdir -p "$DUMP_DIR"

TITLE="${1:-}"
TIMESTAMP=$(date +%F-%H%M)
FILENAME="${DUMP_DIR}/${TIMESTAMP}.md"

if [ -n "$TITLE" ]; then
  echo "# $TITLE" > "$FILENAME"
  echo "" >> "$FILENAME"
  echo "Captured: $(date '+%Y-%m-%d %H:%M')" >> "$FILENAME"
  echo "" >> "$FILENAME"
else
  echo "# Brain Dump ${TIMESTAMP}" > "$FILENAME"
  echo "" >> "$FILENAME"
  echo "Captured: $(date '+%Y-%m-%d %H:%M')" >> "$FILENAME"
  echo "" >> "$FILENAME"
fi

echo "Type your brain dump (Ctrl-D when done):"
echo "---"
cat >> "$FILENAME"

echo ""
echo "---"
echo "Saved to: $FILENAME ($(wc -l < "$FILENAME") lines)"
echo "Run /braindump in Claude Code to process it."
