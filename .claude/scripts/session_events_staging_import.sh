#!/usr/bin/env bash
# session_events_staging_import.sh — drain session_events_staging.jsonl into
# the `sessions` table (llm#956, #710 follow-up).
#
# WHY: log_session.sh's `start`/`stop` cases used to write to `sessions` via
# the duckdb CLI directly, taking the same exclusive whole-file lock
# documented in that script's #710 header. A throwaway-DB experiment (12
# concurrent duckdb-CLI writers) landed only 1 write; the other 11 failed
# with "IO Error: Could not set lock on file ... Conflicting lock is held".
# That error was suppressed THREE times over at the call site: `2>/dev/null`,
# `|| true`, and the caller backgrounding the whole hook with `nohup ... &`.
# This script is the other half of the #710 pattern (mirrors
# hook_events_load.sh / skill_usage_staging_import.sh /
# command_usage_staging_import.sh): drain the lock-free JSONL staging file
# into `sessions` at ETL cadence, when contention is lower. Called from
# roborev_metrics_etl.sh right next to the other staging imports.
#
# Two-phase within one import file — start rows first, then stop rows — so a
# session that both starts AND stops inside one ETL window lands correctly:
#
#   Phase 1 (start): INSERT OR REPLACE, keyed on session_id (PRIMARY KEY).
#     This mirrors the ORIGINAL log_session.sh `start` semantics exactly: a
#     second `start` for the same session_id resets ended_at/duration_min/
#     burn_status/orphans_killed to their defaults, same as the pre-#956
#     direct-duckdb `INSERT OR REPLACE` did — NOT a new behavior.
#   Phase 2 (stop): UPDATE ... SET ended_at/duration_min/summary/model, using
#     the SAME COALESCE(NULLIF(new,''), existing) guard the original `stop`
#     case used, so a blank staged model/summary never clobbers a value
#     recorded by an earlier stop.
#
# Only the LATEST staged row per session_id per phase is applied
# (row_number() OVER (PARTITION BY session_id ORDER BY ts DESC) = 1), so a
# stray duplicate event never fights itself for "last write wins". This also
# makes re-importing the SAME file idempotent: replaying phase 1 then phase 2
# against identical input rows reproduces the same final state — phase 1's
# INSERT OR REPLACE is deterministic given the same input, and phase 2's
# UPDATE recomputes the same COALESCE result from the same source values.
#
# Errors are NOT silenced on the critical write: stderr is left connected
# (no `2>/dev/null` on the INSERT/UPDATE itself) and a genuine failure is
# echoed with an "ERROR:" prefix to both stderr and this script's log file,
# and the script returns non-zero — the caller
# (roborev_metrics_etl.sh) redirects this script's combined stdout+stderr
# into its own log file rather than discarding it, so a human reading that
# log sees the real duckdb error text instead of a swallowed failure. This is
# a deliberate departure from the `2>/dev/null || log "...non-fatal"` pattern
# used elsewhere in this codebase: the ENTIRE reason this bug went unnoticed
# for weeks was triple-suppressed errors, so the fix must not repeat that
# pattern on the import side.
#
# Usage:
#   session_events_staging_import.sh [db_path] [staging_path]
#
#   db_path        Defaults to ~/.claude/logs/unified.duckdb
#   staging_path   Defaults to ~/.claude/logs/session_events_staging.jsonl
#                  (override for tests against a scratch DB/staging file)
#
# Tracked in llm#956.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_PATH="${1:-$HOME/.claude/logs/unified.duckdb}"
STAGING="${2:-$HOME/.claude/logs/session_events_staging.jsonl}"
LOGFILE="${HOME}/.claude/logs/session_events_staging_import.log"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} session_events_staging_import: $*"
  echo "${ts} session_events_staging_import: $*" >> "$LOGFILE" 2>/dev/null || true
}

if ! command -v duckdb >/dev/null 2>&1; then
  log "SKIP (duckdb not on PATH)"
  exit 0
fi

# ── Ensure schema (defensive; should already exist via unified_log_init.sql) ─
duckdb -init /dev/null "${DB_PATH}" -c "
  CREATE TABLE IF NOT EXISTS sessions (
    session_id VARCHAR PRIMARY KEY,
    project VARCHAR,
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    duration_min DOUBLE,
    model VARCHAR,
    burn_status VARCHAR,
    orphans_killed INTEGER DEFAULT 0,
    summary VARCHAR
  );
" 2>/dev/null || log "WARN schema ensure failed (non-fatal)"

if [ ! -f "${STAGING}" ] || [ ! -s "${STAGING}" ]; then
  log "SKIP (no pending events in staging: ${STAGING})"
  exit 0
fi

# ── Atomic hand-off: mv aside before reading, so events written WHILE this
# script runs land in a fresh staging file and are picked up whole next run ──
_IMPORT="${STAGING}.import_$(date +%s)_$$"
mv "${STAGING}" "${_IMPORT}" 2>/dev/null || { log "WARN mv failed (non-fatal)"; exit 0; }

_COLS="{type: 'VARCHAR', ts: 'VARCHAR', session_id: 'VARCHAR', project: 'VARCHAR', summary: 'VARCHAR', model: 'VARCHAR'}"

_err_out=$(duckdb -init /dev/null "${DB_PATH}" -c "
  -- Phase 1: start rows (latest per session_id) -> INSERT OR REPLACE
  INSERT OR REPLACE INTO sessions (session_id, project, started_at, summary, model)
  SELECT session_id, project, CAST(ts AS TIMESTAMP), NULLIF(summary,''), NULLIF(model,'')
  FROM (
    SELECT *, row_number() OVER (PARTITION BY session_id ORDER BY ts DESC) AS rn
    FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
    WHERE type = 'start' AND session_id IS NOT NULL
  ) WHERE rn = 1;

  -- Phase 2: stop rows (latest per session_id) -> UPDATE with COALESCE guard
  UPDATE sessions SET
    ended_at = s.ended_at,
    duration_min = EXTRACT(EPOCH FROM (s.ended_at - sessions.started_at)) / 60.0,
    summary = COALESCE(NULLIF(s.summary,''), sessions.summary),
    model = COALESCE(NULLIF(s.model,''), sessions.model)
  FROM (
    SELECT session_id, ended_at, summary, model FROM (
      SELECT session_id, CAST(ts AS TIMESTAMP) AS ended_at, summary, model,
             row_number() OVER (PARTITION BY session_id ORDER BY ts DESC) AS rn
      FROM read_json('${_IMPORT}', format = 'newline_delimited', columns = ${_COLS}, ignore_errors = true)
      WHERE type = 'stop' AND session_id IS NOT NULL
    ) WHERE rn = 1
  ) AS s
  WHERE sessions.session_id = s.session_id;
" 2>&1)
_rc=$?

if [ "$_rc" -ne 0 ]; then
  echo "ERROR: session_events_staging_import: duckdb write failed (exit=${_rc}): ${_err_out}" >&2
  log "ERROR: duckdb write failed (exit=${_rc}) detail=${_err_out}"
  # Preserve the batch instead of deleting it: a failed write must not also
  # destroy the only copy of the data it failed to write. Rename out of the
  # way so the NEXT run's atomic hand-off doesn't collide with it; a human
  # (or a future automated retry) can re-attempt by moving it back to the
  # canonical staging path.
  mv "${_IMPORT}" "${_IMPORT}.failed" 2>/dev/null || true
  log "ERROR: batch preserved at ${_IMPORT}.failed for manual retry"
  exit 1
fi

rm -f "${_IMPORT}" 2>/dev/null || true
log "import done"

# ── etl_freshness registration (llm#309 Phase 1a): update AFTER the write
# actually lands, not before -- calling this from `stop` (pre-#956) was
# itself another duckdb CLI call subject to the same lock, which is why
# etl_freshness.sessions had been frozen for weeks alongside the data. ──────
_FRESHNESS_HELPER="${SCRIPT_DIR}/etl_freshness_upsert.sh"
if [ -x "${_FRESHNESS_HELPER}" ]; then
  "${_FRESHNESS_HELPER}" sessions "${DB_PATH}" "" --table sessions --ts-col started_at 2>/dev/null \
    || log "WARN etl_freshness_upsert failed (non-fatal)"
fi

exit 0
