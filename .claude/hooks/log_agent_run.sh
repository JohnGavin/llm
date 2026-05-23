#!/usr/bin/env bash
# log_agent_run.sh — Log agent dispatch + completion to unified DuckDB.
# Hook: wired to BOTH PreToolUse(Agent) and PostToolUse(Agent) in settings.json.
#   PreToolUse  -> agent_start (status='running', captures started_at)
#   PostToolUse -> agent_stop  (sets ended_at, duration, status done/failed)
# Reads the hook payload as JSON on stdin (modern interface); falls back to
# CLAUDE_TOOL_INPUT env (legacy). ALWAYS exits 0 — must never block dispatch.
set -uo pipefail   # deliberately NOT -e

_log_script="$HOME/.claude/scripts/log_session.sh"
[ -x "$_log_script" ] || exit 0
[ -f "$HOME/.claude/logs/.current_session" ] || exit 0
_sid=$(cat "$HOME/.claude/logs/.current_session" 2>/dev/null || echo "")
[ -n "$_sid" ] || exit 0

_input=$(cat 2>/dev/null || echo "")   # consume stdin once

_jq() { echo "$_input" | jq -r "$1" 2>/dev/null || echo ""; }

if [ -n "$_input" ] && command -v jq >/dev/null 2>&1; then
  _event=$(_jq '.hook_event_name // empty')
  _agent_type=$(_jq '.tool_input.subagent_type // empty')
  _model=$(_jq '.tool_input.model // empty')
  _desc=$(_jq '.tool_input.description // empty')
  _tuid=$(_jq '.tool_use_id // empty')
  _is_err=$(_jq '.tool_response.is_error // empty')
else
  _event=""
  _legacy="${CLAUDE_TOOL_INPUT:-}"
  _agent_type=$(echo "$_legacy" | grep -o '"subagent_type":"[^"]*"' | cut -d'"' -f4)
  _model=$(echo "$_legacy" | grep -o '"model":"[^"]*"' | cut -d'"' -f4)
  _desc=$(echo "$_legacy" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
  _tuid=""
  _is_err=""
fi

[ -n "$_agent_type" ] || _agent_type="general-purpose"
[ -n "$_model" ] || _model="inherited"
_proj="$(basename "$(pwd)")"

case "$_event" in
  PreToolUse)
    "$_log_script" agent_start "$_sid" "$_proj" "$_desc" "$_agent_type" "$_model" "$_tuid" 2>/dev/null || true
    ;;
  PostToolUse)
    _status="done"
    if [ -n "$_is_err" ] && [ "$_is_err" != "false" ]; then _status="failed"; fi
    "$_log_script" agent_stop "$_sid" "$_proj" "$_desc" "$_agent_type" "$_status" "$_tuid" 2>/dev/null || true
    ;;
  *)
    # Event undeterminable (legacy single-wiring or missing field): record the
    # dispatch as a completed run so agent_type is at least captured. Log the
    # raw payload to a debug file to inform future hardening.
    echo "$(date '+%F %T') unknown-event payload=$(echo "$_input" | head -c 300)" \
      >> "$HOME/.claude/logs/agent_hook_debug.log" 2>/dev/null || true
    "$_log_script" agent_stop "$_sid" "$_proj" "$_desc" "$_agent_type" "done" "$_tuid" 2>/dev/null || true
    ;;
esac
exit 0
