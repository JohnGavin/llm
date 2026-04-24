#!/usr/bin/env bash
# log_agent_run.sh — Log agent spawns to unified DuckDB
# Hook: PostToolUse (Agent)
# Captures agent type, model from tool input JSON

set -euo pipefail

_log_script="$HOME/.claude/scripts/log_session.sh"
[ -x "$_log_script" ] || exit 0
[ -f "$HOME/.claude/logs/.current_session" ] || exit 0

_sid=$(cat "$HOME/.claude/logs/.current_session" 2>/dev/null || echo "")
[ -n "$_sid" ] || exit 0

# Claude sets CLAUDE_TOOL_INPUT as JSON for PostToolUse hooks
_input="${CLAUDE_TOOL_INPUT:-}"
if [ -n "$_input" ]; then
  _agent_type=$(echo "$_input" | grep -o '"subagent_type":"[^"]*"' | cut -d'"' -f4 || echo "general-purpose")
  _model=$(echo "$_input" | grep -o '"model":"[^"]*"' | cut -d'"' -f4 || echo "inherited")
  _desc=$(echo "$_input" | grep -o '"description":"[^"]*"' | cut -d'"' -f4 || echo "")
else
  _agent_type="unknown"
  _model="unknown"
  _desc=""
fi

"$_log_script" agent_start "$_sid" "$(basename "$(pwd)")" "$_desc" "$_agent_type" "$_model" 2>/dev/null || true

exit 0
