#!/usr/bin/env bash
# job_failure_retry.sh kicks a failed scheduled job once when the policy table
# says its cause is `self-heal` (.claude/state/job_failure_policy.tsv), and
# never anything else. Pattern: tests/test_scanner_triage.sh.
#
# Every case runs against a FAKE launchctl placed first on PATH, scratch plists,
# logs, policy tables, state and log files in a temp dir. It never touches real
# launchd, ~/.claude/logs or the shipped table (the shipped table is only
# checked for shape, in section M).
#
# Needs Rscript (the script classifies with job_failure_lib.R). Without it the
# test exits 3 (INDETERMINATE) with a visible message -- it does NOT claim a
# pass. Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SCRIPT="${JOB_FAILURE_RETRY_SCRIPT:-$ROOT/.claude/scripts/job_failure_retry.sh}"
SHIPPED="$ROOT/.claude/state/job_failure_policy.tsv"

if [ -z "$(command -v Rscript || true)" ]; then
    echo "INDETERMINATE: Rscript not found -- job_failure_retry.sh NOT exercised"
    exit 3
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/job_failure_retry_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
chk()  { if [ "$2" = "0" ]; then ok "$1"; else fail "$1"; fi; }

MARK="SECRETMARKER_7731"   # planted in every job log; must never reach the retry log

# ---- fixtures -----------------------------------------------------------------
FAKE="$WORK/fakebin"; LC="$WORK/lc"; PL="$WORK/plists"; LG="$WORK/logs"
mkdir -p "$FAKE" "$LC" "$PL" "$LG"
cat > "$FAKE/launchctl" <<'EOF'
#!/bin/bash
# fake launchctl: `list` prints the table in $FAKE_LC_DIR/table (PID<TAB>Status<TAB>Label);
# `kickstart gui/<uid>/<label>` records the label and applies after.<label>
# (an exit status, or "running"). FAKE_LC_FAIL=1 makes every call fail.
D="${FAKE_LC_DIR:?}"
[ "${FAKE_LC_FAIL:-0}" = "1" ] && { echo "launchctl: fake failure" >&2; exit 1; }
case "${1:-}" in
  list) cat "$D/table" ;;
  kickstart)
    for a in "$@"; do t="$a"; done
    label="${t##*/}"
    echo "$label" >> "$D/kicks"
    [ "${FAKE_LC_KICK_FAIL:-0}" = "1" ] && exit 3
    after=0; [ -f "$D/after.$label" ] && after="$(cat "$D/after.$label")"
    pid="-"; st="$after"; if [ "$after" = "running" ]; then pid=4242; st=0; fi
    awk -F'\t' -v OFS='\t' -v l="$label" -v p="$pid" -v s="$st" '$3==l{$1=p;$2=s}1' "$D/table" > "$D/table.new"
    mv "$D/table.new" "$D/table"
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$FAKE/launchctl"

make_job() {   # label -> plist + a log whose error line carries the marker
    local label="$1" o="$LG/$1.out"
    printf 'INFO: start\nERROR: unable to download https://x/%s\n' "$MARK" > "$o"
    : > "$LG/$label.err"
    printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key><string>%s</string>\n<key>StandardOutPath</key><string>%s</string>\n<key>StandardErrorPath</key><string>%s</string></dict></plist>\n' \
        "$label" "$o" "$LG/$label.err" > "$PL/$label.plist"
}
for j in t-heal-a t-heal-b t-heal-c t-heal-d t-known t-human t-unlisted t-unlogged; do make_job "com.claude.$j"; done

HDR="$(printf 'job\tcause_regex\tclass\tissue\tnote')"
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
POL="$WORK/policy.tsv"
{
    echo "# fixture"; echo "$HDR"
    for j in a b c d; do row "com.claude.t-heal-$j" "unable to download" self-heal "" "transient"; done
    row com.claude.t-known "unable to download" known 5 "tracked"
    row com.claude.t-human "unable to download" human 6 "owner decides"
} > "$POL"

STATE="$WORK/retry.state"; RLOG="$WORK/retry.log"

fail_table() {   # label...: those fail (exit 1), plus a healthy job and an Apple job
    { printf 'PID\tStatus\tLabel\n'
      printf -- '-\t0\tcom.claude.t-fine\n-\t78\tcom.apple.fake\n'
      for l in "$@"; do printf -- '-\t1\t%s\n' "$l"; done
    } > "$LC/table"
}
reset() { rm -f "$LC/kicks" "$LC"/after.* "$STATE" "$RLOG"; fail_table "$@"; }
kicks() { if [ -f "$LC/kicks" ]; then wc -l < "$LC/kicks" | tr -d ' '; else echo 0; fi; }
kicked() { grep -qx "$1" "$LC/kicks" 2>/dev/null; }

RC=0
run() {   # args... ; stdout+stderr to $WORK/out, status to RC
    ( export PATH="$FAKE:$PATH" FAKE_LC_DIR="$LC" JOB_FAILURE_POLICY_FILE="${POLICY_USE:-$POL}" \
             JOB_FAILURE_PLIST_DIRS="$PL" JOB_FAILURE_RETRY_STATE="$STATE" JOB_FAILURE_RETRY_LOG="$RLOG" \
             JOB_FAILURE_RETRY_POLL=0.1 JOB_FAILURE_RETRY_GRACE=0 \
             JOB_FAILURE_LIB="$ROOT/.claude/scripts/lib/job_failure_lib.R"
      bash "${SCRIPT_USE:-$SCRIPT}" "$@" ) > "$WORK/out" 2>&1
    RC=$?
}

# ---- A. report-only changes nothing ----------------------------------------------
reset com.claude.t-heal-a
run
chk "A: report-only exits 0 (nothing changed)" "$RC"
[ "$(kicks)" = "0" ]; chk "A: report-only kicks nothing" "$?"
[ ! -f "$STATE" ] && [ ! -f "$RLOG" ]; chk "A: report-only writes no state and no log" "$?"
grep -q 'com.claude.t-heal-a' "$WORK/out"; chk "A: report-only names the job it WOULD retry" "$?"

# ---- B. a self-heal job is kicked once and recovers -------------------------------
reset com.claude.t-heal-a
run --apply --wait 20
chk "B: recovered job -> exit 0" "$RC"
[ "$(kicks)" = "1" ] && kicked com.claude.t-heal-a; chk "B: kicked exactly once" "$?"
grep -q 'com.claude.t-heal-a' "$STATE" 2>/dev/null; chk "B: state records the label for today" "$?"
grep -q 'com.claude.t-heal-a.*recovered' "$WORK/out"; chk "B: stdout reports recovered" "$?"
[ "$(wc -l < "$RLOG" | tr -d ' ')" = "1" ]; chk "B: one log line per action" "$?"
grep -q 'com.claude.t-heal-a' "$RLOG" && grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' "$RLOG"; chk "B: log line has label and UTC time" "$?"
! grep -q "$MARK" "$RLOG" "$STATE" && ! grep -q 'unable to download' "$RLOG"; chk "B: log and state carry no text from the job's own logs" "$?"
! grep -q "$MARK" "$WORK/out"; chk "B: stdout carries no text from the job's own logs" "$?"

# ---- C. same UTC day: not kicked again --------------------------------------------
fail_table com.claude.t-heal-a      # it fails again later the same day
run --apply --wait 20
[ "$(kicks)" = "1" ]; chk "C: second call the same UTC day does not kick again" "$?"
[ "$RC" = "1" ]; chk "C: a job still failing after its one retry exits 1" "$?"
grep -q 'com.claude.t-heal-a.*already-retried' "$WORK/out"; chk "C: stdout says already-retried" "$?"
export JOB_FAILURE_RETRY_TODAY=2099-01-02
run --apply --wait 20
unset JOB_FAILURE_RETRY_TODAY
[ "$(kicks)" = "2" ]; chk "C: the next UTC day it may be kicked again (falsifies the state gate)" "$?"

# ---- D. known / human / unlisted jobs are never kicked ----------------------------
reset com.claude.t-known com.claude.t-human com.claude.t-unlisted
run --apply --wait 20
chk "D: known/human/unlisted failing jobs -> exit 0 (nothing to retry)" "$RC"
[ "$(kicks)" = "0" ]; chk "D: none of them is kicked" "$?"
reset com.claude.t-unlogged         # plist exists, no log for it: class indeterminate
rm -f "$LG/com.claude.t-unlogged.out" "$LG/com.claude.t-unlogged.err"
run --apply --wait 20
[ "$(kicks)" = "0" ]; chk "D: a job whose cause cannot be read is not kicked" "$?"

# ---- E. falsification: drop the self-heal row -> no kick --------------------------
reset com.claude.t-heal-a
grep -v 'com.claude.t-heal-a' "$POL" > "$WORK/policy_norow.tsv"
POLICY_USE="$WORK/policy_norow.tsv" run --apply --wait 20
[ "$(kicks)" = "0" ]; chk "E: without its self-heal row the job is not kicked (falsification of B)" "$?"
sed 's/com.claude.t-heal-a\(.*\)self-heal/com.claude.t-heal-a\1known/' "$POL" > "$WORK/policy_known.tsv"
POLICY_USE="$WORK/policy_known.tsv" run --apply --wait 20
[ "$(kicks)" = "0" ]; chk "E: the same row as class known is not kicked" "$?"

# ---- F. at most 3 per run -----------------------------------------------------------
reset com.claude.t-heal-a com.claude.t-heal-b com.claude.t-heal-c com.claude.t-heal-d
run --apply --wait 20
[ "$(kicks)" = "3" ]; chk "F: four eligible jobs -> exactly 3 are kicked" "$?"
! kicked com.claude.t-heal-d; chk "F: the 4th (in label order) is not kicked" "$?"
grep -q 'com.claude.t-heal-d.*deferred' "$WORK/out"; chk "F: the 4th is reported as deferred" "$?"
grep -q 'com.claude.t-heal-d' "$STATE" 2>/dev/null && r=1 || r=0
chk "F: a deferred job is not recorded as retried" "$r"

# ---- G. empty / missing / unparseable policy -> INDETERMINATE (3), no kick ---------
reset com.claude.t-heal-a
: > "$WORK/p_empty.tsv"
printf '%s\n' "$HDR" > "$WORK/p_hdr.tsv"
printf 'job\tregex\tclass\n' > "$WORK/p_badhdr.tsv"
{ echo "$HDR"; row com.claude.t-heal-a "x" always-fine "" n; } > "$WORK/p_badclass.tsv"
for nm in empty hdr badhdr badclass missing; do
    f="$WORK/p_$nm.tsv"; [ "$nm" = missing ] && f="$WORK/does-not-exist.tsv"
    POLICY_USE="$f" run --apply --wait 20
    [ "$RC" = "3" ]; chk "G($nm): policy table not usable -> exit 3" "$?"
    [ "$(kicks)" = "0" ]; chk "G($nm): nothing kicked" "$?"
    grep -q 'INDETERMINATE' "$WORK/out"; chk "G($nm): says INDETERMINATE" "$?"
done
reset      # no failing jobs at all, unusable table: still INDETERMINATE, never success
POLICY_USE="$WORK/p_empty.tsv" run --apply --wait 20
[ "$RC" = "3" ]; chk "G: an empty table is INDETERMINATE even when nothing is failing" "$?"

# ---- H. still failing after the retry -> exit 1 ------------------------------------
reset com.claude.t-heal-a
echo 1 > "$LC/after.com.claude.t-heal-a"
run --apply --wait 20
[ "$RC" = "1" ]; chk "H: retried job that still fails -> exit 1" "$?"
grep -q 'com.claude.t-heal-a.*still-failing' "$WORK/out"; chk "H: stdout says still-failing" "$?"
grep -q 'still-failing' "$RLOG"; chk "H: the log line records still-failing" "$?"

# ---- I. launchctl unavailable / kickstart refused / job never finishes -------------
reset com.claude.t-heal-a
FAKE_LC_FAIL=1 run --apply --wait 20
[ "$RC" = "3" ]; chk "I: launchctl failing -> exit 3 (INDETERMINATE)" "$?"
reset com.claude.t-heal-a
FAKE_LC_KICK_FAIL=1 run --apply --wait 20
[ "$RC" = "1" ] && grep -q 'kickstart-failed' "$WORK/out"; chk "I: kickstart refused -> exit 1, reported kickstart-failed" "$?"
reset com.claude.t-heal-a
echo running > "$LC/after.com.claude.t-heal-a"
run --apply --wait 1
[ "$RC" = "3" ] && grep -q 'com.claude.t-heal-a.*timeout' "$WORK/out"; chk "I: a job still running at --wait expiry -> exit 3, never success" "$?"

# ---- J. usage ------------------------------------------------------------------------
reset com.claude.t-heal-a
run --bogus
[ "$RC" = "2" ]; chk "J: unknown flag -> exit 2" "$?"
run --apply --wait abc
[ "$RC" = "2" ]; chk "J: non-numeric --wait -> exit 2" "$?"
[ "$(kicks)" = "0" ]; chk "J: usage errors kick nothing" "$?"

# ---- K. never kicks a label outside com.claude.* ------------------------------------
reset
{ echo "$HDR"; row com.apple.fake "unable to download" self-heal "" n; } > "$WORK/p_apple.tsv"
fail_table com.apple.fake
make_job com.apple.fake
POLICY_USE="$WORK/p_apple.tsv" run --apply --wait 20
[ "$(kicks)" = "0" ]; chk "K: a non com.claude.* label is never kicked, even with a self-heal row" "$?"

# ---- L. mutants: the gates must be load-bearing --------------------------------------
mut() {   # name sed-expr
    sed "$2" "$SCRIPT" > "$WORK/mut_$1.sh"
    cmp -s "$SCRIPT" "$WORK/mut_$1.sh" && { fail "L($1): the mutation did not change the script"; return 1; }
    return 0
}
if mut class 's/identical(r\$class, "self-heal")/TRUE/'; then
    reset com.claude.t-known com.claude.t-human
    SCRIPT_USE="$WORK/mut_class.sh" run --apply --wait 20
    [ "$(kicks)" -gt 0 ]; chk "L: dropping the self-heal class gate makes D go red (it kicks known/human)" "$?"
fi
if mut max 's/MAX_PER_RUN=3/MAX_PER_RUN=99/'; then
    reset com.claude.t-heal-a com.claude.t-heal-b com.claude.t-heal-c com.claude.t-heal-d
    SCRIPT_USE="$WORK/mut_max.sh" run --apply --wait 20
    [ "$(kicks)" = "4" ]; chk "L: removing the cap makes F go red (4 kicks)" "$?"
fi
if mut state 's/# STATE-GATE.*$//; s/^\( *\)if retried_today "\$label"; then/\1if false; then/'; then
    reset com.claude.t-heal-a
    SCRIPT_USE="$WORK/mut_state.sh" run --apply --wait 20
    fail_table com.claude.t-heal-a
    SCRIPT_USE="$WORK/mut_state.sh" run --apply --wait 20
    [ "$(kicks)" = "2" ]; chk "L: removing the once-per-day gate makes C go red (2 kicks)" "$?"
fi

# ---- M. the shipped table and the script itself ---------------------------------------
bash -n "$SCRIPT"; chk "M: bash -n" "$?"
case "$(basename "$SCRIPT")" in
    *close*|*delete*|*reap*|*gc*|*reload*|*unload*|*purge*|*prune*|*kill*) fail "M: script name must avoid close/delete/reap/gc/reload/unload/purge/prune/kill" ;;
    *) ok "M: script name avoids the Tier-2 deny-list words" ;;
esac
grep -qE 'launchctl (load|unload|bootstrap|bootout|remove|stop)' "$SCRIPT" && r=1 || r=0
chk "M: the script never calls launchctl load/unload/bootstrap/bootout/remove/stop" "$r"
grep -q 'job_failure_assess' "$SCRIPT"; chk "M: classification goes through job_failure_assess (not re-implemented)" "$?"
awk -F'\t' '$1 ~ /^com\.claude\.(config|knowledge)-pulse$/ && $3=="self-heal"{n++} END{exit !(n==2)}' "$SHIPPED"
chk "M: shipped table has self-heal rows for config-pulse and knowledge-pulse" "$?"

echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
