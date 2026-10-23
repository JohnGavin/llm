#!/bin/bash
# Tests for the per-project deny-list loader in private_data_scan.sh
# (llm#1434 Gap 2a). Hermetic: a temp git repo, a temp HOME, a stubbed gh
# (repo reported PRIVATE so the private-term rule is out of the picture), and a
# SYNTHETIC canary string only. Exact exit codes asserted (0 / 1 / 3).
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
SCAN="$ROOT/.claude/scripts/private_data_scan.sh"
WORK="$(mktemp -d)"; WORK="$(cd -P "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# The two file names have ONE home: the scanner. Read them from it.
LOCAL_NAME="$(sed -n 's/^PROJECT_DENYLIST_NAME="\(.*\)"$/\1/p' "$SCAN")"
DECL_NAME="$(sed -n 's/^PROJECT_DECLARE_NAME="\(.*\)"$/\1/p' "$SCAN")"
[ -n "$LOCAL_NAME" ] && [ -n "$DECL_NAME" ] || { echo "FAIL could not read file names from the scanner"; exit 1; }

CANARY="PROJCANARY_x7Kq2Rm"
GLOBAL_CANARY="GLOBCANARY_p9Lw4Tz"
export HOME="$WORK/home"; mkdir -p "$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
export UNIFIED_DB_PATH="$WORK/none.duckdb"
export PRIVATE_VALUES_FILE="$WORK/global_values.env"
printf 'GLOBAL_X=%s\n' "$GLOBAL_CANARY" > "$PRIVATE_VALUES_FILE"; chmod 600 "$PRIVATE_VALUES_FILE"
STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\necho PRIVATE\n' > "$STUB/gh"; chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"

OUT="$WORK/out.txt"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
expect_rc() { if [ "$3" = "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (want $2, got $3; out: $(tr '\n' ' ' < "$OUT" | cut -c1-300))"; fi; }
nocanary() { if grep -qF -e "$CANARY" -e "$GLOBAL_CANARY" "$OUT"; then bad "$1 (canary text leaked)"; else ok "$1"; fi; }
has() { if grep -qF -- "$2" "$OUT"; then ok "$1"; else bad "$1 (no '$2')"; fi; }

# mkrepo DIR: fresh repo with the local list gitignored and one clean base commit.
mkrepo() {
    rm -rf "$1"; mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email t@e.com; git -C "$1" config user.name T
    git -C "$1" config core.hooksPath /dev/null
    printf '%s\n' "$LOCAL_NAME" > "$1/.gitignore"
    printf 'clean\n' > "$1/README.txt"
    git -C "$1" add .gitignore README.txt
    git -C "$1" commit -q -m base
}
# run REPO [ARGS...]: scan the staged set; prints the exit code.
run() { local r="$1"; shift; REPO_ROOT="$r" bash "$SCAN" --staged --quiet "$@" > "$OUT" 2>&1; echo $?; }
stage_canary() { printf 'value=%s\n' "$CANARY" > "$1/notes.txt"; git -C "$1" add notes.txt; }
write_list() { printf 'PROJ_SECRET=%s\n' "$CANARY" > "$2"; chmod 600 "$2"; }

R="$WORK/repo"

# (a) canary in the project list is blocked when another file with it is staged
mkrepo "$R"; write_list "$R" "$R/$LOCAL_NAME"; stage_canary "$R"
rc=$(run "$R"); expect_rc "a: staged canary matched by project list" 1 "$rc"
nocanary "a1: output carries no canary text"
has "a2: finding names a project deny-list entry" "project deny-list entry"
# a3 falsification: remove the list -> the same staged file passes
rm -f "$R/$LOCAL_NAME"
rc=$(run "$R"); expect_rc "a3 falsification: without the project list the same staged file is clean" 0 "$rc"

# (b) no declare + no list: passes
mkrepo "$R"; printf 'ok\n' > "$R/f.txt"; git -C "$R" add f.txt
rc=$(run "$R"); expect_rc "b: no marker, no list -> clean" 0 "$rc"

# (c) declare + list missing -> 3 ; creating it -> 0 ; deleting -> 3
mkrepo "$R"; printf '# project holds personal data\n' > "$R/$DECL_NAME"; printf 'ok\n' > "$R/f.txt"; git -C "$R" add f.txt
rc=$(run "$R"); expect_rc "c: marker + list missing -> INDETERMINATE" 3 "$rc"
has "c1: reason named" "is missing"
nocanary "c2: no canary text"
write_list "$R" "$R/$LOCAL_NAME"
rc=$(run "$R"); expect_rc "c3 falsification: creating the list flips 3 -> 0" 0 "$rc"
rm -f "$R/$LOCAL_NAME"
rc=$(run "$R"); expect_rc "c4 falsification: deleting it flips back to 3" 3 "$rc"

# (d) declare + list present but thin (comment only / value shorter than 6)
mkrepo "$R"; printf '# x\n' > "$R/$DECL_NAME"; printf 'ok\n' > "$R/f.txt"; git -C "$R" add f.txt
printf '# nothing here\nSHORT=abc\n' > "$R/$LOCAL_NAME"; chmod 600 "$R/$LOCAL_NAME"
rc=$(run "$R"); expect_rc "d: marker + thin list -> INDETERMINATE" 3 "$rc"
has "d1: reason named" "is thin"

# (e) declare with path= to an existing list elsewhere
mkrepo "$R"; EXT="$WORK/elsewhere.env"; write_list "$R" "$EXT"
printf 'path=%s\n' "$EXT" > "$R/$DECL_NAME"; stage_canary "$R"
rc=$(run "$R"); expect_rc "e: path= list is loaded, canary blocked" 1 "$rc"
nocanary "e1: output carries no canary text"
# e2: ~/ prefix resolves against HOME
cp "$EXT" "$HOME/ext_list.env"; chmod 600 "$HOME/ext_list.env"
printf 'path=~/ext_list.env\n' > "$R/$DECL_NAME"
rc=$(run "$R"); expect_rc "e2: ~/ path= resolved against HOME, canary blocked" 1 "$rc"

# (f) path= target missing; relative path= invalid
mkrepo "$R"; printf 'path=%s\n' "$WORK/nope.env" > "$R/$DECL_NAME"; printf 'ok\n' > "$R/f.txt"; git -C "$R" add f.txt
rc=$(run "$R"); expect_rc "f: path= target missing -> INDETERMINATE" 3 "$rc"
printf 'path=relative.env\n' > "$R/$DECL_NAME"
rc=$(run "$R"); expect_rc "f2: relative path= rejected -> INDETERMINATE" 3 "$rc"

# (g) the local list is tracked by git
mkrepo "$R"; write_list "$R" "$R/$LOCAL_NAME"; git -C "$R" add -f "$LOCAL_NAME"
rc=$(run "$R"); expect_rc "g: tracked project list -> INDETERMINATE" 3 "$rc"
has "g1: reason named" "tracked by git"
nocanary "g2: no canary text"
git -C "$R" rm -q --cached "$LOCAL_NAME"
rc=$(run "$R"); expect_rc "g3 falsification: untracked again -> clean" 0 "$rc"

# (h) --no-denylist skips project lists and ignores a missing required one
mkrepo "$R"; printf '# x\n' > "$R/$DECL_NAME"; stage_canary "$R"
rc=$(run "$R" --no-denylist); expect_rc "h: --no-denylist, required list missing -> not a failure" 0 "$rc"
write_list "$R" "$R/$LOCAL_NAME"
rc=$(run "$R" --no-denylist); expect_rc "h2: --no-denylist does not apply the project list" 0 "$rc"

# (i) not gitignored -> warning only
mkrepo "$R"; : > "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -q -m ign
write_list "$R" "$R/$LOCAL_NAME"; printf 'ok\n' > "$R/f.txt"; git -C "$R" add f.txt
rc=$(run "$R"); expect_rc "i: list not gitignored -> still runs" 0 "$rc"
has "i1: warning printed" "not covered by .gitignore"

echo ""
echo "project-denylist tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
