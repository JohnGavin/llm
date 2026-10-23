#!/usr/bin/env bash
# tests/test_one_home_ext_lists.sh -- drive .claude/scripts/one_home_ext_lists_check.sh
# (llm#1436, "one home per value" for the document / image / archive extension
# lists) and FALSIFY it: a lint that has never been seen red is not a check.
#
# Pure bash + git; runs on the CI runner. Exit 0 all pass, 1 any failure,
# 3 INDETERMINATE (git missing).
#
# Cases
#   1. real repo: the lint passes (positive control)
#   2. (b) real repo, empty allow-list: it FAILS on the rule-prose mentions
#   3. (a) fixture repo: real scanner + real guard + empty allow-list passes;
#      then a literal copy of each list is added to a third file, one at a time,
#      and the lint FAILS naming that file (DOC, IMAGE, ARCHIVE)
#   4. a partial list (one member missing) is not a copy
#   5. allow-list: an entry with a reason allows; no reason allows nothing; a
#      stale entry fails
#   6. INDETERMINATE (exit 3): home list emptied; scanner missing; not a git tree
# The behavioural half of falsification (c) -- removing a member from the scanner
# list changes what the import guard blocks -- is in the guard's own --selftest.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK="${REPO_ROOT}/.claude/scripts/one_home_ext_lists_check.sh"
SCANNER_REL=".claude/scripts/private_data_scan.sh"
GUARD_REL=".claude/hooks/public_repo_file_import_guard.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
# expect NAME WANT-RC [ARGS...]  (runs the lint, records output in $OUT)
OUT=""
expect() {
  local name="$1" want="$2" rc; shift 2
  OUT="$(bash "$CHECK" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then pass "$name (rc=$rc)"; else fail "$name (rc=$rc, want $want): $OUT"; fi
}
out_has() { case "$OUT" in *"$2"*) pass "$1" ;; *) fail "$1 -- output lacked '$2': $OUT" ;; esac; }

command -v git >/dev/null 2>&1 || { echo "INDETERMINATE: git not on PATH"; exit 3; }
[ -f "$CHECK" ] || { echo "FAIL: $CHECK missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── 1 + 2: the real repo ────────────────────────────────────────────────────
expect "real repo: each list has one home" 0 --root "$REPO_ROOT" --quiet
: > "$TMP/empty_allow.txt"
expect "(b) real repo, EMPTY allow-list: fails on the legitimate mentions" 1 --root "$REPO_ROOT" --allowlist "$TMP/empty_allow.txt" --quiet
out_has "(b) the failure names the rule prose" ".claude/rules/private-data-scanning.md"

# ── 3: fixture repo (real scanner + real guard only) ────────────────────────
FIX="$TMP/fix"
mkdir -p "$FIX/.claude/scripts" "$FIX/.claude/hooks" "$FIX/docs"
cp "$REPO_ROOT/$SCANNER_REL" "$FIX/$SCANNER_REL"
cp "$REPO_ROOT/$GUARD_REL" "$FIX/$GUARD_REL"
git -C "$FIX" init -q 2>/dev/null
git -C "$FIX" add -A >/dev/null 2>&1
expect "fixture (real scanner + guard, empty allow-list) passes" 0 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet

member_line() { # LIST -> the members of that list from its real home, space-separated
  case "$1" in
    DOC) grep -m1 '^DOC_FORMAT_EXTS=' "$REPO_ROOT/$SCANNER_REL" ;;
    IMAGE) grep -m1 '^IMAGE_EXTS=' "$REPO_ROOT/$SCANNER_REL" ;;
    ARCHIVE) grep -m1 '^ARCHIVE_EXTS=' "$REPO_ROOT/$GUARD_REL" ;;
  esac | sed 's/^[A-Z_]*="//; s/"$//; s/^ *//; s/ *$//'
}

for L in DOC IMAGE ARCHIVE; do
  M="$(member_line "$L")"
  if [ -z "${M// /}" ]; then fail "(a) $L: could not read the real list from its home"; continue; fi
  # Three spellings: space list, glob alternation, regex alternation.
  printf 'x = "%s"\n' "$M" > "$FIX/docs/copy.txt"
  git -C "$FIX" add -A >/dev/null 2>&1
  expect "(a) $L: a space-separated literal copy in another file FAILS" 1 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
  out_has "(a) $L: failure names the copy" "docs/copy.txt"
  GLOB="$(printf '%s' "$M" | sed 's/ /|*./g; s/^/*./')"
  printf 'case $f in %s) ;; esac\n' "$GLOB" > "$FIX/docs/copy.txt"
  git -C "$FIX" add -A >/dev/null 2>&1
  expect "(a) $L: a glob-pattern copy (the old fast-path style) FAILS" 1 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
  UPPER="$(printf '%s' "$M" | tr 'a-z' 'A-Z' | sed 's/ /|/g')"
  printf 'RE=(%s)\n' "$UPPER" > "$FIX/docs/copy.txt"
  git -C "$FIX" add -A >/dev/null 2>&1
  expect "(a) $L: an upper-case regex-alternation copy FAILS" 1 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
  # 4: one member missing is not a copy
  PART="${M#* }"
  printf 'x = "%s"\n' "$PART" > "$FIX/docs/copy.txt"
  git -C "$FIX" add -A >/dev/null 2>&1
  expect "$L: a list with its first member missing is not a copy" 0 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
  rm -f "$FIX/docs/copy.txt"
  git -C "$FIX" add -A >/dev/null 2>&1
  expect "$L: copy removed -> passes again" 0 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
done

# ── 5: allow-list semantics ─────────────────────────────────────────────────
DOCM="$(member_line DOC)"
printf 'x = "%s"\n' "$DOCM" > "$FIX/docs/copy.txt"
git -C "$FIX" add -A >/dev/null 2>&1
printf '%s\n' "docs/copy.txt | DOC | fixture prose that needs concrete extensions" > "$TMP/allow_ok.txt"
expect "allow-list entry with a reason allows the copy" 0 --root "$FIX" --allowlist "$TMP/allow_ok.txt" --quiet
printf '%s\n' "docs/copy.txt | DOC" "docs/copy.txt | DOC | " "docs/copy.txt || some reason" > "$TMP/allow_bad.txt"
expect "allow-list entries with no reason allow nothing" 1 --root "$FIX" --allowlist "$TMP/allow_bad.txt" --quiet
printf '%s\n' "docs/copy.txt | IMAGE | wrong list for this copy" > "$TMP/allow_wrong.txt"
expect "an entry for a different list allows nothing (and is stale)" 1 --root "$FIX" --allowlist "$TMP/allow_wrong.txt" --quiet
rm -f "$FIX/docs/copy.txt"
git -C "$FIX" add -A >/dev/null 2>&1
expect "stale allow-list entry (copy gone) FAILS" 1 --root "$FIX" --allowlist "$TMP/allow_ok.txt" --quiet
out_has "stale entry is reported as stale" "stale allow-list entry"

# ── 6: INDETERMINATE ────────────────────────────────────────────────────────
sed -i.bak 's/^DOC_FORMAT_EXTS=.*/DOC_FORMAT_EXTS=""/' "$FIX/$SCANNER_REL"; rm -f "$FIX/$SCANNER_REL.bak"
expect "home list emptied -> INDETERMINATE, not PASS" 3 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
cp "$REPO_ROOT/$SCANNER_REL" "$FIX/$SCANNER_REL"
expect "scanner restored -> passes again" 0 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
rm -f "$FIX/$SCANNER_REL"
expect "home file missing -> INDETERMINATE" 3 --root "$FIX" --allowlist "$TMP/empty_allow.txt" --quiet
mkdir -p "$TMP/notgit"
expect "not a git work tree -> INDETERMINATE" 3 --root "$TMP/notgit" --quiet
expect "unknown option -> usage (2)" 2 --bogus

echo "Summary: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
