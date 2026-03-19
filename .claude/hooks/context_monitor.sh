#!/usr/bin/env bash
# context_monitor.sh - Progressive context usage warnings
# Hook: PostToolUse (Bash, Task)
# Checks context usage percentage and warns at thresholds.
# Note: CLAUDE_CONTEXT_USAGE_PERCENT is set by Claude Code when available.

set -euo pipefail

# Context percentage may be available as environment variable
USAGE_PCT="${CLAUDE_CONTEXT_USAGE_PERCENT:-0}"

# Skip if percentage not available
if [ "$USAGE_PCT" -eq 0 ] 2>/dev/null; then
  exit 0
fi

if [ "$USAGE_PCT" -ge 90 ]; then
  echo "CAUTION: Context at ${USAGE_PCT}%! Complete current task with full quality. Auto-compact imminent."
elif [ "$USAGE_PCT" -ge 80 ]; then
  echo "INFO: Context at ${USAGE_PCT}%. Auto-compact approaching. Consider finishing current task."
elif [ "$USAGE_PCT" -ge 65 ]; then
  echo "INFO: Context at ${USAGE_PCT}%. Save important decisions to CURRENT_WORK.md."
elif [ "$USAGE_PCT" -ge 40 ]; then
  echo "INFO: Context at ${USAGE_PCT}%. Consider saving non-obvious discoveries to memory."
fi

exit 0
