#!/usr/bin/env bash
# test_private_term_write_guard.sh -- JohnGavin/llm#1387 (privacy layer L1)
#
# Two-sided tests of .claude/hooks/private_term_write_guard.sh. Everything is
# pinned to a temp dir: a TEMP term list (canary plus one fake term), scratch git
# repos, and a stub visibility lookup (PTWG_VISIBILITY_CMD), so no network is
# used and the real ~/.config/private_terms.txt is never read. All terms are
# synthetic. The canary is assembled from two literals so this file never
# contains it.
#
# Exit codes (the guard's --check semantics): 0 pass, 1 finding, 2 usage,
# 3 INDETERMINATE. This test exits 0 all green, 1 any failure.
# Every blocking case is paired with a falsification (see the F-cases at the end).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/.claude/hooks/private_term_write_guard.sh"

CANARY="zzcanary""privterm7q"
TERM1="fakeprojx"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ptwg_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
unset PRIVATE_TERMS_MAX_AGE_DAYS

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect_rc() { # name want got
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (exit $3, want $2)"; fi
}

iso_offset() { # days ago -> ISO-8601 UTC
  python3 -c 'import sys,datetime
d=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=int(sys.argv[1]))
print(d.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}
mkterms() { # FILE ISO [TERM...]
  local f="$1" gen="$2"; shift 2
  { printf '# private_terms v1 generated=%s count=%s\n' "$gen" "$#"
    printf '# a comment, never a term\n'
    local t; for t in "$@"; do printf '%s\n' "$t"; done
  } > "$f"
}

# Stub visibility: the repo basename decides.
cat > "$WORK/stubvis.sh" <<'STUB'
#!/usr/bin/env bash
case "$(basename "$1")" in
  pubrepo)  echo public ;;
  privrepo) echo private ;;
  localrepo) echo local_only ;;
  unkrepo)  exit 1 ;;
  *)        echo private ;;
esac
STUB
chmod +x "$WORK/stubvis.sh"

for r in pubrepo privrepo localrepo unkrepo; do
  mkdir -p "$WORK/$r"
  git -C "$WORK/$r" init -q 2>/dev/null
done
mkdir -p "$WORK/plain"   # not a repo (the temp dir itself is outside any repo)

GOOD="$WORK/terms_good.txt"
mkterms "$GOOD" "$(iso_offset 0)" "$CANARY" "$TERM1"

# payload builders (JSON via python so quoting is exact)
j() { python3 -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])))' "$1"; }
p_write()    { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"; }
p_edit()     { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Edit","cwd":"/tmp","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[3],"new_string":sys.argv[2]}}))' "$1" "$2" "${3:-}"; }
p_multi()    { python3 -c 'import json,sys;print(json.dumps({"tool_name":"MultiEdit","cwd":"/tmp","tool_input":{"file_path":sys.argv[1],"edits":[{"old_string":"a","new_string":"clean"},{"old_string":"b","new_string":sys.argv[2]}]}}))' "$1" "$2"; }
p_notebook() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"NotebookEdit","cwd":"/tmp","tool_input":{"notebook_path":sys.argv[1],"new_source":sys.argv[2],"cell_id":"c1"}}))' "$1" "$2"; }

OUT="$WORK/out.txt"
ERR="$WORK/err.txt"
# g PAYLOAD [TERMS-FILE] -> rc of --check ; stdout in $OUT, stderr in $ERR
g() {
  local payload="$1" terms="${2:-$GOOD}" hook="${3:-$HOOK}"
  printf '%s' "$payload" \
    | env PRIVATE_TERMS_FILE="$terms" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh" bash "$hook" --check >"$OUT" 2>"$ERR"
  echo $?
}
leaks() { grep -q -i -F -- "$2" "$1"; }

P="$WORK/pubrepo"; V="$WORK/privrepo"; L="$WORK/localrepo"; U="$WORK/unkrepo"; N="$WORK/plain"

echo "private_term_write_guard tests:"

# ---- t1: positive control, then the private-repo twin -----------------------
rc=$(g "$(p_write "$P/a.txt" "hello $CANARY world")"); expect_rc "t1: Write of the canary into a public repo is a finding" 1 "$rc"
rc=$(g "$(p_write "$V/a.txt" "hello $CANARY world")"); expect_rc "t1b: the same Write in a private repo passes" 0 "$rc"
rc=$(g "$(p_write "$L/a.txt" "hello $CANARY world")"); expect_rc "t1c: the same Write in a local-only repo passes" 0 "$rc"
rc=$(g "$(p_write "$N/a.txt" "hello $CANARY world")"); expect_rc "t1d: the same Write outside any repo passes" 0 "$rc"
rc=$(g "$(p_write "$P/a.txt" "hello clean world")"); expect_rc "t1e: clean content into a public repo passes" 0 "$rc"

# ---- t2: input shapes ---------------------------------------------------------
rc=$(g "$(p_edit "$P/a.txt" "use $TERM1 here")"); expect_rc "t2: Edit new_string with a term into a public repo is a finding" 1 "$rc"
rc=$(g "$(p_edit "$P/a.txt" "all clean" "was $TERM1")"); expect_rc "t2b: a term only in old_string (being removed) passes" 0 "$rc"
rc=$(g "$(p_edit "$V/a.txt" "use $TERM1 here")"); expect_rc "t2c: Edit with a term in a private repo passes" 0 "$rc"
rc=$(g "$(p_notebook "$P/nb.ipynb" "x <- '$TERM1'")"); expect_rc "t3: NotebookEdit new_source with a term into a public repo is a finding" 1 "$rc"
rc=$(g "$(p_notebook "$V/nb.ipynb" "x <- '$TERM1'")"); expect_rc "t3b: NotebookEdit in a private repo passes" 0 "$rc"
rc=$(g "$(p_multi "$P/a.txt" "see $TERM1")"); expect_rc "t3c: MultiEdit with a term in the second edit is a finding" 1 "$rc"
rc=$(g "$(p_write "$P/new/sub/dir/a.txt" "x $TERM1")"); expect_rc "t4: Write to a not-yet-existing subdir of a public repo is a finding" 1 "$rc"
rel=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":"rel.txt","content":"x "+sys.argv[2]}}))' "$P" "$TERM1")
rc=$(g "$rel"); expect_rc "t4b: a relative file_path resolves against the payload cwd" 1 "$rc"
rc=$(g '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"echo hi"}}'); expect_rc "t4c: a Bash call is not this hook's business" 0 "$rc"
rc=$(g ""); expect_rc "t4d: an empty payload passes" 0 "$rc"
rc=$(g "not json"); expect_rc "t4e: a garbage payload is INDETERMINATE, not a pass" 3 "$rc"
rc=$(g "$(p_write "$P/a.txt" "")"); expect_rc "t4f: empty new content passes" 0 "$rc"

# ---- t5: matching semantics ---------------------------------------------------
rc=$(g "$(p_write "$P/a.txt" "see ${TERM1}x and x${TERM1} and ${TERM1}9")"); expect_rc "t5: a term glued to letters or digits is NOT a finding" 0 "$rc"
rc=$(g "$(p_write "$P/a.txt" "see FakeProjX_v2 here")"); expect_rc "t5b: case-insensitive, and an underscore is a word boundary" 1 "$rc"
rc=$(g "$(p_write "$P/a.txt" "see foo-${TERM1}-bar")"); expect_rc "t5c: hyphens are word boundaries" 1 "$rc"

# ---- t6: INDETERMINATE (fail closed, public repo only) -------------------------
rc=$(g "$(p_write "$P/a.txt" "clean")" "$WORK/does-not-exist.txt"); expect_rc "t6: term list missing, public repo -> INDETERMINATE" 3 "$rc"
if grep -q "private_terms_sync.sh" "$ERR"; then ok "t6a: the message says how to fix it"; else bad "t6a: no fix hint in the message"; fi
rc=$(g "$(p_write "$V/a.txt" "clean")" "$WORK/does-not-exist.txt"); expect_rc "t6b: term list missing, private repo -> pass (list not needed)" 0 "$rc"
rc=$(g "$(p_write "$N/a.txt" "clean")" "$WORK/does-not-exist.txt"); expect_rc "t6c: term list missing, non-repo path -> pass (list not needed)" 0 "$rc"
rc=$(g "$(p_write "$U/a.txt" "clean")" "$WORK/does-not-exist.txt"); expect_rc "t6d: unknown visibility is treated as public -> INDETERMINATE without a list" 3 "$rc"
rc=$(g "$(p_write "$U/a.txt" "x $TERM1")"); expect_rc "t6e: unknown visibility with a good list and a term -> finding" 1 "$rc"

mkterms "$WORK/stale.txt" "$(iso_offset 30)" "$CANARY" "$TERM1"
rc=$(g "$(p_write "$P/a.txt" "clean")" "$WORK/stale.txt"); expect_rc "t7: list 30 days old (max 7) -> INDETERMINATE" 3 "$rc"
if grep -q "stale" "$ERR"; then ok "t7a: the message says the list is stale"; else bad "t7a: stale not mentioned"; fi
rc=$(printf '%s' "$(p_write "$P/a.txt" "clean")" | env PRIVATE_TERMS_MAX_AGE_DAYS=60 PRIVATE_TERMS_FILE="$WORK/stale.txt" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh" bash "$HOOK" --check >"$OUT" 2>"$ERR"; echo $?)
expect_rc "t7b (falsify): the same list passes with PRIVATE_TERMS_MAX_AGE_DAYS=60" 0 "$rc"
mkterms "$WORK/nocanary.txt" "$(iso_offset 0)" "$TERM1"
rc=$(g "$(p_write "$P/a.txt" "x $TERM1")" "$WORK/nocanary.txt"); expect_rc "t8: list without the canary -> INDETERMINATE even though the content has a term" 3 "$rc"
if grep -q "canary" "$ERR"; then ok "t8a: the message names the canary check"; else bad "t8a: canary not mentioned"; fi
printf 'no header here\n%s\n%s\n' "$CANARY" "$TERM1" > "$WORK/nohdr.txt"
rc=$(g "$(p_write "$P/a.txt" "clean")" "$WORK/nohdr.txt"); expect_rc "t9: list with no header line -> INDETERMINATE" 3 "$rc"
printf '# private_terms v1 generated=%s count=0\n# only comments\n' "$(iso_offset 0)" > "$WORK/noterms.txt"
rc=$(g "$(p_write "$P/a.txt" "clean")" "$WORK/noterms.txt"); expect_rc "t9b: header but no terms -> INDETERMINATE" 3 "$rc"
: > "$WORK/empty.txt"
rc=$(g "$(p_write "$P/a.txt" "clean")" "$WORK/empty.txt"); expect_rc "t9c: empty list -> INDETERMINATE" 3 "$rc"
mkterms "$WORK/future.txt" "$(iso_offset -5)" "$CANARY" "$TERM1"
rc=$(g "$(p_write "$P/a.txt" "clean")" "$WORK/future.txt"); expect_rc "t9d: header dated in the future -> INDETERMINATE" 3 "$rc"

# ---- t10: the message never carries the matched text ----------------------------
rc=$(g "$(p_write "$P/a.txt" "secret prose around $TERM1 stays out of the report")"); expect_rc "t10: finding for the leak test" 1 "$rc"
if leaks "$ERR" "$TERM1" || leaks "$OUT" "$TERM1" || leaks "$ERR" "secret prose"; then bad "t10a: message contains the term or the line"; else ok "t10a: message has no term and no line content"; fi
if grep -q "private-term" "$ERR"; then ok "t10b: message names the rule"; else bad "t10b: rule name missing"; fi
rc=$(g "$(p_write "$P/a.txt" "x $CANARY y")"); expect_rc "t10c: finding for the canary leak test" 1 "$rc"
if leaks "$ERR" "$CANARY"; then bad "t10d: message echoes the canary"; else ok "t10d: message does not echo the canary"; fi
printf 'finding mentions %s\n' "$TERM1" > "$WORK/fake_out.txt"
if leaks "$WORK/fake_out.txt" "$TERM1"; then ok "t10e (falsify): the leak assertion goes red on text that contains the term"; else bad "t10e: leak assertion cannot detect a leak"; fi

# ---- t11: hook mode (harness protocol) ---------------------------------------------
printf '%s' "$(p_write "$P/a.txt" "x $TERM1")" \
  | env PRIVATE_TERMS_FILE="$GOOD" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh" bash "$HOOK" >"$OUT" 2>"$ERR"; rc=$?
expect_rc "t11: hook mode blocks a finding with exit 2" 2 "$rc"
if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["hookSpecificOutput"];assert d["permissionDecision"]=="deny" and d["hookEventName"]=="PreToolUse"' "$OUT" 2>/dev/null; then ok "t11a: deny JSON is valid"; else bad "t11a: deny JSON invalid: $(head -c 200 "$OUT")"; fi
if leaks "$OUT" "$TERM1"; then bad "t11b: deny JSON contains the term"; else ok "t11b: deny JSON has no term"; fi
printf '%s' "$(p_write "$P/a.txt" "x")" \
  | env PRIVATE_TERMS_FILE="$WORK/does-not-exist.txt" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh" bash "$HOOK" >"$OUT" 2>"$ERR"; rc=$?
expect_rc "t11c: hook mode blocks INDETERMINATE (missing list, public repo) with exit 2" 2 "$rc"
printf '%s' "$(p_write "$P/a.txt" "clean")" \
  | env PRIVATE_TERMS_FILE="$GOOD" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh" bash "$HOOK" >"$OUT" 2>"$ERR"; rc=$?
expect_rc "t11d: hook mode allows clean content with exit 0" 0 "$rc"
if [ ! -s "$OUT" ] && [ ! -s "$ERR" ]; then ok "t11e: an allow is silent"; else bad "t11e: an allow produced output"; fi
rc=$(bash "$HOOK" --bogus </dev/null >/dev/null 2>&1; echo $?); expect_rc "t12: an unknown argument is a usage error" 2 "$rc"

# ---- F-cases: make the key tests fail on purpose ---------------------------------------
echo "  falsification:"
# F1: empty the list -> the term test must NOT stay a finding (it goes INDETERMINATE).
rc=$(g "$(p_write "$P/a.txt" "x $TERM1")" "$WORK/empty.txt")
if [ "$rc" = "3" ]; then ok "F1: emptying the list turns t2 from finding(1) into INDETERMINATE(3), never a pass"; else bad "F1: empty list gave exit $rc"; fi

# F2: break the matcher (grep reads /dev/null instead of the list) -> t1 must go red.
MUT="$WORK/mut"; mkdir -p "$MUT/lib"
cp "$ROOT/.claude/hooks/lib/private_term_payload.py" "$MUT/lib/"
cp "$HOOK" "$MUT/private_term_write_guard.sh"
sed 's|-f "\$PT_FILE" 2>/dev/null|-f /dev/null 2>/dev/null|' "$ROOT/.claude/hooks/lib/private_terms.sh" > "$MUT/lib/private_terms.sh"
if cmp -s "$MUT/lib/private_terms.sh" "$ROOT/.claude/hooks/lib/private_terms.sh"; then bad "F2: the mutation did not apply"; fi
rc=$(g "$(p_write "$P/a.txt" "hello $CANARY world")" "$GOOD" "$MUT/private_term_write_guard.sh")
if [ "$rc" != "1" ]; then ok "F2: a broken matcher makes t1 go red (exit $rc, not 1); the liveness probe catches it"; else bad "F2: broken matcher still reported a finding"; fi

# F3: treat every repo as private -> t1 must go red (public block is real, not a constant).
cat > "$WORK/allpriv.sh" <<'STUB'
#!/usr/bin/env bash
echo private
STUB
chmod +x "$WORK/allpriv.sh"
rc=$(printf '%s' "$(p_write "$P/a.txt" "hello $CANARY world")" | env PRIVATE_TERMS_FILE="$GOOD" PTWG_VISIBILITY_CMD="$WORK/allpriv.sh" bash "$HOOK" --check >"$OUT" 2>"$ERR"; echo $?)
if [ "$rc" = "0" ]; then ok "F3: visibility=private makes the same write pass (the block depends on visibility)"; else bad "F3: exit $rc with visibility=private"; fi

# F4: a guard mutated to print the term is caught by the leak assertion (t10a).
cp "$ROOT/.claude/hooks/lib/private_terms.sh" "$MUT/lib/private_terms.sh"
sed 's|The term is deliberately not shown|Term was: fakeprojx|' "$HOOK" > "$MUT/private_term_write_guard.sh"
rc=$(g "$(p_write "$P/a.txt" "x $TERM1 y")" "$GOOD" "$MUT/private_term_write_guard.sh")
if leaks "$ERR" "$TERM1"; then ok "F4: a guard mutated to print the term trips the leak assertion"; else bad "F4: mutated guard did not trip the leak assertion"; fi

# F5: age check removed -> t7 must go red.
sed 's|if \[ "\$age_days" -gt "\$max" \]|if false|' "$ROOT/.claude/hooks/lib/private_terms.sh" > "$MUT/lib/private_terms.sh"
cp "$HOOK" "$MUT/private_term_write_guard.sh"
rc=$(g "$(p_write "$P/a.txt" "clean")" "$WORK/stale.txt" "$MUT/private_term_write_guard.sh")
if [ "$rc" != "3" ]; then ok "F5: without the age check a 30-day-old list is accepted (t7 goes red, exit $rc)"; else bad "F5: age-check mutation did not change the result"; fi

echo "  ---"
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
