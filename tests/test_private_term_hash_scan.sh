#!/usr/bin/env bash
# test_private_term_hash_scan.sh -- llm#1389 (privacy layer L3).
# Exercises private_terms_hashes.sh (owner helper) and private_term_hash_scan.sh
# (CI scanner) with a SYNTHETIC term list only; no real private term is used.
# bash 3.2 compatible. Exit 0 all pass, 1 any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/.claude/scripts/private_terms_hashes.sh"
SCANNER="$REPO_ROOT/.claude/scripts/private_term_hash_scan.sh"
L1LIB="$REPO_ROOT/.claude/hooks/lib/private_terms.sh"

CANARY="zzcanary""privterm7q"
T1="qqfaketermone"
T2="qqfake two"
T3="Qq_Under Score"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pth_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() {
  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "ok   - $1"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $1 (expected '$2', got '$3')"
  fi
}

# ---- synthetic term list --------------------------------------------------
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TERMS="$TMP/terms.txt"
{
  echo "# private_terms v1 generated=$NOW count=4"
  echo "$CANARY"
  echo "$T1"
  echo "$T2"
  echo "$T3"
} > "$TERMS"
export PRIVATE_TERMS_FILE="$TERMS"

# ---- helper: generate payloads -------------------------------------------
OUT_A="$TMP/out_a"
OUT_B="$TMP/out_b"
bash "$HELPER" --out-dir "$OUT_A" --repo example/repo > "$TMP/helper_a.out" 2>&1
check "helper exits 0" 0 $?
bash "$HELPER" --out-dir "$OUT_B" > "$TMP/helper_b.out" 2>&1
check "helper second run exits 0" 0 $?

check "salt.txt is mode 600" 600 "$(stat -c %a "$OUT_A/salt.txt" 2>/dev/null || stat -f %Lp "$OUT_A/salt.txt")"
check "hashes.txt is mode 600" 600 "$(stat -c %a "$OUT_A/hashes.txt" 2>/dev/null || stat -f %Lp "$OUT_A/hashes.txt")"
check "payload first line carries maxtokens=3" "maxtokens=3" "$(head -n 1 "$OUT_A/hashes.txt")"
check "payload has one digest per term (4)" 4 "$(tail -n +2 "$OUT_A/hashes.txt" | grep -c -E '^[0-9a-f]{64}$')"
check "helper prints the two gh secret set commands" 2 "$(grep -c '^  gh secret set ' "$TMP/helper_a.out")"
check "salts differ between runs" 1 "$(cmp -s "$OUT_A/salt.txt" "$OUT_B/salt.txt" && echo 0 || echo 1)"
check "digests differ between runs" 1 "$(cmp -s "$OUT_A/hashes.txt" "$OUT_B/hashes.txt" && echo 0 || echo 1)"
LEAK=0
for t in "$CANARY" "$T1" "qqfake" "under"; do
  if grep -q -i -F -- "$t" "$TMP/helper_a.out" "$OUT_A/hashes.txt" "$OUT_A/salt.txt"; then LEAK=1; fi
done
check "helper output and payload contain no term text" 0 "$LEAK"

bash "$HELPER" > /dev/null 2>&1
check "helper without --out-dir is usage (2)" 2 $?
PRIVATE_TERMS_FILE="$TMP/does_not_exist" bash "$HELPER" --out-dir "$TMP/out_c" > /dev/null 2>&1
check "helper with no term list is INDETERMINATE (3)" 3 $?

SALT_A="$(cat "$OUT_A/salt.txt")"
HASHES_A="$(cat "$OUT_A/hashes.txt")"
SALT_B="$(cat "$OUT_B/salt.txt")"
HASHES_B="$(cat "$OUT_B/hashes.txt")"

# ---- temp git repo --------------------------------------------------------
R="$TMP/repo"
mkdir -p "$R"
git -C "$R" init -q
GC="git -C $R -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false"
printf 'hello\n' > "$R/a.txt"
git -C "$R" add a.txt
$GC commit -q -m base

BASE=""
HEAD=""
begin() { BASE="$(git -C "$R" rev-parse HEAD)"; }
finish() {
  git -C "$R" add -A
  $GC commit -q -m change
  HEAD="$(git -C "$R" rev-parse HEAD)"
}

# scan <label> : runs the scanner with the A payloads; result in RC / OUTF
RC=0
OUTF="$TMP/scan.out"
scan() {
  PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="$HASHES_A" \
    bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
  RC=$?
}

# 1. canary token added -> finding
begin
printf 'note %s here\n' "$CANARY" >> "$R/a.txt"
finish
scan
check "canary token added => exit 1" 1 "$RC"
check "finding names the rule" 1 "$(grep -c 'rule=private-term-hash' "$OUTF")"
check "finding reports file:line (a.txt:2)" 1 "$(grep -c 'a.txt:2' "$OUTF")"
check "output never contains the canary" 0 "$(grep -c -i -F -- "$CANARY" "$OUTF")"

# 2. same diff without the token -> clean
begin
printf 'an ordinary sentence\n' >> "$R/a.txt"
finish
scan
check "clean diff => exit 0" 0 "$RC"

# 3. glued to letters/digits -> not a match
begin
printf 'x%sx\n%s2\nprefix%s\n' "$T1" "$T1" "$CANARY" >> "$R/a.txt"
finish
scan
check "term glued to letters/digits => exit 0" 0 "$RC"

# 4. separators that L1 also treats as boundaries
begin
printf 'a-%s-b\n' "$T1" >> "$R/a.txt"
finish
scan
check "hyphen-separated term => exit 1" 1 "$RC"

begin
printf 'UPPER %s\n' "$(printf '%s' "$T1" | tr '[:lower:]' '[:upper:]')" >> "$R/a.txt"
finish
scan
check "case-insensitive term => exit 1" 1 "$RC"

# 5. multi-token terms
begin
printf 'see QQFAKE-Two here\n' >> "$R/a.txt"
finish
scan
check "two-token term found => exit 1" 1 "$RC"
check "multi-token finding does not echo the text" 0 "$(grep -c -i -F -e qqfake -e 'two here' "$OUTF")"

begin
printf 'a qq under score b\n' >> "$R/a.txt"
finish
scan
check "three-token term (underscore in list) found => exit 1" 1 "$RC"

begin
printf 'qqfake\ntwo\n' >> "$R/a.txt"
finish
scan
check "tokens of a multi-token term on separate lines => exit 0" 0 "$RC"

# 6. only ADDED lines count
begin
printf 'keep\n%s\n' "$T1" > "$R/b.txt"
finish
begin
printf 'keep\n' > "$R/b.txt"
finish
scan
check "term only on a REMOVED line => exit 0" 0 "$RC"

# 7. an added line that starts with '++ ' is content, not a diff header
begin
printf '++ %s\n' "$T1" >> "$R/a.txt"
finish
scan
check "added line starting with '++ ' is scanned => exit 1" 1 "$RC"

# 8. a term in a brand-new file reports that file
begin
mkdir -p "$R/sub dir"
printf 'l1\nl2 %s\n' "$T1" > "$R/sub dir/new.txt"
finish
scan
check "new file with a space in its path reported" 1 "$(grep -c 'sub dir/new.txt:2' "$OUTF")"

# 9. INDETERMINATE paths
begin
printf 'clean\n' >> "$R/a.txt"
finish
PRIVATE_TERMS_SALT="" PRIVATE_TERM_HASHES="$HASHES_A" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "missing salt => exit 3" 3 $?
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "missing hashes => exit 3" 3 $?
env -u PRIVATE_TERMS_SALT -u PRIVATE_TERM_HASHES bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "both secrets unset => exit 3" 3 $?
PRIVATE_TERMS_SALT="" PRIVATE_TERM_HASHES="" PR_FROM_FORK=true bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "fork PR without secrets => exit 3" 3 $?
check "fork message says forks" 1 "$(grep -c -i 'forks' "$OUTF")"

NO_CANARY="$(printf '%s\n' "$HASHES_A" | grep -v -x "$(printf '%s' "$CANARY" | openssl dgst -sha256 -hmac "$SALT_A" | awk '{print $NF}')")"
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="$NO_CANARY" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "payload lacking the canary digest => exit 3" 3 $?
check "canary-less control really lost a line" "$(printf '%s\n' "$HASHES_A" | wc -l | tr -d ' ')" "$(( $(printf '%s\n' "$NO_CANARY" | wc -l | tr -d ' ') + 1 ))"

PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="maxtokens=3" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "payload with no digests => exit 3" 3 $?
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="$(printf '%s\n' "$HASHES_A" | tail -n +2)" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "payload without maxtokens line => exit 3" 3 $?
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="$HASHES_A" bash "$SCANNER" --base "deadbeef" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "unresolvable base => exit 3" 3 $?
bash "$SCANNER" --base "$BASE" > /dev/null 2>&1
check "missing --head is usage (2)" 2 $?

# 10. wrong salt: hashes made with salt B never match under salt A, and the
#     canary check turns that mismatch into INDETERMINATE rather than a pass.
begin
printf 'note %s again\n' "$CANARY" >> "$R/a.txt"
finish
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="$HASHES_B" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "digests from another salt => exit 3 (never a silent pass)" 3 $?
PRIVATE_TERMS_SALT="$SALT_B" PRIVATE_TERM_HASHES="$HASHES_B" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "matching salt B payload still finds the canary => exit 1" 1 $?

# 11. PARITY with the L1 matcher over the same fixture lines
begin
FIX="$TMP/fixture.txt"
cat > "$FIX" <<EOF
see $T1 here
$(printf '%s' "$T1" | tr '[:lower:]' '[:upper:]')
x$T1
${T1}x
${T1}2
a-${T1}-b
a_${T1}_b
$T2
QQFAKE_two
qqfake
nothing at all
qq under score
prefix.$T2.
- $T1
$CANARY
EOF
cp "$FIX" "$R/parity.txt"
finish
scan
check "parity fixture scan finds something => exit 1" 1 "$RC"
L1_LINES="$(
  . "$L1LIB"
  pt_prepare || exit 9
  pt_match < "$FIX" | sort -n | tr '\n' ' '
)"
SC_LINES="$(grep -o 'parity.txt:[0-9]*' "$OUTF" | cut -d: -f2 | sort -n | tr '\n' ' ')"
check "hash scanner flags the same lines as the L1 matcher" "$L1_LINES" "$SC_LINES"
check "parity is not vacuous (L1 flagged 10 lines)" 10 "$(printf '%s' "$L1_LINES" | wc -w | tr -d ' ')"

# 12. FALSIFICATION CONTROLS: break the machinery on purpose and require red.
MUT="$TMP/mut"
mkdir -p "$MUT/lib"
cp "$L1LIB" "$MUT/l1.sh"
cp "$REPO_ROOT/.claude/scripts/lib/private_term_hash_lib.sh" "$MUT/lib/private_term_hash_lib.sh"

begin
printf 'note %s third\n' "$CANARY" >> "$R/a.txt"
finish

# (a) emptied hash list: only the header remains
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="maxtokens=3" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "FALSIFY emptied hash list: canary diff is NOT a pass (3)" 3 $?

# (b) broken tokeniser: the n-gram emitter prints a constant
sed 's/print key "\\t" g/print key "\\t" "x"/' "$REPO_ROOT/.claude/scripts/lib/private_term_hash_lib.sh" > "$MUT/lib/private_term_hash_lib.sh"
cp "$SCANNER" "$MUT/scan_a.sh"
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="$HASHES_A" bash "$MUT/scan_a.sh" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "FALSIFY broken tokeniser: liveness probe turns it INDETERMINATE (3)" 3 $?

# (c) broken tokeniser AND liveness probe removed: the canary add goes unseen,
#     which is exactly what the real assertion (exit 1) would catch
sed 's/grep -q -x -F -- "\$PTH_CANARY" "\$WORK\/probe"/true/' "$SCANNER" > "$MUT/scan_b.sh"
PRIVATE_TERMS_SALT="$SALT_A" PRIVATE_TERM_HASHES="$HASHES_A" bash "$MUT/scan_b.sh" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "FALSIFY blind detector: canary add yields 0 instead of 1 (assertion would go red)" 0 $?
check "FALSIFY control sed really changed the scanner" 1 "$(cmp -s "$SCANNER" "$MUT/scan_b.sh" && echo 0 || echo 1)"

# (d) dropped salt: a different salt cannot reproduce the digests
PRIVATE_TERMS_SALT="not-the-salt" PRIVATE_TERM_HASHES="$HASHES_A" bash "$SCANNER" --base "$BASE" --head "$HEAD" --repo-dir "$R" > "$OUTF" 2>&1
check "FALSIFY wrong salt: canary diff is NOT a pass (3)" 3 $?

# (e) restore: the real scanner on the same diff is red for the right reason
scan
check "restored: canary diff => exit 1" 1 "$RC"

echo
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
exit 0
