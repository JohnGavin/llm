#!/usr/bin/env bash
# skill_usage_staging_import.sh — drain skill_usage_staging.jsonl into skill_usage.
#
# Card 1b (own-your-context plan). Companion to .claude/hooks/log_skill_use.sh:
# the hook stages one JSON line per Skill-tool invocation (no duckdb CLI, no
# lock contention — see the hook's header comment / log_session.sh #710).
# This script imports the staging file into the `skill_usage` table on the
# same cadence as the rest of the ETL — it is called from
# roborev_metrics_etl.sh right next to the existing hook_events staging
# import, using the identical atomic-handoff pattern (mv staging file aside
# before reading it, so new events during the import land in a fresh file).
#
# Schema note: skill_usage ALREADY exists in production with an older,
# session-aggregated shape (session_id, session_date, project, skill_name,
# invocations, etl_run_at) written by skill_usage_etl.R. This script does
# NOT replace that table — it ADDS the new event-level columns
# (project_path, args_hash, ts, backfilled) alongside the legacy ones via
# `ADD COLUMN IF NOT EXISTS`, so both writers coexist: legacy rows keep their
# columns NULL for the new fields, and new-style rows keep session_date/
# project/invocations/etl_run_at NULL. See backfill_skill_usage.R for the
# historical counterpart that also writes this event-level shape.
#
# etl_freshness coordination (#309 Card 1a, may not be merged yet): if the
# shared etl_freshness_upsert.sh helper is present alongside this script, we
# use it (it already implements the exact upsert semantics for an
# event-driven/no-SLA source). If it is NOT present (1a not yet merged into
# this branch), we fall back to an inline CREATE TABLE IF NOT EXISTS + INSERT
# OR REPLACE with the identical schema, so this script works standalone
# either way and never conflicts once 1a lands.
#
# Usage:
#   skill_usage_staging_import.sh [db_path] [staging_path]
#
#   db_path        Defaults to ~/.claude/logs/unified.duckdb
#   staging_path   Defaults to ~/.claude/logs/skill_usage_staging.jsonl
#                  (override for tests against a scratch DB/staging file)
#
# Idempotent: dedupes on (session_id, skill_name, ts) at insert time via
# NOT EXISTS, so re-running against a leftover import file is a no-op.
# Non-fatal: never aborts the caller — always exits 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_PATH="${1:-$HOME/.claude/logs/unified.duckdb}"
STAGING="${2:-$HOME/.claude/logs/skill_usage_staging.jsonl}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') skill_usage_staging_import: $*"; }

if ! command -v duckdb >/dev/null 2>&1; then
  log "SKIP (duckdb not on PATH)"
  exit 0
fi

# ── Ensure schema (additive; safe against the legacy skill_usage_etl.R table) ─
duckdb -init /dev/null "${DB_PATH}" -c "
  CREATE TABLE IF NOT EXISTS skill_usage (
    session_id   VARCHAR,
    skill_name   VARCHAR,
    project_path VARCHAR,
    args_hash    VARCHAR,
    ts           TIMESTAMP,
    backfilled   BOOLEAN DEFAULT FALSE
  );
  ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS project_path VARCHAR;
  ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS args_hash    VARCHAR;
  ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS ts           TIMESTAMP;
  ALTER TABLE skill_usage ADD COLUMN IF NOT EXISTS backfilled   BOOLEAN DEFAULT FALSE;
" 2>/dev/null || { log "WARN schema ensure failed (non-fatal)"; }

# ── Drain staging file (atomic handoff, mirrors hook_events import) ──────────
if [ ! -f "${STAGING}" ] || [ ! -s "${STAGING}" ]; then
  log "SKIP (no pending events in staging: ${STAGING})"
  exit 0
fi

_IMPORT="${STAGING}.import_$(date +%s)_$$"
mv "${STAGING}" "${_IMPORT}" 2>/dev/null || { log "WARN mv failed (non-fatal)"; exit 0; }

if [ -f "${_IMPORT}" ]; then
  duckdb -init /dev/null "${DB_PATH}" -c "
    INSERT INTO skill_usage (session_id, skill_name, project_path, args_hash, ts, backfilled)
    SELECT
      s.session_id,
      s.skill_name,
      s.project_path,
      s.args_hash,
      CAST(s.ts AS TIMESTAMP) AS ts,
      FALSE
    FROM read_json(
      '${_IMPORT}',
      format        = 'newline_delimited',
      columns       = {ts: 'VARCHAR', session_id: 'VARCHAR', skill_name: 'VARCHAR',
                       project_path: 'VARCHAR', args_hash: 'VARCHAR'},
      ignore_errors = true
    ) AS s
    WHERE s.session_id IS NOT NULL AND s.skill_name IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM skill_usage u
        WHERE u.session_id = s.session_id
          AND u.skill_name = s.skill_name
          AND date_trunc('second', u.ts) = date_trunc('second', CAST(s.ts AS TIMESTAMP))
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
  "${_FRESHNESS_HELPER}" skill_usage "${DB_PATH}" "" --table skill_usage --ts-col ts 2>/dev/null || true
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
      'skill_usage',
      (SELECT MAX(ts) FROM skill_usage),
      current_timestamp,
      NULL,
      'unknown';
  " 2>/dev/null || log "WARN etl_freshness upsert failed (non-fatal)"
fi

exit 0
