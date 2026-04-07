#!/usr/bin/env bash
# wiki_health_onwrite.sh - T1 health check on every wiki/ Edit/Write
# Hook: PostToolUse (Edit, Write)
# Fires fast single-file check; reports inline; never blocks (warnings only).
#
# To block on errors, use the pre-commit hook (T2) instead.

set -uo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$FILE_PATH" ] && exit 0

# Only act on files inside a */wiki/ directory
case "$FILE_PATH" in
  */wiki/*.md) ;;
  *) exit 0 ;;
esac

# Find the wiki dir (parent of the file)
WIKI_DIR=$(dirname "$FILE_PATH")
SCRIPT="$HOME/.claude/scripts/wiki_health_check.sh"
[ ! -x "$SCRIPT" ] && exit 0

# Run single-file check (quiet mode — output only on errors)
"$SCRIPT" "$WIKI_DIR" --single "$FILE_PATH" --quiet
exit 0  # never block on warnings; T2 pre-commit blocks instead
