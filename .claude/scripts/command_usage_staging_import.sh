#!/usr/bin/env bash
# command_usage_staging_import.sh — drain command_usage_staging.jsonl into
# command_usage.
#
# Card 1e (own-your-context plan, #745). Companion to
# .claude/hooks/log_command_use.sh: the hook stages one JSON line per
# slash-command invocation (no duckdb CLI, no lock contention — mirrors
# skill_usage_staging_import.sh / log_session.sh #710). This script imports
# the staging file into the `command_usage` table on the same cadence as
# the rest of the ETL — called from roborev_metrics_etl.sh right next to
# the skill_usage staging import, using the identical atomic-handoff
# pattern (mv staging file aside before reading it, so new events during
# the import land in a fresh file).
#
# Schema mirrors skill_usage exactly (session_id, command_name,
# project_path, args_hash, ts, backfilled) — see backfill_command_usage.R
# for the historical counterpart that writes the same shape.
#
# etl_freshness coordination (#309 Card 1a): if the shared
# etl_freshness_upsert.sh helper is present alongside this script, use it;
# otherwise fall back to an inline CREATE TABLE IF NOT EXISTS + INSERT OR
# REPLACE with the identical schema.
#
# Usage:
#   command_usage_staging_import.sh [db_path] [staging_path]
#
#   db_path        Defaults to ~/.claude/logs/unified.duckdb
#   staging_path   Defaults to ~/.claude/logs/command_usage_staging.jsonl
#                  (override for tests against a scratch DB/staging file)
#
# Idempotent: dedupes on (session_id, command_name, ts, args_hash) at
# insert time via NOT EXISTS, so re-running against a leftover import file
# is a no-op. args_hash is compared with COALESCE(..., '') = COALESCE(..., '')
# so NULL (backfill's hash_args() for a no-args command) and '' (the hook's
# args_hash for a no-args command) are treated as the SAME value — otherwise
# IS NOT DISTINCT FROM would treat NULL and '' as distinct and double-count
# every no-args command re-seen across the two writers (#747 review). Two
# invocations differing only in actual (non-empty) args are still never
# conflated into one row.
# Non-fatal: never aborts the caller — always exits 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_PATH="${1:-$HOME/.claude/logs/unified.duckdb}"
STAGING="${2:-$HOME/.claude/logs/command_usage_staging.jsonl}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') command_usage_staging_import: $*"; }

if ! command -v duckdb >/dev/null 2>&1; then
  log "SKIP (duckdb not on PATH)"
  exit 0
fi

# ── Ensure schema (additive; mirrors skill_usage) ───────────────────────────
duckdb -init /dev/null "${DB_PATH}" -c "
  CREATE TABLE IF NOT EXISTS command_usage (
    session_id   VARCHAR,
    command_name VARCHAR,
    project_path VARCHAR,
    args_hash    VARCHAR,
    ts           TIMESTAMP,
    backfilled   BOOLEAN DEFAULT FALSE
  );
" 2>/dev/null || { log "WARN schema ensure failed (non-fatal)"; }

# ── Drain staging file (atomic handoff, mirrors skill_usage import) ─────────
if [ ! -f "${STAGING}" ] || [ ! -s "${STAGING}" ]; then
  log "SKIP (no pending events in staging: ${STAGING})"
  exit 0
fi

_IMPORT="${STAGING}.import_$(date +%s)_$$"
mv "${STAGING}" "${_IMPORT}" 2>/dev/null || { log "WARN mv failed (non-fatal)"; exit 0; }

if [ -f "${_IMPORT}" ]; then
  duckdb -init /dev/null "${DB_PATH}" -c "
    INSERT INTO command_usage (session_id, command_name, project_path, args_hash, ts, backfilled)
    SELECT
      s.session_id,
      s.command_name,
      s.project_path,
      s.args_hash,
      CAST(s.ts AS TIMESTAMP) AS ts,
      FALSE
    FROM read_json(
      '${_IMPORT}',
      format        = 'newline_delimited',
      columns       = {ts: 'VARCHAR', session_id: 'VARCHAR', command_name: 'VARCHAR',
                       project_path: 'VARCHAR', args_hash: 'VARCHAR'},
      ignore_errors = true
    ) AS s
    WHERE s.session_id IS NOT NULL AND s.command_name IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM command_usage u
        WHERE u.session_id = s.session_id
          AND u.command_name = s.command_name
          AND date_trunc('second', u.ts) = date_trunc('second', CAST(s.ts AS TIMESTAMP))
          AND COALESCE(u.args_hash, '') = COALESCE(s.args_hash, '')
      );
  " 2>/dev/null || log "WARN duckdb insert failed (non-fatal)"
  rm -f "${_IMPORT}" 2>/dev/null || true
  log "import done"
fi

# ── etl_freshness registration (defensive re: #309 Card 1a coordination) ────
_FRESHNESS_HELPER="${SCRIPT_DIR}/etl_freshness_upsert.sh"
if [ -x "${_FRESHNESS_HELPER}" ]; then
  # Event-driven source, no SLA -> empty cadence -> status='unknown' (helper
  # semantics: empty/non-numeric cadence => NULL => 'unknown').
  "${_FRESHNESS_HELPER}" command_usage "${DB_PATH}" "" --table command_usage --ts-col ts 2>/dev/null || true
else
  duckdb -init /dev/null "${DB_PATH}" -c "
    CREATE TABLE IF NOT EXISTS etl_freshness (
      source_name            VARCHAR PRIMARY KEY,
      last_row_ts             TIMESTAMP,
      last_etl_run_ts         TIMESTAMP,
      expected_cadence_hours  DOUBLE,
      status                  VARCHAR
    );
    INSERT OR REPLACE INTO etl_freshness
      (source_name, last_row_ts, last_etl_run_ts, expected_cadence_hours, status)
    SELECT
      'command_usage',
      (SELECT MAX(ts) FROM command_usage),
      current_timestamp,
      NULL,
      'unknown';
  " 2>/dev/null || log "WARN etl_freshness upsert failed (non-fatal)"
fi

exit 0
