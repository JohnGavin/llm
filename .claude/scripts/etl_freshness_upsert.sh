#!/usr/bin/env bash
# etl_freshness_upsert.sh — record ETL freshness for a data source in unified.duckdb
#
# Makes silent ETL staleness impossible (llm#309 Phase 1a): every ETL writer
# calls this helper after it finishes writing, so a single registry table
# (`etl_freshness`) always answers "when did each source last update, and is
# that within its expected cadence?" without any writer having to build its
# own freshness logic.
#
# Usage:
#   etl_freshness_upsert.sh <source_name> <db_path> [cadence_hours] \
#       [--table TABLE --ts-col COLUMN | --file PATH]
#
#   source_name     Stable identifier for the data source, e.g. 'sessions',
#                    'roborev', 'burn_rate'. Primary key in etl_freshness.
#   db_path          Path to the unified DuckDB (or a scratch DB for tests).
#   cadence_hours    Expected refresh interval in hours. Omit (or pass "")
#                    for event-driven sources with no SLA -> status='unknown'.
#   --table/--ts-col Derive last_row_ts from MAX(ts_col) FROM table. Silently
#                    skipped (last_row_ts stays NULL) if the table does not
#                    exist yet — never errors.
#   --file PATH      Derive last_row_ts from this file's mtime instead of a
#                    DB table (for writers whose source-of-truth is a JSONL
#                    staging file, not a queryable table).
#
# Idempotent: CREATE TABLE IF NOT EXISTS + INSERT OR REPLACE keyed on
# source_name. Safe to call on every ETL run.
#
# Fail-open: a missing duckdb binary, a missing source table, or a DB write
# failure never aborts the caller — this script exits 0 in all of those
# cases. It exits 1 only on a genuine usage error (missing required args),
# so callers should still guard invocations with `|| true`.
#
# Tracked in llm#309 Phase 1a.

set -uo pipefail

SOURCE_NAME="${1:-}"
DB_PATH="${2:-}"
CADENCE_HOURS="${3:-}"
shift 3 2>/dev/null || true

if [ -z "$SOURCE_NAME" ] || [ -z "$DB_PATH" ]; then
  echo "usage: etl_freshness_upsert.sh <source_name> <db_path> [cadence_hours] [--table T --ts-col C | --file PATH]" >&2
  exit 1
fi

TABLE=""
TS_COL=""
FILE_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --table)  TABLE="${2:-}";     shift 2 2>/dev/null || shift ;;
    --ts-col) TS_COL="${2:-}";    shift 2 2>/dev/null || shift ;;
    --file)   FILE_PATH="${2:-}"; shift 2 2>/dev/null || shift ;;
    *) shift ;;
  esac
done

if ! command -v duckdb >/dev/null 2>&1; then
  echo "etl_freshness_upsert: SKIP (duckdb not in PATH)" >&2
  exit 0
fi

# ── Escape single quotes for safe SQL string literals ──────────────────────
_esc() { printf '%s' "$1" | sed "s/'/''/g"; }

_source_esc="$(_esc "$SOURCE_NAME")"

# ── Determine the last_row_ts SQL expression ───────────────────────────────
LAST_ROW_TS_EXPR="NULL::TIMESTAMP"

if [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ]; then
  # Portable mtime -> epoch (GNU stat -c, BSD stat -f fallback), then epoch ->
  # ISO-ish string (BSD `date -r <epoch>`, GNU `date -d @<epoch>` fallback —
  # the two-step chain works on both: GNU `-r` wants a *file*, so it errs
  # cleanly on a bare epoch number and falls through to the `-d @epoch` form).
  _mtime_epoch=$(stat -c %Y "$FILE_PATH" 2>/dev/null || stat -f %m "$FILE_PATH" 2>/dev/null || echo "")
  if [ -n "$_mtime_epoch" ]; then
    _mtime_iso=$(date -u -r "$_mtime_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || date -u -d "@${_mtime_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    if [ -n "$_mtime_iso" ]; then
      LAST_ROW_TS_EXPR="TIMESTAMP '$(_esc "$_mtime_iso")'"
    fi
  fi
elif [ -n "$TABLE" ] && [ -n "$TS_COL" ]; then
  _table_esc="$(_esc "$TABLE")"
  _exists=$(duckdb -init /dev/null "$DB_PATH" -noheader -list -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = '${_table_esc}';" 2>/dev/null || echo 0)
  _exists="${_exists:-0}"
  if [ "${_exists}" -ge 1 ] 2>/dev/null; then
    LAST_ROW_TS_EXPR="(SELECT MAX(\"${TS_COL}\") FROM \"${TABLE}\")"
  fi
fi

# ── Determine the cadence SQL literal ───────────────────────────────────────
# Empty or non-numeric -> NULL (event-driven source, no SLA -> status='unknown')
CADENCE_SQL="NULL"
case "$CADENCE_HOURS" in
  ''|*[!0-9.]*) CADENCE_SQL="NULL" ;;
  *) CADENCE_SQL="$CADENCE_HOURS" ;;
esac

duckdb -init /dev/null "$DB_PATH" -c "
CREATE TABLE IF NOT EXISTS etl_freshness (
  source_name            VARCHAR PRIMARY KEY,
  last_row_ts            TIMESTAMP,
  last_etl_run_ts         TIMESTAMP,
  expected_cadence_hours DOUBLE,
  status                  VARCHAR
);

INSERT OR REPLACE INTO etl_freshness
  (source_name, last_row_ts, last_etl_run_ts, expected_cadence_hours, status)
SELECT
  '${_source_esc}',
  lrt.last_row_ts,
  current_timestamp,
  ${CADENCE_SQL},
  CASE
    WHEN ${CADENCE_SQL} IS NULL THEN 'unknown'
    WHEN lrt.last_row_ts IS NULL THEN 'unknown'
    WHEN EXTRACT(EPOCH FROM (current_timestamp - lrt.last_row_ts)) / 3600.0 > ${CADENCE_SQL}
      THEN 'stale'
    ELSE 'fresh'
  END
FROM (SELECT ${LAST_ROW_TS_EXPR} AS last_row_ts) lrt;
" 2>/dev/null || { echo "etl_freshness_upsert: WARN duckdb upsert failed for source=${SOURCE_NAME}" >&2; exit 0; }

exit 0
