#!/bin/bash
# Tests for `private_data_git_hooks_install.sh --audit` (llm#1434 Gap 1).
# Hermetic: synthetic repos under a mktemp dir and a pinned global git config;
# the real config, real repos and the network are never touched. Exact exit
# codes asserted (0 / 1 / 2 / 3). Each "uncovered" case has a falsification.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
AUD="${AUDIT_SCRIPT_UNDER_TEST:-$ROOT/.claude/scripts/private_data_git_hooks_install.sh}"   # override = red-first runs against an older script
WORK="$(mktemp -d)"; WORK="$(cd -P "$WORK" && pwd -P)"
trap 'chmod -R u+rw "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
GATE="$WORK/gate_hooks"; mkdir -p "$GATE"
printf '#!/bin/sh\n. "$PII_HOOKS_DIR/lib/pii_gate.sh"\n' > "$GATE/pre-commit"; chmod +x "$GATE/pre-commit"
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$GATE"

SCAN="$WORK/docs_gh"; mkdir -p "$SCAN"
OUT="$WORK/out.txt"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect_rc() { if [ "$3" = "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (want $2, got $3; out: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi; }
has()   { grep -qF -- "$2" "$OUT" && ok "$1" || bad "$1 (no '$2' in: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; }
hasnt() { grep -qF -- "$2" "$OUT" && bad "$1 ('$2' present)" || ok "$1"; }

mkrepo() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@e.com; git -C "$1" config user.name T; }
run() { bash "$AUD" --audit --root "$SCAN" > "$OUT" 2>&1; echo $?; }
fingerprint() { find "$SCAN" -type f \( -name config -o -name pre-commit \) -print0 | sort -z | xargs -0 cksum | cksum; }

# a1: no override, global gate in effect -> covered
mkrepo "$SCAN/plain"
rc=$(run); expect_rc "a1: repo without an override is covered by the global hook" 0 "$rc"
has "a1a: summary line" "repos=1 covered=1 uncovered=0 indeterminate=0"

# a2: local hooksPath whose pre-commit runs the scanner (installer marker) -> covered
mkdir -p "$WORK/own_ok"
printf '#!/bin/sh\n# private-data-scan pre-commit gate (marker)\n' > "$WORK/own_ok/pre-commit"; chmod +x "$WORK/own_ok/pre-commit"
mkrepo "$SCAN/override_ok"; git -C "$SCAN/override_ok" config core.hooksPath "$WORK/own_ok"
rc=$(run); expect_rc "a2: local hooksPath with a scanner-running pre-commit is covered" 0 "$rc"
has "a2a: counts" "repos=2 covered=2 uncovered=0 indeterminate=0"

# a3: local hooksPath, no scanner -> uncovered, exit 1
mkdir -p "$WORK/own_bad"; printf '#!/bin/sh\necho hi\n' > "$WORK/own_bad/pre-commit"; chmod +x "$WORK/own_bad/pre-commit"
mkrepo "$SCAN/override_bad"; git -C "$SCAN/override_bad" config core.hooksPath "$WORK/own_bad"
rc=$(run); expect_rc "a3: local hooksPath without the scanner is uncovered" 1 "$rc"
has "a3a: reason reported" "reason=pre-commit-does-not-run-scanner"
has "a3b: counts" "repos=3 covered=2 uncovered=1 indeterminate=0"
hasnt "a3c: no repo name in the output" "override_bad"
hasnt "a3d: no path in the output" "$WORK"
grep -qE '^UNCOVERED repo-[0-9a-f]{8} reason=' "$OUT" && ok "a3e: label is repo-<8 hex>" || bad "a3e: label shape"

# a4: the repo's own .git/hooks/pre-commit has the marker but the override replaces it -> still uncovered
printf '#!/bin/sh\n# private-data-scan pre-commit gate (ignored under an override)\n' > "$SCAN/override_bad/.git/hooks/pre-commit"; chmod +x "$SCAN/override_bad/.git/hooks/pre-commit"
rc=$(run); expect_rc "a4: .git/hooks hook is ignored under an override -> still uncovered" 1 "$rc"
# a5: override to a dir with no pre-commit at all
mkdir -p "$WORK/own_empty"; mkrepo "$SCAN/override_empty"; git -C "$SCAN/override_empty" config core.hooksPath "$WORK/own_empty"
rc=$(run); expect_rc "a5: override dir with no pre-commit is uncovered" 1 "$rc"
has "a5a: reason" "reason=no-pre-commit-in-effective-hooks-dir"
# a6: non-executable hook is ignored by git -> uncovered
mkdir -p "$WORK/own_noexec"; printf '# private-data-scan pre-commit gate\n' > "$WORK/own_noexec/pre-commit"; chmod 644 "$WORK/own_noexec/pre-commit"
mkrepo "$SCAN/override_noexec"; git -C "$SCAN/override_noexec" config core.hooksPath "$WORK/own_noexec"
rc=$(run); expect_rc "a6: non-executable scanner hook is uncovered" 1 "$rc"
has "a6a: reason" "reason=pre-commit-not-executable-file"

# b: falsification -- an audit that ignores the local override sees nothing wrong
sed 's/config --type=path --get core.hooksPath/config --global --type=path --get core.hooksPath/' "$AUD" > "$WORK/audit_ignores_override.sh"
cmp -s "$AUD" "$WORK/audit_ignores_override.sh" && bad "b0: mutation did not change the script" || ok "b0: mutation applied"
bash "$WORK/audit_ignores_override.sh" --audit --root "$SCAN" > "$OUT" 2>&1; rc=$?
expect_rc "b1 (falsification): audit ignoring the local override reports everything covered" 0 "$rc"

# c: report-only -- no config or hook file changed by any run
before=$(fingerprint)
run >/dev/null
after=$(fingerprint)
[ "$before" = "$after" ] && ok "c1: report-only, configs and hooks unchanged after a run" || bad "c1: files changed"

# d: broken config -> INDETERMINATE (3) when nothing is uncovered, 1 when something is
rm -rf "$SCAN/override_bad" "$SCAN/override_empty" "$SCAN/override_noexec"
mkrepo "$SCAN/broken"; printf '[core\n  this is not a config\n' > "$SCAN/broken/.git/config"
rc=$(run); expect_rc "d1: unreadable config is INDETERMINATE, never covered" 3 "$rc"
has "d1a: reported as uninspectable" "UNINSPECTABLE repo-"
has "d1b: counts" "uncovered=0 indeterminate=1"
mkrepo "$SCAN/override_bad2"; git -C "$SCAN/override_bad2" config core.hooksPath "$WORK/own_bad"
rc=$(run); expect_rc "d2: an uncovered repo wins over an uninspectable one" 1 "$rc"
rm -rf "$SCAN/broken" "$SCAN/override_bad2"
rc=$(run); expect_rc "d3 (falsification): broken repo removed -> back to 0" 0 "$rc"

# e: no global hooksPath at all -> default <repo>/.git/hooks decides
export GIT_CONFIG_GLOBAL="$WORK/empty_gitconfig"; : > "$GIT_CONFIG_GLOBAL"
rc=$(run); expect_rc "e1: no global hooksPath and no repo hook -> the plain repo is uncovered" 1 "$rc"
printf '#!/bin/sh\n# private-data-scan pre-commit gate\n' > "$SCAN/plain/.git/hooks/pre-commit"; chmod +x "$SCAN/plain/.git/hooks/pre-commit"
rc=$(run); expect_rc "e2: default .git/hooks pre-commit with the marker -> covered again" 0 "$rc"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"

# f: usage and root errors
bash "$AUD" --audit --install > "$OUT" 2>&1; rc=$?; expect_rc "f1: --audit combined with an action is a usage error" 2 "$rc"
bash "$AUD" --audit --root "$WORK/does_not_exist" > "$OUT" 2>&1; rc=$?; expect_rc "f2: missing root is INDETERMINATE, not 0" 3 "$rc"

# g: linked worktrees are not counted twice
git -C "$SCAN/plain" -c user.email=t@e.com -c user.name=T commit -q --no-verify --allow-empty -m init
git -C "$SCAN/plain" worktree add -q "$SCAN/plain_wt" -b wt >/dev/null 2>&1
rc=$(run)
has "g1: a linked worktree is skipped (same repo count)" "repos=2 "

echo ""; echo "private_data_git_hooks_audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
