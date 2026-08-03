#!/usr/bin/env bash
# staleness_banner.sh — session-start banner for the consolidated staleness table.
#
# Reads the `staleness_status` view (llm#893 steps 1-2; populated by
# .claude/scripts/staleness_collect.sh) and implements the out-of-band check
# that fixes defect 3: every prior checker was itself a launchd job, so a
# total launchd outage (llm#886) silenced the monitor along with everything
# it watched. This script is wired into session_init.sh — a different
# trigger class from launchd — so a dead collector becomes visible the next
# time a session starts, not after days of silence.
#
# Rule, in priority order:
#   1. If the collector's own heartbeat row is missing or stale, print ONLY
#      that — when the collector is dead, no other row in the table is
#      trustworthy, so nothing else is worth printing.
#   2. Otherwise, if any other asset is stale, print a capped one-line
#      summary naming up to STALENESS_BANNER_MAX assets.
#   3. Otherwise, silent.
#
# Usage:
#   staleness_banner.sh
#   STALENESS_DB=/path/to/scratch.duckdb staleness_banner.sh   # testing
#
# Fail-open: a missing duckdb binary, a missing DB, a missing `staleness`
# table/view, or any query error all print nothing and exit 0. Never aborts
# the caller under `set -euo pipefail` (hook-pipefail-no-stderr lesson,
# llm#695) — every command substitution below is guarded with `|| true` or a
# preceding existence check.
#
# Tracked in llm#893 step 2.

set -uo pipefail

DB="${STALENESS_DB:-${HOME}/.claude/logs/unified.duckdb}"
MAX_NAMED="${STALENESS_BANNER_MAX:-6}"

command -v duckdb >/dev/null 2>&1 || exit 0
[ -f "$DB" ] || exit 0

# ─── Collector heartbeat check (priority 1) ──────────────────────────────────
# NULL-safe: if the `staleness` table/view doesn't exist yet, or the
# collector has never written a row, this query returns nothing — treated
# the same as "collector stale" (fail-safe, not silent-benign).
_collector_row=$(duckdb -init /dev/null "$DB" -noheader -list -c "
  SELECT status || '|' ||
         COALESCE(CAST(FLOOR(EXTRACT(EPOCH FROM (current_timestamp - last_seen_ts)) / 3600.0) AS BIGINT)::VARCHAR, '')
  FROM staleness_status
  WHERE asset_kind = 'collector' AND asset_id = 'staleness_collect';
" 2>/dev/null) || exit 0

if [ -z "$_collector_row" ]; then
  echo "staleness: COLLECTOR STALE (never observed) — all staleness data untrustworthy"
  exit 0
fi

_collector_status="${_collector_row%%|*}"
_collector_hours="${_collector_row#*|}"

if [ "$_collector_status" = "stale" ]; then
  if [ -n "$_collector_hours" ]; then
    echo "staleness: COLLECTOR STALE (last ran ${_collector_hours}h ago) — all staleness data untrustworthy"
  else
    echo "staleness: COLLECTOR STALE — all staleness data untrustworthy"
  fi
  exit 0
fi

# ─── Compact summary of other stale assets (priority 2) ─────────────────────
_stale_rows=$(duckdb -init /dev/null "$DB" -noheader -list -c "
  SELECT asset_kind || ':' || asset_id
  FROM staleness_status
  WHERE status = 'stale' AND asset_kind != 'collector'
  ORDER BY asset_kind, asset_id;
" 2>/dev/null) || exit 0

[ -n "$_stale_rows" ] || exit 0

_total=$(printf '%s\n' "$_stale_rows" | grep -c . || true)
_named=$(printf '%s\n' "$_stale_rows" | head -n "$MAX_NAMED" | paste -sd, -)
_extra=$(( _total - MAX_NAMED ))

if [ "$_extra" -gt 0 ]; then
  echo "staleness: ${_total} stale (${_named}, +${_extra} more)"
else
  echo "staleness: ${_total} stale (${_named})"
fi

exit 0
