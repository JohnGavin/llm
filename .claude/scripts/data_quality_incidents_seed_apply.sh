#!/usr/bin/env bash
# data_quality_incidents_seed_apply.sh — seed known data-quality incidents
# into unified.duckdb.
#
# Idempotent: INSERT OR IGNORE on a fixed PK per incident row.
# Safe to run multiple times — will not create duplicate incident rows.
#
# Requires the `data_quality_incidents` table to already exist; run
# housekeeping_schema_apply.sh first if this is a fresh DB.
#
# Usage:
#   bash .claude/scripts/data_quality_incidents_seed_apply.sh
#
# Tracked in llm#913, llm#915.

set -euo pipefail

DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SQL="${SCRIPT_DIR}/data_quality_incidents_seed.sql"

if [ ! -f "$SQL" ]; then
  echo "ERROR: SQL file not found: $SQL" >&2
  exit 1
fi

if [ ! -f "$DB" ]; then
  echo "ERROR: DuckDB not found at $DB" >&2
  echo "  Create it first with: duckdb $DB < .claude/scripts/unified_log_init.sql" >&2
  exit 1
fi

if ! command -v duckdb >/dev/null 2>&1; then
  echo "ERROR: duckdb not found in PATH" >&2
  exit 1
fi

duckdb "$DB" < "$SQL"
echo "data_quality_incidents seeded in $DB"
