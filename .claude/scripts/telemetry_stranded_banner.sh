#!/usr/bin/env bash
# telemetry_stranded_banner.sh - session-start banner reader for the
# llmtelemetry stranded/aborted-run log.
#
# Writers (JohnGavin/llmtelemetry):
#   inst/scripts/export_and_deploy_data.sh  record_stranded_run
#     <ISO-ts> repo=<path> conflicts=<n> files=[...]            (older lines: no kind=)
#     <ISO-ts> repo=<path> conflicts=<n> files=[...] kind=export_optional_step_error
#   exec/refresh_codexbar.sh  abort_refresh
#     <ISO-ts> kind=codexbar_refresh_abort exit=<n> reason=[...]
# ISO-ts is date '+%Y-%m-%dT%H:%M:%S%z'. A line without kind= is reported as
# kind "stranded_run".
#
# Three outcomes, never conflated (checks-must-distinguish-unknown):
#   entries in the last N days -> one line:
#       telemetry-stranded: 2 in last 3d (last: 2026-10-11 export_optional_step_error) -- see <log>
#   none (incl. missing/empty file) -> prints nothing
#   indeterminate (log unreadable, or non-empty lines whose timestamp cannot
#       be parsed and no recent entry found) -> one INDETERMINATE line
#
# N defaults to 3 days: the writers run at session end, so a failure normally
# shows within a day; 3d spans a weekend gap without a stale failure nagging
# for a week. Override: TELEMETRY_STRANDED_DAYS.
# Log path override (selftests, never the real log): TELEMETRY_STRANDED_LOG.
#
# Only the last 200 lines are read (fast; bounded). Always exits 0: the banner
# must never break session start. Skippable: CLAUDE_TELEMETRY_STRANDED_CHECK=0.
#
# Usage: telemetry_stranded_banner.sh
# Selftest: .claude/hooks/telemetry_stranded_banner_selftest.sh

[ "${CLAUDE_TELEMETRY_STRANDED_CHECK:-1}" != "0" ] || exit 0

LOG="${TELEMETRY_STRANDED_LOG:-$HOME/.claude/logs/telemetry_stranded_runs.log}"
DAYS="${TELEMETRY_STRANDED_DAYS:-3}"
case "$DAYS" in
  ''|*[!0-9]*) DAYS=3 ;;
esac

# Missing file = none.
[ -e "$LOG" ] || exit 0

if [ ! -f "$LOG" ] || [ ! -r "$LOG" ]; then
  echo "telemetry-stranded: INDETERMINATE (cannot read $LOG) -- check the file"
  exit 0
fi

# Cutoff date (local YYYY-MM-DD); BSD date first, GNU fallback.
CUTOFF=$(date -v-"${DAYS}"d '+%Y-%m-%d' 2>/dev/null) \
  || CUTOFF=$(date -d "${DAYS} days ago" '+%Y-%m-%d' 2>/dev/null) \
  || CUTOFF=""
if [ -z "$CUTOFF" ]; then
  echo "telemetry-stranded: INDETERMINATE (cannot compute ${DAYS}-day cutoff) -- see $LOG"
  exit 0
fi

# One awk pass. Day granularity: compares the leading YYYY-MM-DD of each line.
RESULT=$(tail -n 200 "$LOG" 2>/dev/null | awk -v cutoff="$CUTOFF" '
  /^[[:space:]]*$/ { next }
  {
    ts = $1
    if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) { bad++; next }
    day = substr(ts, 1, 10)
    if (day >= cutoff) {
      n++
      lastday = day
      kind = "stranded_run"
      if (match($0, /kind=[^ ]+/)) kind = substr($0, RSTART + 5, RLENGTH - 5)
      lastkind = kind
    }
  }
  END { printf "%d %d %s %s\n", n, bad, (lastday == "" ? "-" : lastday), (lastkind == "" ? "-" : lastkind) }
') || RESULT=""

if [ -z "$RESULT" ]; then
  echo "telemetry-stranded: INDETERMINATE (could not parse $LOG) -- check the file"
  exit 0
fi

read -r N BAD LASTDAY LASTKIND <<EOF
$RESULT
EOF

if [ "${N:-0}" -gt 0 ] 2>/dev/null; then
  EXTRA=""
  [ "${BAD:-0}" -gt 0 ] && EXTRA=" (+${BAD} unparseable lines)"
  echo "telemetry-stranded: ${N} in last ${DAYS}d (last: ${LASTDAY} ${LASTKIND})${EXTRA} -- see ${LOG}"
elif [ "${BAD:-0}" -gt 0 ] 2>/dev/null; then
  echo "telemetry-stranded: INDETERMINATE (${BAD} line(s) with unparseable timestamps, no recent entry found) -- see ${LOG}"
fi
exit 0
