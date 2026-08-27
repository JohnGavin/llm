#!/usr/bin/env bash
# error_events_staging_import.sh — drain error_events_staging.jsonl into the
# `errors` table (llm#956, #710 follow-up).
#
# WHY: log_session.sh's `error` case used to write to `errors` via the
# duckdb CLI directly, taking the same exclusive whole-file lock documented
# in that script's #710 header (see session_events_staging_import.sh's
# header for the concurrency evidence — same root cause, same fix pattern,
# different table). This script drains the lock-free JSONL staging file into
# `errors` at ETL cadence. Called from roborev_metrics_etl.sh right next to
# the other staging imports.
#
# `errors` is a plain append-only log (auto-increment `id`, no natural
# unique key), so idempotency is achieved the same way as hook_events: an
# INSERT ... WHERE NOT EXISTS content-match dedupe on
# (session_id, source, error_text, context, logged_at truncated to the
# second) — re-importing the same file never re-inserts the same event.
#
# Errors are NOT silenced on the critical write — see
# session_events_staging_import.sh's header for the rationale (this is the
# same #956 fix, applied to errors instead of sessions).
#
# Usage:
#   error_events_staging_import.sh [db_path] [staging_path]
#
#   db_path        Defaults to ~/.claude/logs/unified.duckdb
#   staging_path   Defaults to ~/.claude/logs/error_events_staging.jsonl
#                  (override for tests against a scratch DB/staging file)
#
# Tracked in llm#956.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_PATH="${1:-$HOME/.claude/logs/unified.duckdb}"
STAGING="${2:-$HOME/.claude/logs/error_events_staging.jsonl}"
LOGFILE="${HOME}/.claude/logs/error_events_staging_import.log"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} error_events_staging_import: $*"
  echo "${ts} error_events_staging_import: $*" >> "$LOGFILE" 2>/dev/null || true
}

if ! command -v duckdb >/dev/null 2>&1; then
  log "SKIP (duckdb not on PATH)"
  exit 0
fi

# ── Ensure schema (defensive; should already exist via unified_log_init.sql) ─
duckdb -init /dev/null "${DB_PATH}" -c "
  CREATE SEQUENCE IF NOT EXISTS error_seq START 1;
  CREATE TABLE IF NOT EXISTS errors (
    id INTEGER PRIMARY KEY DEFAULT nextval('error_seq'),
    session_id VARCHAR,
    source VARCHAR,
    error_text VARCHAR,
    context VARCHAR,
    logged_at TIMESTAMP DEFAULT current_timestamp
  );
" 2>/dev/null || log "WARN schema ensure failed (non-fatal)"

if [ ! -f "${STAGING}" ] || [ ! -s "${STAGING}" ]; then
  log "SKIP (no pending events in staging: ${STAGING})"
  exit 0
fi

_IMPORT="${STAGING}.import_$(date +%s)_$$"
mv "${STAGING}" "${_IMPORT}" 2>/dev/null || { log "WARN mv failed (non-fatal)"; exit 0; }

_err_out=$(duckdb -init /dev/null "${DB_PATH}" -c "
  INSERT INTO errors (session_id, source, error_text, context, logged_at)
  SELECT s.session_id, s.source, s.error_text, s.context, s.ts
  FROM (
    SELECT session_id, source, error_text, context, CAST(ts AS TIMESTAMP) AS ts
    FROM read_json(
      '${_IMPORT}',
      format = 'newline_delimited',
      columns = {ts: 'VARCHAR', session_id: 'VARCHAR', source: 'VARCHAR',
                 error_text: 'VARCHAR', context: 'VARCHAR'},
      ignore_errors = true
    )
    WHERE session_id IS NOT NULL
  ) s
  WHERE NOT EXISTS (
    SELECT 1 FROM errors e
    WHERE e.session_id = s.session_id
      AND COALESCE(e.source,'') = COALESCE(s.source,'')
      AND COALESCE(e.error_text,'') = COALESCE(s.error_text,'')
      AND COALESCE(e.context,'') = COALESCE(s.context,'')
      AND date_trunc('second', e.logged_at) = date_trunc('second', s.ts)
  );
" 2>&1)
_rc=$?

if [ "$_rc" -ne 0 ]; then
  echo "ERROR: error_events_staging_import: duckdb write failed (exit=${_rc}): ${_err_out}" >&2
  log "ERROR: duckdb write failed (exit=${_rc}) detail=${_err_out}"
  # Preserve the batch instead of deleting it (see session_events_staging_
  # import.sh's failure-path comment for the rationale) so a failed write
  # never also destroys the only copy of the data it failed to write.
  mv "${_IMPORT}" "${_IMPORT}.failed" 2>/dev/null || true
  log "ERROR: batch preserved at ${_IMPORT}.failed for manual retry"
  exit 1
fi

rm -f "${_IMPORT}" 2>/dev/null || true
log "import done"

# ── etl_freshness registration (llm#309 Phase 1a): `errors` was never
# tracked in the registry before this fix (its writer was the same
# unwired-until-#956 direct-duckdb path) — add it now that it has a durable
# writer, for the same read-time staleness view every other source uses. ────
_FRESHNESS_HELPER="${SCRIPT_DIR}/etl_freshness_upsert.sh"
if [ -x "${_FRESHNESS_HELPER}" ]; then
  "${_FRESHNESS_HELPER}" errors "${DB_PATH}" "" --table errors --ts-col logged_at 2>/dev/null \
    || log "WARN etl_freshness_upsert failed (non-fatal)"
fi

exit 0
