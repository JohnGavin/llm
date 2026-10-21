#!/usr/bin/env bash
# gh_run_retry.sh -- re-run a failed SCHEDULED GitHub Actions run ONCE when the failure
# looks transient, so the 06:30 overnight email does not report a failure that has
# already healed (companion of job_failure_retry.sh, which does the same for launchd).
#
# Usage:
#   gh_run_retry.sh [--apply]
#     (no flag)  report only: print what WOULD be re-run, change nothing
#     --apply    `gh run rerun <id> --failed` for each eligible run
#
# Scope: PUBLIC repos of the owner only (`gh repo list <owner> --visibility public`, and
# `gh repo view` must say PUBLIC again right before an action). A repo whose visibility or
# runs cannot be read is skipped and reported as ONE INDETERMINATE line that never names
# it. Private repos are never touched (their runs cost Actions minutes).
#
# Candidates: runs with event `schedule`, conclusion failure or cancelled, run_attempt 1
# (so a run is retried at most once, ever), created in the last 24 h.
# A candidate is transient only if EITHER
#   (a) a failed-job log matches a row of .claude/state/gh_transient_patterns.tsv
#       (owner-signed; columns pattern_regex, note), the log is streamed into grep and
#       never printed or stored, or
#   (b) a job is `cancelled` with ZERO recorded steps (the runner never started).
# Anything else (a real test failure, say) is left for the owner.
#
# Limits (a standing authorisation in AGENTS.md, "Failed-job retry"): at most 3 reruns per
# run of this script, `gh run rerun --failed` only, never another gh mutation.
#
# stdout, one line each (the email parses the first form):
#   <owner/repo> <workflow> run <id> retried (a|b)        (--apply, rerun requested)
#   <owner/repo> <workflow> run <id> would retry (a|b)    (report only)
#   <owner/repo> <workflow> run <id> retry failed (a|b)   (--apply, gh refused)
#   INDETERMINATE: <fixed reason>
# Audit log (--apply only): ~/.claude/logs/gh_run_retry.log, one line per action with
# repo, run id, UTC time, reason class and outcome. Nothing from a run log.
#
# Exit: 0 nothing needed (or report only), 1 at least one rerun requested,
#       2 usage, 3 INDETERMINATE (gh missing or unauthenticated, pattern table
#       missing/empty/unparseable, repo list unreadable, or a repo/run could not be read).
#       Never read 3 as success.
#
# Env overrides (tests use them; the defaults are the real files):
#   GH_RETRY_PATTERNS_FILE  pattern table      GH_RETRY_LOG  audit log
#   GH_RETRY_OWNER          default JohnGavin  GH_RETRY_NOW  epoch seconds
# Bash 3.2 compatible.
set -u

# Append, never prepend: a test's fake gh must stay first on PATH.
export PATH="${PATH:-}:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PATTERNS="${GH_RETRY_PATTERNS_FILE:-$ROOT/.claude/state/gh_transient_patterns.tsv}"
RLOG="${GH_RETRY_LOG:-$HOME/.claude/logs/gh_run_retry.log}"
OWNER="${GH_RETRY_OWNER:-JohnGavin}"
NOW="${GH_RETRY_NOW:-$(date -u +%s)}"
MAX_PER_RUN=3
TAB="$(printf '\t')"

usage() { echo "usage: gh_run_retry.sh [--apply]" >&2; exit 2; }

APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        *) usage ;;
    esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh_run_retry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_line() {   # repo run class outcome
    [ "$APPLY" = "1" ] || return 0
    mkdir -p "$(dirname "$RLOG")" 2>/dev/null
    printf '%s repo=%s run=%s class=%s outcome=%s\n' "$(now_utc)" "$1" "$2" "$3" "$4" >> "$RLOG" 2>/dev/null
}

indeterminate() {
    echo "INDETERMINATE: $1"
    log_line "-" "-" "-" "indeterminate"
    exit 3
}

# ---- 1. gh must be usable ---------------------------------------------------------
command -v gh >/dev/null 2>&1 || indeterminate "gh not available"
gh auth status >/dev/null 2>&1 || indeterminate "gh not authenticated"

# ---- 2. the owner-signed pattern table --------------------------------------------
[ -r "$PATTERNS" ] || indeterminate "transient pattern table missing"
awk -F'\t' '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next } $1 == "pattern_regex" { next } { print $1 }' \
    "$PATTERNS" | tr -d '\r' > "$TMP/patterns.txt"
[ -s "$TMP/patterns.txt" ] || indeterminate "transient pattern table empty"
while IFS= read -r re; do
    [ -n "$re" ] || indeterminate "transient pattern table unparseable"
    grep -E -e "$re" /dev/null >/dev/null 2>&1
    [ $? -ne 2 ] || indeterminate "transient pattern table unparseable"
done < "$TMP/patterns.txt"

# ---- 3. the cut-off: runs created in the last 24 h ---------------------------------
cut_epoch=$((NOW - 86400))
CUTOFF="$(date -u -r "$cut_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$cut_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$CUTOFF" ] || indeterminate "cannot compute the 24 h cut-off"

# ---- 4. public repos of the owner ---------------------------------------------------
gh repo list "$OWNER" --visibility public --limit 200 --json nameWithOwner --jq '.[].nameWithOwner' \
    > "$TMP/repos.txt" 2>/dev/null || indeterminate "public repo list unreadable"
[ -s "$TMP/repos.txt" ] || indeterminate "no public repos listed"

: > "$TMP/summary.txt"
UNREAD=0       # repos or runs that could not be read (reported as one line, never named)
RETRIED=0      # reruns requested
SEEN=0         # candidates handled (retried or would-retry)

# transient_class REPO RUN -> prints a|b, or nothing. rc 0 = decided, 1 = could not read.
transient_class() {
    local repo="$1" run="$2" n0
    # (b) a cancelled job that recorded no step at all: the runner never started
    n0="$(gh run view "$run" --repo "$repo" --json jobs \
        --jq '[.jobs[]? | select(.conclusion == "cancelled" and ((.steps // []) | length) == 0)] | length' 2>/dev/null)"
    case "$n0" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$n0" -gt 0 ]; then echo b; return 0; fi
    # (a) a failed-job log matching the table; streamed, never printed
    rm -f "$TMP/log_rc"
    { gh run view "$run" --repo "$repo" --log-failed 2>/dev/null; echo "$?" > "$TMP/log_rc"; } \
        | grep -E -q -f "$TMP/patterns.txt"
    if [ "$?" -eq 0 ]; then echo a; return 0; fi
    [ "$(cat "$TMP/log_rc" 2>/dev/null)" = "0" ] || return 1
    return 0
}

while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    [ "$SEEN" -lt "$MAX_PER_RUN" ] || break
    case "$repo" in */*) ;; *) UNREAD=$((UNREAD + 1)); continue ;; esac
    vis="$(gh repo view "$repo" --json visibility --jq .visibility 2>/dev/null)"
    if [ -z "$vis" ]; then UNREAD=$((UNREAD + 1)); continue; fi
    [ "$vis" = "PUBLIC" ] || continue          # never touch anything that is not public
    if ! gh run list --repo "$repo" --event schedule --limit 30 \
        --json databaseId,workflowName,conclusion,attempt,createdAt,event \
        --jq ".[] | select(.event == \"schedule\" and (.conclusion == \"failure\" or .conclusion == \"cancelled\") and .attempt == 1 and .createdAt >= \"$CUTOFF\") | [(.databaseId | tostring), .workflowName] | join(\"\\t\")" \
        > "$TMP/runs.tsv" 2>/dev/null; then
        UNREAD=$((UNREAD + 1)); continue
    fi
    while IFS="$TAB" read -r run wf; do
        [ -n "$run" ] || continue
        case "$run" in *[!0-9]*) continue ;; esac
        [ "$SEEN" -lt "$MAX_PER_RUN" ] || break
        cls="$(transient_class "$repo" "$run")"
        if [ "$?" -ne 0 ]; then UNREAD=$((UNREAD + 1)); continue; fi
        [ -n "$cls" ] || continue
        SEEN=$((SEEN + 1))
        if [ "$APPLY" != "1" ]; then
            printf '%s %s run %s would retry (%s)\n' "$repo" "$wf" "$run" "$cls" >> "$TMP/summary.txt"
        elif gh run rerun "$run" --repo "$repo" --failed >/dev/null 2>&1; then
            RETRIED=$((RETRIED + 1))
            log_line "$repo" "$run" "$cls" "rerun-requested"
            printf '%s %s run %s retried (%s)\n' "$repo" "$wf" "$run" "$cls" >> "$TMP/summary.txt"
        else
            UNREAD=$((UNREAD + 1))      # asked and refused: the run is NOT retried
            log_line "$repo" "$run" "$cls" "rerun-failed"
            printf '%s %s run %s retry failed (%s)\n' "$repo" "$wf" "$run" "$cls" >> "$TMP/summary.txt"
        fi
    done < "$TMP/runs.tsv"
done < "$TMP/repos.txt"

cat "$TMP/summary.txt"
if [ "$UNREAD" -gt 0 ]; then
    echo "INDETERMINATE: $UNREAD repo(s) or run(s) could not be read, so a failed run may not have been retried"
    log_line "-" "-" "-" "indeterminate"
    exit 3
fi
[ "$RETRIED" -eq 0 ] || exit 1
exit 0
