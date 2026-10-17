#!/bin/bash
# Tests for .claude/scripts/global_hooks_path_check.sh (llm#1388).
# Hermetic: synthetic clones under a mktemp dir, a stub `gh` (visibility table
# in $VIS_TABLE), a pinned global git config; the real config and the network
# are never touched. Exact exit codes asserted: 0 / 1 / 3. Each "reported" case
# has a falsification that changes only the thing that triggered it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
CHECK="$ROOT/.claude/scripts/global_hooks_path_check.sh"
WORK="$(mktemp -d)"; WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
GH="$WORK/hooks_global"; mkdir -p "$GH" "$WORK/hooks_other"
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$GH"

VIS_TABLE="$WORK/vis.tsv"; export VIS_TABLE
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/sh
# gh repo view OWNER/REPO --json visibility -q .visibility
v=$(awk -v k="$3" '$1 == k {print $2; exit}' "$VIS_TABLE")
[ -n "$v" ] || exit 1
[ "$v" = "FAIL" ] && exit 1
echo "$v"
EOF
chmod +x "$WORK/bin/gh"

SCAN="$WORK/docs_gh"; mkdir -p "$SCAN"
OUT="$WORK/out.txt"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect_rc() { if [ "$3" = "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (want $2, got $3; out: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi; }
has()   { grep -qF -- "$2" "$OUT" && ok "$1" || bad "$1 (no '$2' in: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; }
hasnt() { grep -qF -- "$2" "$OUT" && bad "$1 ('$2' present)" || ok "$1"; }

mkclone() { # dir remote-url
  mkdir -p "$1"; git -C "$1" init -q -b main
  git -C "$1" config user.email t@e.com; git -C "$1" config user.name T
  git -C "$1" remote add origin "$2"
}
run() { env PATH="$WORK/bin:$PATH" GHPC_SCAN_ROOT="$SCAN" GHPC_GH="$WORK/bin/gh" bash "$CHECK" > "$OUT" 2>&1; echo $?; }

mkclone "$SCAN/good" "git@github.com:synth/good.git"
mkclone "$SCAN/nested/deep/good2" "https://github.com/synth/good2.git"
printf 'synth/good PUBLIC\nsynth/good2 PUBLIC\n' > "$VIS_TABLE"

rc=$(run); expect_rc "g1: every public clone uses the global hooks dir" 0 "$rc"
has "g1a: summary counts the 2 public clones" "public_clones=2 bypass=0"

# a clone with its own core.hooksPath
mkclone "$SCAN/bypass_local" "git@github.com:synth/bypass_local.git"
git -C "$SCAN/bypass_local" config core.hooksPath "$WORK/hooks_other"
echo 'synth/bypass_local PUBLIC' >> "$VIS_TABLE"
rc=$(run); expect_rc "g2: public clone with a repo-local hooksPath is a bypass" 1 "$rc"
has "g2a: it is named" "BYPASS $SCAN/bypass_local"
hasnt "g2b: the good clones are not named" "BYPASS $SCAN/good"
git -C "$SCAN/bypass_local" config --unset core.hooksPath
rc=$(run); expect_rc "g2c (falsify): override removed -> clean again" 0 "$rc"

# local hooksPath that resolves to the same dir through a symlink is fine
ln -s "$GH" "$WORK/hooks_link"
git -C "$SCAN/bypass_local" config core.hooksPath "$WORK/hooks_link"
rc=$(run); expect_rc "g3: a symlink that resolves to the global dir is not a bypass" 0 "$rc"
git -C "$SCAN/bypass_local" config core.hooksPath ""
rc=$(run); expect_rc "g3a: an empty local hooksPath (hooks disabled) is a bypass" 1 "$rc"
has "g3b: reported as unset" "hooksPath=unset"
git -C "$SCAN/bypass_local" config --unset core.hooksPath

# private repo bypassing is not this check's business
mkclone "$SCAN/private_one" "git@github.com:synth/private_one.git"
git -C "$SCAN/private_one" config core.hooksPath "$WORK/hooks_other"
echo 'synth/private_one PRIVATE' >> "$VIS_TABLE"
rc=$(run); expect_rc "g4: a PRIVATE clone with its own hooksPath is not reported" 0 "$rc"
sed -i.bak 's#^synth/private_one PRIVATE#synth/private_one PUBLIC#' "$VIS_TABLE"
rc=$(run); expect_rc "g4a (falsify): same clone made PUBLIC is reported" 1 "$rc"
sed -i.bak 's#^synth/private_one PUBLIC#synth/private_one PRIVATE#' "$VIS_TABLE"

# non-GitHub origin, and no origin: skipped
mkclone "$SCAN/gitlab_one" "https://gitlab.example.invalid/synth/x.git"
git -C "$SCAN/gitlab_one" config core.hooksPath "$WORK/hooks_other"
mkdir -p "$SCAN/no_origin"; git -C "$SCAN/no_origin" init -q -b main
git -C "$SCAN/no_origin" config core.hooksPath "$WORK/hooks_other"
rc=$(run); expect_rc "g5: non-GitHub and origin-less clones are skipped" 0 "$rc"

# linked worktrees are skipped, and a duplicate of a bypassing clone counts once
git -C "$SCAN/good" -c core.hooksPath=/dev/null commit -q --allow-empty -m base
git -C "$SCAN/good" worktree add -q "$SCAN/wt_of_good" -b wt-branch
git -C "$SCAN/good" config --worktree core.hooksPath "$WORK/hooks_other" 2>/dev/null || true
rc=$(run); expect_rc "g6: a linked worktree directory is not scanned as a clone" 0 "$rc"
has "g6a: the worktree is not counted (3 public clones, not 4)" "public_clones=3"

# visibility lookup failure: INDETERMINATE, unless a bypass is also present
mkclone "$SCAN/lookup_fail" "git@github.com:synth/lookup_fail.git"
echo 'synth/lookup_fail FAIL' >> "$VIS_TABLE"
rc=$(run); expect_rc "g7: a visibility lookup failure with no bypass is INDETERMINATE" 3 "$rc"
has "g7a: the clone is listed as UNKNOWN" "UNKNOWN $SCAN/lookup_fail"
git -C "$SCAN/bypass_local" config core.hooksPath "$WORK/hooks_other"
rc=$(run); expect_rc "g7b: a determinate bypass wins over the lookup failure" 1 "$rc"
git -C "$SCAN/bypass_local" config --unset core.hooksPath
sed -i.bak 's#^synth/lookup_fail FAIL#synth/lookup_fail PUBLIC#' "$VIS_TABLE"
rc=$(run); expect_rc "g7c (falsify): lookup succeeds -> clean" 0 "$rc"

# global setting missing: every public clone bypasses
git config --file "$GIT_CONFIG_GLOBAL" --unset core.hooksPath
rc=$(env PATH="$WORK/bin:$PATH" GHPC_SCAN_ROOT="$SCAN" GHPC_GH="$WORK/bin/gh" GHPC_EXPECTED_HOOKS="$GH" bash "$CHECK" > "$OUT" 2>&1; echo $?)
expect_rc "g8: global core.hooksPath unset -> public clones are reported" 1 "$rc"
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$GH"

# read-only: no clone's config changed by the run (g2c..g8 left them as set)
before=$(cat "$SCAN"/good/.git/config)
run >/dev/null
after=$(cat "$SCAN"/good/.git/config)
[ "$before" = "$after" ] && ok "g9: the check does not modify clone config" || bad "g9: config changed"

echo "---"
if [ "$fail" -eq 0 ]; then echo "$pass/$pass PASS"; else echo "FAILURES: $fail (passed $pass)"; fi
exit "$fail"
