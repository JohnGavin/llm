#!/usr/bin/env bash
# phi_scan.sh: output redaction, bash 3.2 safety, exit-code contract.
#
# SYNTHETIC fixtures only (obviously fake sentinel values). The scanner under
# test can be swapped with PHI_SCAN_SCRIPT, which is how the falsification
# runs point this test at the OLD behaviour and confirm red.
# Bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SCAN="${PHI_SCAN_SCRIPT:-$ROOT/.claude/scripts/phi_scan.sh}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/phi_scan_test.XXXXXX")"
trap 'chmod -R u+rw "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
# Keep git from discovering a parent repo above the scratch dir.
export GIT_CEILING_DIRECTORIES="$(dirname "$WORK")"

pass=0; total=0
check() { # check DESC RESULT(0=true)
    total=$((total + 1))
    if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else echo "FAIL: $1"; fi
}

# Unique sentinels: nothing else in the output can contain 6+ char substrings
NHS="731 582 9046"
EMAIL="qzjxk.unique7@sentinelmail.invalid"
TOKEN="Xq7Zk2Pw9Vb4Nm8Rt"

BAD="$WORK/bad.txt"
printf 'Patient record %s\ncontact %s\nkey %s\n' "$NHS" "$EMAIL" "$TOKEN" > "$BAD"
CLEAN="$WORK/clean.txt"
printf 'nothing sensitive here\njust prose\n' > "$CLEAN"

# (a) findings reported AND no sentinel / 6+ char substring in stdout+stderr
OUT="$(/bin/bash "$SCAN" "$BAD" 2>&1)"; rc=$?
check "(a) findings exit 1 (got $rc)" "$([ "$rc" -eq 1 ]; echo $?)"
check "(a) NHS finding reported by rule" "$(printf '%s' "$OUT" | grep -q 'NHS Number'; echo $?)"
check "(a) Email finding reported by rule" "$(printf '%s' "$OUT" | grep -q 'Email'; echo $?)"
check "(a) entropy finding reported" "$(printf '%s' "$OUT" | grep -q 'High-entropy'; echo $?)"
check "(a) file:line present" "$(printf '%s' "$OUT" | grep -q 'bad.txt:1'; echo $?)"
leak=0
for v in "$NHS" "$EMAIL" "$TOKEN"; do
    n=${#v}; i=0
    while [ $((i + 6)) -le "$n" ]; do
        sub="${v:$i:6}"
        if printf '%s' "$OUT" | grep -qF -e "$sub"; then leak=1; echo "  leaked substring: [redacted-in-test-log len=6 value-index=$i]"; fi
        i=$((i + 1))
    done
done
check "(a) output contains no 6+ char substring of any fixture value" "$leak"

# (b) clean file => 0
OUT="$(/bin/bash "$SCAN" "$CLEAN" 2>&1)"; rc=$?
check "(b) clean file exit 0 (got $rc)" "$([ "$rc" -eq 0 ]; echo $?)"

# (c) no args, nothing staged, inside a git repo => 0 under /bin/bash (no mapfile)
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
OUT="$(cd "$REPO" && /bin/bash "$SCAN" 2>&1)"; rc=$?
check "(c) nothing staged exit 0 (got $rc)" "$([ "$rc" -eq 0 ]; echo $?)"
check "(c) no mapfile error" "$(printf '%s' "$OUT" | grep -q 'mapfile'; [ $? -ne 0 ]; echo $?)"

# (c2) staged file with a finding is found and redacted
printf 'Patient %s\n' "$NHS" > "$REPO/staged.txt"
git -C "$REPO" add staged.txt 2>/dev/null
OUT="$(cd "$REPO" && /bin/bash "$SCAN" 2>&1)"; rc=$?
check "(c2) staged finding exit 1 (got $rc)" "$([ "$rc" -eq 1 ]; echo $?)"
check "(c2) staged output redacted" "$(printf '%s' "$OUT" | grep -qF -e '731 582'; [ $? -ne 0 ]; echo $?)"

# (d) indeterminate: non-git dir with no args; unreadable file; missing file
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"
OUT="$(cd "$PLAIN" && /bin/bash "$SCAN" 2>&1)"; rc=$?
check "(d) non-git dir, no args => 3 (got $rc)" "$([ "$rc" -eq 3 ]; echo $?)"

UNR="$WORK/unreadable.txt"; echo "x" > "$UNR"; chmod 000 "$UNR"
if [ -r "$UNR" ]; then
    echo "SKIP: (d) unreadable-file case (running as a user that can read mode 000)"
else
    OUT="$(/bin/bash "$SCAN" "$UNR" 2>&1)"; rc=$?
    check "(d) unreadable file => 3 (got $rc)" "$([ "$rc" -eq 3 ]; echo $?)"
    OUT="$(/bin/bash "$SCAN" "$CLEAN" "$UNR" 2>&1)"; rc=$?
    check "(d) clean + unreadable => 3, not 0 (got $rc)" "$([ "$rc" -eq 3 ]; echo $?)"
fi
OUT="$(/bin/bash "$SCAN" "$WORK/does-not-exist.txt" 2>&1)"; rc=$?
check "(d) missing file => 3 (got $rc)" "$([ "$rc" -eq 3 ]; echo $?)"
OUT="$(/bin/bash "$SCAN" "$BAD" "$WORK/does-not-exist.txt" 2>&1)"; rc=$?
check "(d) finding + missing file => 1 (finding wins; got $rc)" "$([ "$rc" -eq 1 ]; echo $?)"

# (e) bad flag => 2
OUT="$(/bin/bash "$SCAN" --no-such-flag "$CLEAN" 2>&1)"; rc=$?
check "(e) bad flag => 2 (got $rc)" "$([ "$rc" -eq 2 ]; echo $?)"

# (f) a file with no 13+ char token must not abort the scan (pipefail guard)
OUT="$(/bin/bash "$SCAN" "$CLEAN" 2>&1)"; rc=$?
check "(f) no-long-token file reaches the summary" "$(printf '%s' "$OUT" | grep -q 'clean (0 findings)'; echo $?)"

echo "test_phi_scan.sh: $pass/$total passed"
[ "$pass" -eq "$total" ]
