#!/usr/bin/env bash
# agent_runs_reaper.sh — llm#1045 safety net for agent_runs rows whose
# PostToolUse(Agent) hook never fired the real agent-stop write (killed
# agent, session ended mid-dispatch, crashed harness).
#
# The normal path (log_agent_run.sh's PostToolUse case) writes a terminal
# status exactly once, at the dispatch's real end. This script closes the
# remaining rows: `status = 'running'` and stale by the threshold documented
# in agent_runs_reaper.sql.
#
# Invoked from roborev_metrics_etl.sh right after agent_events_staging_
# import.sh -- same ETL cadence as the import it reaps behind. Always exits
# 0 (best-effort; mirrors session_reaper.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${1:-${HOME}/.claude/logs/unified.duckdb}"
SQL_FILE="${SCRIPT_DIR}/agent_runs_reaper.sql"

[ -f "$DB" ] || exit 0
[ -f "$SQL_FILE" ] || exit 0
command -v duckdb >/dev/null 2>&1 || exit 0

duckdb -init /dev/null "$DB" -c ".read '${SQL_FILE}'" 2>/dev/null || true
exit 0
