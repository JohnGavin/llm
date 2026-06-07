#!/usr/bin/env bash
# housekeeping_schema_apply.sh — apply housekeeping schema to unified.duckdb
#
# Idempotent: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
# Safe to run multiple times — will not drop or alter existing data.
#
# Usage:
#   bash .claude/scripts/housekeeping_schema_apply.sh
#
# Tracked in llm#550 Phase B.

set -euo pipefail

DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SQL="${SCRIPT_DIR}/housekeeping_schema_init.sql"

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
echo "housekeeping schema applied to $DB"
