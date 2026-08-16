#!/usr/bin/env bash
# log_session.sh — Write session events to unified DuckDB
# Usage: log_session.sh start|stop [session_id] [project] [summary]
#
# CONCURRENCY NOTE (#710, extended #956):
#   unified.duckdb has many concurrent writers (roborev ETL, staleness
#   collector, hook_events loader, telemetry). Writing via the duckdb CLI
#   takes an EXCLUSIVE whole-file lock — DuckDB allows no concurrent readers
#   or writers while it is held. A throwaway-DB experiment with 12 concurrent
#   CLI writers landed only 1: "IO Error: Could not set lock on file ...
#   Conflicting lock is held ... by ...". Every one of the 11 lost writes
#   failed with exactly the error this script used to suppress three times
#   over: `2>/dev/null` here, `|| true` here, and the caller backgrounding the
#   whole hook with `nohup ... &`.
#
#   FIX (#710 for `hook`, #956 for start/stop/error/agent_start/agent_stop):
#   every case below writes to an append-only JSONL staging file instead of
#   the duckdb CLI (no lock needed — each printf/>> is an atomic kernel write
#   <= PIPE_BUF). The corresponding `*_staging_import.sh` script drains its
#   staging file into the real table from roborev_metrics_etl.sh, at a time
#   when duckdb contention is lower:
#     hook        -> hook_events_staging.jsonl   -> hook_events_load.sh
#     start/stop  -> session_events_staging.jsonl -> session_events_staging_import.sh
#     agent_start/agent_stop -> agent_events_staging.jsonl -> agent_events_staging_import.sh
#     error       -> error_events_staging.jsonl  -> error_events_staging_import.sh
#
#   This script no longer calls the duckdb CLI at all — every case is a
#   lock-free append. The etl_freshness registry updates for `sessions` and
#   `agent_runs` moved out of the `stop`/`agent_stop` cases (which fired
#   before the data had actually landed, and were themselves subject to the
#   same lock) into the corresponding *_staging_import.sh scripts, which call
#   them right after the real write lands.
set -euo pipefail

DB="$HOME/.claude/logs/unified.duckdb"
ACTION="${1:-}"
SESSION_ID="${2:-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo unknown)}"
PROJECT="${3:-$(basename "$(pwd)")}"
SUMMARY="${4:-}"

# Ensure DB exists
if [ ! -f "$DB" ]; then
  echo "WARN: unified.duckdb not found at $DB" >&2
  exit 0
fi

# ── JSON-escape a single field for embedding in a JSONL string literal ─────
# Order matters: strip control chars that would break a single JSONL line
# (newline/CR/tab -> space) FIRST, then escape backslashes, then quotes —
# mirrors the `hook` case's original escaping (kept byte-for-byte).
_json_escape() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_now_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

case "$ACTION" in
  start)
    # llm#803: optional 5th arg MODEL. No reliable harness env var carries the
    # active model at SessionStart time (before any assistant turn exists),
    # so today's callers (session_init.sh) never pass it and this stays NULL
    # at start -- it is populated later by `stop`, which can read the model
    # out of the session's own transcript JSONL once at least one turn has
    # happened. The param exists so a future caller with a reliable source
    # can populate it directly without a log_session.sh change.
    MODEL_START="${5:-}"
    _STAGING="${HOME}/.claude/logs/session_events_staging.jsonl"
    _ts=$(_now_ts)
    _proj_esc=$(_json_escape "$PROJECT")
    _summary_esc=$(_json_escape "$(echo "$SUMMARY" | head -c 500)")
    _model_esc=$(_json_escape "$MODEL_START")
    printf '{"type":"start","ts":"%s","session_id":"%s","project":"%s","summary":"%s","model":"%s"}\n' \
      "$_ts" "$SESSION_ID" "$_proj_esc" "$_summary_esc" "$_model_esc" \
      >> "${_STAGING}" 2>/dev/null || true
    # Store session ID for stop to read
    echo "$SESSION_ID" > "$HOME/.claude/logs/.current_session"
    ;;
  stop)
    # Read stored session ID if not provided
    if [ "$SESSION_ID" = "" ] && [ -f "$HOME/.claude/logs/.current_session" ]; then
      SESSION_ID=$(cat "$HOME/.claude/logs/.current_session")
    fi
    # llm#803: optional 5th arg MODEL, sourced by the caller (session_stop.sh)
    # from the session's transcript JSONL (each assistant turn embeds a
    # top-level "model" field). The import side applies the identical
    # COALESCE(NULLIF(...), existing) guard the old direct-duckdb UPDATE
    # used, so a blank/missing staged value never clobbers a model recorded
    # by an earlier `stop` for this session — see
    # session_events_staging_import.sh.
    MODEL_STOP="${5:-}"
    _STAGING="${HOME}/.claude/logs/session_events_staging.jsonl"
    _ts=$(_now_ts)
    _summary_esc=$(_json_escape "$(echo "$SUMMARY" | head -c 500)")
    _model_esc=$(_json_escape "$MODEL_STOP")
    printf '{"type":"stop","ts":"%s","session_id":"%s","summary":"%s","model":"%s"}\n' \
      "$_ts" "$SESSION_ID" "$_summary_esc" "$_model_esc" \
      >> "${_STAGING}" 2>/dev/null || true
    rm -f "$HOME/.claude/logs/.current_session"
    # etl_freshness for `sessions` is now updated by
    # session_events_staging_import.sh AFTER the staged stop actually lands
    # in the table (llm#956) -- calling it here, before the write has landed,
    # was itself another duckdb CLI call subject to the same lock, which is
    # why etl_freshness.sessions had been frozen for weeks.
    ;;
  error)
    SOURCE="${5:-unknown}"
    _STAGING="${HOME}/.claude/logs/error_events_staging.jsonl"
    _ts=$(_now_ts)
    _source_esc=$(_json_escape "$SOURCE")
    _errtext_esc=$(_json_escape "$(echo "$SUMMARY" | head -c 1000)")
    _context_esc=$(_json_escape "$PROJECT")
    printf '{"ts":"%s","session_id":"%s","source":"%s","error_text":"%s","context":"%s"}\n' \
      "$_ts" "$SESSION_ID" "$_source_esc" "$_errtext_esc" "$_context_esc" \
      >> "${_STAGING}" 2>/dev/null || true
    ;;
  hook)
    HOOK_NAME="${5:-unknown}"
    EVENT_TYPE="${6:-unknown}"
    # JSONL staging: no duckdb CLI, no exclusive lock (#710 durable fix).
    # Each >> append is <= PIPE_BUF (512 B) and atomic at the kernel level;
    # no concurrent writer can interleave within a single printf line.
    # roborev_metrics_etl.sh imports this file into hook_events on each ETL run.
    _HOOK_STAGING="${HOME}/.claude/logs/hook_events_staging.jsonl"
    _preview=$(echo "$SUMMARY" | head -c 200)
    _preview_esc=$(_json_escape "$_preview")
    printf '{"ts":"%s","session_id":"%s","hook_name":"%s","event_type":"%s","output_preview":"%s"}\n' \
      "$(_now_ts)" "$SESSION_ID" "$HOOK_NAME" "$EVENT_TYPE" "$_preview_esc" \
      >> "${_HOOK_STAGING}" 2>/dev/null || true
    ;;
  agent_start)
    AGENT_TYPE="${5:-unknown}"
    MODEL="${6:-unknown}"
    TOOL_USE_ID="${7:-}"
    _STAGING="${HOME}/.claude/logs/agent_events_staging.jsonl"
    _ts=$(_now_ts)
    _agent_esc=$(_json_escape "$AGENT_TYPE")
    _model_esc=$(_json_escape "$MODEL")
    _preview_esc=$(_json_escape "$(echo "$SUMMARY" | head -c 200)")
    _tuid_esc=$(_json_escape "$TOOL_USE_ID")
    printf '{"type":"agent_start","ts":"%s","session_id":"%s","agent_type":"%s","model":"%s","prompt_preview":"%s","status":"running","tool_use_id":"%s"}\n' \
      "$_ts" "$SESSION_ID" "$_agent_esc" "$_model_esc" "$_preview_esc" "$_tuid_esc" \
      >> "${_STAGING}" 2>/dev/null || true
    ;;
  agent_stop)
    AGENT_TYPE="${5:-unknown}"
    STATUS="${6:-done}"
    TOOL_USE_ID="${7:-}"
    _STAGING="${HOME}/.claude/logs/agent_events_staging.jsonl"
    _ts=$(_now_ts)
    _agent_esc=$(_json_escape "$AGENT_TYPE")
    _status_esc=$(_json_escape "$STATUS")
    _preview_esc=$(_json_escape "$(echo "$SUMMARY" | head -c 200)")
    _tuid_esc=$(_json_escape "$TOOL_USE_ID")
    printf '{"type":"agent_stop","ts":"%s","session_id":"%s","agent_type":"%s","model":"","prompt_preview":"%s","status":"%s","tool_use_id":"%s"}\n' \
      "$_ts" "$SESSION_ID" "$_agent_esc" "$_preview_esc" "$_status_esc" "$_tuid_esc" \
      >> "${_STAGING}" 2>/dev/null || true
    # etl_freshness for `agent_runs` is now updated by
    # agent_events_staging_import.sh AFTER the staged stop actually lands
    # (llm#956) -- see the `stop` case comment above for why calling it here
    # (before the write lands) was itself lock-prone.
    ;;
  *)
    echo "Usage: log_session.sh start|stop|error|hook|agent_start|agent_stop [session_id] [project] [summary] [extra_args...]" >&2
    exit 1
    ;;
esac
