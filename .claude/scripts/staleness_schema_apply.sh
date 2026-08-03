#!/usr/bin/env bash
# staleness_schema_apply.sh — apply the staleness fact-table schema to unified.duckdb
#
# Idempotent: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE VIEW + CREATE
# INDEX IF NOT EXISTS. Safe to run multiple times — will not drop or alter
# existing data.
#
# Usage:
#   bash .claude/scripts/staleness_schema_apply.sh
#   bash .claude/scripts/staleness_schema_apply.sh --db /path/to/scratch.duckdb
#
# Tracked in llm#893 step 1.

set -euo pipefail

DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"

while [ $# -gt 0 ]; do
  case "$1" in
    --db) DB="${2:-}"; shift 2 ;;
    *) echo "Usage: $0 [--db PATH]" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SQL="${SCRIPT_DIR}/staleness_schema.sql"

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
echo "staleness schema applied to $DB"
