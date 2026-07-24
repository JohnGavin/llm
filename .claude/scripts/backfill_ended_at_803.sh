#!/usr/bin/env bash
# backfill_ended_at_803.sh — ONE-OFF backfill for llm#803.
#
# At the time this issue was filed, `sessions.ended_at` was NULL for 2637 of
# 4620 rows (57%) — historical rows that predate the session_stop.sh /bye-gate
# fix and the session_reaper.sh ongoing sweep (both llm#803). This script
# applies the SAME rule as session_reaper.sql (see that file for the full
# staleness/imputed-duration rationale) once, against the existing backlog,
# and prints before/after counts plus a sanity check.
#
# This is NOT wired into any hook and does not run automatically — it is a
# manual, one-off remediation. Run it once against the live DB after review;
# re-running it is harmless (idempotent: WHERE ended_at IS NULL means already
# backfilled rows are never touched again).
#
# Usage:
#   backfill_ended_at_803.sh <path-to-unified.duckdb>
#
# Validate first against a scratch copy, e.g.:
#   cp ~/.claude/logs/unified.duckdb /tmp/sess_test.duckdb
#   backfill_ended_at_803.sh /tmp/sess_test.duckdb
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/session_reaper.sql"
DB="${1:?Usage: backfill_ended_at_803.sh <path-to-unified.duckdb>}"

if [ ! -f "$DB" ]; then
  echo "ERROR: DB not found at $DB" >&2
  exit 1
fi
if [ ! -f "$SQL_FILE" ]; then
  echo "ERROR: SQL file not found at $SQL_FILE" >&2
  exit 1
fi
if ! command -v duckdb >/dev/null 2>&1; then
  echo "ERROR: duckdb not on PATH. Run via: nix-shell <llm>/default.nix --run '$0 $DB'" >&2
  exit 1
fi

echo "== Before =="
duckdb -init /dev/null "$DB" -c "
  SELECT COUNT(*) AS total,
         SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) AS null_ended
  FROM sessions;
"

echo "== Applying backfill (session_reaper.sql rule) =="
duckdb -init /dev/null "$DB" -c ".read '${SQL_FILE}'"

echo "== After =="
duckdb -init /dev/null "$DB" -c "
  SELECT COUNT(*) AS total,
         SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) AS null_ended
  FROM sessions;
"

echo "== Sanity check: any ended_at < started_at? (expect 0) =="
duckdb -init /dev/null "$DB" -c "
  SELECT COUNT(*) AS bad_rows FROM sessions WHERE ended_at < started_at;
"
