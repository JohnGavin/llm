#!/usr/bin/env bash
# session_reaper.sh — llm#803 safety net for sessions whose Stop hook never
# fired the real session-end write (crash, kill -9, /clear, machine sleep).
#
# The normal path (session_stop.sh, gated on the one-shot /bye sentinel —
# see llm#803) writes `ended_at` exactly once, at the session's real end.
# This script closes the remaining rows: `ended_at IS NULL` and stale by the
# threshold documented in session_reaper.sql.
#
# Invoked from session_init.sh, backgrounded + timeout-bounded by the
# caller — must never block session start. Always exits 0 (best-effort).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${HOME}/.claude/logs/unified.duckdb"
SQL_FILE="${SCRIPT_DIR}/session_reaper.sql"

[ -f "$DB" ] || exit 0
[ -f "$SQL_FILE" ] || exit 0
command -v duckdb >/dev/null 2>&1 || exit 0

duckdb -init /dev/null "$DB" -c ".read '${SQL_FILE}'" 2>/dev/null || true
exit 0
