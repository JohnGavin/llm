#!/usr/bin/env bash
# llm#1458 part 2: scanner_triage.sh + the email's use of its outcome.
#
# Every case builds its own scratch HOME, scratch DuckDB, scratch files and a
# STUB `gh` on PATH, and passes them explicitly (HOME, UNIFIED_DB_PATH,
# SCANNER_TRIAGE_DIR, GH_STUB_DIR), so it measures the fixture and never the
# live DB, the real ~/.claude, or GitHub. The policy table under test is the
# shipped one (.claude/state/scanner_policy.tsv).
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
TRIAGE="${SCANNER_TRIAGE_SCRIPT:-$ROOT/.claude/scripts/scanner_triage.sh}"
POLICY="$ROOT/.claude/state/scanner_policy.tsv"
LIB="$ROOT/.claude/scripts/lib/scanner_triage_lib.R"
SCHEMA="$ROOT/.claude/scripts/housekeeping_schema_init.sql"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scanner_triage_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TAB="$(printf '\t')"
TODAY="$(date -u +%Y-%m-%d)"

pass=0; total=0
check() { # check DESC CONDITION-RESULT(0=true)
    total=$((total + 1))
    if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else echo "FAIL: $1"; fi
}
mode_of() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1"; }

# --- stub gh -----------------------------------------------------------------
STUB="$WORK/stubbin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
d="$GH_STUB_DIR"
echo "gh $*" >> "$d/calls.log"
if [ -f "$d/fail" ]; then echo "stub gh: forced failure" >&2; exit 1; fi
sub="$1 $2"; shift 2
bodyfile=""; title=""
prev=""
for a in "$@"; do
    [ "$prev" = "--body-file" ] && bodyfile="$a"
    [ "$prev" = "--title" ] && title="$a"
    prev="$a"
done
case "$sub" in
    "issue list")
        for f in "$d"/issue_*.title; do
            [ -e "$f" ] || continue
            n="$(basename "$f" .title)"; n="${n#issue_}"
            printf '%s\t%s\n' "$n" "$(cat "$f")"
        done ;;
    "issue view")
        n="$1"; cat "$d/issue_$n.body"
        for c in "$d"/issue_"$n".comment.*; do [ -e "$c" ] && cat "$c"; done
        exit 0 ;;
    "issue create")
        n=$(( $(cat "$d/counter" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$d/counter"
        printf '%s' "$title" > "$d/issue_$n.title"; cp "$bodyfile" "$d/issue_$n.body"
        echo "https://github.com/stub/stub/issues/$n" ;;
    "issue comment")
        n="$1"; c=$(( $(cat "$d/ccounter" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$d/ccounter"
        cp "$bodyfile" "$d/issue_$n.comment.$c" ;;
    *) echo "stub gh: unexpected: $sub" >&2; exit 64 ;;
esac
EOF
chmod +x "$STUB/gh"

# --- scenario builder ----------------------------------------------------------
# new_case NAME  -> sets H DB GH_STUB_DIR for a fresh scratch world
new_case() {
    CASE="$WORK/$1"; rm -rf "$CASE"; mkdir -p "$CASE/home/.claude/logs" "$CASE/gh" "$CASE/files"
    H="$CASE/home"; DB="$CASE/u.duckdb"; GH_STUB_DIR="$CASE/gh"; OUTD="$H/.claude/logs/scanner_triage"
    : > "$GH_STUB_DIR/calls.log"
}
# seed_db CUR_FILE [PREV_FILE]: files hold "name<TAB>path<TAB>note" lines.
# The previous run (2 days earlier) always exists unless PREV_FILE is "none".
seed_db() {
    local cur="$1" prev="${2:-}" n_cur n_prev sqlf="$CASE/seed.sql"
    rm -f "$DB"
    duckdb -init /dev/null "$DB" -c ".read $SCHEMA" >/dev/null 2>&1
    n_cur=$(awk 'END{print NR}' "$cur")
    : > "$sqlf"
    if [ "$prev" != "none" ]; then
        if [ -z "$prev" ]; then prev="$CASE/prev.tsv"; printf 'cred-shape\t/prev/only/file\tprev\n' > "$prev"; fi
        n_prev=$(awk 'END{print NR}' "$prev")
        echo "INSERT INTO housekeeping_runs (id,task,source_script,started_at,ended_at,status,rows_written) VALUES ('prev-run','secret_exposure_scan','t', now() - INTERVAL 2 DAY, now() - INTERVAL 2 DAY,'ok',$n_prev);" >> "$sqlf"
        awk -F'\t' -v q="'" '{printf "INSERT INTO secret_scan_findings VALUES (md5(" q "prev-run:%d" q ")," q "prev-run" q ", now() - INTERVAL 2 DAY," q "3" q "," q "high" q "," q "%s" q "," q "-" q "," q "%s" q "," q "%s" q ");\n", NR, $2, $1, $3}' "$prev" >> "$sqlf"
    fi
    echo "INSERT INTO housekeeping_runs (id,task,source_script,started_at,ended_at,status,rows_written) VALUES ('cur-run','secret_exposure_scan','t', now(), now(),'ok',$n_cur);" >> "$sqlf"
    awk -F'\t' -v q="'" '{printf "INSERT INTO secret_scan_findings VALUES (md5(" q "cur-run:%d" q ")," q "cur-run" q ", now()," q "3" q "," q "high" q "," q "%s" q "," q "-" q "," q "%s" q "," q "%s" q ");\n", NR, $2, $1, $3}' "$cur" >> "$sqlf"
    duckdb -init /dev/null "$DB" -c ".read $sqlf" >/dev/null 2>&1
}
run_triage() { # run_triage ARGS...  -> RC, OUT
    OUT="$(env HOME="$H" UNIFIED_DB_PATH="$DB" SCANNER_TRIAGE_DIR="$OUTD" \
        SCANNER_POLICY_FILE="$POLICY" GH_STUB_DIR="$GH_STUB_DIR" PATH="${PRE_PATH:+$PRE_PATH:}$STUB:$PATH" \
        bash "$TRIAGE" "$@" 2>&1)"
    RC=$?
}
outcome() { cat "$OUTD/$TODAY.json" 2>/dev/null; }

# --- (a) fix safety conditions ------------------------------------------------
new_case a
mkdir -p "$CASE/files/.claude/hooks" "$CASE/files/plain" "$CASE/gitrepo"
printf 'x\n' > "$CASE/files/plain/ok.env";           chmod 644 "$CASE/files/plain/ok.env"
printf '#!/bin/sh\n' > "$CASE/files/plain/run.sh";   chmod 755 "$CASE/files/plain/run.sh"
printf 'x\n' > "$CASE/files/.claude/hooks/h.sh";     chmod 644 "$CASE/files/.claude/hooks/h.sh"
printf 'x\n' > "$CASE/gitrepo/in_repo.env";          chmod 644 "$CASE/gitrepo/in_repo.env"
git -C "$CASE/gitrepo" init -q 2>/dev/null
ln -s "$CASE/files/plain/ok.env" "$CASE/files/plain/link.env"
# Positive control: the "outside a work tree" premise actually holds for the fixture.
git -C "$CASE/files/plain" rev-parse --is-inside-work-tree >/dev/null 2>&1
check "(a) control: the fixture dir is NOT inside a git work tree" $(( $? == 0 ? 1 : 0 ))
git -C "$CASE/gitrepo" rev-parse --is-inside-work-tree >/dev/null 2>&1
check "(a) control: the git fixture IS inside a work tree" $?
{
    printf 'bad-permissions\t%s\tn\n' "$CASE/files/plain/ok.env"
    printf 'bad-permissions\t%s\tn\n' "$CASE/files/plain/run.sh"
    printf 'bad-permissions\t%s\tn\n' "$CASE/files/.claude/hooks/h.sh"
    printf 'bad-permissions\t%s\tn\n' "$CASE/gitrepo/in_repo.env"
    printf 'bad-permissions\t%s\tn\n' "$CASE/files/plain/link.env"
} > "$CASE/cur.tsv"
seed_db "$CASE/cur.tsv"

run_triage --dry-run
check "(a) dry-run exits 0 (got $RC: $OUT)" $(( RC == 0 ? 0 : 1 ))
check "(a) dry-run: the plain 644 file is NOT chmod'd" $(( $(mode_of "$CASE/files/plain/ok.env") == 644 ? 0 : 1 ))
check "(a) dry-run: nothing fixed in the outcome" $(outcome | grep -q '"fixed":0,'; echo $?)
check "(a) dry-run writes no DESTRUCTIVE log line" $( [ -s "$H/.claude/logs/scanner_triage.log" ]; echo $(( $? == 0 ? 1 : 0 )) )

run_triage --apply
check "(a) apply exits 0 (got $RC: $OUT)" $(( RC == 0 ? 0 : 1 ))
check "(a) apply: the plain 644 file outside a work tree IS chmod'd to 600" $(( $(mode_of "$CASE/files/plain/ok.env") == 600 ? 0 : 1 ))
check "(a) apply: the executable file is NEVER chmod'd" $(( $(mode_of "$CASE/files/plain/run.sh") == 755 ? 0 : 1 ))
check "(a) apply: the hook-path file is NEVER chmod'd" $(( $(mode_of "$CASE/files/.claude/hooks/h.sh") == 644 ? 0 : 1 ))
check "(a) apply: the file inside a git work tree is NEVER chmod'd" $(( $(mode_of "$CASE/gitrepo/in_repo.env") == 644 ? 0 : 1 ))
check "(a) apply: exactly 1 fixed, 4 left for the owner" $(outcome | grep -q '"fixed":1,.*"needs_you":4,'; echo $?)
check "(a) apply: a DESTRUCTIVE line with a path hash and old mode is logged" \
    $(grep -q "^DESTRUCTIVE: .* path-hash=[0-9a-f]\{16\} old-mode=644 " "$H/.claude/logs/scanner_triage.log"; echo $?)
check "(a) the log holds the hash, not the path" $(grep -q "ok.env" "$H/.claude/logs/scanner_triage.log"; echo $(( $? == 0 ? 1 : 0 )))
check "(a) the outcome carries the exact revert command" $(outcome | grep -q "chmod 644 '$CASE/files/plain/ok.env'"; echo $?)
check "(a) a revert command from the outcome restores the old mode" $(
    cmd="$(outcome | sed -n 's/.*"reverts":\["\([^"]*\)".*/\1/p')"; eval "$cmd"; [ "$(mode_of "$CASE/files/plain/ok.env")" = 644 ]; echo $? )

# --- (b) cap of 10 ------------------------------------------------------------
new_case b
: > "$CASE/cur.tsv"
i=1
while [ $i -le 12 ]; do
    printf 'x\n' > "$CASE/files/f$i.env"; chmod 644 "$CASE/files/f$i.env"
    printf 'bad-permissions\t%s\tn\n' "$CASE/files/f$i.env" >> "$CASE/cur.tsv"
    i=$((i + 1))
done
seed_db "$CASE/cur.tsv"
run_triage --apply
n600=0; i=1
while [ $i -le 12 ]; do [ "$(mode_of "$CASE/files/f$i.env")" = 600 ] && n600=$((n600 + 1)); i=$((i + 1)); done
check "(b) apply stops at the cap: exactly 10 of 12 chmod'd (got $n600)" $(( n600 == 10 ? 0 : 1 ))
check "(b) the 2 over the cap are counted as needing the owner" $(outcome | grep -q '"fixed":10,.*"needs_you":2,'; echo $?)

# --- (b2) same cap/log checks under the SYSTEM chmod and a BSD-like chmod ----------
# Regression: `chmod 600 -- FILE` is a FILE operand `--` on macOS /bin/chmod (the
# chmod happens, then it exits 1), which made apply mode report "chmod-failed",
# count no mutation (cap bypassed), and write no DESTRUCTIVE line. GNU chmod
# accepts `--`, so the stub below mimics BSD to catch it on Linux/CI too.
BSDSTUB="$WORK/bsdchmod"; mkdir -p "$BSDSTUB"
cat > "$BSDSTUB/chmod" <<'EOF'
#!/bin/sh
# BSD-like: every operand after the mode is a file, including a literal "--".
mode="$1"; shift; rc=0
for f in "$@"; do
    if [ "$f" = "--" ]; then echo "chmod: --: No such file or directory" >&2; rc=1
    else /bin/chmod "$mode" "$f" || rc=1; fi
done
exit $rc
EOF
/bin/chmod +x "$BSDSTUB/chmod"
apply_cap_case() { # apply_cap_case LABEL PRE_PATH
    local lab="$1" i n600 nlog
    new_case "b2_$lab"
    : > "$CASE/cur.tsv"; i=1
    while [ $i -le 12 ]; do
        printf 'x\n' > "$CASE/files/f$i.env"; /bin/chmod 644 "$CASE/files/f$i.env"
        printf 'bad-permissions\t%s\tn\n' "$CASE/files/f$i.env" >> "$CASE/cur.tsv"
        i=$((i + 1))
    done
    seed_db "$CASE/cur.tsv"
    PRE_PATH="$2" run_triage --apply
    n600=0; i=1
    while [ $i -le 12 ]; do [ "$(mode_of "$CASE/files/f$i.env")" = 600 ] && n600=$((n600 + 1)); i=$((i + 1)); done
    nlog=$(grep -c "^DESTRUCTIVE: .* path-hash=[0-9a-f]\{16\} old-mode=644 " "$H/.claude/logs/scanner_triage.log" 2>/dev/null)
    check "(b2/$lab) exactly 10 of 12 chmod'd (got $n600)" $(( n600 == 10 ? 0 : 1 ))
    check "(b2/$lab) 10 fixed, 2 left for the owner (cap holds)" $(outcome | grep -q '"fixed":10,.*"needs_you":2,'; echo $?)
    check "(b2/$lab) 10 DESTRUCTIVE lines with path-hash and old-mode (got ${nlog:-0})" $(( ${nlog:-0} == 10 ? 0 : 1 ))
    check "(b2/$lab) no chmod-failed note" $(outcome | grep -q 'chmod-failed'; echo $(( $? == 0 ? 1 : 0 )))
    check "(b2/$lab) outcome carries revert commands" $(outcome | grep -q "chmod 644 '$CASE/files/f"; echo $?)
}
apply_cap_case sys /bin
apply_cap_case bsdstub "$BSDSTUB"
PRE_PATH=""

# --- (c) unlisted type is human;standing rows are not new -----------------------
new_case c
printf 'x\n' > "$CASE/files/c.env"; chmod 644 "$CASE/files/c.env"
{
    printf 'brand-new-type\t%s\tn\n' "$CASE/files/c.env"
    printf 'known-store-in-worktree\t/some/store\tn\n'
    printf 'known-store-sibling-copy\t/standing/copy\tn\n'
} > "$CASE/cur.tsv"
printf 'known-store-sibling-copy\t/standing/copy\tn\n' > "$CASE/prev.tsv"
seed_db "$CASE/cur.tsv" "$CASE/prev.tsv"
awk -F'\t' '$2=="brand-new-type"' "$POLICY" | grep -q . ; check "(c) control: brand-new-type is absent from the policy table" $(( $? == 0 ? 1 : 0 ))
run_triage --apply
check "(c) exits 0 (got $RC: $OUT)" $(( RC == 0 ? 0 : 1 ))
check "(c) the 2 NEW human/unlisted rows need the owner, the standing row is not counted" $(outcome | grep -q '"fixed":0,"filed":0,"tracked":0,"already_ok":0,"needs_you":2,'; echo $?)
check "(c) nothing was chmod'd" $(( $(mode_of "$CASE/files/c.env") == 644 ? 0 : 1 ))
check "(c) no gh call was made for human rows" $( [ ! -s "$GH_STUB_DIR/calls.log" ]; echo $? )

# --- (d) dedupe -------------------------------------------------------------------
new_case d
{
    printf 'cred-shape\t/p/one\tn\n'
    printf 'cred-shape\t/p/two\tn\n'
    printf 'unfiltered-capture\t/p/three\tn\n'
} > "$CASE/cur.tsv"
seed_db "$CASE/cur.tsv"
run_triage --dry-run
check "(d) dry-run creates nothing and counts both types as needing the owner" $(( $(ls "$GH_STUB_DIR" | grep -c '^issue_') == 0 ? 0 : 1 ))
check "(d) dry-run made no create/comment call" $(grep -cE 'issue (create|comment)' "$GH_STUB_DIR/calls.log" | grep -qx 0; echo $?)
run_triage --apply
nissues=$(ls "$GH_STUB_DIR" | grep -c '\.title$')
check "(d) first apply opens exactly one issue per type (2), got $nissues" $(( nissues == 2 ? 0 : 1 ))
check "(d) the 3 rows are counted as filed" $(outcome | grep -q '"filed":3,.*"needs_you":0,'; echo $?)
run_triage --apply
check "(d) second apply the same day opens no second issue" $(( $(ls "$GH_STUB_DIR" | grep -c '\.title$') == 2 ? 0 : 1 ))
check "(d) second apply the same day adds no comment" $(( $(ls "$GH_STUB_DIR" | grep -c 'comment') == 0 ? 0 : 1 ))
check "(d) second apply counts them as tracked" $(outcome | grep -q '"filed":0,"tracked":3,'; echo $?)
# Next day: the open issue's body carries YESTERDAY's marker.
for f in "$GH_STUB_DIR"/issue_*.body; do printf 'Scanner: x\nscanner-triage-day:2000-01-01\n' > "$f"; done
run_triage --apply
ncom=$(ls "$GH_STUB_DIR" | grep -c 'comment')
check "(d) a later day adds one comment per open issue (2), got $ncom, and no new issue" $(( ncom == 2 && $(ls "$GH_STUB_DIR" | grep -c '\.title$') == 2 ? 0 : 1 ))
run_triage --apply
check "(d) a second run on that day adds no further comment" $(( $(ls "$GH_STUB_DIR" | grep -c 'comment') == 2 ? 0 : 1 ))
check "(d) a closed issue is not matched (stub lists open issues only): no create on repeat" $(( $(ls "$GH_STUB_DIR" | grep -c '\.title$') == 2 ? 0 : 1 ))

# --- (e) public-repo hygiene: no path/value in anything sent to GitHub -------------
new_case e
SENT_PATH="/SENTINELPATH_7c1e/home/owner/credentials.env"
SENT_VAL="SENTINELVALUE_ghp_9f8e7d6c5b4a"
printf 'cred-shape\t%s\tline holds %s\n' "$SENT_PATH" "$SENT_VAL" > "$CASE/cur.tsv"
seed_db "$CASE/cur.tsv"
run_triage --apply
nt=$(ls "$GH_STUB_DIR" | grep -c '\.title$')
check "(e) control: an issue was actually filed (otherwise the grep below is vacuous)" $(( nt == 1 ? 0 : 1 ))
printf 'x\n' > /dev/null
check "(e) no issue title/body contains the sentinel path or value" $(cat "$GH_STUB_DIR"/issue_* 2>/dev/null | grep -q 'SENTINEL'; echo $(( $? == 0 ? 1 : 0 )))
check "(e) the gh call log contains no sentinel" $(grep -q 'SENTINEL' "$GH_STUB_DIR/calls.log"; echo $(( $? == 0 ? 1 : 0 )))
check "(e) the issue body names scanner, type, count and run id" $(grep -q 'secret_exposure_scan' "$GH_STUB_DIR"/issue_*.body && grep -q 'cred-shape' "$GH_STUB_DIR"/issue_*.body && grep -q 'cur-run' "$GH_STUB_DIR"/issue_*.body; echo $?)
for f in "$GH_STUB_DIR"/issue_*.body; do printf 'old\nscanner-triage-day:2000-01-01\n' > "$f"; done
run_triage --apply
check "(e) a comment was posted (control) and holds no sentinel" $(cat "$GH_STUB_DIR"/issue_*.comment.* | grep -q 'cred-shape' && ! cat "$GH_STUB_DIR"/issue_*.comment.* | grep -q SENTINEL; echo $?)

# --- (f) INDETERMINATE, never a silent zero -----------------------------------------
new_case f
printf 'cred-shape\t/p/one\tn\n' > "$CASE/cur.tsv"
seed_db "$CASE/cur.tsv"
echo 'this is not a duckdb file' > "$CASE/garbage.duckdb"
DB_SAVE="$DB"; DB="$CASE/garbage.duckdb"
run_triage --apply
check "(f) unreadable DB -> exit 3 (got $RC: $OUT)" $(( RC == 3 ? 0 : 1 ))
check "(f) unreadable DB says INDETERMINATE and why" $(echo "$OUT" | grep -q 'INDETERMINATE'; echo $?)
DB="$CASE/missing.duckdb"
run_triage --apply
check "(f) missing DB -> exit 3 (got $RC)" $(( RC == 3 ? 0 : 1 ))
DB="$DB_SAVE"
seed_db "$CASE/cur.tsv" none
run_triage --apply
check "(f) no earlier run to compare against -> exit 3 (got $RC)" $(( RC == 3 ? 0 : 1 ))
check "(f) ... and the outcome file says indeterminate with a reason" $(outcome | grep -q '"status":"indeterminate","why":"no earlier run'; echo $?)
mkdir -p "$CASE/indet_dir"; cp "$OUTD"/*.json "$CASE/indet_dir/"
rm -f "$OUTD"/*.json
seed_db "$CASE/cur.tsv"
touch "$GH_STUB_DIR/fail"
run_triage --apply
check "(f) gh unavailable with auto-file rows -> exit 3 (got $RC)" $(( RC == 3 ? 0 : 1 ))
check "(f) ... and those rows are counted as needing the owner, not as filed" $(outcome | grep -q '"filed":0,.*"needs_you":1,'; echo $?)
rm -f "$GH_STUB_DIR/fail"
run_triage --bogus-flag
check "(f) a bad flag is a usage error (exit 2, got $RC)" $(( RC == 2 ? 0 : 1 ))

# --- (g) the email's assessment of the outcome -------------------------------------
cat > "$WORK/assess.R" <<EOF
source("$LIB")
pol <- scanner_policy_read("$POLICY")
rd <- function(dir) scanner_triage_outcome_read(dir, "cur-run", "secret_exposure_scan")
a <- function(types, dir) scanner_triage_assess(types, "secret_exposure_scan", pol, rd(dir))
emit <- function(k, v) cat(sprintf("%s=%s\n", k, v))
cls <- scanner_class_of(pol, "secret_exposure_scan", c("brand-new-type", "bad-permissions", "cred-shape"))
emit("class_unlisted", cls[[1]]); emit("class_fix", cls[[2]]); emit("class_file", cls[[3]])
emit("class_nopolicy", scanner_class_of(NULL, "secret_exposure_scan", "bad-permissions"))
x <- a(c(rep("bad-permissions", 5)), "$WORK/a/home/.claude/logs/scanner_triage")
emit("a_fixed", x[["fixed"]]); emit("a_needs", x[["needs_you"]]); emit("a_ind", x[["indeterminate"]]); emit("a_reverts", length(x[["reverts"]]))
x <- a(c("cred-shape", "cred-shape", "unfiltered-capture"), "$WORK/d/home/.claude/logs/scanner_triage")
emit("d_needs", x[["needs_you"]]); emit("d_ind", x[["indeterminate"]]); emit("d_handled", x[["filed"]] + x[["tracked"]])
x <- a(c("brand-new-type", "known-store-in-worktree"), "$WORK/c/home/.claude/logs/scanner_triage")
emit("c_needs", x[["needs_you"]])
x <- a(c("cred-shape"), "$WORK/nonexistent")
emit("none_needs", x[["needs_you"]]); emit("none_ind", x[["indeterminate"]]); emit("none_unres", x[["unresolved"]])
x <- a(c("cred-shape", "brand-new-type"), "$WORK/nonexistent")
emit("mix_needs", x[["needs_you"]]); emit("mix_ind", x[["indeterminate"]])
x <- scanner_triage_assess(character(0), "secret_exposure_scan", pol, rd("$WORK/nonexistent"))
emit("empty_needs", x[["needs_you"]]); emit("empty_ind", x[["indeterminate"]])
x <- a(c("cred-shape"), "$WORK/f/indet_dir")
emit("f_ind", x[["indeterminate"]]); emit("f_needs", x[["needs_you"]])
x <- a(c("cred-shape"), "$WORK/f/home/.claude/logs/scanner_triage")
emit("g_needs", x[["needs_you"]]); emit("g_ind", x[["indeterminate"]])
emit("other_run", scanner_triage_outcome_read("$WORK/d/home/.claude/logs/scanner_triage", "some-other-run", "secret_exposure_scan")[["status"]])
EOF
RSCRIPT="$(command -v Rscript || true)"
if [ -z "$RSCRIPT" ]; then
    echo "SKIP: Rscript not found -- (g) email assessment NOT exercised in this environment"
else
    # (g) reuses the outcomes written by cases a, d, c above (real triage output).
    # Case d's outcome dir holds the LAST apply (tracked); case f was left with gh failing.
    RES="$("$RSCRIPT" "$WORK/assess.R" 2>&1)"
    got() { printf '%s\n' "$RES" | grep -qx "$1=$2"; echo $?; }
    check "(g) unlisted type is class human" $(got class_unlisted human)
    check "(g) bad-permissions is auto-fix, cred-shape auto-file" $(( $(got class_fix auto-fix) + $(got class_file auto-file) ))
    check "(g) an unreadable policy makes everything human" $(got class_nopolicy human)
    check "(g) auto-fix: 1 fixed, the 4 unsafe rows need the owner, a revert command is listed" $(( $(got a_fixed 1) + $(got a_needs 4) + $(got a_ind FALSE) + $(got a_reverts 1) ))
    check "(g) auto-file rows with an outcome: nobody needs the owner, not indeterminate" $(( $(got d_needs 0) + $(got d_ind FALSE) + $(got d_handled 3) ))
    check "(g) human rows need the owner" $(got c_needs 2)
    check "(g) auto rows with NO outcome are indeterminate, not ok and not action" $(( $(got none_needs 0) + $(got none_ind TRUE) + $(got none_unres 1) ))
    check "(g) a human row alongside an unresolved auto row still needs the owner" $(( $(got mix_needs 1) + $(got mix_ind TRUE) ))
    check "(g) no new rows -> nothing needed, not indeterminate" $(( $(got empty_needs 0) + $(got empty_ind FALSE) ))
    check "(g) an outcome the triage wrote as indeterminate (no baseline) makes auto rows indeterminate" $(( $(got f_ind TRUE) + $(got f_needs 0) ))
    check "(g) rows triage could not file (gh down) need the owner" $(( $(got g_needs 1) + $(got g_ind FALSE) ))
    check "(g) an outcome for another run is not accepted" $(got other_run missing)
fi

echo "scanner_triage: ${pass}/${total} PASS"
[ "$pass" -eq "$total" ]
