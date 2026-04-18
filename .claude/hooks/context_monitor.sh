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

# ── Periodic burn rate check (every ~20 tool calls) ──────────────────
BURN_COUNTER="/tmp/claude_burn_counter"
BURN_INTERVAL=20
_bc=0
[ -f "$BURN_COUNTER" ] && _bc=$(cat "$BURN_COUNTER" 2>/dev/null || echo 0)
_bc=$((_bc + 1))
echo "$_bc" > "$BURN_COUNTER"

if [ "$((_bc % BURN_INTERVAL))" -eq 0 ]; then
  _burn_script="$HOME/.claude/scripts/burn_rate_check.sh"
  if [ -x "$_burn_script" ]; then
    _burn_msg=$(timeout 10 "$_burn_script" compact 2>/dev/null) || true
    case "${_burn_msg:-}" in
      *CRITICAL*|*WARN*) echo "$_burn_msg" ;;
    esac
  fi
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
