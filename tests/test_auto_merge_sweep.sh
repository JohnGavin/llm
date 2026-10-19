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
echo "$*" >> "$d/calls.log"
case "$1 $2" in
  "pr edit") if [ -f "$d/edit_fail_$3" ] && printf '%s' "$*" | grep -q -e '--add-label'; then exit 1; fi
             if [ -f "$d/unlabel_fail" ] && printf '%s' "$*" | grep -q -e '--remove-label'; then exit 1; fi
             exit 0 ;;
  "pr merge") if [ -f "$d/merge_fail_$3" ]; then echo "SECRET-TITLE-ERR" >&2; exit 1; fi; exit 0 ;;
  "label list") if [ -f "$d/no_label" ]; then exit 0; fi; echo "auto-merged"; exit 0 ;;
  "auth status") exit "$(cat "$d/auth_rc" 2>/dev/null || echo 0)" ;;
  "pr list") cat "$d/list.json" || exit 1 ;;
  "pr view") c=$(cat "$d/vc_$3" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$d/vc_$3"
             if [ -f "$d/unk_until_$3" ] && [ "$c" -le "$(cat "$d/unk_until_$3")" ]; then cat "$d/view_unk_$3.json"
             elif [ "$c" -ge 2 ] && [ -f "$d/view2_$3.json" ]; then cat "$d/view2_$3.json"; else cat "$d/view_$3.json" 2>/dev/null || exit 1; fi ;;
  "repo view") echo "O/R" ;;
  "api repos/O/R/pulls/"*) : ;;
esac
if [ "$1" = "api" ]; then
  case "$2" in
    */files) p="${2%/files}"; n="${p##*/}"
             if [ -f "$d/files_$n" ]; then cat "$d/files_$n"; exit 0; else exit 1; fi ;;
  esac
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
cat > "$W/sync_stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/sync_calls.log"
while [ $# -gt 0 ]; do
  if [ "$1" = "--facts" ]; then cp "$2" "$STUB_DIR/facts_seen.tsv"; fi
  shift
done
exit "${SYNC_RC:-0}"
EOF
export AUTO_MERGE_SYNC="$W/sync_stub.sh"
export AUTO_MERGE_LOG="$W/am.log"
export STUB_DIR="$STUB" GATE_RC=0 AUTO_MERGE_REPO_DIR="$FAKE" AUTO_MERGE_GATE="$W/gate.sh"
export PATH="$BIN:$PATH"
export AUTO_MERGE_RETRY_SLEEP=0

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
  rm -f "$STUB"/*; rm -f "$AUTO_MERGE_LOG"
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
  local lj="" l f nf=0 new old
  for l in $labels; do
    if [ -n "$lj" ]; then lj="$lj,"; fi
    lj="$lj{\"name\":\"$l\"}"
  done
  : > "$STUB/files_$n"
  for f in $files; do   # token "new:old" is a rename from old to new
    new="${f%%:*}"; old=""
    case "$f" in *:*) old="${f#*:}" ;; esac
    printf '%s\t%s\n' "$new" "$old" >> "$STUB/files_$n"
    nf=$((nf + 1))
  done
  if [ -z "$changed" ]; then changed="$nf"; fi
  printf '%s' "$assoc" > "$STUB/assoc_$n"
  printf '{"number":%s,"state":"%s","isDraft":%s,"mergeStateStatus":"%s","headRefOid":"%s","labels":[%s],"statusCheckRollup":%s,"changedFiles":%s}\n' \
    "$n" "$state" "$draft" "$merge" "${HEAD:-aaaaaaa$n}" "$lj" "$(checks_json "$checks")" "$changed" > "$STUB/view_$n.json"
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
if printf '%s\n' "$OUT" | grep -qx 'prs=1 eligible=1 not_eligible=0 indeterminate=0 merged=0 failed=0'; then ok; else bad "summary line: $OUT"; fi

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
setup_repo ON; mkpr 1 OWNER OPEN false BLOCKED "" "S,S" "R/a.R"; run 1
expect "BLOCKED (required check missing)" 1 NOT-ELIGIBLE blocked-by-rules
setup_repo ON; mkpr 1 OWNER OPEN false UNSTABLE "" "S" "R/a.R"; run 1
expect "UNSTABLE" 1 NOT-ELIGIBLE unstable
setup_repo ON; mkpr 1 OWNER OPEN false DRAFT "" "S" "R/a.R"; run 1
expect "mergeStateStatus DRAFT" 1 NOT-ELIGIBLE draft
setup_repo ON; mkpr 1 OWNER OPEN false HAS_HOOKS "" "S" "R/a.R"; run 1
expect "HAS_HOOKS" 1 ELIGIBLE all-conditions-met
# UNKNOWN is transient: retried, then resolved (stub serves UNKNOWN for the first N views)
mkunk() {  # $1 = number of leading UNKNOWN views for PR 1
  sed 's/"mergeStateStatus":"[A-Z_]*"/"mergeStateStatus":"UNKNOWN"/' "$STUB/view_1.json" > "$STUB/view_unk_1.json"
  printf '%s' "$1" > "$STUB/unk_until_1"
}
setup_repo ON; good; mkunk 2; run 1
expect "UNKNOWN twice then CLEAN" 1 ELIGIBLE all-conditions-met
if [ "$(grep -c '^pr view 1 ' "$STUB/calls.log")" = "3" ]; then ok; else bad "expected 3 pr view calls: $(cat "$STUB/calls.log")"; fi
setup_repo ON; mkpr 1 OWNER OPEN false BLOCKED "" "S" "R/a.R"; mkunk 1; run 1
expect "UNKNOWN then BLOCKED" 1 NOT-ELIGIBLE blocked-by-rules
setup_repo ON; good; mkunk 3; run 1
expect "UNKNOWN three times" 1 INDETERMINATE merge-state-unknown
if [ "$(grep -c '^pr view 1 ' "$STUB/calls.log")" = "3" ]; then ok; else bad "retries must stop at 3 views: $(cat "$STUB/calls.log")"; fi
# a gh failure is not retried or hidden
setup_repo ON; rm -f "$STUB/view_1.json"; printf 'OWNER' > "$STUB/assoc_1"; run 1
expect "view failure not retried" 1 INDETERMINATE view-failed
if [ "$(grep -c '^pr view 1 ' "$STUB/calls.log")" = "1" ]; then ok; else bad "failed view was retried"; fi
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
setup_repo ON; good; rm -f "$STUB/files_1"; run 1
expect "files API fails" 1 INDETERMINATE files-api-failed

# renames: the PREVIOUS path counts too (llm#1471 rename gap)
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" "scripts/x.sh:.claude/hooks/x.sh"; run 1
expect "rename out of hooks" 1 NOT-ELIGIBLE "excluded-path:.claude/hooks/x.sh"
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" "scripts/y.sh:scripts/x.sh"; run 1
expect "rename between ordinary paths" 1 ELIGIBLE all-conditions-met
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" ".claude/rules/new.md:R/old.R"; run 1
expect "rename INTO excluded path" 1 NOT-ELIGIBLE "excluded-path:.claude/rules/new.md"

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
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'prs=3 eligible=1 not_eligible=1 indeterminate=1 merged=0 failed=0'; then ok; else bad "listing summary rc=$RC: $OUT"; fi
if printf '%s\n' "$OUT" | grep -q '^9	'; then bad "draft PR listed"; else ok; fi

setup_repo ON; printf '[]\n' > "$STUB/list.json"; run
if [ "$RC" -eq 0 ] && [ "$OUT" = "prs=0 eligible=0 not_eligible=0 indeterminate=0 merged=0 failed=0" ]; then ok; else bad "no open PRs rc=$RC: $OUT"; fi

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

# ---- 7. report mode never mutates; apply-mode safety flags -------------------
mutations() { grep -E '^(pr (edit|merge|close|comment|review)|label (create|delete)|api .*(-X|--method))' "$STUB/calls.log" 2>/dev/null | grep -c . ; }

setup_repo ON; good; run 1
expect "report mode on eligible PR" 1 ELIGIBLE all-conditions-met
if [ "$(mutations)" = "0" ] && [ -s "$STUB/calls.log" ]; then ok; else bad "report mode made mutating gh calls: $(cat "$STUB/calls.log")"; fi
if [ ! -e "$AUTO_MERGE_LOG" ]; then ok; else bad "report mode wrote the action log"; fi

for flag in '--admin' '--delete-branch'; do
  if grep -Fq -e "$flag" "$SWEEP"; then bad "script contains forbidden flag $flag"; else ok; fi
done
if grep -Eq -e '--auto([^a-z-]|$)' "$SWEEP"; then bad "script contains forbidden flag --auto"; else ok; fi
if grep -Eq -e '--method|-X[[:space:]]+(POST|PUT|PATCH|DELETE)' "$SWEEP"; then
  bad "script contains a mutating gh api call"
else ok; fi

# ---- 8. --apply ----------------------------------------------------------------
runa() { OUT="$(bash "$SWEEP" --repo O/R --apply "$@" 2>"$W/err")"; RC=$?; }
callidx() { grep -n -e "$1" "$STUB/calls.log" | head -1 | cut -d: -f1; }

setup_repo ON; HEAD=abc1234deadbeef; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R"; unset HEAD
runa 1
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'prs=1 eligible=1 not_eligible=0 indeterminate=0 merged=1 failed=0'; then ok; else bad "apply summary rc=$RC: $OUT"; fi
li="$(callidx 'pr edit 1 .*--add-label auto-merged')"; mi="$(callidx 'pr merge 1 ')"
if [ -n "$li" ] && [ -n "$mi" ] && [ "$li" -lt "$mi" ]; then ok; else bad "label must precede merge (label=$li merge=$mi)"; fi
if grep -q -e 'pr merge 1 .*--squash' "$STUB/calls.log" && grep -q -e '--match-head-commit abc1234deadbeef' "$STUB/calls.log"; then ok; else bad "merge must be squash with --match-head-commit <sha>: $(cat "$STUB/calls.log")"; fi
if grep -q -e '--admin' -e '--delete-branch' "$STUB/calls.log" || grep -Eq -e '--auto([^a-z-]|$)' "$STUB/calls.log"; then bad "forbidden merge flag used"; else ok; fi

# log line: fields present, no title text
if grep -q "	1	abc1234	labelled	" "$AUTO_MERGE_LOG" && grep -q "	1	abc1234	merged	" "$AUTO_MERGE_LOG"; then ok; else bad "log lines missing: $(cat "$AUTO_MERGE_LOG" 2>&1)"; fi
if grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	' "$AUTO_MERGE_LOG"; then ok; else bad "log timestamp format"; fi

# head changed between evaluation and action
setup_repo ON; HEAD=aaaaaaa1111111; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R"
HEAD=bbbbbbb2222222; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R"; mv "$STUB/view_1.json" "$STUB/view2_1.json"; unset HEAD
HEAD=aaaaaaa1111111; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R"; unset HEAD
runa 1
if [ "$(mutations)" = "0" ] && grep -q "skipped	head-changed" "$AUTO_MERGE_LOG" && [ "$RC" -eq 0 ]; then ok; else bad "head-changed must skip with no mutation (rc=$RC): $(cat "$STUB/calls.log")"; fi

# merge failure removes the label and exits 1
setup_repo ON; good; : > "$STUB/merge_fail_1"
runa 1
if [ "$RC" -eq 1 ]; then ok; else bad "merge failure exit $RC, wanted 1"; fi
ai="$(callidx 'pr edit 1 .*--add-label')"; ri="$(callidx 'pr edit 1 .*--remove-label auto-merged')"
if [ -n "$ai" ] && [ -n "$ri" ] && [ "$ai" -lt "$ri" ]; then ok; else bad "label not removed after failed merge (add=$ai remove=$ri)"; fi
if printf '%s\n' "$OUT" | grep -qx 'prs=1 eligible=1 not_eligible=0 indeterminate=0 merged=0 failed=1'; then ok; else bad "failure summary: $OUT"; fi
if grep -q "merge-failed" "$AUTO_MERGE_LOG" && grep -q "unlabelled" "$AUTO_MERGE_LOG"; then ok; else bad "failure log lines"; fi
if grep -q SECRET-TITLE-ERR "$AUTO_MERGE_LOG"; then bad "gh error text leaked into the log"; else ok; fi

# cap: --max 1 with two eligible PRs merges only one
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R"; mkpr 2 OWNER OPEN false CLEAN "" "S" "R/b.R"
runa --max 1 1 2
if [ "$RC" -eq 0 ] && [ "$(grep -c '^pr merge' "$STUB/calls.log")" = "1" ] && grep -q "skipped	cap-reached" "$AUTO_MERGE_LOG"; then ok; else bad "cap --max 1 (rc=$RC): $(cat "$STUB/calls.log")"; fi
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S" "R/a.R"; mkpr 2 OWNER OPEN false CLEAN "" "S" "R/b.R"
runa 1 2
if [ "$(grep -c '^pr merge' "$STUB/calls.log")" = "2" ]; then ok; else bad "default cap should allow 2 merges"; fi
bash "$SWEEP" --repo O/R --apply --max 0 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "--max 0: exit $rc, wanted 2"; fi
bash "$SWEEP" --repo O/R --max x >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "--max x: exit $rc, wanted 2"; fi

# NOT-ELIGIBLE and INDETERMINATE PRs are never mutated
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S,F" "R/a.R"; mkpr 2 OWNER OPEN false UNKNOWN "" "S" "R/b.R"
mkpr 3 OWNER OPEN false CLEAN "" "S" "scripts/x.sh:.claude/hooks/x.sh"
runa 1 2 3
if [ "$RC" -eq 0 ] && [ "$(mutations)" = "0" ] && printf '%s\n' "$OUT" | grep -qx 'prs=3 eligible=0 not_eligible=2 indeterminate=1 merged=0 failed=0'; then ok; else bad "ineligible PRs must not be mutated (rc=$RC): $OUT"; fi

# BLOCKED PR (required check missing): never labelled or merged under --apply
setup_repo ON; mkpr 1 OWNER OPEN false BLOCKED "" "S,S" "R/a.R"
runa 1
if [ "$RC" -eq 0 ] && [ "$(mutations)" = "0" ] && ! grep -q '^pr merge' "$STUB/calls.log" && printf '%s\n' "$OUT" | grep -qx 'prs=1 eligible=0 not_eligible=1 indeterminate=0 merged=0 failed=0'; then ok; else bad "BLOCKED PR must not be mutated (rc=$RC): $OUT / $(cat "$STUB/calls.log")"; fi

# label does not exist: INDETERMINATE, nothing created or merged
setup_repo ON; good; : > "$STUB/no_label"
runa 1
if [ "$(mutations)" = "0" ] && printf '%s\n' "$OUT" | grep -qx 'prs=1 eligible=0 not_eligible=0 indeterminate=1 merged=0 failed=0'; then ok; else bad "missing label handling: $OUT / $(cat "$STUB/calls.log")"; fi

# label add fails: no merge attempted
setup_repo ON; good; : > "$STUB/edit_fail_1"
runa 1
if ! grep -q '^pr merge' "$STUB/calls.log" && [ "$RC" -eq 0 ]; then ok; else bad "merge attempted although label add failed"; fi

# merge fails and unlabel also fails: still exit 1, warning on stderr
setup_repo ON; good; : > "$STUB/merge_fail_1"; : > "$STUB/unlabel_fail"
runa 1
if [ "$RC" -eq 1 ] && grep -q 'could not be removed' "$W/err"; then ok; else bad "unlabel failure not reported (rc=$RC): $(cat "$W/err")"; fi

# log write failure: reported on stderr, does not abort
setup_repo ON; good
mkdir -p "$W/blocker"; : > "$W/blocker/file"
AUTO_MERGE_LOG="$W/blocker/file/sub/log" runa 1
if [ "$RC" -eq 0 ] && grep -q 'could not write the action log' "$W/err" && printf '%s\n' "$OUT" | grep -q 'merged=1'; then ok; else bad "log failure handling rc=$RC: $(cat "$W/err")"; fi

# ---- 9. scheduling pieces and heartbeat (llm#1471) ---------------------------------
REC="$ROOT/bin/launchd-recorders/auto-merge-sweep"
PLIST="$ROOT/.claude/launchd/com.claude.auto-merge-sweep.plist"
if grep -v '^#' "$REC" | grep -q -e '"--apply"' && grep -v '^#' "$REC" | grep -q -e '"--max" "3"'; then ok; else bad "recorder must carry --apply and --max 3"; fi
if [ -x "$REC" ]; then ok; else bad "recorder not executable"; fi
if grep -q 'auto_merge_sweep.sh' "$REC"; then ok; else bad "recorder does not call the sweep"; fi
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$PLIST" >/dev/null 2>&1; then ok; else bad "plist invalid (plutil)"; fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$PLIST" 2>/dev/null; then ok; else bad "plist invalid (python)"; fi
else
  echo "SKIP: neither plutil nor python3 -- plist validity NOT exercised"
fi
if grep -q '<integer>1800</integer>' "$PLIST" && grep -q 'RunAtLoad</key>' "$PLIST"; then ok; else bad "plist: StartInterval 1800 / RunAtLoad"; fi
if grep -q '^com.claude.auto-merge-sweep[[:space:]]' "$ROOT/.claude/state/launchd-timeouts.txt"; then ok; else bad "timeout entry missing"; fi

if command -v duckdb >/dev/null 2>&1; then
  HKDB="$W/hk.duckdb"
  rm -f "$HKDB"
  duckdb -init /dev/null "$HKDB" < "$ROOT/.claude/scripts/housekeeping_schema_init.sql" >/dev/null 2>&1
  hkn() { duckdb -init /dev/null -csv -noheader "$HKDB" -c "SELECT count(*) FROM housekeeping_runs WHERE task='auto_merge_sweep' ${1:-}" 2>&1; }
  export UNIFIED_DB_PATH="$HKDB"

  setup_repo ON; good
  run 1
  if [ "$(hkn)" = "0" ]; then ok; else bad "report mode wrote a heartbeat"; fi

  setup_repo ON; good
  runa 1
  if [ "$(hkn "AND status='ok' AND rows_written=1")" = "1" ]; then ok; else bad "apply: expected one ok row with rows_written=1, got $(hkn)"; fi

  setup_repo ON; good; : > "$STUB/merge_fail_1"
  runa 1
  if [ "$(hkn "AND status='failed'")" = "1" ]; then ok; else bad "merge failure (exit 1): expected one failed row"; fi

  setup_repo ON; good; printf '1' > "$STUB/auth_rc"
  runa 1
  if [ "$RC" -eq 3 ] && [ "$(hkn "AND status='failed'")" = "2" ]; then ok; else bad "exit 3 must record failed (rc=$RC, failed rows=$(hkn "AND status='failed'"))"; fi

  setup_repo ON; printf '[]\n' > "$STUB/list.json"
  runa
  if [ "$(hkn "AND status='ok' AND rows_written=0")" = "1" ]; then ok; else bad "no open PRs: expected an ok row with 0 merged"; fi
  unset UNIFIED_DB_PATH
else
  echo "SKIP: duckdb not on PATH -- heartbeat rows NOT exercised"
fi

# ---- 10. merge history sync after --apply (llm#1471) -----------------------------------
setup_repo ON; good
runa 1
if [ "$(wc -l < "$STUB/sync_calls.log" 2>/dev/null | tr -d ' ')" = "1" ] && grep -q -e '--repo O/R --limit 50 --facts ' "$STUB/sync_calls.log"; then ok; else bad "--apply must call the sync once with --limit 50 and --facts: $(cat "$STUB/sync_calls.log" 2>&1)"; fi
if [ "$(cat "$STUB/facts_seen.tsv" 2>/dev/null)" = "$(printf '1\tsuccess\tPASS')" ]; then ok; else bad "facts for the merged PR: $(cat "$STUB/facts_seen.tsv" 2>&1)"; fi
setup_repo ON; good; run 1
if [ ! -e "$STUB/sync_calls.log" ]; then ok; else bad "report mode must not call the sync"; fi
setup_repo ON; mkpr 1 OWNER OPEN false CLEAN "" "S,F" "R/a.R"
runa 1
if [ -e "$STUB/sync_calls.log" ] && [ ! -s "$STUB/facts_seen.tsv" ]; then ok; else bad "apply with no merge still records owner merges (sync called, empty facts)"; fi
setup_repo ON; good; SYNC_RC=3; export SYNC_RC
runa 1
if [ "$RC" -eq 0 ] && grep -q 'merge history sync failed (exit 3)' "$W/err" && printf '%s\n' "$OUT" | grep -q 'merged=1'; then ok; else bad "sync failure must warn and not fail the sweep (rc=$RC): $(cat "$W/err")"; fi
SYNC_RC=0; export SYNC_RC
AUTO_MERGE_SYNC="$W/no-such-sync.sh" runa 1
if [ "$RC" -eq 0 ] && grep -q 'merge history sync script not readable' "$W/err"; then ok; else bad "missing sync script must warn (rc=$RC)"; fi
setup_repo ON; good; AUTO_MERGE_LIB="$W/no-such-lib.sh" run 1
if [ "$RC" -eq 3 ]; then ok; else bad "missing classification library must exit 3, got $RC"; fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
exit 0
