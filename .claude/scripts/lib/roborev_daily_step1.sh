#!/usr/bin/env bash
# roborev_daily_step1.sh -- map the exit code of roborev_daily_report.R (Step 1
# of bin/roborev_daily_cron.sh) to a housekeeping_runs row.
#
# Source this file; it defines one function and runs nothing.
#
#   roborev_daily_record_step1 <rc> <unified_db> <source_script> <log_fn>
#
# rc=0        -> nothing recorded, returns 0.
# rc!=0 (3 = INDETERMINATE: unified.duckdb stayed locked, no snapshot written)
#             -> best-effort INSERT of a status='failed' housekeeping_runs row
#                (task 'roborev_daily') so the launchd health email shows it;
#                returns <rc> so the caller can propagate it.
#
# The INSERT itself needs the DB; if it is still locked the insert fails. That
# is logged and non-fatal: the non-zero exit status still reaches launchd.

roborev_daily_record_step1() {
  local rc="$1" db="$2" src="$3" logfn="$4"
  [ "${rc}" -eq 0 ] && return 0

  local label="failed"
  [ "${rc}" -eq 3 ] && label="INDETERMINATE (unified.duckdb locked, no snapshot)"
  "${logfn}" "ERROR: roborev_daily_report.R exit=${rc} -- ${label}"

  if command -v duckdb >/dev/null 2>&1 && [ -f "${db}" ]; then
    local id ts
    id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    duckdb "${db}" "
      INSERT OR IGNORE INTO housekeeping_runs
        (id, task, source_script, started_at, ended_at, status, rows_written)
      VALUES ('${id}', 'roborev_daily', '${src}',
              TIMESTAMPTZ '${ts}', TIMESTAMPTZ '${ts}', 'failed', 0);
    " >/dev/null 2>&1 \
      || "${logfn}" "duckdb WARN: housekeeping_runs failed-row INSERT failed (non-fatal; exit status still propagates)"
  fi
  return "${rc}"
}
