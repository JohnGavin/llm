#!/usr/bin/env bash
# Overnight email line for the scheduled digest-publish job (llm#1389
# follow-up): .claude/scripts/lib/digest_publish_lib.R, used by
# send_overnight_self_review_email.R. Pure-function tests on synthetic
# heartbeat rows -- no DB, no network, no real ~/.claude.
#
# Falsification is built in: a mutant of the lib that treats ONE failure as
# needs-you MUST turn the one-failure cases red.
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
LIB="$ROOT/.claude/scripts/lib/digest_publish_lib.R"
EMAIL="$ROOT/.claude/scripts/send_overnight_self_review_email.R"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/digest_publish_email_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; total=0
check() { # check DESC CONDITION-RESULT(0=true)
    total=$((total + 1))
    if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else echo "FAIL: $1"; fi
}

RSCRIPT="$(command -v Rscript || true)"
if [ -z "$RSCRIPT" ]; then
    echo "SKIP: Rscript not found -- digest publish email assessment NOT exercised"
    exit 0
fi

# Scenarios share one driver; $1 = lib path. Prints key=value lines.
cat > "$WORK/drive.R" <<'EOF'
args <- commandArgs(trailingOnly = TRUE)
source(args[[1]])
now <- as.POSIXct("2026-10-19 06:00:00", tz = "UTC")
mk <- function(status, hours_ago, rows = 0L) {
  data.frame(status = status, rows_written = rows,
             at = now - hours_ago * 3600, stringsAsFactors = FALSE)
}
emit <- function(k, x) cat(sprintf("%s=%s|%s|%s\n", k, x$state, x$bucket, x$label))
emit("refreshed", digest_publish_assess(rbind(mk("ok", 3, 412L), mk("skipped", 27)), now))
emit("current", digest_publish_assess(rbind(mk("skipped", 3), mk("ok", 27, 412L)), now))
emit("one_failure", digest_publish_assess(rbind(mk("failed", 3), mk("skipped", 27)), now))
emit("two_failures", digest_publish_assess(rbind(mk("failed", 3), mk("failed", 27), mk("ok", 51, 412L)), now))
emit("no_run_36h", digest_publish_assess(mk("skipped", 37), now))
emit("no_run_60h", digest_publish_assess(mk("skipped", 61), now))
emit("fail_then_missing", digest_publish_assess(mk("failed", 37), now))
emit("recovered", digest_publish_assess(rbind(mk("ok", 3, 9L), mk("failed", 27), mk("failed", 51)), now))
emit("no_rows", digest_publish_assess(mk("ok", 3)[0, ], now))
emit("null_runs", digest_publish_assess(NULL, now))
emit("no_count", digest_publish_assess(mk("ok", 3, NA_integer_), now))
EOF

run_with() { "$RSCRIPT" "$WORK/drive.R" "$1" 2>&1; }
RES="$(run_with "$LIB")"
got() { printf '%s\n' "$RES" | grep -q "^$1=$2"; echo $?; }

check "driver produced output" $(printf '%s\n' "$RES" | grep -q '^refreshed='; echo $?)
check "refreshed: ok bucket, 'digests refreshed to 412 terms'" $(got refreshed 'refreshed|ok|digests refreshed to 412 terms$')
check "current: ok bucket, 'digests current'" $(got current 'current|ok|digests current$')
check "one failure: quiet (ok bucket), NOT needs-you" $(got one_failure 'one_failure|ok|')
check "one failure: label says it retries" $(printf '%s\n' "$RES" | grep '^one_failure=' | grep -q 'retries tomorrow'; echo $?)
check "two consecutive failures: needs you (failed bucket)" $(got two_failures 'needs_you|failed|needs you')
check "no run in 36 h after a good run: one miss, quiet" $(got no_run_36h 'one_failure|ok|ok — no run in the last 36 h')
check "no run in 60 h: two missed slots, needs you" $(got no_run_60h 'needs_you|failed|')
check "failed run then a missed slot: needs you" $(got fail_then_missing 'needs_you|failed|')
check "a success after failures resets: refreshed" $(got recovered 'refreshed|ok|digests refreshed to 9 terms')
check "no rows at all: indeterminate, never ok" $(got no_rows 'indeterminate|indeterminate|')
check "NULL runs: indeterminate" $(got null_runs 'indeterminate|indeterminate|')
check "refresh without a term count: indeterminate" $(got no_count 'indeterminate|indeterminate|')

# --- wiring: the email script uses the lib and the heartbeat task name ----------
check "email script sources the lib" $(grep -q 'lib", "digest_publish_lib.R"' "$EMAIL"; echo $?)
check "email script routes task private_terms_publish to digest_publish_assess" \
    $(grep -q 'identical(hb\$task, "private_terms_publish")' "$EMAIL"; echo $?)

# --- Falsification: a mutant that treats ONE failure as needs-you ----------------
sed 's/failures >= 2L/failures >= 1L/' "$LIB" > "$WORK/mutant_lib.R"
if cmp -s "$LIB" "$WORK/mutant_lib.R"; then
    check "mutant changed the lib (falsification not vacuous)" 1
else
    MRES="$(run_with "$WORK/mutant_lib.R")"
    mgot() { printf '%s\n' "$MRES" | grep -q "^$1=$2"; echo $?; }
    # The mutant must make the one-failure expectation FAIL (grep rc != 0).
    mrc="$(mgot one_failure 'one_failure|ok|')"
    check "MUTANT (one failure = needs you) turns the one-failure test red" $(( mrc == 0 ? 1 : 0 ))
    mrc="$(mgot no_run_36h 'one_failure|ok|')"
    check "MUTANT turns the single-missed-slot test red" $(( mrc == 0 ? 1 : 0 ))
fi

echo "digest_publish_email: ${pass}/${total} PASS"
[ "$pass" -eq "$total" ]
