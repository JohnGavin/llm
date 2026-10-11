#!/bin/bash
# Two-sided tests of the global PII git hooks (llm#1365): git-hooks/pre-commit,
# git-hooks/pre-push and git-hooks/lib/pii_gate.sh.
#
# Hermetic by construction:
#   * every repo is synthetic, under a mktemp dir; the real config is never
#     changed -- hooks are selected per command with `-c core.hooksPath=...` or by
#     running the hook script directly;
#   * HOME, the global/system git config, the deny-list (PRIVATE_VALUES_FILE) and
#     the unified DB are all pinned to the temp dir, so neither the developer's
#     real ~/.config/private_values.env nor ~/.claude/logs is read or written;
#   * git-lfs is a recording stub on PATH.
# Exact exit codes are asserted (0 pass / 1 FAIL / 2 usage / 3 INDETERMINATE,
# exit-code-conventions). Every "blocked" case is paired with a falsification:
# change ONLY the thing that blocked it and assert the hook now lets it through.
# HOOKS resolves from this script's own directory (portable-build-artifacts).
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOKS="$HERE"
WORK="$(mktemp -d)"; WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export UNIFIED_DB_PATH="$WORK/none.duckdb"
export PRIVATE_VALUES_FILE="$WORK/pv.env"
SENTINEL="SELFTEST_1365_SENTINEL_q9Zr4mXk"
printf 'MY_SENTINEL=%s\n' "$SENTINEL" > "$PRIVATE_VALUES_FILE"; chmod 600 "$PRIVATE_VALUES_FILE"
SCAN_LOG="$HOME/.claude/logs/private_data_scan.log"
OUT="$WORK/out.txt"

# git-lfs stub: records its arguments and stdin; exit code from $LFS_RC.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git-lfs" <<EOF
#!/bin/sh
echo "args: \$*" >> "$WORK/lfs.log"
cat >> "$WORK/lfs.stdin"
exit \${LFS_RC:-0}
EOF
chmod +x "$WORK/bin/git-lfs"
export PATH="$WORK/bin:$PATH"

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect_rc() { # label want got
  if [ "$3" = "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (want exit $2, got $3; out: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi
}
expect_out() { # label pattern
  if grep -q -- "$2" "$OUT"; then ok "$1"; else bad "$1 (no '$2' in: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi
}

mkrepo() { # dir
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@e.com
  git -C "$1" config user.name T
  echo clean > "$1/f.txt"
  git -C "$1" add .
  git -c core.hooksPath=/dev/null -C "$1" commit -qm base
}
# pc DIR [HOOKDIR] : run the pre-commit hook inside DIR, capture rc/out.
pc() { ( cd "$1" && "${2:-$HOOKS}/pre-commit" ) > "$OUT" 2>&1; echo $?; }
# pp DIR LSHA RSHA [REMOTE] [HOOKDIR] : run the pre-push hook with git's stdin protocol.
pp() {
  printf 'refs/heads/main %s refs/heads/main %s\n' "$2" "$3" \
    | ( cd "$1" && "${5:-$HOOKS}/pre-push" "${4:-origin}" "https://example.invalid/x.git" ) > "$OUT" 2>&1
  echo "${PIPESTATUS[1]}"
}
Z=0000000000000000000000000000000000000000

# ---- pre-commit -------------------------------------------------------------
R="$WORK/r1"; mkrepo "$R"
echo "hello world" > "$R/a.txt"; git -C "$R" add a.txt
rc=$(pc "$R"); expect_rc "pc-1: clean staged commit passes" 0 "$rc"

echo "leak: $SENTINEL" > "$R/leak.txt"; git -C "$R" add leak.txt
rc=$(pc "$R"); expect_rc "pc-2: staged deny-list value is blocked" 1 "$rc"
expect_out "pc-2a: message says BLOCKED and names the hook" "pre-commit BLOCKED"
if grep -q "$SENTINEL" "$OUT"; then bad "pc-2b: the leaked value is echoed in the output"; else ok "pc-2b: the leaked value is not echoed"; fi
git -C "$R" rm -q --cached leak.txt
rc=$(pc "$R"); expect_rc "pc-2c (falsify): leak unstaged -> passes" 0 "$rc"

# End to end through git itself (commit must not be created when blocked).
echo "leak: $SENTINEL" > "$R/leak.txt"; git -C "$R" add leak.txt
before=$(git -C "$R" rev-parse HEAD)
git -c core.hooksPath="$HOOKS" -C "$R" commit -qm leak > "$OUT" 2>&1; rc=$?
after=$(git -C "$R" rev-parse HEAD)
if [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then ok "pc-3: git commit with a leak is refused, no commit created"; else bad "pc-3: rc=$rc before=$before after=$after"; fi
git -C "$R" rm -q --cached leak.txt; rm -f "$R/leak.txt"
echo "fine" > "$R/ok.txt"; git -C "$R" add ok.txt
git -c core.hooksPath="$HOOKS" -C "$R" commit -qm fine > "$OUT" 2>&1; rc=$?
expect_rc "pc-3a (falsify): same repo, clean commit via git succeeds" 0 "$rc"

# PDF in a public-visibility repo (no remote/gh -> visibility unknown -> public).
R="$WORK/r2"; mkrepo "$R"
printf '%%PDF-1.4\n%%fixture\n' > "$R/doc.pdf"; git -C "$R" add doc.pdf
rc=$(pc "$R"); expect_rc "pc-4: PDF in a public repo is blocked" 1 "$rc"
expect_out "pc-4a: reason is the document-format gate" "document-format-blocked"
git -C "$R" rm -q --cached doc.pdf; printf '%%PDF-1.4\n' > "$R/doc.txt"; git -C "$R" add doc.txt
rc=$(pc "$R"); expect_rc "pc-4b (falsify): same bytes as .txt -> passes" 0 "$rc"
# Allow-listed PDF with no extractable text: scanner is INDETERMINATE (3); hook must block with 3.
git -C "$R" rm -q --cached doc.txt
printf '%%PDF-1.4\n' > "$R/doc.pdf"; git -C "$R" add doc.pdf
printf 'doc.pdf | pc-5 fixture\n' > "$WORK/doc-allow.txt"
rc=$(PRIVATE_DATA_DOC_ALLOWLIST="$WORK/doc-allow.txt" pc "$R")
expect_rc "pc-5: scanner INDETERMINATE (3) is blocked as exit 3, not passed" 3 "$rc"
expect_out "pc-5a: message says INDETERMINATE" "INDETERMINATE"

# Scanner missing -> fail closed with a clear message (hooks dir copy without .claude/).
NOSCAN="$WORK/noscan/git-hooks"; mkdir -p "$NOSCAN"; cp -R "$HOOKS/lib" "$HOOKS/pre-commit" "$HOOKS/pre-push" "$NOSCAN/"
R="$WORK/r3"; mkrepo "$R"; echo x > "$R/b.txt"; git -C "$R" add b.txt
rc=$(pc "$R" "$NOSCAN"); expect_rc "pc-6: scanner missing -> blocked, exit 3" 3 "$rc"
expect_out "pc-6a: message names the missing scanner" "scanner not found"
mkdir -p "$WORK/noscan/.claude/scripts"; cp "$HOOKS/../.claude/scripts/private_data_scan.sh" "$WORK/noscan/.claude/scripts/"
rc=$(pc "$R" "$NOSCAN"); expect_rc "pc-6b (falsify): scanner present -> passes" 0 "$rc"
rm -rf "$WORK/noscan/.claude"
git -C "$R" reset -q   # nothing staged: scanner not needed
rc=$(pc "$R" "$NOSCAN"); expect_rc "pc-6c: nothing staged -> no scan, passes even without scanner" 0 "$rc"

# Per-repo hook (no marker) is still invoked, and its failure propagates.
R="$WORK/r4"; mkrepo "$R"; echo x > "$R/c.txt"; git -C "$R" add c.txt
printf '#!/bin/sh\necho invoked >> "%s/repo_hook.log"\nexit ${REPO_HOOK_RC:-0}\n' "$WORK" > "$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
rm -f "$WORK/repo_hook.log"
rc=$(pc "$R"); expect_rc "pc-7: repo with its own pre-commit passes" 0 "$rc"
if [ -f "$WORK/repo_hook.log" ]; then ok "pc-7a: the repo's own pre-commit WAS invoked"; else bad "pc-7a: repo's own pre-commit NOT invoked"; fi
rc=$(REPO_HOOK_RC=7 pc "$R"); expect_rc "pc-7b: the repo hook's failing exit status (7) propagates" 7 "$rc"
rm -f "$R/.git/hooks/pre-commit" "$WORK/repo_hook.log"
rc=$(pc "$R"); expect_rc "pc-7c (falsify): no repo hook -> passes, nothing invoked" 0 "$rc"
if [ -f "$WORK/repo_hook.log" ]; then bad "pc-7d: log exists with no hook"; else ok "pc-7d: no phantom invocation"; fi

# Installer-marked per-repo hook: scan exactly once, not twice.
R="$WORK/r5"; mkrepo "$R"; echo y > "$R/d.txt"; git -C "$R" add d.txt
bash "$HOOKS/../.claude/scripts/private_data_git_hooks_install.sh" --repo "$R" --install --hook pre-commit > "$OUT" 2>&1
rm -f "$SCAN_LOG"
( cd "$R" && PRIVATE_DATA_SCAN_BIN="$HOOKS/../.claude/scripts/private_data_scan.sh" "$HOOKS/pre-commit" ) > "$OUT" 2>&1; rc=$?
n=$(grep -c "mode=staged" "$SCAN_LOG" 2>/dev/null); n=${n:-0}
expect_rc "pc-8: installer-marked repo hook + global hook passes" 0 "$rc"
if [ "$n" = "1" ]; then ok "pc-8a: scanner ran exactly once (no double scan)"; else bad "pc-8a: scanner ran $n times, want 1"; fi
# Falsify: remove the marker -> the repo hook is opaque to us, so both scan (2 runs).
sed -i.bak 's/private-data-scan pre-commit gate/xx/g' "$R/.git/hooks/pre-commit"; rm -f "$R/.git/hooks/pre-commit.bak"
rm -f "$SCAN_LOG"
( cd "$R" && PRIVATE_DATA_SCAN_BIN="$HOOKS/../.claude/scripts/private_data_scan.sh" "$HOOKS/pre-commit" ) > "$OUT" 2>&1; rc=$?
n=$(grep -c "mode=staged" "$SCAN_LOG" 2>/dev/null); n=${n:-0}
if [ "$n" = "2" ]; then ok "pc-8b (falsify): marker removed -> scanned twice, so the count really measures it"; else bad "pc-8b: scanner ran $n times, want 2"; fi
bash "$HOOKS/../.claude/scripts/private_data_git_hooks_install.sh" --repo "$R" --uninstall --hook pre-commit > "$OUT" 2>&1

# ---- pre-push ---------------------------------------------------------------
# History: root (leaky or clean) -> second (clean).
mkhist() { # dir leaky-root(0/1)
  mkdir -p "$1"; git -C "$1" init -q -b main
  git -C "$1" config user.email t@e.com; git -C "$1" config user.name T
  if [ "$2" = "1" ]; then echo "leak: $SENTINEL" > "$1/root.txt"; else echo clean > "$1/root.txt"; fi
  git -C "$1" add .; git -c core.hooksPath=/dev/null -C "$1" commit -qm root
  echo more > "$1/two.txt"; git -C "$1" add .; git -c core.hooksPath=/dev/null -C "$1" commit -qm two
}
R="$WORK/h1"; mkhist "$R" 1
ROOT=$(git -C "$R" rev-list --max-parents=0 HEAD); TIP=$(git -C "$R" rev-parse HEAD)
rm -f "$WORK/lfs.log" "$WORK/lfs.stdin"
rc=$(pp "$R" "$ROOT" "$Z"); expect_rc "pp-1: new branch whose ONLY commit is a leaky root commit is blocked" 1 "$rc"
expect_out "pp-1a: message says pre-push BLOCKED" "pre-push BLOCKED"
rc=$(pp "$R" "$TIP" "$Z"); expect_rc "pp-2: new branch, leak in the ROOT commit, clean tip, is blocked (<root>..<sha> would miss it)" 1 "$rc"
R2="$WORK/h2"; mkhist "$R2" 0
TIP2=$(git -C "$R2" rev-parse HEAD)
rc=$(pp "$R2" "$TIP2" "$Z"); expect_rc "pp-2a (falsify): same history, clean root -> passes" 0 "$rc"
# Update of an existing branch: only rsha..lsha is scanned.
ROOT2=$(git -C "$R2" rev-list --max-parents=0 HEAD)
rc=$(pp "$R" "$TIP" "$ROOT"); expect_rc "pp-3: update rsha..lsha with a clean new commit passes (leak is in the already-pushed root)" 0 "$rc"
echo "leak: $SENTINEL" > "$R2/three.txt"; git -C "$R2" add .; git -c core.hooksPath=/dev/null -C "$R2" commit -qm three
TIP3=$(git -C "$R2" rev-parse HEAD)
rc=$(pp "$R2" "$TIP3" "$TIP2"); expect_rc "pp-3a: update whose new commit leaks is blocked" 1 "$rc"
# Remote-tracking ref makes a commit "already pushed to this remote".
git -C "$R" update-ref refs/remotes/origin/main "$ROOT"
rc=$(pp "$R" "$TIP" "$Z" origin); expect_rc "pp-4: new branch, leaky root already on origin/main -> only new commits scanned, passes" 0 "$rc"
rc=$(pp "$R" "$TIP" "$Z" otherremote); expect_rc "pp-4a (falsify): pushing to a remote that does not have it -> root scanned, blocked" 1 "$rc"
git -C "$R" update-ref -d refs/remotes/origin/main
# Remote tip unknown locally: fall back to scanning everything not on the remote.
rc=$(pp "$R" "$TIP" "1111111111111111111111111111111111111111"); expect_rc "pp-5: remote tip unknown locally -> full scan, leak found" 1 "$rc"
# Deleting a ref: nothing to scan.
rc=$(pp "$R" "$Z" "$TIP"); expect_rc "pp-6: ref deletion passes without scanning" 0 "$rc"

# git-lfs still invoked, with the same args and stdin.
rm -f "$WORK/lfs.log" "$WORK/lfs.stdin"
rc=$(pp "$R2" "$TIP2" "$Z")
expect_rc "pp-7: clean push passes" 0 "$rc"
if grep -q "args: pre-push origin https://example.invalid/x.git" "$WORK/lfs.log" 2>/dev/null; then ok "pp-7a: git-lfs invoked with 'pre-push <remote> <url>'"; else bad "pp-7a: git-lfs not invoked correctly ($(cat "$WORK/lfs.log" 2>/dev/null))"; fi
if grep -q "$TIP2" "$WORK/lfs.stdin" 2>/dev/null; then ok "pp-7b: git-lfs received the ref lines on stdin"; else bad "pp-7b: git-lfs got no stdin"; fi
rc=$(LFS_RC=5 pp "$R2" "$TIP2" "$Z"); expect_rc "pp-7c: git-lfs failure (5) propagates" 5 "$rc"
rm -f "$WORK/lfs.log"
rc=$(pp "$R" "$TIP" "$Z"); expect_rc "pp-7d: a blocked push never reaches git-lfs" 1 "$rc"
if [ -f "$WORK/lfs.log" ]; then bad "pp-7e: git-lfs invoked despite the block"; else ok "pp-7e: git-lfs not invoked after a block"; fi
# git-lfs absent: original behaviour preserved (exit 2 + the original message).
rc=$(PATH="/usr/bin:/bin" pp "$R2" "$Z" "$TIP2")
if PATH="/usr/bin:/bin" command -v git-lfs >/dev/null 2>&1; then
  echo "SKIP pp-8: git-lfs exists in /usr/bin:/bin on this machine"
else
  expect_rc "pp-8: git-lfs missing -> exit 2 as before" 2 "$rc"
  expect_out "pp-8a: original 'git-lfs was not found' message kept" "'git-lfs' was not found"
fi

# Scanner missing at push time.
rc=$(pp "$R2" "$TIP2" "$Z" origin "$NOSCAN"); expect_rc "pp-9: scanner missing -> push blocked, exit 3" 3 "$rc"
expect_out "pp-9a: message names the missing scanner" "scanner not found"

# Per-repo pre-push is still invoked (with stdin) after git-lfs; marker => single scan.
printf '#!/bin/sh\ncat >> "%s/repo_pp.stdin"\nexit ${REPO_HOOK_RC:-0}\n' "$WORK" > "$R2/.git/hooks/pre-push"; chmod +x "$R2/.git/hooks/pre-push"
rm -f "$WORK/repo_pp.stdin"
rc=$(pp "$R2" "$TIP2" "$Z"); expect_rc "pp-10: repo with its own pre-push passes" 0 "$rc"
if grep -q "$TIP2" "$WORK/repo_pp.stdin" 2>/dev/null; then ok "pp-10a: repo's own pre-push invoked with the ref lines on stdin"; else bad "pp-10a: repo's own pre-push not invoked / no stdin"; fi
rc=$(REPO_HOOK_RC=9 pp "$R2" "$TIP2" "$Z"); expect_rc "pp-10b: its failing status (9) propagates" 9 "$rc"
rm -f "$R2/.git/hooks/pre-push" "$WORK/repo_pp.stdin"
rc=$(pp "$R2" "$TIP2" "$Z"); expect_rc "pp-10c (falsify): hook removed -> passes" 0 "$rc"
if [ -f "$WORK/repo_pp.stdin" ]; then bad "pp-10d: phantom invocation"; else ok "pp-10d: not invoked without a hook"; fi

# End to end: real `git push` to a bare repo, new branch with a leaky root commit.
git init -q --bare "$WORK/remote.git"
git -C "$R" remote add origin "$WORK/remote.git" 2>/dev/null
git -c core.hooksPath="$HOOKS" -C "$R" push -q origin main > "$OUT" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && ! git -C "$WORK/remote.git" rev-parse -q --verify refs/heads/main >/dev/null; then ok "pp-11: git push of a leaky root commit is refused; remote has no ref"; else bad "pp-11: rc=$rc; remote ref present?"; fi
mkhist "$WORK/h3" 0
git -c core.hooksPath="$HOOKS" -C "$WORK/h3" push -q "$WORK/remote.git" main > "$OUT" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && git -C "$WORK/remote.git" rev-parse -q --verify refs/heads/main >/dev/null; then ok "pp-11a (falsify): clean root commit pushes through git"; else bad "pp-11a: rc=$rc $(cat "$OUT")"; fi

# post-* hooks are not part of this change.
for h in post-commit post-merge post-checkout post-rewrite; do
  if grep -q "private_data_scan\|pii_gate" "$HOOKS/$h"; then bad "untouched: $h references the PII gate"; else ok "untouched: $h has no PII gate"; fi
done

echo "---"
if [ "$fail" -eq 0 ]; then echo "$pass/$pass PASS"; else echo "FAILURES: $fail (passed $pass)"; fi
exit "$fail"
