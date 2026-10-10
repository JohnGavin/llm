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

# fmt_epoch EPOCH FORMAT -- BSD (macOS) `date -r` first, GNU `date -d @` second.
fmt_epoch() { date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2"; }

# No status file: say WHY, from launchd's own state, instead of guessing.
# Four distinct situations (checks-must-distinguish-unknown):
#   job not loaded            -> the report can never run until it is installed
#   loaded, runs = 0          -> first run still pending; say when it is due
#   loaded, ran, no status    -> the wrapper ran but wrote nothing (a defect)
#   launchd state unreadable  -> we do not know
# Seam for tests: ROBOREV_LF_LAUNCHD_PRINT_FILE names a file holding
# `launchctl print` output; a path that does not exist means "not loaded".
if [ ! -f "${STATUS}" ]; then
  LABEL="com.claude.roborev-likely-fixed-report"
  lp=""; lp_rc=0
  if [ -n "${ROBOREV_LF_LAUNCHD_PRINT_FILE:-}" ]; then
    if [ -f "${ROBOREV_LF_LAUNCHD_PRINT_FILE}" ]; then
      lp="$(cat "${ROBOREV_LF_LAUNCHD_PRINT_FILE}")"
    else
      lp_rc=113
    fi
  elif command -v launchctl >/dev/null 2>&1; then
    lp="$(launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null)"; lp_rc=$?
  else
    echo "likely-fixed report: not run (no report found; launchd state could not be read here)"
    exit 3
  fi

  if [ "${lp_rc}" -ne 0 ] || [ -z "${lp}" ]; then
    echo "likely-fixed report: not run (no report found; the weekly job ${LABEL} is NOT loaded in launchd -- install it, see the plist header)"
    exit 3
  fi

  runs="$(printf '%s\n' "${lp}" | sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\)$/\1/p' | head -1)"
  last_exit="$(printf '%s\n' "${lp}" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
  case "${runs}" in
    0)
      wd="$(printf '%s\n' "${lp}" | sed -n 's/.*"Weekday" => \([0-9][0-9]*\).*/\1/p' | head -1)"
      hr="$(printf '%s\n' "${lp}" | sed -n 's/.*"Hour" => \([0-9][0-9]*\).*/\1/p' | head -1)"
      mn="$(printf '%s\n' "${lp}" | sed -n 's/.*"Minute" => \([0-9][0-9]*\).*/\1/p' | head -1)"
      if [ -n "${wd}" ] && [ -n "${hr}" ] && [ -n "${mn}" ]; then
        dow="$(fmt_epoch "${NOW}" %w)"; chh="$(fmt_epoch "${NOW}" %H)"; cmm="$(fmt_epoch "${NOW}" %M)"
        cur=$(( 10#${dow} * 1440 + 10#${chh} * 60 + 10#${cmm} ))
        tgt=$(( 10#${wd} * 1440 + 10#${hr} * 60 + 10#${mn} ))
        delta=$(( (tgt - cur + 10080) % 10080 ))
        [ "${delta}" -eq 0 ] && delta=10080
        due=$(( NOW - NOW % 60 + delta * 60 ))
        echo "likely-fixed report: not run yet (job loaded, 0 runs so far; first run due $(fmt_epoch "${due}" '%a %Y-%m-%d %H:%M'))"
      else
        echo "likely-fixed report: not run yet (job loaded, 0 runs so far; next due time not readable from launchd)"
      fi
      exit 3 ;;
    ''|*[!0-9]*)
      echo "likely-fixed report: not run (no report found; job loaded but its run count could not be read from launchd)"
      exit 3 ;;
    *)
      echo "likely-fixed report: not run (no report found although the job loaded and ran ${runs} time(s), last exit ${last_exit:-unknown} -- the wrapper wrote no status file)"
      exit 3 ;;
  esac
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
