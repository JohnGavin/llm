#!/bin/bash
# llm#1456: the private-term rule (L2) must judge ADDED lines only in --staged
# (pre-commit) and --range (pre-push) mode. A pre-existing listed word on a line
# the commit did not add must not block it; an added line, or any line of a new
# file, still must. Exit codes asserted exactly (0 clean / 1 finding).
#
# Hermetic and synthetic, like test_private_term_rule.sh: temp repos, pinned
# HOME / git config / DB, a `gh` stub reporting PUBLIC, and a temp term list of
# synthetic terms. The real ~/.config/private_terms.txt is never read. Bash 3.2.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
SCAN="${SCAN_OVERRIDE:-$ROOT/.claude/scripts/private_data_scan.sh}"
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
OUT="$WORK/out.txt"
TL="$WORK/terms.txt"
{ printf '# private_terms v1 generated=%s count=2\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n%s\n' "$CANARY" "$TERM1"; } > "$TL"

mkdir -p "$WORK/bin"
printf '#!/bin/sh\nprintf "PUBLIC\\n"\n' > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect_rc() { # label want got
  if [ "$3" = "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (want exit $2, got $3; out: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi
}
sc() { # sc ARGS... -> rc ; output in $OUT
  env STUB_VIS=PUBLIC PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$TL" REPO_ROOT="$R" \
    bash "$SCAN" "$@" > "$OUT" 2>&1
  echo $?
}
g() { git -c core.hooksPath=/dev/null -C "$R" "$@"; }

# Fresh repo whose base commit already holds a listed word on line 2 of old.txt.
mkrepo() {
  R="$WORK/repo_$1"; mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@e.com
  git -C "$R" config user.name T
  printf 'first line\nold line mentions %s here\nthird line\nkept line mentions %s too\n' "$TERM1" "$TERM1" > "$R/old.txt"
  git -C "$R" add .
  g commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
}

# ---- staged (pre-commit path) ------------------------------------------------
mkrepo a
printf 'first line\nold line mentions %s here\nthird line\nkept line mentions %s too\nfifth clean line\n' "$TERM1" "$TERM1" > "$R/old.txt"
git -C "$R" add old.txt
rc=$(sc --staged); expect_rc "a: staged, pre-existing term, clean added line" 0 "$rc"

mkrepo b
printf 'first line\nold line mentions %s here\nthird line\nkept line mentions %s too\nnew line with %s\n' "$TERM1" "$TERM1" "$TERM1" > "$R/old.txt"
git -C "$R" add old.txt
rc=$(sc --staged --tsv); expect_rc "b: staged, listed word in an ADDED line" 1 "$rc"
line=$(awk -F'\t' '$1=="FINDING" && $6=="private-term" {print $5}' "$OUT" | head -n 1)
if [ "$line" = "5" ]; then ok "b1: finding is on the added line 5, not the old lines 2/4"; else bad "b1: reported line '$line' (want 5)"; fi

mkrepo c
printf 'first line\nthird line\nkept line mentions %s too\n' "$TERM1" > "$R/old.txt"
git -C "$R" add old.txt
rc=$(sc --staged); expect_rc "c: staged, the removed line held the word" 0 "$rc"

mkrepo d
printf 'brand new file\nmentions %s\n' "$TERM1" > "$R/new.txt"
git -C "$R" add new.txt
rc=$(sc --staged); expect_rc "d: staged NEW file containing a word" 1 "$rc"

# ---- range (pre-push path) ---------------------------------------------------
mkrepo e
printf 'first line\nold line mentions %s here\nthird line\nkept line mentions %s too\nfifth clean line\n' "$TERM1" "$TERM1" > "$R/old.txt"
git -C "$R" add old.txt; g commit -qm clean-add
rc=$(sc --range "$BASE" HEAD); expect_rc "ea: range, pre-existing term, clean added line" 0 "$rc"

mkrepo f
printf 'first line\nold line mentions %s here\nthird line\nkept line mentions %s too\nnew line with %s\n' "$TERM1" "$TERM1" "$TERM1" > "$R/old.txt"
git -C "$R" add old.txt; g commit -qm term-add
rc=$(sc --range "$BASE" HEAD --tsv); expect_rc "eb: range, listed word in an ADDED line" 1 "$rc"
line=$(awk -F'\t' '$1=="FINDING" && $6=="private-term" {print $5}' "$OUT" | head -n 1)
if [ "$line" = "5" ]; then ok "eb1: finding is on the added line 5"; else bad "eb1: reported line '$line' (want 5)"; fi

mkrepo g
printf 'first line\nthird line\nkept line mentions %s too\n' "$TERM1" > "$R/old.txt"
git -C "$R" add old.txt; g commit -qm remove-line
rc=$(sc --range "$BASE" HEAD); expect_rc "ec: range, the removed line held the word" 0 "$rc"

mkrepo h
printf 'brand new file\nmentions %s\n' "$TERM1" > "$R/new.txt"
git -C "$R" add new.txt; g commit -qm new-file
rc=$(sc --range "$BASE" HEAD); expect_rc "ed: range, NEW file containing a word" 1 "$rc"
rc=$(sc --range --not-remotes HEAD); expect_rc "ee: new-branch form (--not-remotes) still reports the root commit's word" 1 "$rc"

echo "---"
if [ "$fail" -eq 0 ]; then echo "$pass/$pass PASS"; else echo "FAILURES: $fail (passed $pass)"; fi
exit "$fail"
