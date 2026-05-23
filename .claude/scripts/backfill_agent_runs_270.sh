#!/usr/bin/env bash
# backfill_agent_runs_270.sh — One-time heuristic backfill for issue #270.
#
# Heuristic for ended_at (computed per session, ordered by started_at using LEAD):
#   1. If there is a next agent_runs row in the same session:
#        ended_at = LEAST(next_started_at, started_at + 600s)
#   2. Else if sessions.ended_at exists and is after started_at:
#        ended_at = LEAST(sessions.ended_at, started_at + 600s)
#   3. Else:
#        ended_at = started_at + 60s
#
# Uses a CTE with LEAD() for next-row look-ahead. CASE (not COALESCE+LEAST)
# handles NULL fallthrough correctly.
#
# Idempotent: only touches rows where status='running' AND (backfilled IS NULL
# OR backfilled=false). Safe to re-run.
#
# Usage: backfill_agent_runs_270.sh [db_path]
#   Default db_path: ~/.claude/logs/unified.duckdb
#
# Do NOT run against the live DB without orchestrator approval — test only.

set -uo pipefail

DB="${1:-$HOME/.claude/logs/unified.duckdb}"

if [ ! -f "$DB" ]; then
  echo "ERROR: DB not found: $DB" >&2
  exit 1
fi

TS=$(date '+%Y%m%d_%H%M%S')
BACKUP="${DB}.pre270.${TS}.bak"

echo "Backing up $DB -> $BACKUP"
cp -a "$DB" "$BACKUP"
echo "Backup created."

echo "Running migration ALTERs..."
duckdb "$DB" -c "
  ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS tool_use_id VARCHAR;
  ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS backfilled BOOLEAN DEFAULT false;
"

echo "Running backfill..."
duckdb "$DB" -c "
  WITH windowed AS (
    SELECT
      ar.id,
      ar.started_at,
      ar.session_id,
      LEAD(ar.started_at) OVER (
        PARTITION BY ar.session_id ORDER BY ar.started_at
      ) AS next_started_at,
      s.ended_at AS sess_ended_at
    FROM agent_runs ar
    LEFT JOIN sessions s ON s.session_id = ar.session_id
    WHERE ar.status = 'running'
      AND (ar.backfilled IS NULL OR ar.backfilled = false)
  )
  UPDATE agent_runs
  SET
    ended_at = CASE
      WHEN w.next_started_at IS NOT NULL
        THEN LEAST(w.next_started_at, w.started_at + INTERVAL 600 SECOND)
      WHEN w.sess_ended_at IS NOT NULL AND w.sess_ended_at > w.started_at
        THEN LEAST(w.sess_ended_at, w.started_at + INTERVAL 600 SECOND)
      ELSE
        w.started_at + INTERVAL 60 SECOND
    END,
    duration_sec = EXTRACT(EPOCH FROM (
      CASE
        WHEN w.next_started_at IS NOT NULL
          THEN LEAST(w.next_started_at, w.started_at + INTERVAL 600 SECOND)
        WHEN w.sess_ended_at IS NOT NULL AND w.sess_ended_at > w.started_at
          THEN LEAST(w.sess_ended_at, w.started_at + INTERVAL 600 SECOND)
        ELSE
          w.started_at + INTERVAL 60 SECOND
      END - w.started_at
    )),
    status = 'done',
    backfilled = true
  FROM windowed w
  WHERE agent_runs.id = w.id;
"

echo ""
echo "Summary after backfill:"
duckdb "$DB" -c "
  SELECT status, backfilled, COUNT(*) AS n
  FROM agent_runs
  GROUP BY status, backfilled
  ORDER BY status, backfilled;
"
