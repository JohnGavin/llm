#!/usr/bin/env bash
# log_session.sh — Write session events to unified DuckDB
# Usage: log_session.sh start|stop [session_id] [project] [summary]
#
# CONCURRENCY NOTE (#710):
#   The `hook` case fires on every PostToolUse (i.e. every tool call).
#   Using the duckdb CLI here held an EXCLUSIVE write lock on unified.duckdb
#   for ~100ms per call.  DuckDB's lock model allows no concurrent readers
#   or writers while that lock is held.  With a busy Claude session firing
#   dozens of PostToolUse events per minute, the ETL could never acquire a
#   write connection through its 3 × 10 s retry window.
#
#   FIX: the `hook` case now writes to an append-only JSONL staging file
#   (no lock needed — each printf/>> is an atomic kernel write ≤ PIPE_BUF).
#   roborev_metrics_etl.sh imports the staging file into hook_events after
#   the main ETL, when contention is lower.
#
#   All other cases (start, stop, error, agent_start, agent_stop) fire at
#   most once per session boundary and retain the duckdb CLI path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    duckdb -init /dev/null "$DB" -c "
      INSERT OR REPLACE INTO sessions (session_id, project, started_at, summary, model)
      VALUES ('$SESSION_ID', '$PROJECT', current_timestamp, '$SUMMARY', NULLIF('$MODEL_START', ''));
    " 2>/dev/null || true
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
    # top-level "model" field). COALESCE means a blank/missing value never
    # clobbers a model recorded by an earlier `stop` call for this session.
    MODEL_STOP="${5:-}"
    duckdb -init /dev/null "$DB" -c "
      UPDATE sessions
      SET ended_at = current_timestamp,
          duration_min = EXTRACT(EPOCH FROM (current_timestamp - started_at)) / 60.0,
          summary = COALESCE(NULLIF('$SUMMARY', ''), summary),
          model = COALESCE(NULLIF('$MODEL_STOP', ''), model)
      WHERE session_id = '$SESSION_ID';
    " 2>/dev/null || true
    rm -f "$HOME/.claude/logs/.current_session"
    # ETL freshness registry (llm#309 Phase 1a): event-driven, no SLA -> unknown.
    if [ -x "${SCRIPT_DIR}/etl_freshness_upsert.sh" ]; then
      "${SCRIPT_DIR}/etl_freshness_upsert.sh" sessions "$DB" "" \
        --table sessions --ts-col started_at >/dev/null 2>&1 || true
    fi
    ;;
  error)
    SOURCE="${5:-unknown}"
    duckdb -init /dev/null "$DB" -c "
      INSERT INTO errors (session_id, source, error_text, context)
      VALUES ('$SESSION_ID', '$SOURCE', '$(echo "$SUMMARY" | sed "s/'/''/g")', '$PROJECT');
    " 2>/dev/null || true
    ;;
  hook)
    HOOK_NAME="${5:-unknown}"
    EVENT_TYPE="${6:-unknown}"
    # JSONL staging: no duckdb CLI, no exclusive lock (#710 durable fix).
    # Each >> append is ≤ PIPE_BUF (512 B) and atomic at the kernel level;
    # no concurrent writer can interleave within a single printf line.
    # roborev_metrics_etl.sh imports this file into hook_events on each ETL run.
    _HOOK_STAGING="${HOME}/.claude/logs/hook_events_staging.jsonl"
    _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
    # JSON-escape the preview: backslashes first, then double-quotes, then strip
    # control chars (newlines / carriage-returns / tabs) that would break JSONL.
    _preview=$(echo "$SUMMARY" | head -c 200 | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g')
    _preview=$(printf '%s' "$_preview" | sed 's/"/\\"/g')
    printf '{"ts":"%s","session_id":"%s","hook_name":"%s","event_type":"%s","output_preview":"%s"}\n' \
      "$_ts" "$SESSION_ID" "$HOOK_NAME" "$EVENT_TYPE" "$_preview" \
      >> "${_HOOK_STAGING}" 2>/dev/null || true
    ;;
  agent_start)
    AGENT_TYPE="${5:-unknown}"
    MODEL="${6:-unknown}"
    TOOL_USE_ID="${7:-}"
    duckdb -init /dev/null "$DB" -c "
      INSERT INTO agent_runs (session_id, agent_type, model, started_at, prompt_preview, status, tool_use_id)
      VALUES ('$SESSION_ID', '$AGENT_TYPE', '$MODEL', current_timestamp,
              '$(echo "$SUMMARY" | head -c 200 | sed "s/'/''/g")', 'running',
              NULLIF('$TOOL_USE_ID',''));
    " 2>/dev/null || true
    ;;
  agent_stop)
    AGENT_TYPE="${5:-unknown}"
    STATUS="${6:-done}"
    TOOL_USE_ID="${7:-}"
    PROMPT_PV="$(echo "$SUMMARY" | head -c 200 | sed "s/'/''/g")"
    _hit=""
    if [ -n "$TOOL_USE_ID" ]; then
      _hit=$(duckdb -init /dev/null "$DB" -noheader -list -c "
        UPDATE agent_runs SET ended_at=current_timestamp,
          duration_sec=EXTRACT(EPOCH FROM (current_timestamp-started_at)), status='$STATUS'
        WHERE tool_use_id='$TOOL_USE_ID' AND status='running' RETURNING id;" 2>/dev/null || echo "")
    fi
    if [ -z "$_hit" ]; then
      _hit=$(duckdb -init /dev/null "$DB" -noheader -list -c "
        UPDATE agent_runs SET ended_at=current_timestamp,
          duration_sec=EXTRACT(EPOCH FROM (current_timestamp-started_at)), status='$STATUS'
        WHERE id=(SELECT id FROM agent_runs WHERE session_id='$SESSION_ID'
          AND agent_type='$AGENT_TYPE' AND status='running'
          ORDER BY started_at DESC LIMIT 1) RETURNING id;" 2>/dev/null || echo "")
    fi
    if [ -z "$_hit" ]; then
      duckdb -init /dev/null "$DB" -c "
        INSERT INTO agent_runs (session_id, agent_type, model, started_at, ended_at,
          duration_sec, prompt_preview, status, tool_use_id)
        VALUES ('$SESSION_ID','$AGENT_TYPE','inherited',current_timestamp,
          current_timestamp,0,'$PROMPT_PV','$STATUS',NULLIF('$TOOL_USE_ID',''));" 2>/dev/null || true
    fi
    # ETL freshness registry (llm#309 Phase 1a): event-driven, no SLA -> unknown.
    if [ -x "${SCRIPT_DIR}/etl_freshness_upsert.sh" ]; then
      "${SCRIPT_DIR}/etl_freshness_upsert.sh" agent_runs "$DB" "" \
        --table agent_runs --ts-col started_at >/dev/null 2>&1 || true
    fi
    ;;
  *)
    echo "Usage: log_session.sh start|stop|error|hook|agent_start|agent_stop [session_id] [project] [summary] [extra_args...]" >&2
    exit 1
    ;;
esac
