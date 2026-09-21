#!/usr/bin/env bash
# ci_availability_check.sh -- is GitHub Actions actually running for this repo?
#
# Origin: JohnGavin/llm#1234 (Actions monthly budget exhausted; ~10 days with
# no CI). A gate that does not run looks identical to a gate that passed, so
# "CI unavailable" must be a first-class, visible state -- not silence.
#
# Exit codes (exit-code-conventions; checks-must-distinguish-unknown):
#   0  AVAILABLE      newest run actually started (success/failure/in_progress...)
#   1  UNAVAILABLE    the two newest runs both ended startup_failure
#   2  usage error
#   3  INDETERMINATE  could not tell: gh missing, auth/API failure (a 401 is
#                     retried once with GH_TOKEN unset; if that still fails ->
#                     3, never 1), no runs, or a single uncorroborated
#                     startup_failure / only pending runs
#
# Modes:
#   (default)                     print RESULT line + evidence, exit as above
#   --banner                      print ci:ok | ci:UNAVAILABLE | ci:unknown, exit 0
#   --record-start REASON SOURCE  append an open row to the outage ledger
#   --record-end                  close the open ledger row (sets end date)
# Options: --repo OWNER/REPO (default JohnGavin/llm), --ledger PATH,
#          --date YYYY-MM-DD (for record-*; default today)
#
# Billing sub-question is reported separately and NEVER changes the exit code:
# it is informational (readable / not readable with current auth).
#
# Ledger: .claude/state/ci_outages.tsv  (start_date, end_date_or_open, reason,
# source). record-start appends; record-end only rewrites the end field of the
# single open row. Nothing else is ever edited or deleted.

set -uo pipefail

REPO="JohnGavin/llm"
MODE="check"
LEDGER=""
DATE_OVERRIDE=""
REASON=""
SOURCE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LEDGER="${SCRIPT_DIR}/../state/ci_outages.tsv"

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --ledger) LEDGER="${2:-}"; shift 2 ;;
    --date) DATE_OVERRIDE="${2:-}"; shift 2 ;;
    --banner) MODE="banner"; shift ;;
    --record-start)
      MODE="record-start"; REASON="${2:-}"; SOURCE="${3:-}"; shift $(( $# >= 3 ? 3 : $# )) ;;
    --record-end) MODE="record-end"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ci_availability_check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

LEDGER="${LEDGER:-${CI_OUTAGE_LEDGER:-$DEFAULT_LEDGER}}"
TODAY="${DATE_OVERRIDE:-$(date +%F)}"
HEADER=$'start_date\tend_date_or_open\treason\tsource'

# ── ledger modes ─────────────────────────────────────────────────────────────
if [ "$MODE" = "record-start" ] || [ "$MODE" = "record-end" ]; then
  if ! printf '%s' "$TODAY" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    echo "ci_availability_check: --date must be YYYY-MM-DD, got '$TODAY'" >&2
    exit 2
  fi
fi

if [ "$MODE" = "record-start" ]; then
  if [ -z "$REASON" ] || [ -z "$SOURCE" ]; then
    echo "usage: --record-start REASON SOURCE" >&2
    exit 2
  fi
  case "$REASON$SOURCE" in *$'\t'*|*$'\n'*)
    echo "ci_availability_check: REASON/SOURCE must not contain tabs or newlines" >&2
    exit 2 ;;
  esac
  if [ -f "$LEDGER" ] && awk -F'\t' 'NR>1 && $2=="open" {f=1} END {exit !f}' "$LEDGER"; then
    echo "ci_availability_check: an open outage already exists in $LEDGER; close it first (--record-end)" >&2
    exit 2
  fi
  mkdir -p "$(dirname "$LEDGER")"
  [ -f "$LEDGER" ] || printf '%s\n' "$HEADER" > "$LEDGER"
  printf '%s\topen\t%s\t%s\n' "$TODAY" "$REASON" "$SOURCE" >> "$LEDGER"
  echo "recorded outage start $TODAY in $LEDGER"
  exit 0
fi

if [ "$MODE" = "record-end" ]; then
  if [ ! -f "$LEDGER" ]; then
    echo "ci_availability_check: no ledger at $LEDGER" >&2
    exit 2
  fi
  n_open=$(awk -F'\t' 'NR>1 && $2=="open" {c++} END {print c+0}' "$LEDGER")
  if [ "$n_open" != "1" ]; then
    echo "ci_availability_check: expected exactly 1 open outage in $LEDGER, found $n_open" >&2
    exit 2
  fi
  tmp="$(mktemp "${LEDGER}.XXXXXX")"
  awk -F'\t' -v OFS='\t' -v d="$TODAY" 'NR>1 && $2=="open" {$2=d} {print}' "$LEDGER" > "$tmp" \
    && mv "$tmp" "$LEDGER"
  echo "closed open outage with end date $TODAY in $LEDGER"
  exit 0
fi

# ── availability check ───────────────────────────────────────────────────────
OWNER="${REPO%%/*}"
emit() { # emit RESULT_WORD detail exit_code
  if [ "$MODE" = "banner" ]; then
    case "$1" in
      AVAILABLE) echo "ci:ok" ;;
      UNAVAILABLE) echo "ci:UNAVAILABLE" ;;
      *) echo "ci:unknown" ;;
    esac
    exit 0
  fi
  echo "RESULT: $1 ($2)"
  exit "$3"
}

if ! command -v gh >/dev/null 2>&1; then
  emit INDETERMINATE "gh not on PATH; cannot query workflow runs" 3
fi

NOTE=""
ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT
JQ_RUNS='.[] | "\(.conclusion)\t\(.status)"'

runs="$(gh run list --repo "$REPO" --limit 10 --json conclusion,status,createdAt --jq "$JQ_RUNS" 2>"$ERRF")"
rc=$?
if [ $rc -ne 0 ] && grep -qE '401|Bad credentials' "$ERRF"; then
  # A stale GH_TOKEN shadows the working keyring credential (llm#1012/#1019).
  runs="$(env -u GH_TOKEN -u GITHUB_TOKEN gh run list --repo "$REPO" --limit 10 --json conclusion,status,createdAt --jq "$JQ_RUNS" 2>"$ERRF")"
  rc=$?
  if [ $rc -eq 0 ]; then
    NOTE="; NOTE: GH_TOKEN was rejected (401) and shadows the keyring credential, retried without it"
  fi
fi
if [ $rc -ne 0 ]; then
  reason="$(head -c 200 "$ERRF" | tr '\n' ' ')"
  emit INDETERMINATE "gh run list failed (exit $rc): ${reason:-no stderr}" 3
fi
if [ -z "$runs" ]; then
  emit INDETERMINATE "no workflow runs returned for $REPO" 3
fi

classify() { # "conclusion<TAB>status" -> ok | bad | pending
  local c s
  c="${1%%$'\t'*}"; s="${1#*$'\t'}"
  if [ "$c" = "startup_failure" ]; then echo bad
  elif [ -n "$c" ]; then echo ok
  elif [ "$s" = "in_progress" ]; then echo ok
  else echo pending; fi
}

first="$(printf '%s\n' "$runs" | sed -n '1p')"
second="$(printf '%s\n' "$runs" | sed -n '2p')"
c1="$(classify "$first")"
c2="pending"
[ -n "$second" ] && c2="$(classify "$second")"

# Billing sub-question: informational only, never changes the exit code.
billing="not queried"
if [ "$MODE" = "check" ]; then
  bill="$(gh api "/users/${OWNER}/settings/billing/usage" --jq '[.usageItems[] | select(.product=="actions") | .netAmount] | add // 0' 2>"$ERRF")"
  if [ $? -eq 0 ]; then
    billing="readable; actions netAmount in returned usage = ${bill} USD (budget/limit itself is not exposed here)"
  else
    billing="INDETERMINATE: billing usage endpoint not readable with current auth ($(head -c 120 "$ERRF" | tr '\n' ' '))"
  fi
  echo "billing: $billing"
fi

if [ "$c1" = "ok" ]; then
  emit AVAILABLE "newest run started: ${first//$'\t'/ }${NOTE}" 0
elif [ "$c1" = "bad" ] && [ "$c2" = "bad" ]; then
  emit UNAVAILABLE "two newest runs ended startup_failure; cause not attributed (budget/billing is one possibility, workflow syntax another)${NOTE}" 1
elif [ "$c1" = "bad" ]; then
  emit INDETERMINATE "newest run is startup_failure but not corroborated by the next run${NOTE}" 3
else
  emit INDETERMINATE "newest run has no conclusion yet and is not in_progress (queued/waiting)${NOTE}" 3
fi
