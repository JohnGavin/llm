#!/usr/bin/env bash
# etl_freshness_stale_banner.sh — session-start banner for stale ETL sources.
#
# Reads the push-based `etl_freshness` registry table (llm#309 Phase 1a; rows
# are written by .claude/scripts/etl_freshness_upsert.sh, called by each ETL
# writer after it finishes running) and prints one `STALE: <source> (<N>d)`
# line per source currently marked stale. Silent when there are none.
#
# Complementary to etl_freshness_check.sh (session_init.sh Phase 15a), which
# pulls freshness live from a hardcoded table list. This script surfaces
# writer-self-reported staleness instead.
#
# Usage:
#   etl_freshness_stale_banner.sh
#   ETL_FRESHNESS_DB=/path/to/scratch.duckdb etl_freshness_stale_banner.sh   # testing
#
# Fail-open: a missing duckdb binary, a missing DB, a missing etl_freshness
# table, or any query error all print nothing and exit 0. Never aborts the
# caller under `set -euo pipefail` (hook-pipefail-no-stderr lesson).
#
# Tracked in llm#309 Phase 1a.

set -uo pipefail

DB="${ETL_FRESHNESS_DB:-${HOME}/.claude/logs/unified.duckdb}"

command -v duckdb >/dev/null 2>&1 || exit 0
[ -f "$DB" ] || exit 0

_rows=$(duckdb -init /dev/null "$DB" -noheader -list -c "
  SELECT source_name || '|' ||
         CAST(FLOOR(EXTRACT(EPOCH FROM (current_timestamp - COALESCE(last_row_ts, last_etl_run_ts))) / 86400.0) AS BIGINT)
  FROM etl_freshness
  WHERE status = 'stale';
" 2>/dev/null) || exit 0

[ -n "$_rows" ] || exit 0

while IFS='|' read -r _src _days; do
  [ -z "$_src" ] && continue
  echo "STALE: ${_src} (${_days}d)"
done <<< "$_rows"

exit 0
