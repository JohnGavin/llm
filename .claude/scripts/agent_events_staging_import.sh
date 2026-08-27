#!/usr/bin/env bash
# agent_events_staging_import.sh — drain agent_events_staging.jsonl into the
# `agent_runs` table (llm#956, #710 follow-up).
#
# WHY: log_session.sh's `agent_start`/`agent_stop` cases used to write to
# `agent_runs` via the duckdb CLI directly, taking the same exclusive
# whole-file lock documented in that script's #710 header (see
# session_events_staging_import.sh's header for the concurrency evidence —
# same root cause, same fix pattern, different table). This script drains
# the lock-free JSONL staging file into `agent_runs` at ETL cadence. Called
# from roborev_metrics_etl.sh right next to the other staging imports.
#
# Matching logic replicates the ORIGINAL log_session.sh `agent_start`/
# `agent_stop` three-tier semantics, applied at import time instead of live:
#
#   Phase 1a (agent_start, tool_use_id present): insert a new 'running' row,
#     deduped by NOT EXISTS(tool_use_id) so re-importing the same file never
#     creates a second row for the same dispatch.
#   Phase 1b (agent_start, tool_use_id absent): insert deduped by content
#     match (session_id, agent_type, started_at truncated to the second) —
#     mirrors the hook_events dedup pattern for callers with no natural key.
#   Phase 2a (agent_stop, tool_use_id present): UPDATE the row with that
#     tool_use_id WHERE status='running'. The status='running' guard is what
#     makes this idempotent: re-running the same stop event against an
#     already-stopped row matches zero rows and is a clean no-op — it does
#     NOT reach the phase 3 fallback (see below), so it never inserts twice.
#   Phase 2b (agent_stop, tool_use_id absent): UPDATE the LATEST running row
#     for (session_id, agent_type) — mirrors the original code's second-tier
#     fallback match.
#   Phase 3 (agent_stop, tool_use_id present, but NO row exists anywhere with
#     that tool_use_id): insert a minimal 'inherited' row, mirroring the
#     original code's last-resort INSERT for a stop event with no matching
#     start. Deduped by NOT EXISTS(tool_use_id), so this is also idempotent
#     on replay — once inserted, that tool_use_id exists, so a second import
#     of the same file finds it in Phase 2a instead (WHERE status='running'
#     no longer matches, since phase 3 set status to the stop's final value,
#     not 'running' — so it's a no-op, not a second insert).
#
#   NOT implemented: the equivalent phase-3 fallback for tool_use_id-ABSENT
#   agent_stop events with no matching running row. In current production
#   the only caller (log_agent_run.sh) always supplies tool_use_id from the
#   hook payload, so this path is a rare defensive branch in the original
#   code and was dropped here to keep the import logic provably idempotent
#   rather than replicate a branch that cannot be exercised by the current
#   caller. Such an event is logged (non-fatal) as an orphan-drop; see
#   `log()` output. Flagged here for anyone re-auditing this file.
#
# Errors are NOT silenced on the critical write — see
# session_events_staging_import.sh's header for the rationale (this is the
# same #956 fix, applied to agent_runs instead of sessions).
#
# Usage:
#   agent_events_staging_import.sh [db_path] [staging_path]
#
#   db_path        Defaults to ~/.claude/logs/unified.duckdb
#   staging_path   Defaults to ~/.claude/logs/agent_events_staging.jsonl
#                  (override for tests against a scratch DB/staging file)
#
# Tracked in llm#956.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_PATH="${1:-$HOME/.claude/logs/unified.duckdb}"
STAGING="${2:-$HOME/.claude/logs/agent_events_staging.jsonl}"
LOGFILE="${HOME}/.claude/logs/agent_events_staging_import.log"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} agent_events_staging_import: $*"
  echo "${ts} agent_events_staging_import: $*" >> "$LOGFILE" 2>/dev/null || true
}

if ! command -v duckdb >/dev/null 2>&1; then
  log "SKIP (duckdb not on PATH)"
  exit 0
fi

# ── Ensure schema (defensive; should already exist via unified_log_init.sql
# + migrate_agent_runs_270.sql) ─────────────────────────────────────────────
duckdb -init /dev/null "${DB_PATH}" -c "
  CREATE SEQUENCE IF NOT EXISTS agent_seq START 1;
  CREATE TABLE IF NOT EXISTS agent_runs (
    id INTEGER PRIMARY KEY DEFAULT nextval('agent_seq'),
    session_id VARCHAR,
    agent_type VARCHAR,
    model VARCHAR,
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    duration_sec DOUBLE,
    prompt_preview VARCHAR,
    status VARCHAR DEFAULT 'running'
  );
  ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS tool_use_id VARCHAR;
  ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS backfilled BOOLEAN DEFAULT false;
  -- llm#1045: dispatch_id/parent_dispatch_id/outcome -- see
  -- migrate_agent_runs_1045.sql for the full rationale. Mirrored here so a
  -- fresh DB or a staging replay acquires these columns without depending
  -- on the one-time migration having run first.
  ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS dispatch_id VARCHAR;
  ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS parent_dispatch_id VARCHAR;
  ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS outcome VARCHAR;
" 2>/dev/null || log "WARN schema ensure failed (non-fatal)"

if [ ! -f "${STAGING}" ] || [ ! -s "${STAGING}" ]; then
  log "SKIP (no pending events in staging: ${STAGING})"
  exit 0
fi

_IMPORT="${STAGING}.import_$(date +%s)_$$"
mv "${STAGING}" "${_IMPORT}" 2>/dev/null || { log "WARN mv failed (non-fatal)"; exit 0; }

_COLS="{type: 'VARCHAR', ts: 'VARCHAR', session_id: 'VARCHAR', agent_type: 'VARCHAR', model: 'VARCHAR', prompt_preview: 'VARCHAR', status: 'VARCHAR', tool_use_id: 'VARCHAR'}"

_err_out=$(duckdb -init /dev/null "${DB_PATH}" -c "
  -- Phase 1a: agent_start WITH tool_use_id -> insert if no row has that tool_use_id
  INSERT INTO agent_runs (session_id, agent_type, model, started_at, prompt_preview, status, tool_use_id)
  SELECT x.session_id, x.agent_type, x.model, CAST(x.ts AS TIMESTAMP), x.prompt_preview, 'running', x.tool_use_id
  FROM (
    SELECT *, row_number() OVER (PARTITION BY tool_use_id ORDER BY ts DESC) AS rn
    FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
    WHERE type = 'agent_start' AND session_id IS NOT NULL AND NULLIF(tool_use_id,'') IS NOT NULL
  ) x
  WHERE x.rn = 1
    AND NOT EXISTS (SELECT 1 FROM agent_runs ar WHERE ar.tool_use_id = x.tool_use_id);

  -- Phase 1b: agent_start WITHOUT tool_use_id -> content-dedupe insert
  INSERT INTO agent_runs (session_id, agent_type, model, started_at, prompt_preview, status, tool_use_id)
  SELECT x.session_id, x.agent_type, x.model, CAST(x.ts AS TIMESTAMP), x.prompt_preview, 'running', NULL
  FROM (
    SELECT *, row_number() OVER (PARTITION BY session_id, agent_type, ts ORDER BY ts DESC) AS rn
    FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
    WHERE type = 'agent_start' AND session_id IS NOT NULL AND NULLIF(tool_use_id,'') IS NULL
  ) x
  WHERE x.rn = 1
    AND NOT EXISTS (
      SELECT 1 FROM agent_runs ar
      WHERE ar.session_id = x.session_id AND ar.agent_type = x.agent_type
        AND ar.tool_use_id IS NULL
        AND date_trunc('second', ar.started_at) = date_trunc('second', CAST(x.ts AS TIMESTAMP))
    );

  -- Phase 2a: agent_stop WITH tool_use_id -> update matching running row
  UPDATE agent_runs SET
    ended_at = s.stop_ts,
    duration_sec = EXTRACT(EPOCH FROM (s.stop_ts - agent_runs.started_at)),
    status = s.status
  FROM (
    SELECT tool_use_id, status, stop_ts FROM (
      SELECT tool_use_id, status, CAST(ts AS TIMESTAMP) AS stop_ts,
             row_number() OVER (PARTITION BY tool_use_id ORDER BY ts DESC) AS rn
      FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
      WHERE type = 'agent_stop' AND session_id IS NOT NULL AND NULLIF(tool_use_id,'') IS NOT NULL
    ) WHERE rn = 1
  ) s
  WHERE agent_runs.tool_use_id = s.tool_use_id
    AND agent_runs.status = 'running';

  -- Phase 2b: agent_stop WITHOUT tool_use_id -> update latest running row for (session_id, agent_type)
  UPDATE agent_runs SET
    ended_at = s.stop_ts,
    duration_sec = EXTRACT(EPOCH FROM (s.stop_ts - agent_runs.started_at)),
    status = s.status
  FROM (
    SELECT session_id, agent_type, status, stop_ts FROM (
      SELECT session_id, agent_type, status, CAST(ts AS TIMESTAMP) AS stop_ts,
             row_number() OVER (PARTITION BY session_id, agent_type ORDER BY ts DESC) AS rn
      FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
      WHERE type = 'agent_stop' AND session_id IS NOT NULL AND NULLIF(tool_use_id,'') IS NULL
    ) WHERE rn = 1
  ) s
  WHERE agent_runs.id = (
    SELECT ar2.id FROM agent_runs ar2
    WHERE ar2.session_id = s.session_id AND ar2.agent_type = s.agent_type AND ar2.status = 'running'
    ORDER BY ar2.started_at DESC LIMIT 1
  )
  AND agent_runs.status = 'running';

  -- Phase 3: agent_stop WITH tool_use_id but NO row exists at all with that id -> orphan insert
  INSERT INTO agent_runs (session_id, agent_type, model, started_at, ended_at, duration_sec, prompt_preview, status, tool_use_id)
  SELECT x.session_id, x.agent_type, 'inherited', x.stop_ts, x.stop_ts, 0, x.prompt_preview, x.status, x.tool_use_id
  FROM (
    SELECT *, row_number() OVER (PARTITION BY tool_use_id ORDER BY ts DESC) AS rn
    FROM (
      SELECT session_id, agent_type, prompt_preview, status, tool_use_id, ts, CAST(ts AS TIMESTAMP) AS stop_ts
      FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
      WHERE type = 'agent_stop' AND session_id IS NOT NULL AND NULLIF(tool_use_id,'') IS NOT NULL
    )
  ) x
  WHERE x.rn = 1
    AND NOT EXISTS (SELECT 1 FROM agent_runs ar WHERE ar.tool_use_id = x.tool_use_id);
" 2>&1)
_rc=$?

if [ "$_rc" -ne 0 ]; then
  echo "ERROR: agent_events_staging_import: duckdb write failed (exit=${_rc}): ${_err_out}" >&2
  log "ERROR: duckdb write failed (exit=${_rc}) detail=${_err_out}"
  # Preserve the batch instead of deleting it (see session_events_staging_
  # import.sh's failure-path comment for the rationale) so a failed write
  # never also destroys the only copy of the data it failed to write.
  mv "${_IMPORT}" "${_IMPORT}.failed" 2>/dev/null || true
  log "ERROR: batch preserved at ${_IMPORT}.failed for manual retry"
  exit 1
fi

# Visibility for the one intentionally-unhandled edge case (see header):
# agent_stop with NO tool_use_id and no matching running row anywhere.
_orphan_dropped=$(duckdb -init /dev/null -noheader -list "${DB_PATH}" -c "
  SELECT count(*) FROM (
    SELECT session_id, agent_type,
           row_number() OVER (PARTITION BY session_id, agent_type ORDER BY ts DESC) AS rn
    FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
    WHERE type = 'agent_stop' AND session_id IS NOT NULL AND NULLIF(tool_use_id,'') IS NULL
  ) x
  WHERE x.rn = 1
    AND NOT EXISTS (
      SELECT 1 FROM agent_runs ar
      WHERE ar.session_id = x.session_id AND ar.agent_type = x.agent_type AND ar.status <> 'running'
    );
" 2>/dev/null || echo "")
if [ -n "$_orphan_dropped" ] && [ "$_orphan_dropped" != "0" ]; then
  log "NOTE: ${_orphan_dropped} tool_use_id-less agent_stop event(s) with no matching running row were dropped (see header 'NOT implemented')"
fi

rm -f "${_IMPORT}" 2>/dev/null || true
log "import done"

# ── etl_freshness registration (llm#309 Phase 1a): update AFTER the write
# actually lands -- see session_events_staging_import.sh header for why this
# moved out of the synchronous `agent_stop` hook path. ──────────────────────
_FRESHNESS_HELPER="${SCRIPT_DIR}/etl_freshness_upsert.sh"
if [ -x "${_FRESHNESS_HELPER}" ]; then
  "${_FRESHNESS_HELPER}" agent_runs "${DB_PATH}" "" --table agent_runs --ts-col started_at 2>/dev/null \
    || log "WARN etl_freshness_upsert failed (non-fatal)"
fi

exit 0
