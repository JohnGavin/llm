#!/bin/bash
# Two-sided test of the post-commit ephemeral-path guard (llm#923).
set -u
HOOK="/Users/johngavin/docs_gh/worktrees/llm/feat/cc-20260802-120510/git-hooks/post-commit"
WORK=$(mktemp -d)
MARKER="$WORK/roborev_was_called"

# Stub roborev: records that it was invoked.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/roborev" <<EOF
#!/bin/sh
echo "invoked \$*" >> "$MARKER"
EOF
chmod +x "$WORK/bin/roborev"

# Copy the hook, pointing it at the stub instead of /usr/local/bin/roborev,
# and drop the git-lfs tail (irrelevant to this guard).
mkdir -p "$WORK/repo"
sed -e "s#ROBOREV=\"/usr/local/bin/roborev\"#ROBOREV=\"$WORK/bin/roborev\"#" \
    -e '/git-lfs/d' -e '/git lfs/d' "$HOOK" > "$WORK/hook.sh"
chmod +x "$WORK/hook.sh"

git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" config user.email t@e.com
git -C "$WORK/repo" config user.name T
echo hi > "$WORK/repo/f.txt"
git -C "$WORK/repo" add .
git -c core.hooksPath=/dev/null -C "$WORK/repo" commit -qm "test commit"

fail=0

# Case 1: temp path -> roborev MUST NOT be invoked.
( cd "$WORK/repo" && "$WORK/hook.sh" )
if [ -f "$MARKER" ]; then
  echo "FAIL case 1: roborev was invoked from a temp repo ($(cat "$MARKER"))"
  fail=1
else
  echo "PASS case 1: guard blocked roborev in $WORK/repo"
fi

# Case 2: override set -> roborev MUST be invoked (proves the guard is the
# thing blocking, not a hook that silently does nothing).
( cd "$WORK/repo" && ROBOREV_ALLOW_TMP_REPOS=1 "$WORK/hook.sh" )
if [ -f "$MARKER" ]; then
  echo "PASS case 2: override re-enabled roborev"
else
  echo "FAIL case 2: roborev not invoked even with ROBOREV_ALLOW_TMP_REPOS=1"
  fail=1
fi

# Case 3: a non-temp repo must still be reviewed.
rm -f "$MARKER"
REAL="$HOME/.cache/llm923_guard_test_repo"
rm -rf "$REAL"
mkdir -p "$REAL"
git -C "$REAL" init -q -b main
git -C "$REAL" config user.email t@e.com
git -C "$REAL" config user.name T
echo hi > "$REAL/f.txt"
git -C "$REAL" add .
git -c core.hooksPath=/dev/null -C "$REAL" commit -qm "test commit"
( cd "$REAL" && "$WORK/hook.sh" )
if [ -f "$MARKER" ]; then
  echo "PASS case 3: non-temp repo still reviewed"
else
  echo "FAIL case 3: guard over-matched — non-temp repo was skipped"
  fail=1
fi
rm -rf "$REAL" "$WORK"

echo "---"
if [ "$fail" -eq 0 ]; then echo "3/3 PASS"; else echo "FAILURES"; fi
exit "$fail"
