#!/usr/bin/env bash
# backfill_agent_runs_1045.sh — ONE-OFF backfill for llm#1045.
#
# At the time this issue was filed, `agent_runs.status` was 'running' for 49
# of 553 rows -- historical dispatches whose PostToolUse(Agent) hook never
# fired (killed agent, session ended mid-dispatch, crashed harness), stuck
# stale since before the ongoing agent_runs_reaper.sql sweep existed. This
# script applies the SAME rule as agent_runs_reaper.sql (see that file for
# the full staleness-threshold rationale) once, against the existing
# backlog, prints before/after counts, and -- unlike backfill_ended_at_803.sh
# -- ALSO records a `data_quality_incidents` row documenting the backfill
# window, per the llm#803 precedent this issue explicitly cites.
#
# Modes:
#   (no flag)   DRY RUN (default) -- prints what would change; makes no writes.
#   --apply     Applies the reaper SQL to the given DB, then inserts the
#               `data_quality_incidents` row.
#
# This is NOT wired into any hook and does not run automatically -- it is a
# manual, one-off remediation. Re-running with --apply is harmless: the
# reaper's WHERE clause only matches 'running' rows past the threshold (once
# reaped, status='unknown' no longer matches), and the incident insert is
# `INSERT OR IGNORE` on a fixed id.
#
# Usage:
#   backfill_agent_runs_1045.sh [--apply] [path-to-unified.duckdb]
#
#   Default DB path: ~/.claude/logs/unified.duckdb
#
# Validate first against a scratch copy, e.g.:
#   cp ~/.claude/logs/unified.duckdb /tmp/agent_runs_test.duckdb
#   backfill_agent_runs_1045.sh --apply /tmp/agent_runs_test.duckdb
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER_SQL="${SCRIPT_DIR}/agent_runs_reaper.sql"

APPLY=0
DB="${HOME}/.claude/logs/unified.duckdb"
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    *) DB="$arg" ;;
  esac
done

if [ ! -f "$DB" ]; then
  echo "ERROR: DB not found at $DB" >&2
  exit 1
fi
if [ ! -f "$REAPER_SQL" ]; then
  echo "ERROR: SQL file not found at $REAPER_SQL" >&2
  exit 1
fi
if ! command -v duckdb >/dev/null 2>&1; then
  echo "ERROR: duckdb not on PATH. Run via: nix-shell <llm>/default.nix --run '$0 $*'" >&2
  exit 1
fi

echo "== Before =="
duckdb -init /dev/null "$DB" -c "
  SELECT COUNT(*) AS total,
         SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running_now,
         SUM(CASE WHEN status = 'running'
                   AND started_at < current_timestamp - INTERVAL 4 HOUR
                  THEN 1 ELSE 0 END) AS stale_running
  FROM agent_runs;
"

if [ "$APPLY" -ne 1 ]; then
  echo "== DRY RUN: would apply agent_runs_reaper.sql (rerun with --apply to write) =="
  duckdb -init /dev/null -readonly "$DB" -c "
    SELECT id, session_id, agent_type, started_at
    FROM agent_runs
    WHERE status = 'running'
      AND started_at < current_timestamp - INTERVAL 4 HOUR
    ORDER BY started_at;
  "
  exit 0
fi

echo "== Backing up DB before write =="
BACKUP="${DB}.bak-1045-$(date +%Y%m%d_%H%M%S)"
cp "$DB" "$BACKUP"
echo "Backup: $BACKUP"

echo "== Applying backfill (agent_runs_reaper.sql rule) =="
# Capture the affected window BEFORE the reaper mutates status, so
# window_start reflects the true earliest affected started_at.
_WINDOW_START=$(duckdb -init /dev/null -readonly -noheader -list "$DB" -c "
  SELECT MIN(started_at) FROM agent_runs
  WHERE status = 'running' AND started_at < current_timestamp - INTERVAL 4 HOUR;
")
_WINDOW_START=$(echo "$_WINDOW_START" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

duckdb -init /dev/null "$DB" -c ".read '${REAPER_SQL}'"

if [ -z "$_WINDOW_START" ] || [ "$_WINDOW_START" = "NULL" ]; then
  echo "== No stale rows found this run (already reaped, or none exist) -- skipping data_quality_incidents insert =="
  echo "== After =="
  duckdb -init /dev/null "$DB" -c "
    SELECT COUNT(*) AS total,
           SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running_now,
           SUM(CASE WHEN status = 'unknown' THEN 1 ELSE 0 END) AS unknown_now
    FROM agent_runs;
  "
  echo "== Existing data_quality_incidents row (if any from a prior --apply) =="
  duckdb -init /dev/null -readonly "$DB" -c "
    SELECT id, asset, column_name, window_start, window_end, issue_ref
    FROM data_quality_incidents WHERE issue_ref LIKE '%1045%';
  "
  exit 0
fi

echo "== After =="
duckdb -init /dev/null "$DB" -c "
  SELECT COUNT(*) AS total,
         SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running_now,
         SUM(CASE WHEN status = 'unknown' THEN 1 ELSE 0 END) AS unknown_now
  FROM agent_runs;
"

echo "== Recording data_quality_incidents row (llm#1045 precedent: llm#803) =="
duckdb -init /dev/null "$DB" -c "
  INSERT OR IGNORE INTO data_quality_incidents
    (id, asset, column_name, window_start, window_end, reason, issue_ref, recorded_at)
  VALUES (
    'llm1045-agent_runs-status-backfill',
    'agent_runs',
    'status',
    TIMESTAMP '${_WINDOW_START}',
    current_timestamp,
    'agent_runs_reaper.sql (llm#1045) backfilled status = ''unknown'' for rows stuck at ''running'' with no agent_stop event observed within 4h (PostToolUse(Agent) hook never fired -- killed agent, session ended mid-dispatch, or crashed harness). These rows'' actual termination outcome is NOT observed; do not treat status=''unknown'' as either success or failure.',
    'llm#1045',
    current_timestamp
  );
"

echo "== data_quality_incidents row =="
duckdb -init /dev/null -readonly "$DB" -c "
  SELECT id, asset, column_name, window_start, window_end, issue_ref
  FROM data_quality_incidents WHERE issue_ref LIKE '%1045%';
"

echo "== Sanity check: any ended_at < started_at? (expect 0) =="
duckdb -init /dev/null -readonly "$DB" -c "
  SELECT COUNT(*) AS bad_rows FROM agent_runs WHERE ended_at < started_at;
"
