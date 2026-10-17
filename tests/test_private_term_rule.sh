#!/bin/bash
# Two-sided tests of the private-term rule in private_data_scan.sh and of the
# global commit-msg hook (llm#1388, parent #1382).
#
# Hermetic: every repo is synthetic under a mktemp dir; HOME, the git config,
# the deny-list, the term list and the unified DB are pinned to the temp dir;
# `gh` is a stub on PATH (STUB_VIS=PUBLIC|PRIVATE|fail), so there is no network
# and the real ~/.config/private_terms.txt is never read. All terms are
# synthetic. The canary is assembled from two literals so that this file never
# contains it. Exit codes are asserted exactly (0 clean / 1 finding /
# 3 INDETERMINATE). Every blocking case is paired with a falsification.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
SCAN="$ROOT/.claude/scripts/private_data_scan.sh"
HOOKS="$ROOT/git-hooks"
WORK="$(mktemp -d)"; WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export UNIFIED_DB_PATH="$WORK/none.duckdb"
export PRIVATE_VALUES_FILE="$WORK/pv.env"
printf 'K=unrelated_value_for_denylist_presence\n' > "$PRIVATE_VALUES_FILE"; chmod 600 "$PRIVATE_VALUES_FILE"
unset PRIVATE_DATA_SCAN_VISIBILITY PRIVATE_TERMS_MAX_AGE_DAYS REPO_ROOT

CANARY="zzcanary""privterm7q"
TERM1="alphaproj"
TERM2="a.b+c"
OUT="$WORK/out.txt"
TL="$WORK/terms.txt"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/sh
case "${STUB_VIS:-PUBLIC}" in
  fail) exit 1 ;;
  *) printf '%s\n' "${STUB_VIS:-PUBLIC}" ;;
esac
EOF
chmod +x "$WORK/bin/gh"

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect_rc() { # label want got
  if [ "$3" = "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (want exit $2, got $3; out: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi
}
expect_out() { # label pattern
  if grep -q -- "$2" "$OUT"; then ok "$1"; else bad "$1 (no '$2' in: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
days_ago_iso() { # N
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ
}
# mkterms FILE GENERATED-ISO [TERM...]  (header + terms + a comment line)
mkterms() {
  local f="$1" gen="$2"; shift 2
  { printf '# private_terms v1 generated=%s count=%s\n' "$gen" "$#"
    printf '# a comment, never a term\n'
    for t in "$@"; do printf '%s\n' "$t"; done; } > "$f"
}
mkterms "$TL" "$(now_iso)" "$CANARY" "$TERM1" "$TERM2"

# sc VIS FILE [SCANNER-ARGS...] -> rc ; output in $OUT. Terms file is $PT (default $TL).
PT="$TL"
sc() {
  local vis="$1"; shift
  env STUB_VIS="$vis" PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$PT" REPO_ROOT="$R" \
    bash "$SCAN" "$@" > "$OUT" 2>&1
  echo $?
}
mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@e.com
  git -C "$1" config user.name T
  echo clean > "$1/f.txt"; git -C "$1" add .
  git -c core.hooksPath=/dev/null -C "$1" commit -qm base
}
R="$WORK/repo"; mkrepo "$R"
put() { printf '%s\n' "$2" > "$R/$1"; } # put NAME LINE

# ---- positive control: the canary in content is a finding -------------------
put sample1.txt "nothing here but $CANARY today"
rc=$(sc PUBLIC --paths "$R/sample1.txt"); expect_rc "t1: canary in scanned content is a finding" 1 "$rc"
expect_out "t1a: finding names the rule" "private-term"
put sample1.txt "nothing here at all"
rc=$(sc PUBLIC --paths "$R/sample1.txt"); expect_rc "t1b (falsify): same file without the canary is clean" 0 "$rc"

# ---- whole-word, case-insensitive, - and _ are boundaries --------------------
put sample2.txt "intro
see foo-${TERM1}_bar here
outro"
rc=$(sc PUBLIC --paths "$R/sample2.txt" --tsv); expect_rc "t2: term inside foo-term_bar is a finding" 1 "$rc"
line=$(awk -F'\t' '$1=="FINDING" && $6=="private-term" {print $5}' "$OUT" | head -n 1)
if [ "$line" = "2" ]; then ok "t2a: reported on line 2"; else bad "t2a: line was '$line'"; fi
put sample2.txt "x ALPHAPROJ y"
rc=$(sc PUBLIC --paths "$R/sample2.txt"); expect_rc "t2b: case-insensitive" 1 "$rc"
put sample2.txt "${TERM1}"
rc=$(sc PUBLIC --paths "$R/sample2.txt"); expect_rc "t2c: term alone on a line (start and end)" 1 "$rc"
put sample2.txt "see ${TERM1}x here and x${TERM1} too and ${TERM1}9"
rc=$(sc PUBLIC --paths "$R/sample2.txt"); expect_rc "t3: term glued to letters or digits is NOT a finding" 0 "$rc"

# ---- regex metacharacters are literal ---------------------------------------
put sample3.txt "value $TERM2 end"
rc=$(sc PUBLIC --paths "$R/sample3.txt"); expect_rc "t4: metachar term matches itself literally" 1 "$rc"
put sample3.txt "value aXbbc end and a.bbc and a-b+c"
rc=$(sc PUBLIC --paths "$R/sample3.txt"); expect_rc "t4a (falsify): regex-shaped near misses do not match" 0 "$rc"

# ---- fail closed in a public repo -------------------------------------------
put sample4.txt "harmless text"
PT="$WORK/does_not_exist.txt"
rc=$(sc PUBLIC --paths "$R/sample4.txt"); expect_rc "t5: list missing, public -> INDETERMINATE" 3 "$rc"
expect_out "t5a: reason names the problem" "missing or unreadable"
: > "$WORK/empty.txt"; PT="$WORK/empty.txt"
rc=$(sc PUBLIC --paths "$R/sample4.txt"); expect_rc "t5b: list empty -> INDETERMINATE" 3 "$rc"
expect_out "t5c: reason says empty" "is empty"
mkterms "$WORK/nocanary.txt" "$(now_iso)" "$TERM1"; PT="$WORK/nocanary.txt"
rc=$(sc PUBLIC --paths "$R/sample4.txt"); expect_rc "t5d: canary missing from list -> INDETERMINATE" 3 "$rc"
expect_out "t5e: reason names the canary" "canary"
mkterms "$WORK/stale.txt" "$(days_ago_iso 30)" "$CANARY" "$TERM1"; PT="$WORK/stale.txt"
rc=$(sc PUBLIC --paths "$R/sample4.txt"); expect_rc "t5f: list 30 days old (max 7) -> INDETERMINATE" 3 "$rc"
expect_out "t5g: reason says stale" "stale"
rc=$(env PRIVATE_TERMS_MAX_AGE_DAYS=60 STUB_VIS=PUBLIC PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$PT" REPO_ROOT="$R" bash "$SCAN" --paths "$R/sample4.txt" > "$OUT" 2>&1; echo $?)
expect_rc "t5h (falsify): same list passes with PRIVATE_TERMS_MAX_AGE_DAYS=60" 0 "$rc"
{ printf 'no header here\n%s\n' "$CANARY"; } > "$WORK/nohdr.txt"; PT="$WORK/nohdr.txt"
rc=$(sc PUBLIC --paths "$R/sample4.txt"); expect_rc "t5i: no header line -> INDETERMINATE" 3 "$rc"
{ printf '# private_terms v1 generated=%s count=0\n# only comments\n' "$(now_iso)"; } > "$WORK/noterms.txt"; PT="$WORK/noterms.txt"
rc=$(sc PUBLIC --paths "$R/sample4.txt"); expect_rc "t5j: header but no terms -> INDETERMINATE" 3 "$rc"
PT="$WORK/does_not_exist.txt"
rc=$(sc fail --paths "$R/sample4.txt"); expect_rc "t5k: visibility lookup fails -> treated public -> INDETERMINATE" 3 "$rc"
PT="$TL"
rc=$(sc PUBLIC --paths "$R/sample4.txt"); expect_rc "t5l (falsify): a good list on the same file is clean" 0 "$rc"

# ---- private repo and CI mode skip the rule ----------------------------------
put sample5.txt "leaks $CANARY and $TERM1"
PT="$WORK/does_not_exist.txt"
rc=$(sc PRIVATE --paths "$R/sample5.txt"); expect_rc "t6: private repo, no list -> skipped silently, exit 0" 0 "$rc"
if grep -q "private-term\|INDETERMINATE" "$OUT"; then bad "t6a: private run mentioned the rule"; else ok "t6a: private run is silent about the rule"; fi
PT="$TL"
rc=$(sc PRIVATE --paths "$R/sample5.txt"); expect_rc "t6b: private repo with a good list still skips the rule" 0 "$rc"
PT="$WORK/does_not_exist.txt"
rc=$(sc PUBLIC --paths "$R/sample5.txt" --no-denylist); expect_rc "t7: public + --no-denylist (CI mode), no list -> rule skipped, exit 0" 0 "$rc"
PT="$TL"
rc=$(sc PUBLIC --paths "$R/sample5.txt" --no-denylist); expect_rc "t7a: --no-denylist skips the rule even with a list" 0 "$rc"
rc=$(sc PUBLIC --paths "$R/sample5.txt"); expect_rc "t7b (falsify): same file, same list, without --no-denylist -> finding" 1 "$rc"

# ---- staged mode -------------------------------------------------------------
git -C "$R" add sample5.txt
rc=$(sc PUBLIC --staged); expect_rc "t8: staged content with a term is a finding" 1 "$rc"
git -C "$R" rm -q --cached sample5.txt

# ---- the output never contains the term, the canary, or the line -------------
leaks() { grep -qiF -- "$2" "$1"; } # leaks FILE NEEDLE -> 0 when the needle is present
put sample6.txt "secret prose around $TERM1 and $TERM2 stays out of the report"
for fmt in "" "--json" "--tsv"; do
  rc=$(sc PUBLIC --paths "$R/sample6.txt" $fmt); expect_rc "t9: findings produced (${fmt:-human})" 1 "$rc"
  if leaks "$OUT" "$TERM1" || leaks "$OUT" "$TERM2" || leaks "$OUT" "secret prose"; then bad "t9a: output (${fmt:-human}) contains a term or the line"; else ok "t9a: output (${fmt:-human}) has no term and no line content"; fi
done
rc=$(sc PUBLIC --paths "$R/sample1.txt" >/dev/null; put sample1.txt "x $CANARY y"; sc PUBLIC --paths "$R/sample1.txt")
if leaks "$OUT" "$CANARY"; then bad "t9b: canary echoed"; else ok "t9b: canary not echoed"; fi
# Falsification 1: the leak detector itself can go red.
printf 'finding mentions %s\n' "$TERM1" > "$WORK/fake_out.txt"
if leaks "$WORK/fake_out.txt" "$TERM1"; then ok "t9c (falsify): the leak assertion goes red on an output that contains the term"; else bad "t9c: leak assertion cannot detect a leak"; fi
# Falsification 2: a MUTATED scanner that prints the term is caught by the same assertion.
MUT="$WORK/mut/scan.sh"; mkdir -p "$WORK/mut"
sed 's/(term and line redacted)/LEAKED alphaproj/' "$SCAN" > "$MUT"
if cmp -s "$SCAN" "$MUT"; then bad "t9d: mutation did not apply"; else
  put sample6.txt "x $TERM1 y"
  env STUB_VIS=PUBLIC PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$TL" REPO_ROOT="$R" bash "$MUT" --paths "$R/sample6.txt" > "$OUT" 2>&1
  if leaks "$OUT" "$TERM1"; then ok "t9d (falsify): a scanner mutated to print the term makes the assertion fail"; else bad "t9d: mutated scanner did not trip the leak assertion"; fi
fi

# ---- commit-msg hook ----------------------------------------------------------
H() { # H MSGFILE -> rc of the hook run inside $R
  ( cd "$R" && env STUB_VIS="${VIS:-PUBLIC}" PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$PT" "$HOOKS/commit-msg" "$1" ) > "$OUT" 2>&1
  echo $?
}
PT="$TL"
printf 'fix: tidy the report\n\nmentions %s in the body\n' "$CANARY" > "$WORK/msg_bad.txt"
rc=$(H "$WORK/msg_bad.txt"); expect_rc "t10: commit-msg with the canary is blocked" 1 "$rc"
expect_out "t10a: message says commit-msg BLOCKED" "commit-msg BLOCKED"
if leaks "$OUT" "$CANARY"; then bad "t10b: hook output echoes the canary"; else ok "t10b: hook output does not echo the canary"; fi
printf 'fix: tidy the report\n\nnothing to see\n' > "$WORK/msg_ok.txt"
rc=$(H "$WORK/msg_ok.txt"); expect_rc "t10c (falsify): clean message passes" 0 "$rc"
printf 'wip on the %s-module\n' "$TERM1" > "$WORK/msg_term.txt"
rc=$(H "$WORK/msg_term.txt"); expect_rc "t10d: a term (not just the canary) in the message is blocked" 1 "$rc"
PT="$WORK/does_not_exist.txt"
rc=$(H "$WORK/msg_ok.txt"); expect_rc "t10e: list missing in a public repo -> hook exit 3" 3 "$rc"
PT="$TL"; VIS=PRIVATE
rc=$(H "$WORK/msg_bad.txt"); expect_rc "t10f: private repo -> the rule is skipped, canary message passes" 0 "$rc"
VIS=PUBLIC
rc=$(H "$WORK/does_not_exist_msg"); expect_rc "t10g: no readable message file -> exit 2" 2 "$rc"
# Through git itself: commit must not be created when blocked.
echo more > "$R/g.txt"; git -C "$R" add g.txt
before=$(git -C "$R" rev-parse HEAD)
env STUB_VIS=PUBLIC PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$TL" \
  git -c core.hooksPath="$HOOKS" -C "$R" commit -q -m "note about $CANARY" > "$OUT" 2>&1; rc=$?
after=$(git -C "$R" rev-parse HEAD)
if [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then ok "t11: git commit with the canary in the message is refused, no commit created"; else bad "t11: rc=$rc before=$before after=$after"; fi
env STUB_VIS=PUBLIC PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$TL" \
  git -c core.hooksPath="$HOOKS" -C "$R" commit -q -m "plain message" > "$OUT" 2>&1; rc=$?
expect_rc "t11a (falsify): same staged change, clean message, commits" 0 "$rc"

echo "---"
if [ "$fail" -eq 0 ]; then echo "$pass/$pass PASS"; else echo "FAILURES: $fail (passed $pass)"; fi
exit "$fail"
