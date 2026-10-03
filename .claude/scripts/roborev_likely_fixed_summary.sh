#!/bin/bash
# roborev_likely_fixed_summary.sh -- one-line surface for the scheduled
# "likely fixed" report (JohnGavin/llm#1274 option C). Read-only.
#
# Reads likely_fixed_latest.status written by bin/roborev_likely_fixed_report.sh
# and prints ONE line. Consumed by .claude/scripts/send_roborev_email.R (the
# daily roborev email).
#
# A missing, stale, unreadable or failed run NEVER renders as a count: it says
# "not run" / "STALE", so "0 likely fixed" can only ever mean a fresh run that
# really found none (checks-must-distinguish-unknown).
#
# Exit: 0 fresh determinate result (state ok);
#       3 anything else (not run / stale / partial / indeterminate / unreadable).
#
# Env: ROBOREV_LF_DIR (default ~/.claude/logs/roborev_revalidate)
#      ROBOREV_LF_MAX_AGE_SECS (default 691200 = 8d: weekly schedule + 1d grace)
#      ROBOREV_LF_NOW_EPOCH (test seam)

set -uo pipefail

LF_DIR="${ROBOREV_LF_DIR:-${HOME}/.claude/logs/roborev_revalidate}"
MAX_AGE="${ROBOREV_LF_MAX_AGE_SECS:-691200}"
NOW="${ROBOREV_LF_NOW_EPOCH:-$(date +%s)}"
STATUS="${LF_DIR}/likely_fixed_latest.status"

if [ ! -f "${STATUS}" ]; then
  echo "likely-fixed report: not run (no report found; the weekly job may not be loaded)"
  exit 3
fi

kv() { sed -n "s/^$1=//p" "${STATUS}" | head -1; }
state="$(kv state)"; run_epoch="$(kv run_epoch)"; run_date="$(kv run_date)"

case "${run_epoch}" in ''|*[!0-9]*)
  echo "likely-fixed report: not run (status file unreadable: no valid run time)"
  exit 3 ;;
esac

age=$(( NOW - run_epoch ))
days=$(( age / 86400 ))

if [ "${state}" = "indeterminate" ]; then
  echo "likely-fixed report: not run (last attempt ${run_date} could not complete: $(kv reason)); no count available"
  exit 3
fi

if [ "${age}" -gt "${MAX_AGE}" ]; then
  echo "likely-fixed report: STALE (last ran ${run_date}, ${days}d ago; expected weekly); counts withheld"
  exit 3
fi

for k in likely_fixed still_present ambiguous indeterminate repos; do
  case "$(kv ${k})" in ''|*[!0-9]*)
    echo "likely-fixed report: not run (status file unreadable: bad ${k})"
    exit 3 ;;
  esac
done

line="likely-fixed report (${run_date}): $(kv likely_fixed) likely-fixed, $(kv still_present) still-present, $(kv ambiguous) ambiguous, $(kv indeterminate) indeterminate across $(kv repos) repo(s); report-only, nothing closed"
sk="$(kv skipped)"
case "${sk}" in ''|0|*[!0-9]*) ;; *) line="${line}; ${sk} repo(s) not checkable" ;; esac

if [ "${state}" = "ok" ]; then
  echo "${line}"
  exit 0
fi
echo "likely-fixed report: PARTIAL ($(kv failed) repo(s) failed, INDETERMINATE): ${line}"
exit 3
