#!/usr/bin/env bash
# tests/test_auto_merge_sweep.sh -- bin/auto_merge_sweep.sh (llm#1471).
# Stubs `gh` on PATH and the merge gate via AUTO_MERGE_GATE. Network-free,
# bash 3.2 / BSD+GNU portable. Asserts EXACT exit codes and verdict lines.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$ROOT/bin/auto_merge_sweep.sh"
REAL_EXCL="$ROOT/.claude/state/auto_merge_exclusions.txt"
W="$(mktemp -d "${TMPDIR:-/tmp}/ams_test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB="$W/stub"; BIN="$W/bin"; FAKE="$W/repo"
mkdir -p "$STUB" "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
d="$STUB_DIR"
case "$1 $2" in
  "auth status") exit "$(cat "$d/auth_rc" 2>/dev/null || echo 0)" ;;
  "pr list") cat "$d/list.json" || exit 1 ;;
  "pr view") cat "$d/view_$3.json" 2>/dev/null || exit 1 ;;
  "repo view") echo "O/R" ;;
  "api repos/O/R/pulls/"*) : ;;
esac
if [ "$1" = "api" ]; then
  n="${2##*/}"
  if [ -f "$d/assoc_$n" ]; then cat "$d/assoc_$n"; else exit 1; fi
fi
exit 0
EOF
chmod +x "$BIN/gh"
cat > "$W/gate.sh" <<'EOF'
#!/usr/bin/env bash
exit "${GATE_RC:-0}"
EOF
export STUB_DIR="$STUB" GATE_RC=0 AUTO_MERGE_REPO_DIR="$FAKE" AUTO_MERGE_GATE="$W/gate.sh"
export PATH="$BIN:$PATH"

# ---- fixtures ---------------------------------------------------------------
setup_repo() {  # $1 = toggle line text after the marker, or "-" for no AGENTS.md
  rm -rf "$FAKE"
  mkdir -p "$FAKE/.claude/state" "$FAKE/.claude/launchd" "$FAKE/bin/launchd-recorders"
  cp "$REAL_EXCL" "$FAKE/.claude/state/auto_merge_exclusions.txt"
  if [ "$1" != "-" ]; then
    printf '# x\n**Auto-Merge Policy:** %s (global)\n' "$1" > "$FAKE/AGENTS.md"
  fi
  printf '<string>/x/.claude/scripts/zzz_nightly.sh</string>\n' > "$FAKE/.claude/launchd/com.t.plist"
  printf '#!/bin/sh\nexec other_job.sh\n' > "$FAKE/bin/launchd-recorders/rec"
  rm -f "$STUB"/*
  GATE_RC=0; export GATE_RC
  unset AUTO_MERGE_EXCLUSIONS
}

checks_json() {  # spec: comma list of S P K F N X(status-context ok) Y(status-context fail)
  local out="" c item
  for c in $(printf '%s' "$1" | tr ',' ' '); do
    case "$c" in
      S) item='{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}' ;;
      P) item='{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}' ;;
      K) item='{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}' ;;
      N) item='{"__typename":"CheckRun","status":"COMPLETED","conclusion":"NEUTRAL"}' ;;
      F) item='{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}' ;;
      X) item='{"__typename":"StatusContext","state":"SUCCESS"}' ;;
      Y) item='{"__typename":"StatusContext","state":"FAILURE"}' ;;
      *) item='' ;;
    esac
    if [ -n "$item" ]; then
      if [ -n "$out" ]; then out="$out,"; fi
      out="$out$item"
    fi
  done
  printf '[%s]' "$out"
}

# mkpr N assoc state draft merge "labels" "checks" "files" [changed]
mkpr() {
  local n="$1" assoc="$2" state="$3" draft="$4" merge="$5" labels="$6" checks="$7" files="$8" changed="${9:-}"
  local lj="" fj="" l f nf=0
  for l in $labels; do
    if [ -n "$lj" ]; then lj="$lj,"; fi
    lj="$lj{\"name\":\"$l\"}"
  done
  for f in $files; do
    if [ -n "$fj" ]; then fj="$fj,"; fi
    fj="$fj{\"path\":\"$f\"}"
    nf=$((nf + 1))
  done
  if [ -z "$changed" ]; then changed="$nf"; fi
  printf '%s' "$assoc" > "$STUB/assoc_$n"
  printf '{"number":%s,"state":"%s","isDraft":%s,"mergeStateStatus":"%s","labels":[%s],"statusCheckRollup":%s,"files":[%s],"changedFiles":%s}\n' \
    "$n" "$state" "$draft" "$merge" "$lj" "$(checks_json "$checks")" "$fj" "$changed" > "$STUB/view_$n.json"
}

# A fully eligible PR; individual tests override one argument.
good() { mkpr 1 OWNER OPEN false CLEAN "bug" "S,S" "R/foo.R tests/test_foo.R"; }

OUT=""; RC=0
run() { OUT="$(bash "$SWEEP" --repo O/R "$@" 2>"$W/err")"; RC=$?; }

expect() {  # label pr verdict reason expected_rc
  local label="$1" pr="$2" verdict="$3" reason="$4" erc="${5:-0}"
  local want line
  want="$(printf '%s\t%s\t%s' "$pr" "$verdict" "$reason")"
  line="$(printf '%s\n' "$OUT" | grep -E "^$pr	" | head -1)"
  if [ "$RC" -ne "$erc" ]; then bad "$label: exit $RC, wanted $erc (out: $OUT)"; return; fi
  if [ "$line" != "$want" ]; then bad "$label: got '$line', wanted '$want'"; return; fi
  ok
}

# ---- 1. baseline eligible + toggle -------------------------------------------
setup_repo ON; good; run 1
expect "eligible baseline" 1 ELIGIBLE all-conditions-met
if printf '%s\n' "$OUT" | grep -qx 'prs=1 eligible=1 not_eligible=0 indeterminate=0'; then ok; else bad "summary line: $OUT"; fi

setup_repo OFF; good; run 1
expect "toggle OFF" 1 NOT-ELIGIBLE toggle-off
setup_repo MAYBE; good; run 1
expect "toggle unparsable" 1 INDETERMINATE toggle-unparsable
setup_repo -; good; run 1
expect "toggle AGENTS.md missing" 1 INDETERMINATE toggle-unreadable

# ---- 2. author, state, draft, labels -----------------------------------------
setup_repo ON; mkpr 1 CONTRIBUTOR OPEN false CLEAN "" "S" "R/a.R"; run 1
expect "untrusted author" 1 NOT-ELIGIBLE untrusted-author
setup_repo ON; mkpr 1 OWNER OPEN true CLEAN "" "S" "R/a.R"; run 1
expect "draft" 1 NOT-ELIGIBLE draft
setup_repo ON; mkpr 1 OWNER MERGED false CLEAN "" "S" "R/a.R"; run 1
expect "not open" 1 NOT-ELIGIBLE not-open
setup_repo ON; good; rm -f "$STUB/assoc_1"; run 1
expect "author lookup fails" 1 INDETERMINATE author-lookup-failed
setup_repo ON; rm -f "$STUB/view_1.json"; printf 'OWNER' > "$STUB/assoc_1"; run 1
expect "view fails" 1 INDETERMINATE view-failed
for lab in hold needs-owner do-not-merge; do
  setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "bug $lab" "S" "R/a.R"; run 1
  expect "label $lab" 1 NOT-ELIGIBLE "hold-label:$lab"
done

# ---- 3. merge state and checks -----------------------------------------------
setup_repo ON; mkpr 1 OWNER OPEN false DIRTY "" "S" "R/a.R"; run 1
expect "DIRTY" 1 NOT-ELIGIBLE merge-conflict
setup_repo ON; mkpr 1 OWNER OPEN false UNKNOWN "" "S" "R/a.R"; run 1
expect "merge state UNKNOWN" 1 INDETERMINATE merge-state-unknown
setup_repo ON; mkpr 1 OWNER OPEN false BEHIND "" "S" "R/a.R"; run 1
expect "BEHIND alone is not a conflict" 1 ELIGIBLE all-conditions-met
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S,P" "R/a.R"; run 1
expect "pending check" 1 NOT-ELIGIBLE checks-pending
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S,K" "R/a.R"; run 1
expect "skipped check" 1 NOT-ELIGIBLE checks-not-success
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S,N" "R/a.R"; run 1
expect "neutral check" 1 NOT-ELIGIBLE checks-not-success
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S,F" "R/a.R"; run 1
expect "failed check" 1 NOT-ELIGIBLE checks-not-success
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "" "R/a.R"; run 1
expect "zero checks" 1 NOT-ELIGIBLE no-checks
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "X" "R/a.R"; run 1
expect "status context success" 1 ELIGIBLE all-conditions-met
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "X,Y" "R/a.R"; run 1
expect "status context failure" 1 NOT-ELIGIBLE checks-not-success

# ---- 4. exclusion classes ----------------------------------------------------
for p in .claude/hooks/x.sh .claude/rules/a.md .claude/launchd/x.plist \
         bin/launchd-recorders/foo AGENTS.md sub/CLAUDE.md default.nix default.R \
         .claude/settings.json db/x_schema.sql bin/x_schema_apply.sh secrets.env \
         .Renviron .github/workflows/ci.yml .claude/scripts/rotate_keys.sh \
         scripts/my_credential_helper.sh scripts/x_autoclose.sh \
         scripts/job_revalidate.R scripts/job_reaper.sh scripts/worktree_gc.sh \
         scripts/branch_gc.sh docs/index.html; do
  setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/ok.R $p"; run 1
  expect "excluded $p" 1 NOT-ELIGIBLE "excluded-path:$p"
done

# scheduled script found only through a plist reference; falsify by removing it
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" ".claude/scripts/zzz_nightly.sh"; run 1
expect "scheduled via plist" 1 NOT-ELIGIBLE scheduled-script:zzz_nightly.sh
printf '<string>nothing</string>\n' > "$FAKE/.claude/launchd/com.t.plist"; run 1
expect "plist reference removed -> eligible (falsification)" 1 ELIGIBLE all-conditions-met
# scheduled script found only through a recorder reference
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" "lib/other_job.sh"; run 1
expect "scheduled via recorder" 1 NOT-ELIGIBLE scheduled-script:other_job.sh

# fail closed on bad exclusion data and an unreadable scheduled set
setup_repo ON; good; export AUTO_MERGE_EXCLUSIONS="$W/does-not-exist"; run 1
expect "exclusions unreadable" 1 INDETERMINATE exclusions-unreadable
printf '# only comments\n' > "$W/empty_excl"; export AUTO_MERGE_EXCLUSIONS="$W/empty_excl"; run 1
expect "exclusions empty" 1 INDETERMINATE exclusions-empty
printf '([unclosed\n' > "$W/bad_excl"; export AUTO_MERGE_EXCLUSIONS="$W/bad_excl"; run 1
expect "exclusions invalid regex" 1 INDETERMINATE exclusions-invalid-regex
setup_repo ON; good; rm -rf "$FAKE/.claude/launchd" "$FAKE/bin/launchd-recorders"; run 1
expect "scheduled set unreadable" 1 INDETERMINATE scheduled-set-unreadable
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R R/b.R" 5; run 1
expect "files truncated" 1 INDETERMINATE files-truncated
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" ""; run 1
expect "no files listed" 1 INDETERMINATE no-files-listed

# ---- 5. merge gate exit codes ------------------------------------------------
setup_repo ON; good; GATE_RC=0; export GATE_RC; run 1
expect "gate rc 0" 1 ELIGIBLE all-conditions-met
GATE_RC=1; export GATE_RC; run 1
expect "gate rc 1" 1 NOT-ELIGIBLE gate-block
GATE_RC=3; export GATE_RC; run 1
expect "gate rc 3" 1 INDETERMINATE gate-indeterminate
GATE_RC=2; export GATE_RC; run 1
expect "gate rc 2 (other)" 1 INDETERMINATE gate-rc-2
GATE_RC=7; export GATE_RC; run 1
expect "gate rc 7 (other)" 1 INDETERMINATE gate-rc-7
AUTO_MERGE_GATE="$W/no-such-gate"; export AUTO_MERGE_GATE; run 1
expect "gate missing" 1 INDETERMINATE gate-unavailable
AUTO_MERGE_GATE="$W/gate.sh"; export AUTO_MERGE_GATE
# a definite block overrides an earlier indeterminate
setup_repo ON; mkpr 1 OWNER OPEN false UNKNOWN "" "S" "R/a.R"; GATE_RC=1; export GATE_RC; run 1
expect "block beats indeterminate" 1 NOT-ELIGIBLE gate-block

# ---- 6. listing mode, exit codes ---------------------------------------------
setup_repo ON
mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R"
mkpr 2 OWNER OPEN false CLEAN "" "P" "R/b.R"
mkpr 3 OWNER OPEN false UNKNOWN "" "S" "R/c.R"
mkpr 9 OWNER OPEN true CLEAN "" "S" "R/d.R"
printf '[{"number":1,"isDraft":false},{"number":2,"isDraft":false},{"number":3,"isDraft":false},{"number":9,"isDraft":true}]\n' > "$STUB/list.json"
run
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'prs=3 eligible=1 not_eligible=1 indeterminate=1'; then ok; else bad "listing summary rc=$RC: $OUT"; fi
if printf '%s\n' "$OUT" | grep -q '^9	'; then bad "draft PR listed"; else ok; fi

setup_repo ON; printf '[]\n' > "$STUB/list.json"; run
if [ "$RC" -eq 0 ] && [ "$OUT" = "prs=0 eligible=0 not_eligible=0 indeterminate=0" ]; then ok; else bad "no open PRs rc=$RC: $OUT"; fi

setup_repo ON; good; printf '1' > "$STUB/auth_rc"; run 1
if [ "$RC" -eq 3 ]; then ok; else bad "gh unauthenticated: exit $RC, wanted 3"; fi
setup_repo ON; rm -f "$STUB/list.json"; run
if [ "$RC" -eq 3 ]; then ok; else bad "list failure: exit $RC, wanted 3"; fi

bash "$SWEEP" --bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "bad flag: exit $rc, wanted 2"; fi
bash "$SWEEP" abc >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "non-numeric PR: exit $rc, wanted 2"; fi
bash "$SWEEP" --repo >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "--repo without value: exit $rc, wanted 2"; fi

# ---- 7. report-only guard ----------------------------------------------------
if grep -Eq 'pr[[:space:]]+(merge|edit|close|comment|review)' "$SWEEP"; then
  bad "script contains a merge/edit/close/comment/review subcommand"
else ok; fi
if grep -Eq -e '--method|-X[[:space:]]+(POST|PUT|PATCH|DELETE)' "$SWEEP"; then
  bad "script contains a mutating gh api call"
else ok; fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
exit 0
