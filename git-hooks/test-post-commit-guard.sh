#!/bin/bash
# Two-sided tests of the roborev hook guards:
#   * the ephemeral-path guard in post-commit (llm#923)
#   * the per-repo opt-out guard shared by every enqueue path (llm#1296):
#     marker file, no remote, locally configured private roots, and the opt-in
#     allow-list mode.
# Every "blocked" case is paired with a falsification: change ONLY the thing
# that blocked it and assert the stub IS now called. A guard that cannot be seen
# to let a repo through proves nothing.
#
# HOOK resolves from this script's OWN directory. It must never be an absolute
# path to a particular checkout: the first version of this file hardcoded a
# worktree path, so running it from the main checkout silently tested the
# worktree's copy of the hook instead of its own. It reported 3/3 PASS while
# that worktree happened to hold the fixed hook, then FAILed once the worktree
# moved to a branch predating it -- a green result that was never evidence
# about the file shipped alongside it (portable-build-artifacts).
#
# roborev is STUBBED via a copied hook that points at a recording stub: no real
# job is ever queued, and the real ~/.config roots files are never read
# (ROBOREV_PRIVATE_ROOTS_FILE / ROBOREV_ALLOWED_ROOTS_FILE are pinned below).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/post-commit"
REWRITE="$HERE/post-rewrite"
LIB="$HERE/lib/roborev_repo_allowed.sh"
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd -P)
MARKER="$WORK/roborev_was_called"
REAL=""
trap 'rm -rf "$WORK" ${REAL:+"$REAL"}' EXIT

# Pin config so the developer's real local lists never influence the result.
export ROBOREV_PRIVATE_ROOTS_FILE="$WORK/private-roots"
export ROBOREV_ALLOWED_ROOTS_FILE="$WORK/allowed-roots"
unset ROBOREV_ALLOWLIST_MODE

# Stub roborev: records that it was invoked.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/roborev" <<EOF
#!/bin/sh
echo "invoked \$*" >> "$MARKER"
EOF
chmod +x "$WORK/bin/roborev"

# Copy each hook next to a copy of the lib, pointing at the stub instead of
# /usr/local/bin/roborev, and drop the git-lfs tail (irrelevant to this guard).
mkdir -p "$WORK/hookdir/lib"
cp "$LIB" "$WORK/hookdir/lib/roborev_repo_allowed.sh"
sed -e "s#ROBOREV=\"/usr/local/bin/roborev\"#ROBOREV=\"$WORK/bin/roborev\"#" \
    -e '/git-lfs/d' -e '/git lfs/d' "$HOOK" > "$WORK/hookdir/post-commit"
sed -e "s#ROBOREV=\"/usr/local/bin/roborev\"#ROBOREV=\"$WORK/bin/roborev\"#" \
    "$REWRITE" > "$WORK/hookdir/post-rewrite"
chmod +x "$WORK/hookdir/post-commit" "$WORK/hookdir/post-rewrite"

fail=0
pass=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# run_hook DIR [ENV=VAL ...] : run the copied post-commit hook inside DIR.
run_hook() {
  _d=$1; shift
  rm -f "$MARKER"
  ( cd "$_d" && env "$@" "$WORK/hookdir/post-commit" )
}
expect_blocked() { # label
  if [ -f "$MARKER" ]; then bad "$1 (roborev WAS invoked: $(cat "$MARKER"))"; else ok "$1"; fi
}
expect_called() { # label
  if [ -f "$MARKER" ]; then ok "$1"; else bad "$1 (roborev NOT invoked)"; fi
}

mkrepo() { # dir [with-remote]
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@e.com
  git -C "$1" config user.name T
  echo hi > "$1/f.txt"
  git -C "$1" add .
  git -c core.hooksPath=/dev/null -C "$1" commit -qm "test commit"
  if [ "${2:-}" = "remote" ]; then
    git -C "$1" remote add origin https://example.invalid/x.git
  fi
}

mkrepo "$WORK/repo" remote
ALLOW="ROBOREV_ALLOW_TMP_REPOS=1"

# ---- llm#923: ephemeral-path guard -----------------------------------------
run_hook "$WORK/repo" X=1
expect_blocked "case 1: temp path blocked (ephemeral guard)"
run_hook "$WORK/repo" "$ALLOW"
expect_called  "case 2: override re-enables (repo has a remote, no marker)"

# Case 3: a non-temp repo (with a remote) must still be reviewed.
REAL="$HERE/../.roborev_guard_test_repo_$$"
mkrepo "$REAL" remote
REAL=$(cd -P "$REAL" && pwd -P)
run_hook "$REAL" X=1
expect_called  "case 3: non-temp repo with a remote still reviewed"
rm -rf "$REAL"; REAL=""

# ---- llm#1296: marker -------------------------------------------------------
touch "$WORK/repo/.roborev-disable"
run_hook "$WORK/repo" "$ALLOW"
expect_blocked "case 4: .roborev-disable marker blocks"
rm -f "$WORK/repo/.roborev-disable"
run_hook "$WORK/repo" "$ALLOW"
expect_called  "case 4b (falsify): marker removed -> called"

touch "$WORK/repo/PRIVATE"
run_hook "$WORK/repo" "$ALLOW"
expect_blocked "case 5: PRIVATE marker blocks"
rm -f "$WORK/repo/PRIVATE"
run_hook "$WORK/repo" "$ALLOW"
expect_called  "case 5b (falsify): PRIVATE removed -> called"

# ---- llm#1296: no remote ----------------------------------------------------
mkrepo "$WORK/localonly"
run_hook "$WORK/localonly" "$ALLOW"
expect_blocked "case 6: repo with no remote blocked"
git -C "$WORK/localonly" remote add origin https://example.invalid/y.git
run_hook "$WORK/localonly" "$ALLOW"
expect_called  "case 6b (falsify): remote added -> called"

# ---- llm#1296: private-roots file ------------------------------------------
printf '# local list\n%s\n' "$WORK" > "$ROBOREV_PRIVATE_ROOTS_FILE"
run_hook "$WORK/repo" "$ALLOW"
expect_blocked "case 7: repo under a private root blocked"
mkdir -p "$WORK/repo/sub"
( cd "$WORK/repo/sub" && rm -f "$MARKER" && env "$ALLOW" "$WORK/hookdir/post-commit" )
expect_blocked "case 7a: subdirectory of a private-root repo blocked"
printf '# emptied\n' > "$ROBOREV_PRIVATE_ROOTS_FILE"
run_hook "$WORK/repo" "$ALLOW"
expect_called  "case 7b (falsify): root removed from list -> called"
rm -f "$ROBOREV_PRIVATE_ROOTS_FILE"

# ---- llm#1296: marker in the main checkout covers its linked worktrees -----
git -C "$WORK/repo" worktree add -q -b wt "$WORK/wt"
touch "$WORK/repo/.roborev-disable"
run_hook "$WORK/wt" "$ALLOW"
expect_blocked "case 8: marker in main checkout blocks its linked worktree"
rm -f "$WORK/repo/.roborev-disable"
run_hook "$WORK/wt" "$ALLOW"
expect_called  "case 8b (falsify): marker removed -> worktree called"

# ---- llm#1296: opt-in allow-list mode (default OFF) -------------------------
run_hook "$WORK/repo" "$ALLOW"
expect_called  "case 9: default mode reviews an unlisted repo (allow-list OFF)"
run_hook "$WORK/repo" "$ALLOW" ROBOREV_ALLOWLIST_MODE=1
expect_blocked "case 9a: allow-list mode, no list -> fail closed"
printf '%s\n' "$WORK/repo" > "$ROBOREV_ALLOWED_ROOTS_FILE"
run_hook "$WORK/repo" "$ALLOW" ROBOREV_ALLOWLIST_MODE=1
expect_called  "case 9b (falsify): allow-list mode, repo listed -> called"
run_hook "$WORK/localonly" "$ALLOW" ROBOREV_ALLOWLIST_MODE=1
expect_blocked "case 9c: allow-list mode, other repo unlisted -> blocked"

# ---- llm#1296: post-rewrite honours the guard too ---------------------------
rm -f "$MARKER"
touch "$WORK/repo/.roborev-disable"
( cd "$WORK/repo" && "$WORK/hookdir/post-rewrite" )
expect_blocked "case 10: post-rewrite blocked by marker"
rm -f "$WORK/repo/.roborev-disable" "$MARKER"
( cd "$WORK/repo" && "$WORK/hookdir/post-rewrite" )
expect_called  "case 10b (falsify): post-rewrite called without marker"

# ---- guard lib: indeterminate is not allowed --------------------------------
mkdir -p "$WORK/notarepo"
out=$(sh -c ". '$LIB'; roborev_repo_allowed '$WORK/notarepo'"; echo "rc=$?")
case "$out" in
  *rc=3) ok "case 11: non-git dir -> indeterminate (rc=3), not allowed" ;;
  *)     bad "case 11: expected rc=3, got: $out" ;;
esac

# ---- all-files-excluded skip (job 13884: CHANGELOG.md-only commit) ----------
# A commit whose every changed file matches exclude_patterns would review an
# empty diff. Skip it; any non-excluded file, or an unparseable config, reviews.
mkrepo "$WORK/exrepo" remote
cat > "$WORK/exrepo/.roborev.toml" <<'TOML'
# comment
exclude_patterns = [
  "CHANGELOG.md",
  ".claude/CURRENT_WORK.md",   # trailing comment
]
TOML
git -C "$WORK/exrepo" add .roborev.toml
git -c core.hooksPath=/dev/null -C "$WORK/exrepo" commit -qm cfg
exc() { # file... : commit exactly these files (content changes each time)
  for _f in "$@"; do
    mkdir -p "$WORK/exrepo/$(dirname "$_f")"
    echo "$RANDOM$_f" >> "$WORK/exrepo/$_f"
    git -C "$WORK/exrepo" add "$_f"
  done
  git -c core.hooksPath=/dev/null -C "$WORK/exrepo" commit -qm "touch $*"
}
export ROBOREV_GLOBAL_CONFIG="$WORK/no-global.toml"
export ROBOREV_HOOK_LOG="$WORK/hook.log"

exc CHANGELOG.md
run_hook "$WORK/exrepo" "$ALLOW"
expect_blocked "case 12: CHANGELOG.md-only commit -> not enqueued"
if grep -q 'skip: all files excluded' "$ROBOREV_HOOK_LOG" 2>/dev/null; then
  ok "case 12a: distinct 'skip: all files excluded' log line written"
else
  bad "case 12a: no 'skip: all files excluded' log line"
fi

exc CHANGELOG.md .claude/CURRENT_WORK.md
run_hook "$WORK/exrepo" "$ALLOW"
expect_blocked "case 12b: both excluded files only -> not enqueued"

exc CHANGELOG.md scripts/x.sh
run_hook "$WORK/exrepo" "$ALLOW"
expect_called  "case 13 (falsify): CHANGELOG.md + a .sh file -> enqueued"

# Unparseable exclude_patterns: fail toward reviewing, and say so.
printf 'exclude_patterns = [\n  "CHANGELOG.md",\n' > "$WORK/exrepo/.roborev.toml"
exc CHANGELOG.md
run_hook "$WORK/exrepo" "$ALLOW"
expect_called  "case 14: unparseable .roborev.toml -> enqueued (fail toward review)"
if grep -q 'indeterminate: config-unparseable' "$ROBOREV_HOOK_LOG" 2>/dev/null; then
  ok "case 14a: indeterminate logged"
else
  bad "case 14a: no 'indeterminate' log line"
fi

# Global config patterns apply too; a glob matches by basename.
printf 'exclude_patterns = ["*.lock"]\n' > "$WORK/no-global.toml"
printf 'x = 1\n' > "$WORK/exrepo/.roborev.toml"
exc deep/dir/renv.lock
run_hook "$WORK/exrepo" "$ALLOW"
expect_blocked "case 15: global glob '*.lock' matches nested file by basename"
rm -f "$WORK/no-global.toml"
run_hook "$WORK/exrepo" "$ALLOW"
expect_called  "case 15b (falsify): global config gone -> same commit enqueued"

# Empty commit (no files to judge): not skipped.
git -c core.hooksPath=/dev/null -C "$WORK/exrepo" commit -q --allow-empty -m empty
run_hook "$WORK/exrepo" "$ALLOW"
expect_called  "case 16: empty commit (no files) is not skipped"

echo "---"
if [ "$fail" -eq 0 ]; then echo "$pass/$pass PASS"; else echo "FAILURES: $fail (passed $pass)"; fi
exit "$fail"
