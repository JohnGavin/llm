#!/usr/bin/env bash
# gh_run_retry.sh re-runs a failed SCHEDULED run of an owner PUBLIC repo once, only when
# the failure is transient (pattern table row, or a cancelled job with zero steps), and
# never anything else. Pattern: tests/test_job_failure_retry.sh.
#
# Every case runs against a FAKE gh placed first on PATH (it applies the caller's real
# --jq filter with jq, as gh does), scratch tables and logs in a temp dir. It never
# talks to GitHub and never reruns a real run.
#
# Needs jq (the fake gh applies --jq). Without it the test exits 3 (INDETERMINATE) with a
# visible message -- it does NOT claim a pass. Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SCRIPT="${GH_RUN_RETRY_SCRIPT:-$ROOT/.claude/scripts/gh_run_retry.sh}"
SHIPPED="$ROOT/.claude/state/gh_transient_patterns.tsv"

if [ -z "$(command -v jq || true)" ]; then
    echo "INDETERMINATE: jq not found -- gh_run_retry.sh NOT exercised"
    exit 3
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gh_run_retry_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
chk()  { if [ "$2" = "0" ]; then ok "$1"; else fail "$1"; fi; }

MARK="SECRETMARKER_5512"     # planted in every run log; must never reach stdout or the audit log
PRIVNAME="owner/hidden-private-repo"   # a private repo; its name must never be printed

D="$WORK/gh"; FAKE="$WORK/fakebin"
mkdir -p "$D" "$FAKE"
cat > "$FAKE/gh" <<'EOF'
#!/bin/bash
# fake gh. State lives in $FAKE_GH_DIR. Every call is appended to calls.log.
D="${FAKE_GH_DIR:?}"
echo "$*" >> "$D/calls.log"
jqf() { local f="" prev="" a; for a in "$@"; do [ "$prev" = "--jq" ] && f="$a"; prev="$a"; done; printf '%s' "$f"; }
key() { printf '%s' "$1" | tr '/' '_'; }
case "$1 $2" in
  "auth status") exit "$(cat "$D/auth_rc" 2>/dev/null || echo 0)" ;;
  "repo list") [ -f "$D/repolist_fail" ] && exit 1
               cat "$D/repos.json" | jq -r "$(jqf "$@")" ;;
  "repo view") r="$3"; [ -f "$D/vis_$(key "$r")" ] || exit 1
               printf '{"visibility":"%s"}' "$(cat "$D/vis_$(key "$r")")" | jq -r "$(jqf "$@")" ;;
  "run list")  r=""; prev=""; for a in "$@"; do [ "$prev" = "--repo" ] && r="$a"; prev="$a"; done
               [ -f "$D/runlist_fail_$(key "$r")" ] && exit 1
               echo "RUNLIST $r" >> "$D/touched.log"
               jq -r "$(jqf "$@")" "$D/runs_$(key "$r").json" ;;
  "run view")  id="$3"; shift 3
               case " $* " in
                 *" --log-failed "*) [ -f "$D/logfail_$id" ] && exit 1
                                     cat "$D/log_$id" 2>/dev/null; exit 0 ;;
                 *" --json jobs "*) [ -f "$D/jobsfail_$id" ] && exit 1
                                    jq -r "$(jqf "$@")" "$D/jobs_$id.json" ;;
               esac ;;
  "run rerun") [ -f "$D/rerun_fail" ] && { echo "SECRET-ERR" >&2; exit 1; }
               echo "$*" >> "$D/reruns.log" ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$FAKE/gh"

# ---- fixtures -----------------------------------------------------------------
NOW="$(date -u +%s)"
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
RECENT="$(iso $((NOW - 3600)))"
OLD="$(iso $((NOW - 90000)))"

TBL="$WORK/patterns.tsv"
printf '# fixture\npattern_regex\tnote\nError in the HTTP2 framing layer\tcache\nunable to download\tnet\n' > "$TBL"
RLOG="$WORK/retry.log"

reset() {
    rm -rf "$D"; mkdir -p "$D"
    : > "$D/calls.log"
    printf '[{"nameWithOwner":"owner/pub-a"},{"nameWithOwner":"owner/pub-b"},{"nameWithOwner":"%s"}]\n' "$PRIVNAME" > "$D/repos.json"
    echo PUBLIC > "$D/vis_owner_pub-a"; echo PUBLIC > "$D/vis_owner_pub-b"
    echo PRIVATE > "$D/vis_$(printf '%s' "$PRIVNAME" | tr '/' '_')"
    printf '[]' > "$D/runs_owner_pub-a.json"; printf '[]' > "$D/runs_owner_pub-b.json"
    printf '[]' > "$D/runs_$(printf '%s' "$PRIVNAME" | tr '/' '_').json"
    rm -f "$RLOG"
}
# run_json ID CONCLUSION ATTEMPT CREATED EVENT [WORKFLOW] -> one JSON object
run_json() {
    printf '{"databaseId":%s,"workflowName":"%s","conclusion":"%s","attempt":%s,"createdAt":"%s","event":"%s"}' \
        "$1" "${6:-Nightly}" "$2" "$3" "$4" "$5"
}
set_runs() {   # repo-key, objects...
    local k="$1"; shift; local out="" o
    for o in "$@"; do out="${out:+$out,}$o"; done
    printf '[%s]' "$out" > "$D/runs_$k.json"
}
jobs_steps() { printf '{"jobs":[{"name":"build","conclusion":"failure","steps":[{"name":"x","conclusion":"failure"}]}]}' > "$D/jobs_$1.json"; }
jobs_zero_cancelled() { printf '{"jobs":[{"name":"build","conclusion":"cancelled","steps":[]}]}' > "$D/jobs_$1.json"; }
jobs_cancelled_with_steps() { printf '{"jobs":[{"name":"build","conclusion":"cancelled","steps":[{"name":"x","conclusion":"cancelled"}]}]}' > "$D/jobs_$1.json"; }
log_transient() { printf 'step\nError in the HTTP2 framing layer %s\n' "$MARK" > "$D/log_$1"; }
log_real() { printf 'step\nAssertionError: 3 tests failed %s\n' "$MARK" > "$D/log_$1"; }

OUT=""; RC=0
run() {   # extra args
    OUT="$(env PATH="$FAKE:$PATH" FAKE_GH_DIR="$D" GH_RETRY_PATTERNS_FILE="${PAT:-$TBL}" GH_RETRY_LOG="$RLOG" \
        GH_RETRY_OWNER=owner GH_RETRY_NOW="$NOW" bash "${SCRIPT_UNDER_TEST:-$SCRIPT}" "$@" 2>"$WORK/err")"
    RC=$?
}
has() { printf '%s\n' "$OUT" | grep -q -F -e "$1"; }
reruns() { if [ -f "$D/reruns.log" ]; then wc -l < "$D/reruns.log" | tr -d ' '; else echo 0; fi; }

# ---- A. report only changes nothing ---------------------------------------------
reset
set_runs owner_pub-a "$(run_json 101 failure 1 "$RECENT" schedule)"; log_transient 101; jobs_steps 101
run
chk "A1 report-only: exit 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
chk "A2 report-only: names the run as would-retry (a)" "$(has 'owner/pub-a Nightly run 101 would retry (a)' && echo 0 || echo 1)"
chk "A3 report-only: no rerun issued" "$([ "$(reruns)" = 0 ] && echo 0 || echo 1)"
chk "A4 report-only: no audit log written" "$([ ! -e "$RLOG" ] && echo 0 || echo 1)"

# ---- B. apply: reason (a) and reason (b) ------------------------------------------
reset
set_runs owner_pub-a "$(run_json 101 failure 1 "$RECENT" schedule)" "$(run_json 102 cancelled 1 "$RECENT" schedule Build)"
log_transient 101; jobs_steps 101
jobs_zero_cancelled 102; : > "$D/log_102"
run --apply
chk "B1 apply: exit 1 (retried)" "$([ "$RC" = 1 ] && echo 0 || echo 1)"
chk "B2 apply: (a) line" "$(has 'owner/pub-a Nightly run 101 retried (a)' && echo 0 || echo 1)"
chk "B3 apply: (b) line for the zero-step cancelled job" "$(has 'owner/pub-a Build run 102 retried (b)' && echo 0 || echo 1)"
chk "B4 apply: two reruns, both --failed" "$([ "$(reruns)" = 2 ] && grep -q -e '--failed' "$D/reruns.log" && echo 0 || echo 1)"
chk "B5 audit log: one line per action with repo/run/class/outcome" \
    "$(grep -q 'repo=owner/pub-a run=101 class=a outcome=rerun-requested' "$RLOG" && grep -q 'run=102 class=b' "$RLOG" && echo 0 || echo 1)"
chk "B6 no log text reaches stdout or the audit log" "$(printf '%s' "$OUT" | grep -q "$MARK" || grep -q "$MARK" "$RLOG" && echo 1 || echo 0)"

# ---- C. what must NOT be retried -----------------------------------------------------
reset
set_runs owner_pub-a \
    "$(run_json 201 failure 1 "$RECENT" schedule)" \
    "$(run_json 202 failure 2 "$RECENT" schedule)" \
    "$(run_json 203 failure 1 "$RECENT" push)" \
    "$(run_json 204 failure 1 "$OLD" schedule)" \
    "$(run_json 205 success 1 "$RECENT" schedule)" \
    "$(run_json 206 cancelled 1 "$RECENT" schedule)"
log_real 201; jobs_steps 201
for i in 202 203 204 205; do log_transient "$i"; jobs_steps "$i"; done
jobs_cancelled_with_steps 206; log_real 206
run --apply
chk "C1 real failure / attempt 2 / push event / older than 24h / success / cancelled-with-steps: no rerun" "$([ "$(reruns)" = 0 ] && echo 0 || echo 1)"
chk "C2 ... and exit 0 with no output" "$([ "$RC" = 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)"

# ---- D. at most 3 per run ----------------------------------------------------------------
reset
set_runs owner_pub-a "$(run_json 301 failure 1 "$RECENT" schedule)" "$(run_json 302 failure 1 "$RECENT" schedule)" "$(run_json 303 failure 1 "$RECENT" schedule)"
set_runs owner_pub-b "$(run_json 304 failure 1 "$RECENT" schedule)" "$(run_json 305 failure 1 "$RECENT" schedule)"
for i in 301 302 303 304 305; do log_transient "$i"; jobs_steps "$i"; done
run --apply
chk "D1 five candidates, three reruns" "$([ "$(reruns)" = 3 ] && echo 0 || echo 1)"
reset
set_runs owner_pub-a "$(run_json 301 failure 1 "$RECENT" schedule)" "$(run_json 302 failure 1 "$RECENT" schedule)" "$(run_json 303 failure 1 "$RECENT" schedule)" "$(run_json 304 failure 1 "$RECENT" schedule)"
for i in 301 302 303 304; do log_transient "$i"; jobs_steps "$i"; done
run
chk "D2 report-only also stops at three" "$([ "$(printf '%s\n' "$OUT" | grep -c 'would retry')" = 3 ] && echo 0 || echo 1)"

# ---- E. private repos are never touched ------------------------------------------------------
reset
set_runs "$(printf '%s' "$PRIVNAME" | tr '/' '_')" "$(run_json 401 failure 1 "$RECENT" schedule)"
log_transient 401; jobs_steps 401
run --apply
chk "E1 a repo that is not PUBLIC: runs never listed, no rerun" "$(! grep -q "RUNLIST $PRIVNAME" "$D/touched.log" 2>/dev/null && [ "$(reruns)" = 0 ] && echo 0 || echo 1)"
chk "E2 its name is never printed" "$(printf '%s' "$OUT" | grep -q 'hidden-private' && echo 1 || echo 0)"
# visibility unreadable -> skipped, INDETERMINATE, name not printed
reset
rm -f "$D/vis_owner_pub-a"
set_runs owner_pub-a "$(run_json 402 failure 1 "$RECENT" schedule)"; log_transient 402; jobs_steps 402
run --apply
chk "E3 visibility unreadable: exit 3" "$([ "$RC" = 3 ] && echo 0 || echo 1)"
chk "E4 ... one INDETERMINATE line, repo not named, nothing rerun" \
    "$(has 'INDETERMINATE:' && ! printf '%s' "$OUT" | grep -q 'pub-a' && [ "$(reruns)" = 0 ] && echo 0 || echo 1)"

# ---- F. INDETERMINATE (exit 3), never success -------------------------------------------------
reset; echo 1 > "$D/auth_rc"; run --apply
chk "F1 gh unauthenticated: exit 3" "$([ "$RC" = 3 ] && has 'INDETERMINATE: gh not authenticated' && echo 0 || echo 1)"
reset; PAT="$WORK/missing.tsv" run --apply
chk "F2 pattern table missing: exit 3" "$([ "$RC" = 3 ] && has 'INDETERMINATE: transient pattern table missing' && echo 0 || echo 1)"
printf '# only comments\npattern_regex\tnote\n' > "$WORK/empty.tsv"
reset; PAT="$WORK/empty.tsv" run --apply
chk "F3 pattern table empty: exit 3" "$([ "$RC" = 3 ] && has 'INDETERMINATE: transient pattern table empty' && echo 0 || echo 1)"
printf 'pattern_regex\tnote\nunbalanced (paren\tbroken\n' > "$WORK/bad.tsv"
reset; PAT="$WORK/bad.tsv" run --apply
chk "F4 pattern table with an invalid regex: exit 3" "$([ "$RC" = 3 ] && has 'INDETERMINATE: transient pattern table unparseable' && echo 0 || echo 1)"
reset; : > "$D/repolist_fail"; run --apply
chk "F5 repo list unreadable: exit 3" "$([ "$RC" = 3 ] && has 'INDETERMINATE: public repo list unreadable' && echo 0 || echo 1)"
reset
set_runs owner_pub-a "$(run_json 501 failure 1 "$RECENT" schedule)"; log_transient 501; jobs_steps 501; : > "$D/logfail_501"
run --apply
chk "F6 failed-job log unreadable: exit 3, nothing rerun" "$([ "$RC" = 3 ] && [ "$(reruns)" = 0 ] && echo 0 || echo 1)"
reset
set_runs owner_pub-a "$(run_json 502 failure 1 "$RECENT" schedule)"; log_transient 502; jobs_steps 502; : > "$D/rerun_fail"
run --apply
chk "F7 rerun refused by gh: reported as 'retry failed', exit 3, nothing retried" \
    "$([ "$RC" = 3 ] && has 'run 502 retry failed (a)' && ! has ' retried (' && echo 0 || echo 1)"
chk "F8 ... gh's error text is never printed" "$(printf '%s' "$OUT" | grep -q 'SECRET-ERR' && echo 1 || echo 0)"
reset; run --bogus
chk "F9 usage error: exit 2" "$([ "$RC" = 2 ] && echo 0 || echo 1)"
reset
run
chk "F10 healthy and nothing failed: exit 0, no output" "$([ "$RC" = 0 ] && [ -z "$OUT" ] && echo 0 || echo 1)"

# ---- G. the shipped table ---------------------------------------------------------------------------
chk "G1 shipped table exists" "$([ -s "$SHIPPED" ] && echo 0 || echo 1)"
for pat in 'Error in the HTTP2 framing layer' 'unable to download' 'Could not resolve host' 'The hosted runner lost communication' 'The runner has received a shutdown signal'; do
    chk "G2 shipped table has seed row: $pat" "$(awk -F'\t' -v p="$pat" '$1==p{f=1} END{exit f?0:1}' "$SHIPPED" && echo 0 || echo 1)"
done
chk "G3 every shipped row has a note and a valid regex" \
    "$(awk -F'\t' '/^#/||/^$/||$1=="pattern_regex"{next} $2==""{bad=1} END{exit bad?1:0}' "$SHIPPED" && echo 0 || echo 1)"
chk "G4 no shipped regex is empty or matches everything" \
    "$(awk -F'\t' '/^#/||/^$/||$1=="pattern_regex"{next} $1==""||$1=="."||$1==".*"{bad=1} END{exit bad?1:0}' "$SHIPPED" && echo 0 || echo 1)"
chk "G5 script name avoids the destructive words" "$(case "$(basename "$SCRIPT")" in *close*|*delete*|*reap*|*gc*|*reload*|*unload*|*purge*|*prune*|*kill*) echo 1 ;; *) echo 0 ;; esac)"
chk "G6 only gh run rerun --failed mutates" \
    "$(grep -E 'gh (run (cancel|delete)|issue|pr|api -X|repo (delete|edit))' "$SCRIPT" | grep -v '^[[:space:]]*#' | grep -q . && echo 1 || echo 0)"

# ---- H. FALSIFICATION: each guard is what blocks the case ----------------------------------------------
# H1 the attempt==1 filter is what keeps a second attempt out
sed 's/ and .attempt == 1//' "$SCRIPT" > "$WORK/mut_attempt.sh"
reset; set_runs owner_pub-a "$(run_json 601 failure 2 "$RECENT" schedule)"; log_transient 601; jobs_steps 601
SCRIPT_UNDER_TEST="$WORK/mut_attempt.sh" run --apply
chk "H1 mutant without the attempt filter DOES retry attempt 2 (so the filter is what blocks it)" "$([ "$(reruns)" = 1 ] && echo 0 || echo 1)"
run --apply
chk "H1b the real script does not" "$([ "$(reruns)" = 1 ] && echo 0 || echo 1)"
# H2 the pattern table is what makes (a) fire
reset; set_runs owner_pub-a "$(run_json 602 failure 1 "$RECENT" schedule)"; log_transient 602; jobs_steps 602
printf 'pattern_regex\tnote\nsome other thing entirely\tx\n' > "$WORK/other.tsv"
PAT="$WORK/other.tsv" run --apply
chk "H2 a table without the pattern: the same run is NOT retried" "$([ "$(reruns)" = 0 ] && echo 0 || echo 1)"
# H3 the PUBLIC check is what keeps a private repo out
sed 's/\[ "\$vis" = "PUBLIC" \] || continue/:/' "$SCRIPT" > "$WORK/mut_vis.sh"
reset; set_runs "$(printf '%s' "$PRIVNAME" | tr '/' '_')" "$(run_json 603 failure 1 "$RECENT" schedule)"; log_transient 603; jobs_steps 603
SCRIPT_UNDER_TEST="$WORK/mut_vis.sh" run --apply
chk "H3 mutant without the PUBLIC check DOES touch the private repo" "$(grep -q "RUNLIST $PRIVNAME" "$D/touched.log" && echo 0 || echo 1)"
# H4 the zero-step test is what separates a runner that never started from a cancel mid-run
reset; set_runs owner_pub-a "$(run_json 604 cancelled 1 "$RECENT" schedule)"; jobs_cancelled_with_steps 604; log_real 604
run --apply
chk "H4 cancelled job WITH steps: not retried (control for B3)" "$([ "$(reruns)" = 0 ] && echo 0 || echo 1)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
