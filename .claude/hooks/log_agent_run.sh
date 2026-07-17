#!/usr/bin/env bash
# log_agent_run.sh — Log agent dispatch + completion to unified DuckDB.
# Hook: wired to BOTH PreToolUse(Agent) and PostToolUse(Agent) in settings.json.
#   PreToolUse  -> agent_start (status='running', captures started_at)
#   PostToolUse -> agent_stop  (sets ended_at, duration, status done/failed)
# Reads the hook payload as JSON on stdin (modern interface); falls back to
# CLAUDE_TOOL_INPUT env (legacy). ALWAYS exits 0 — must never block dispatch.
#
# Session-id resolution (llm#784): the `.current_session` marker file this
# hook used to depend on exclusively is owned by log_session.sh's
# session_start/session_stop and has been observed absent during an active
# session — every agent dispatch was then silently skipped while `sessions`
# kept filling (agent_runs frozen 2026-07-14, sessions stayed live). Resolve
# session_id in order, self-healing past a missing/stale marker:
#   1. Top-level `session_id` field of the hook's own JSON payload — Claude
#      Code documents this as a common field on every hook event, see
#      https://code.claude.com/docs/en/hooks ("Common Fields").
#   2. `.current_session` marker file (previous/legacy behaviour).
#   3. Self-heal: newest open (no ended_at) row in `sessions`, else the
#      newest row overall, queried directly from unified.duckdb.
#   4. Give up — exit 0, but leave a breadcrumb in agent_hook_debug.log so the
#      miss is visible instead of silent.
set -uo pipefail   # deliberately NOT -e

_log_script="$HOME/.claude/scripts/log_session.sh"
[ -x "$_log_script" ] || exit 0

_input=$(cat 2>/dev/null || echo "")   # consume stdin once

_jq() { echo "$_input" | jq -r "$1" 2>/dev/null || echo ""; }

_have_jq=0
command -v jq >/dev/null 2>&1 && _have_jq=1

# Portable bounded execution for the DB self-heal query (llm#716 pattern):
# GNU timeout is absent on macOS/launchd PATH; fall back to perl's alarm(2).
_TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
_bounded() {
  local secs="$1"; shift
  if [ -n "$_TIMEOUT_CMD" ]; then
    "$_TIMEOUT_CMD" "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; alarm $t; exec @ARGV or die "exec: $!"' "$secs" "$@"
  else
    "$@"
  fi
}

# ── 1. session_id from the hook payload itself ──────────────────────────────
_sid=""
if [ -n "$_input" ] && [ "$_have_jq" -eq 1 ]; then
  _sid=$(_jq '.session_id // empty')
fi

# ── 2. .current_session marker file (legacy / fallback) ────────────────────
if [ -z "$_sid" ] && [ -f "$HOME/.claude/logs/.current_session" ]; then
  _sid=$(cat "$HOME/.claude/logs/.current_session" 2>/dev/null || echo "")
fi

# ── 3. Self-heal: newest open session (else newest row) straight from the DB
if [ -z "$_sid" ]; then
  _db="$HOME/.claude/logs/unified.duckdb"
  if [ -f "$_db" ]; then
    _query="SELECT session_id FROM sessions ORDER BY (ended_at IS NULL) DESC, started_at DESC LIMIT 1;"
    if command -v duckdb >/dev/null 2>&1; then
      _sid=$(_bounded 5 duckdb -init /dev/null "$_db" -noheader -list -c "$_query" 2>/dev/null || echo "")
    else
      _hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      _nix_default="$(cd "${_hook_dir}/../.." 2>/dev/null && pwd)/default.nix"
      if command -v nix-shell >/dev/null 2>&1 && [ -f "$_nix_default" ]; then
        _sid=$(_bounded 15 nix-shell "$_nix_default" --run \
          "duckdb -init /dev/null '$_db' -noheader -list -c \"$_query\"" 2>/dev/null || echo "")
      fi
    fi
    _sid=$(echo "$_sid" | tr -d '[:space:]')
  fi
fi

# ── 4. Give up ───────────────────────────────────────────────────────────────
if [ -z "$_sid" ]; then
  echo "$(date '+%F %T') no-session-id payload=$(echo "$_input" | head -c 300)" \
    >> "$HOME/.claude/logs/agent_hook_debug.log" 2>/dev/null || true
  exit 0
fi

if [ -n "$_input" ] && [ "$_have_jq" -eq 1 ]; then
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
