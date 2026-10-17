#!/usr/bin/env bash
# llm#1458 part 1: secret_exposure_scan.sh must not cry wolf on
#   (a) `env NAME=val ... COMMAND >file` (a command prefix, not an env dump)
#   (b) an alphabet-in-order placeholder token (ghp_ABCDEFGH...),
# while still flagging real whole-environment dumps and a random-looking
# token. Every case points the scanner at a scratch REPO_ROOT and a scratch
# HOME so it measures the fixture, not the checkout it lives in.
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${SCAN_SCRIPT:-$HERE/../.claude/scripts/secret_exposure_scan.sh}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_fp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/tests" "$WORK/home"

# Random-looking token assembled at runtime so no literal sits in this file.
RND="ghp_""Zq7Kx9mWc2LpR4vTn8YbHd3FgJs6Ue1Vo5Ar"

W="$WORK/repo/tests"
cat > "$W/fp_env_prefix.sh" <<'EOF'
rc=$(printf x | env A=1 B="two words" bash "$H" --check >"$OUT" 2>"$ERR"; echo $?)
printf x | env -i A=1 bash "$H" >"$OUT" 2>"$ERR"
EOF
cat > "$W/tp_bare_env.sh" <<'EOF'
env > "$OUT"
EOF
cat > "$W/tp_printenv.sh" <<'EOF'
printenv > "$OUT"
EOF
cat > "$W/tp_export_p.sh" <<'EOF'
export -p > "$OUT"
EOF
cat > "$W/tp_env_assign_only.sh" <<'EOF'
env A=1 > "$OUT"
EOF
printf 'curl -H "Authorization: Bearer ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123" x\n' > "$W/fp_walk_token.sh"
printf 'curl -H "Authorization: Bearer %s" x\n' "$RND" > "$W/tp_random_token.sh"

OUTJ="$WORK/out.json"
HOME="$WORK/home" REPO_ROOT="$WORK/repo" UNIFIED_DB_PATH="$WORK/u.duckdb" \
    bash "$SCAN" --scan --json > "$OUTJ" 2>"$WORK/err.txt"

pass=0
total=0
flagged() { grep -q "\"file\":\"[^\"]*/$1\"" "$OUTJ"; }
expect_clean() {
    total=$((total + 1))
    if flagged "$1"; then echo "FAIL: $1 wrongly flagged ($2)"; else pass=$((pass + 1)); fi
}
expect_flagged() {
    total=$((total + 1))
    if flagged "$1"; then pass=$((pass + 1)); else echo "FAIL: $1 NOT flagged ($2)"; fi
}

# Positive control: the run itself produced findings (a scan that failed or
# saw an empty tree would make every expect_clean vacuous).
total=$((total + 1))
if grep -q '"findings":\[{' "$OUTJ"; then pass=$((pass + 1)); else echo "FAIL: scan produced no findings at all (vacuous run); stderr: $(cat "$WORK/err.txt")"; fi

expect_clean   fp_env_prefix.sh      "env NAME=val command prefix"
expect_clean   fp_walk_token.sh      "alphabet-order placeholder token"
expect_flagged tp_bare_env.sh        "bare env dump"
expect_flagged tp_printenv.sh        "printenv dump"
expect_flagged tp_export_p.sh        "export -p dump"
expect_flagged tp_env_assign_only.sh "env A=1 with no command"
expect_flagged tp_random_token.sh    "random-looking ghp_ token"

echo "secret_scan_false_positives: ${pass}/${total} PASS"
[ "$pass" -eq "$total" ]
