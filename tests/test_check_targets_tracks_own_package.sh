#!/usr/bin/env bash
# tests/test_check_targets_tracks_own_package.sh — runs the checker's built-in
# --selftest (JohnGavin/llm#1295) and asserts the falsifier fixture is really
# caught: a load_all()-without-imports pipeline MUST exit 1, not 0.
#
# Needs Rscript on PATH (the checker parses _targets.R with R).
# Usage: bash tests/test_check_targets_tracks_own_package.sh
# Exit 0 pass, 1 fail, 3 indeterminate (no Rscript).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHK="$REPO_ROOT/.claude/scripts/check_targets_tracks_own_package.sh"

if ! command -v Rscript >/dev/null 2>&1; then
  echo "INDETERMINATE: Rscript not on PATH"
  exit 3
fi

fail=0
out="$(bash "$CHK" --selftest 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: --selftest rc=$rc"; fail=1; }

# Independent falsifier: build a fixture here, outside the script's own selftest.
tmp="$(mktemp -d)"
printf 'Package: zzpkg\n' > "$tmp/DESCRIPTION"
printf 'library(targets)\npkgload::load_all()\nlist()\n' > "$tmp/_targets.R"
bash "$CHK" "$tmp" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: falsifier expected rc=1, got $rc"; fail=1; }
printf 'library(targets)\npkgload::load_all()\ntar_option_set(imports = "zzpkg")\nlist()\n' > "$tmp/_targets.R"
bash "$CHK" "$tmp" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: tracked fixture expected rc=0, got $rc"; fail=1; }
rm -rf "$tmp"

[ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"
