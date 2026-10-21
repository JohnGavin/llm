#!/usr/bin/env bash
# job_failure_retry.sh -- retry a failed launchd job ONCE when the policy table says
# its cause is transient (class `self-heal` in .claude/state/job_failure_policy.tsv),
# so the 06:30 overnight email does not report a failure that has already healed.
#
# Usage:
#   job_failure_retry.sh [--apply] [--wait SECS]
#     (no flag)   report only: print what WOULD be retried, change nothing
#     --apply     kick eligible jobs, then poll their last exit status
#     --wait SECS how long to wait for the kicked jobs to finish (default 300)
#
# Which jobs: every launchd label `com.claude.*` whose last exit status is non-zero AND
# that job_failure_assess() (lib/job_failure_lib.R -- the SAME classification the
# email uses, never re-implemented here) classifies `self-heal`. A job that is
# `known`, `human`, unlisted or whose cause cannot be read is never kicked.
#
# Limits (a standing authorisation in AGENTS.md, "Failed-job retry"): at most 3 jobs
# per run, at most ONE retry per label per UTC day, `launchctl kickstart` only --
# never load/unload/bootstrap/bootout/remove/stop, never another label.
#
# stdout, one line each (the email parses these):
#   RETRY<TAB><label><TAB><outcome>   outcome: would-retry | recovered | still-failing |
#                                     kickstart-failed | already-retried | deferred | timeout
#   INDETERMINATE: <fixed reason>     (exit 3 only)
# Nothing from a job's own log (text, path, value) is ever printed or logged.
#
# Exit: 0 nothing to retry, or every retried job now succeeded
#       1 a retried job still fails (or its retry budget for today is already spent)
#       2 usage
#       3 INDETERMINATE: policy table missing/empty/unparseable, launchctl or Rscript
#         unavailable, classifier failed, or a retried job still running at --wait expiry.
#         Never read as success.
#
# Env overrides (tests use them; defaults are the real files):
#   JOB_FAILURE_POLICY_FILE   policy table
#   JOB_FAILURE_PLIST_DIRS    colon-separated dirs holding <label>.plist
#   JOB_FAILURE_RETRY_STATE   ~/.claude/logs/job_failure_retry.state
#   JOB_FAILURE_RETRY_LOG     ~/.claude/logs/job_failure_retry.log
#   JOB_FAILURE_RETRY_POLL    seconds between polls (default 2)
#   JOB_FAILURE_RETRY_GRACE   seconds a just-kicked job may take to show as running (default 10)
#   JOB_FAILURE_RETRY_TODAY   UTC date YYYY-MM-DD (default: today)
#   JOB_FAILURE_LIB           classification library
# Bash 3.2 compatible.
set -u

# Append, never prepend: a test's fake launchctl must stay first on PATH.
export PATH="${PATH:-}:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="${JOB_FAILURE_LIB:-$HERE/lib/job_failure_lib.R}"
POLICY="${JOB_FAILURE_POLICY_FILE:-$ROOT/.claude/state/job_failure_policy.tsv}"
PLIST_DIRS="${JOB_FAILURE_PLIST_DIRS:-$ROOT/.claude/launchd:$HOME/Library/LaunchAgents}"
STATE="${JOB_FAILURE_RETRY_STATE:-$HOME/.claude/logs/job_failure_retry.state}"
RLOG="${JOB_FAILURE_RETRY_LOG:-$HOME/.claude/logs/job_failure_retry.log}"
POLL="${JOB_FAILURE_RETRY_POLL:-2}"
GRACE="${JOB_FAILURE_RETRY_GRACE:-10}"
TODAY="${JOB_FAILURE_RETRY_TODAY:-$(date -u +%Y-%m-%d)}"
MAX_PER_RUN=3
TAB="$(printf '\t')"

usage() {
    echo "usage: job_failure_retry.sh [--apply] [--wait SECS]" >&2
    exit 2
}

APPLY=0
WAIT=300
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --wait)
            [ $# -ge 2 ] || usage
            case "$2" in ''|*[!0-9]*) usage ;; esac
            WAIT="$2"; shift 2 ;;
        *) usage ;;
    esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/job_failure_retry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One audit line per action; label and outcome only (never anything from a job log).
log_line() {
    [ "$APPLY" = "1" ] || return 0
    mkdir -p "$(dirname "$RLOG")" 2>/dev/null
    printf '%s label=%s outcome=%s\n' "$(now_utc)" "$1" "$2" >> "$RLOG" 2>/dev/null
}

indeterminate() {
    echo "INDETERMINATE: $1"
    log_line "-" "indeterminate"
    exit 3
}

retried_today() { [ -f "$STATE" ] && grep -qxF "$1${TAB}${TODAY}" "$STATE"; }

# ---- 1. launchd and R must be usable --------------------------------------------
command -v launchctl >/dev/null 2>&1 || indeterminate "launchctl not available"
command -v Rscript >/dev/null 2>&1 || indeterminate "Rscript not available, cannot classify failures"
launchctl list > "$TMP/list" 2>/dev/null || indeterminate "launchctl list failed"

# Failed = a com.claude.* job that is not running and whose last exit status is non-zero.
awk -F'\t' '$3 ~ /^com\.claude\.[A-Za-z0-9._-]+$/ && $1 == "-" && $2 ~ /^-?[0-9]+$/ && $2 != "0" { print $3 "\t" $2 }' \
    "$TMP/list" | sort > "$TMP/failing.tsv"

# ---- 2. classify with the email's own library ------------------------------------
cat > "$TMP/classify.R" <<'EOF'
a <- commandArgs(trailingOnly = TRUE)
source(a[[1L]])
pol <- job_failure_policy_read(a[[2L]])
if (!identical(pol$status, "ok")) { cat(pol$status, "\n", sep = ""); quit(status = 3L) }
dirs <- strsplit(a[[3L]], ":", fixed = TRUE)[[1L]]
lines <- readLines(a[[4L]], warn = FALSE)
jobs <- unique(pol$policy$job)
for (ln in lines) {
  f <- strsplit(ln, "\t", fixed = TRUE)[[1L]]
  if (length(f) < 2L || !(f[[1L]] %in% jobs)) next
  r <- job_failure_assess(f[[1L]], f[[2L]], pol, dirs)
  if (identical(r$class, "self-heal")) cat(f[[1L]], "\n", sep = "")
}
EOF
Rscript --vanilla "$TMP/classify.R" "$LIB" "$POLICY" "$PLIST_DIRS" "$TMP/failing.tsv" \
    > "$TMP/selfheal.txt" 2> "$TMP/classify.err"
RC=$?
if [ "$RC" -eq 3 ]; then
    indeterminate "policy table not usable ($(head -n 1 "$TMP/selfheal.txt" | tr -cd 'a-z'))"
elif [ "$RC" -ne 0 ]; then
    indeterminate "classifier failed (Rscript exit $RC)"
fi
sort -u "$TMP/selfheal.txt" > "$TMP/candidates.txt"

# ---- 3. apply the per-day and per-run limits -------------------------------------
: > "$TMP/eligible.txt"
RESULTS="$TMP/results.tsv"      # label<TAB>outcome
: > "$RESULTS"
n=0
while IFS= read -r label; do
    [ -n "$label" ] || continue
    case "$label" in com.claude.*) ;; *) continue ;; esac
    if retried_today "$label"; then   # STATE-GATE
        printf '%s\talready-retried\n' "$label" >> "$RESULTS"
    elif [ "$n" -lt "$MAX_PER_RUN" ]; then
        echo "$label" >> "$TMP/eligible.txt"
        n=$((n + 1))
    else
        printf '%s\tdeferred\n' "$label" >> "$RESULTS"
    fi
done < "$TMP/candidates.txt"

emit() {   # prints RETRY lines for $RESULTS
    while IFS="$TAB" read -r l o; do printf 'RETRY\t%s\t%s\n' "$l" "$o"; done < "$RESULTS"
}

if [ "$APPLY" != "1" ]; then
    while IFS= read -r label; do
        [ -n "$label" ] && printf '%s\twould-retry\n' "$label" >> "$RESULTS"
    done < "$TMP/eligible.txt"
    emit
    exit 0
fi

# ---- 4. kick (once each), then poll the last exit status -------------------------
UIDN="$(id -u)"
: > "$TMP/pending.txt"
mkdir -p "$(dirname "$STATE")" 2>/dev/null
while IFS= read -r label; do
    [ -n "$label" ] || continue
    # Recorded BEFORE the kick: a crash after it must never allow a second retry today.
    printf '%s\t%s\n' "$label" "$TODAY" >> "$STATE" 2>/dev/null
    if launchctl kickstart "gui/${UIDN}/${label}" >/dev/null 2>&1; then
        echo "$label" >> "$TMP/pending.txt"
    else
        printf '%s\tkickstart-failed\n' "$label" >> "$RESULTS"
    fi
done < "$TMP/eligible.txt"

start=$SECONDS
deadline=$((start + WAIT))
while [ -s "$TMP/pending.txt" ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep "$POLL"
    launchctl list > "$TMP/list2" 2>/dev/null || indeterminate "launchctl list failed while polling"
    : > "$TMP/still.txt"
    while IFS= read -r label; do
        row="$(awk -F'\t' -v l="$label" '$3 == l { print $1 "\t" $2; exit }' "$TMP/list2")"
        pid="${row%%${TAB}*}"
        st="${row#*${TAB}}"
        if [ -z "$row" ]; then
            printf '%s\ttimeout\n' "$label" >> "$RESULTS"      # job vanished from launchd: cannot tell
        elif [ "$pid" != "-" ]; then
            : > "$TMP/seen.$label"
            echo "$label" >> "$TMP/still.txt"
        elif [ -f "$TMP/seen.$label" ] || [ $((SECONDS - start)) -ge "$GRACE" ]; then
            if [ "$st" = "0" ]; then
                printf '%s\trecovered\n' "$label" >> "$RESULTS"
            else
                printf '%s\tstill-failing\n' "$label" >> "$RESULTS"
            fi
        else
            echo "$label" >> "$TMP/still.txt"
        fi
    done < "$TMP/pending.txt"
    mv "$TMP/still.txt" "$TMP/pending.txt"
done
while IFS= read -r label; do
    [ -n "$label" ] && printf '%s\ttimeout\n' "$label" >> "$RESULTS"
done < "$TMP/pending.txt"

# ---- 5. report, log, exit --------------------------------------------------------
sort "$RESULTS" > "$TMP/results.sorted"
mv "$TMP/results.sorted" "$RESULTS"
while IFS="$TAB" read -r l o; do log_line "$l" "$o"; done < "$RESULTS"
emit

EXITC=0
if grep -qE "${TAB}(still-failing|kickstart-failed|already-retried)$" "$RESULTS"; then
    EXITC=1
elif grep -qE "${TAB}timeout$" "$RESULTS"; then
    echo "INDETERMINATE: a retried job was still running at --wait expiry"
    EXITC=3
fi
exit "$EXITC"
