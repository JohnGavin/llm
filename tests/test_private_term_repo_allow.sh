#!/bin/bash
# Tests of the per-repo private-term allow-list in private_data_scan.sh.
#
# Hermetic: synthetic repos under a mktemp dir; HOME, git config, deny-list,
# term list and unified DB pinned to the temp dir; `gh` is a stub on PATH
# (STUB_VIS=PUBLIC|PRIVATE|fail). All terms are synthetic. The canary is
# assembled from two literals so this file never contains it. Exit codes are
# asserted exactly. Every case pairs a suppressing/blocking result with its
# falsification.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
SCAN="$ROOT/.claude/scripts/private_data_scan.sh"
WORK="$(mktemp -d)"; WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export UNIFIED_DB_PATH="$WORK/none.duckdb"
export PRIVATE_VALUES_FILE="$WORK/pv.env"
printf 'K=unrelated_value_for_denylist_presence\n' > "$PRIVATE_VALUES_FILE"; chmod 600 "$PRIVATE_VALUES_FILE"
unset PRIVATE_DATA_SCAN_VISIBILITY PRIVATE_TERMS_MAX_AGE_DAYS REPO_ROOT PRIVATE_TERMS_REPO_ALLOW

CANARY="zzcanary""privterm7q"
TERM1="alphaproj"
TERM2="betaproj"
OUT="$WORK/out.txt"
TL="$WORK/terms.txt"
{ printf '# private_terms v1 generated=%s count=3\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n%s\n%s\n' "$CANARY" "$TERM1" "$TERM2"; } > "$TL"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOS'
#!/bin/sh
case "${STUB_VIS:-PUBLIC}" in
  fail) exit 1 ;;
  *) printf '%s\n' "${STUB_VIS:-PUBLIC}" ;;
esac
EOS
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
expect_no_out() { # label pattern
  if grep -q -- "$2" "$OUT"; then bad "$1 ('$2' present)"; else ok "$1"; fi
}

# sc VIS REPO FILE -> rc ; output in $OUT
sc() {
  local vis="$1" repo="$2"; shift 2
  env STUB_VIS="$vis" PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$TL" REPO_ROOT="$repo" \
    bash "$SCAN" --paths "$@" > "$OUT" 2>&1
  echo $?
}
mkrepo() {
  mkdir -p "$1/.claude"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@e.com
  git -C "$1" config user.name T
}
R="$WORK/repo"; mkrepo "$R"
ALLOW="$R/.claude/private_terms_allow.txt"
F="$R/page.txt"

# ---- t1: allowed term in a local-only repo is suppressed, visibly ------------
printf 'a line about %s here\nanother %s line\n' "$TERM1" "$TERM1" > "$F"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t1a (no allow file): term is flagged" 1 "$rc"
printf '%s | subject of this private local-only repo\n' "$TERM1" > "$ALLOW"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t1b: allowed term in a no-remote repo is suppressed" 0 "$rc"
expect_out "t1c: summary line counts hits and terms" "private-term: 2 hit(s) suppressed by repo allow-list (1 term)"
expect_no_out "t1d: summary never prints the term" "$TERM1"
printf 'plain MIXED-case %s\n' "$(printf '%s' "$TERM1" | tr a-z A-Z)" > "$F"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t1e: case-insensitive suppression" 0 "$rc"

# ---- t2: same allow file, repo has a remote (looks public) -> still flagged ---
printf 'a line about %s here\n' "$TERM1" > "$F"
git -C "$R" remote add origin https://example.invalid/x.git
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t2a: repo with a remote and PUBLIC visibility is still flagged" 1 "$rc"
expect_out "t2b: warns the allow-list was not applied" "NOT applied"
rc=$(sc fail "$R" "$F"); expect_rc "t2c: remote + gh lookup fails -> still flagged" 1 "$rc"
git -C "$R" remote remove origin
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t2d (falsify): remote removed -> suppressed again" 0 "$rc"
rc=$(env PRIVATE_DATA_SCAN_VISIBILITY=public STUB_VIS=PUBLIC PATH="$WORK/bin:$PATH" PRIVATE_TERMS_FILE="$TL" REPO_ROOT="$R" bash "$SCAN" --paths "$F" > "$OUT" 2>&1; echo $?)
expect_rc "t2e: PRIVATE_DATA_SCAN_VISIBILITY=public (public mirror) -> not applied, flagged" 1 "$rc"

# ---- t3: a different term in the same repo is still flagged -------------------
printf 'one %s and also %s\n' "$TERM1" "$TERM2" > "$F"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t3a: allowed + non-allowed term on a line -> flagged" 1 "$rc"
printf 'only %s here\n' "$TERM2" > "$F"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t3b: non-allowed term alone -> flagged" 1 "$rc"
printf 'the canary %s\n' "$CANARY" > "$F"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t3c: canary still flagged" 1 "$rc"
printf '%s | try to allow the canary\n' "$CANARY" > "$ALLOW"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t3d: an allow entry for the canary is ignored" 1 "$rc"
expect_out "t3e: canary entry warned about" "canary term"

# ---- t4: entry without a reason is ignored with a warning ---------------------
printf 'a line about %s here\n' "$TERM1" > "$F"
printf '%s\n' "$TERM1" > "$ALLOW"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t4a: bare term (no reason) allows nothing" 1 "$rc"
expect_out "t4b: warns about the missing reason" "no ' | <reason>'"
printf '%s |   \n' "$TERM1" > "$ALLOW"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t4c: blank reason allows nothing" 1 "$rc"
printf '%s | has a reason\n' "$TERM1" > "$ALLOW"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t4d (falsify): with a reason it is suppressed" 0 "$rc"

# ---- t5: visibility indeterminate (not a git repo) -> not applied -------------
N="$WORK/notgit"; mkdir -p "$N/.claude"
printf '%s | has a reason\n' "$TERM1" > "$N/.claude/private_terms_allow.txt"
printf 'a line about %s here\n' "$TERM1" > "$N/page.txt"
rc=$(sc fail "$N" "$N/page.txt"); expect_rc "t5a: REPO_ROOT not a git repo -> allow-list not applied, flagged" 1 "$rc"
expect_out "t5b: warns visibility could not be established" "could not be established"

# ---- t6: an allowed term that is not in the list is harmless ------------------
printf 'unlisted | not in the term list\n%s | has a reason\n' "$TERM1" > "$ALLOW"
printf 'a line about %s here\n' "$TERM1" > "$F"
rc=$(sc PUBLIC "$R" "$F"); expect_rc "t6: unlisted allow entry ignored, listed one applies" 0 "$rc"
expect_out "t6a: counts only the term actually in the list" "(1 term)"

echo "---"
if [ "$fail" -eq 0 ]; then echo "$pass/$pass PASS"; else echo "FAILURES: $fail (passed $pass)"; fi
exit "$fail"
