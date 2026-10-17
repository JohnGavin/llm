#!/usr/bin/env bash
# test_timeout_resolution.sh -- roborev job 14186
#
# GNU `timeout` is absent from a stock macOS PATH. The visibility lookup in
# private_term_write_guard.sh and repo_visibility.sh used to call it bare, so on
# such a PATH the lookup exited 127, collapsed to `unknown`, and private/local
# repos lost their exemption. These tests run the REAL guard and the REAL
# repo_visibility.sh on a PATH built from symlinks that excludes timeout,
# gtimeout and perl, and check the verdicts. Terms are synthetic (a temp list);
# the real term list is never read or printed.
#
# Exit 0 all green, 1 any failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/.claude/hooks/private_term_write_guard.sh"
VIS="$ROOT/.claude/scripts/repo_visibility.sh"
LIB="$ROOT/.claude/hooks/lib/run_bounded.sh"

CANARY="zzcanary""privterm7q"
TERM1="fakeprojx"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/timeout_res_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
unset PRIVATE_TERMS_MAX_AGE_DAYS

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect_rc() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (exit $3, want $2)"; fi; }

REAL_PERL="$(command -v perl 2>/dev/null)" || REAL_PERL=""
REAL_TIMEOUT="$(command -v timeout 2>/dev/null)" || REAL_TIMEOUT=""

# PATH of symlinks to everything the scripts need EXCEPT timeout/gtimeout/perl.
NOTO="$WORK/notimeout_bin"
mkdir -p "$NOTO"
for c in bash sh env python3 git cat tr sed grep egrep fgrep awk basename dirname \
         mktemp rm mkdir date head tail sort uniq wc cut tee printf true false \
         ls stat cp mv tr xargs find od sleep id uname hostname readlink \
         realpath shasum sha256sum openssl diff cmp expr test seq touch chmod ln; do
  p="$(command -v "$c" 2>/dev/null)" || continue
  case "$p" in /*) ln -sf "$p" "$NOTO/$c" 2>/dev/null ;; esac
done

# sanity: the restricted PATH really has no timeout (else the test is vacuous)
if env -i PATH="$NOTO" bash -c 'command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1'; then
  echo "FAIL precondition: restricted PATH still resolves timeout/gtimeout"; exit 1
fi

iso_now() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
TERMS="$WORK/terms.txt"
{ printf '# private_terms v1 generated=%s count=2\n' "$(iso_now)"
  printf '%s\n%s\n' "$CANARY" "$TERM1"; } > "$TERMS"

# scratch repos: no remote => local_only by repo_visibility.sh
mkdir -p "$WORK/localrepo" "$WORK/pubrepo"
git -C "$WORK/localrepo" init -q 2>/dev/null
git -C "$WORK/pubrepo" init -q 2>/dev/null

cat > "$WORK/stubvis.sh" <<'STUB'
#!/usr/bin/env bash
case "$(basename "$1")" in
  pubrepo) echo public ;;
  *) echo private ;;
esac
STUB
chmod +x "$WORK/stubvis.sh"

p_write() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"; }

ERR="$WORK/err.txt"
# guard_nt PAYLOAD [EXTRA_ENV...] -> rc, on the PATH without timeout. Default
# visibility path (no stub) unless PTWG_VISIBILITY_CMD is passed in EXTRA_ENV.
guard_nt() {
  local payload="$1"; shift
  printf '%s' "$payload" | env -i HOME="$WORK" PATH="$NOTO" PRIVATE_TERMS_FILE="$TERMS" \
    REPO_VISIBILITY_NO_CACHE=1 REPO_VISIBILITY_CACHE_FILE="$WORK/cache.tsv" \
    REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$WORK/none.txt" \
    RB_SEARCH_DIRS=/nonexistent RB_PERL_FALLBACK="${REAL_PERL:-/nonexistent}" "$@" \
    bash "$HOOK" --check >/dev/null 2>"$ERR"
  echo $?
}

echo "timeout resolution tests:"

# (a) PATH lacks timeout/gtimeout: perl fallback bounds the lookup
rc=$(guard_nt "$(p_write "$WORK/localrepo/a.txt" "x $TERM1")")
expect_rc "a1: no-timeout PATH, local-only repo write with a term is NOT blocked (default lookup)" 0 "$rc"
rc=$(guard_nt "$(p_write "$WORK/pubrepo/a.txt" "x $TERM1")" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh")
expect_rc "a2: no-timeout PATH, public repo write with a term IS blocked" 1 "$rc"
rc=$(guard_nt "$(p_write "$WORK/pubrepo/a.txt" "x clean")" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh")
expect_rc "a3: no-timeout PATH, public repo clean write passes" 0 "$rc"
rc=$(guard_nt "$(p_write "$WORK/localrepo/a.txt" "x $TERM1")" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh")
expect_rc "a4: no-timeout PATH, stubbed private repo write with a term is NOT blocked" 0 "$rc"

# (b) the default repo_visibility.sh classify path, timeout removed
out="$(env -i HOME="$WORK" PATH="$NOTO" REPO_VISIBILITY_NO_CACHE=1 REPO_VISIBILITY_CACHE_FILE="$WORK/cache.tsv" \
  REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$WORK/none.txt" RB_SEARCH_DIRS=/nonexistent \
  RB_PERL_FALLBACK="${REAL_PERL:-/nonexistent}" bash "$VIS" classify "$WORK/localrepo" 2>/dev/null)"
if [ "$out" = "local_only" ]; then ok "b1: classify of a no-remote repo is local_only without timeout"; else bad "b1: classify gave '$out', want local_only"; fi

# b2: the gh path (the only one that used timeout): a stub `gh` answers PUBLIC
mkdir -p "$WORK/ghrepo" "$WORK/ghbin"
git -C "$WORK/ghrepo" init -q 2>/dev/null
git -C "$WORK/ghrepo" remote add origin git@github.com:synth/ghrepo.git 2>/dev/null
printf '#!/bin/sh\necho PUBLIC\n' > "$WORK/ghbin/gh"
chmod +x "$WORK/ghbin/gh"
out="$(env -i HOME="$WORK" PATH="$NOTO:$WORK/ghbin" REPO_VISIBILITY_NO_CACHE=1 REPO_VISIBILITY_CACHE_FILE="$WORK/cache.tsv" \
  REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$WORK/none.txt" RB_SEARCH_DIRS=/nonexistent \
  RB_PERL_FALLBACK="${REAL_PERL:-/nonexistent}" bash "$VIS" classify "$WORK/ghrepo" 2>/dev/null)"
if [ "$out" = "public" ]; then ok "b2: gh-backed classify returns public without timeout"; else bad "b2: classify gave '$out', want public"; fi

# (c) timeout present: behaviour unchanged
rc=$(printf '%s' "$(p_write "$WORK/pubrepo/a.txt" "x $TERM1")" | env PRIVATE_TERMS_FILE="$TERMS" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh" bash "$HOOK" --check >/dev/null 2>&1; echo $?)
expect_rc "c1: normal PATH, public repo write with a term is blocked" 1 "$rc"
rc=$(printf '%s' "$(p_write "$WORK/localrepo/a.txt" "x $TERM1")" | env PRIVATE_TERMS_FILE="$TERMS" PTWG_VISIBILITY_CMD="$WORK/stubvis.sh" bash "$HOOK" --check >/dev/null 2>&1; echo $?)
expect_rc "c2: normal PATH, private repo write with a term passes" 0 "$rc"

# (d) the helper itself: kills a slow command (124) and passes exit codes through
if [ -n "$REAL_PERL" ]; then
  rc=$(env -i PATH="$NOTO" RB_SEARCH_DIRS=/nonexistent RB_PERL_FALLBACK="$REAL_PERL" \
    bash -c ". '$LIB'; run_bounded 1 sleep 5; echo \$?" 2>/dev/null)
  expect_rc "d1: perl fallback kills a slow command with 124" 124 "$rc"
  rc=$(env -i PATH="$NOTO" RB_SEARCH_DIRS=/nonexistent RB_PERL_FALLBACK="$REAL_PERL" \
    bash -c ". '$LIB'; run_bounded 5 sh -c 'exit 7'; echo \$?" 2>/dev/null)
  expect_rc "d2: perl fallback passes the command's own exit code" 7 "$rc"
else
  bad "d1/d2: perl not available to exercise the fallback"
fi
if [ -n "$REAL_TIMEOUT" ]; then
  rc=$(bash -c ". '$LIB'; run_bounded 1 sleep 5; echo \$?" 2>/dev/null)
  expect_rc "d3: with timeout present a slow command is killed with 124" 124 "$rc"
fi

# (e) NO mechanism at all: INDETERMINATE (125), command not run, reason given,
# and the guard says why instead of a bare "unknown"
rc=$(env -i PATH="$NOTO" RB_SEARCH_DIRS=/nonexistent RB_PERL_FALLBACK=/nonexistent \
  bash -c ". '$LIB'; run_bounded 5 touch '$WORK/ran'; echo \$?" 2>/dev/null)
expect_rc "e1: no timeout/gtimeout/perl => run_bounded returns 125" 125 "$rc"
if [ -e "$WORK/ran" ]; then bad "e1b: the command ran unbounded"; else ok "e1b: the command was not run unbounded"; fi
rc=$(guard_nt "$(p_write "$WORK/pubrepo/a.txt" "x $TERM1")" RB_PERL_FALLBACK=/nonexistent)
expect_rc "e2: unboundable lookup + a term is blocked (fail closed)" 1 "$rc"
if grep -q "could not be bounded" "$ERR"; then ok "e2b: the block message states the lookup could not be bounded"; else bad "e2b: reason missing from block message"; fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
