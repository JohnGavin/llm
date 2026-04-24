#!/usr/bin/env bash
# log_session.sh — Write session events to unified DuckDB
# Usage: log_session.sh start|stop [session_id] [project] [summary]
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

case "$ACTION" in
  start)
    duckdb "$DB" -c "
      INSERT OR REPLACE INTO sessions (session_id, project, started_at, summary)
      VALUES ('$SESSION_ID', '$PROJECT', current_timestamp, '$SUMMARY');
    " 2>/dev/null || true
    # Store session ID for stop to read
    echo "$SESSION_ID" > "$HOME/.claude/logs/.current_session"
    ;;
  stop)
    # Read stored session ID if not provided
    if [ "$SESSION_ID" = "" ] && [ -f "$HOME/.claude/logs/.current_session" ]; then
      SESSION_ID=$(cat "$HOME/.claude/logs/.current_session")
    fi
    duckdb "$DB" -c "
      UPDATE sessions
      SET ended_at = current_timestamp,
          duration_min = EXTRACT(EPOCH FROM (current_timestamp - started_at)) / 60.0,
          summary = COALESCE(NULLIF('$SUMMARY', ''), summary)
      WHERE session_id = '$SESSION_ID';
    " 2>/dev/null || true
    rm -f "$HOME/.claude/logs/.current_session"
    ;;
  error)
    SOURCE="${5:-unknown}"
    duckdb "$DB" -c "
      INSERT INTO errors (session_id, source, error_text, context)
      VALUES ('$SESSION_ID', '$SOURCE', '$(echo "$SUMMARY" | sed "s/'/''/g")', '$PROJECT');
    " 2>/dev/null || true
    ;;
  hook)
    HOOK_NAME="${5:-unknown}"
    EVENT_TYPE="${6:-unknown}"
    duckdb "$DB" -c "
      INSERT INTO hook_events (session_id, hook_name, event_type, output_preview)
      VALUES ('$SESSION_ID', '$HOOK_NAME', '$EVENT_TYPE', '$(echo "$SUMMARY" | head -c 200 | sed "s/'/''/g")');
    " 2>/dev/null || true
    ;;
  agent_start)
    AGENT_TYPE="${5:-unknown}"
    MODEL="${6:-unknown}"
    duckdb "$DB" -c "
      INSERT INTO agent_runs (session_id, agent_type, model, started_at, prompt_preview, status)
      VALUES ('$SESSION_ID', '$AGENT_TYPE', '$MODEL', current_timestamp,
              '$(echo "$SUMMARY" | head -c 200 | sed "s/'/''/g")', 'running');
    " 2>/dev/null || true
    ;;
  agent_stop)
    AGENT_TYPE="${5:-unknown}"
    STATUS="${6:-completed}"
    duckdb "$DB" -c "
      UPDATE agent_runs
      SET ended_at = current_timestamp,
          duration_sec = EXTRACT(EPOCH FROM (current_timestamp - started_at)),
          status = '$STATUS'
      WHERE session_id = '$SESSION_ID'
        AND agent_type = '$AGENT_TYPE'
        AND status = 'running'
      ORDER BY started_at DESC LIMIT 1;
    " 2>/dev/null || true
    ;;
  *)
    echo "Usage: log_session.sh start|stop|error|hook|agent_start|agent_stop [session_id] [project] [summary] [extra_args...]" >&2
    exit 1
    ;;
esac
