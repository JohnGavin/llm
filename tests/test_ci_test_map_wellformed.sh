#!/usr/bin/env bash
# test_ci_test_map_wellformed.sh
#
# Guards tests/ci_test_map.tsv, which .github/workflows/shell-tests.yml parses
# with `IFS=$'\t' read -r test globs status reason`, skipping empty lines,
# lines starting with '#', and the header row whose first field is `test`.
# The map header documents: "Columns (tab-separated): test, globs, status,
# reason" (reason only required when status=skip-ci).
#
# /.gitattributes sets `merge=union` on the map so parallel PRs that each
# append a row merge without conflict markers. Union has one failure mode:
# two branches editing the SAME row differently keep BOTH versions. Check (c)
# below (no duplicate test key) catches that.
#
# Checks on the map:
#   (a) no conflict markers
#   (b) every data row has 3+ TAB-separated fields
#   (c) no duplicate test key (field 1)
#   (d) every test path in field 1 exists in the repo
# Plus: the union merge driver is proven in a throwaway git repo.
#
# CI_TEST_MAP=<path> points the checks at another map (used for falsification
# below). Default: the real map. Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAP="${CI_TEST_MAP:-${REPO_ROOT}/tests/ci_test_map.tsv}"
TAB="$(printf '\t')"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# check_map <file>: prints one line per defect to stdout, returns number of
# defects (capped at 255 by the shell, only compared with 0).
check_map() {
  local f="$1" n=0 line
  if [ ! -s "$f" ]; then
    echo "map missing or empty: $f"
    return 1
  fi
  # (a) conflict markers
  if grep -nE '^(<<<<<<<|=======$|>>>>>>>)' "$f" >/dev/null 2>&1; then
    echo "(a) conflict marker present: $(grep -nE '^(<<<<<<<|=======$|>>>>>>>)' "$f" | head -1)"
    n=$((n + 1))
  fi
  # (b) 3+ TAB-separated fields on every data row
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    case "$line" in
      *"${TAB}"*"${TAB}"*) ;;
      *) echo "(b) row has fewer than 3 TAB-separated fields: ${line}"; n=$((n + 1)) ;;
    esac
  done < "$f"
  # (c) duplicate keys (header row `test` and comments/empties excluded)
  local dups
  dups="$(awk -F'\t' '!/^#/ && NF > 0 && $1 != "" && $1 != "test" { print $1 }' "$f" | sort | uniq -d)"
  if [ -n "$dups" ]; then
    echo "(c) duplicate test key(s): $(echo "$dups" | tr '\n' ' ')"
    n=$((n + 1))
  fi
  # (d) every test path exists
  local key
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if [ ! -e "${REPO_ROOT}/${key}" ]; then
      echo "(d) test path does not exist: ${key}"
      n=$((n + 1))
    fi
  done < <(awk -F'\t' '!/^#/ && NF > 0 && $1 != "" && $1 != "test" { print $1 }' "$f")
  return "$n"
}

echo "== Checks on the map: ${MAP}"
out="$(check_map "$MAP")"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "map is well-formed (a)-(d)"
else
  bad "map has defects:"
  echo "$out" | sed 's/^/    /'
fi

# Only run the self-checks / union proof when testing the real map; with an
# overridden map the caller is doing its own falsification.
if [ -n "${CI_TEST_MAP:-}" ]; then
  echo "Summary: ${PASS} passed, ${FAIL} failed (CI_TEST_MAP override; self-checks skipped)"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# ---- Positive controls: each defect must turn the checker red --------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci_map_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

expect_red() { # name, pattern-in-output, file
  local o r
  o="$(check_map "$3")"; r=$?
  if [ "$r" -ne 0 ] && echo "$o" | grep -q -- "$2"; then
    ok "falsification: $1 detected"
  else
    bad "falsification: $1 NOT detected (rc=${r}, out=${o})"
  fi
}

echo "== Falsification of each check"
cp "$MAP" "$TMP/m_marker.tsv"
printf '<<<<<<< HEAD\n' >> "$TMP/m_marker.tsv"
expect_red "conflict marker" "(a)" "$TMP/m_marker.tsv"

cp "$MAP" "$TMP/m_space.tsv"
printf 'tests/test_ci_test_map_wellformed.sh tests/x.sh run\n' >> "$TMP/m_space.tsv"
expect_red "space-separated row" "(b)" "$TMP/m_space.tsv"

cp "$MAP" "$TMP/m_dup.tsv"
printf 'tests/test_ci_test_map_wellformed.sh\ttests/other.sh\trun\n' >> "$TMP/m_dup.tsv"
expect_red "duplicate key" "(c)" "$TMP/m_dup.tsv"

cp "$MAP" "$TMP/m_missing.tsv"
printf 'tests/test_does_not_exist_zzz.sh\ttests/test_does_not_exist_zzz.sh\trun\n' >> "$TMP/m_missing.tsv"
expect_red "non-existent test path" "(d)" "$TMP/m_missing.tsv"

# ---- Union merge driver proven in a throwaway repo -------------------------
echo "== Union merge driver (throwaway repo)"

# Run git isolated from global/system config and hooks (the global hooks path
# runs a commit gate that must not fire in scratch repos).
sgit() { # dir, args...
  local d="$1"; shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$d" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com \
        -c commit.gpgsign=false "$@"
}

# union_scenario <dir> <with_attr:1|0> -> sets MERGE_RC; leaves repo merged/conflicted
union_scenario() {
  local d="$1" with_attr="$2"
  mkdir -p "$d/tests"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git init -q "$d" >/dev/null 2>&1
  sgit "$d" checkout -q -b base >/dev/null 2>&1
  if [ "$with_attr" = "1" ]; then
    cp "${REPO_ROOT}/.gitattributes" "$d/.gitattributes"
  fi
  printf 'test\tglobs\tstatus\treason\nt/a.sh\tt/a.sh\trun\n' > "$d/tests/ci_test_map.tsv"
  sgit "$d" add -A >/dev/null 2>&1
  sgit "$d" commit -q -m base --no-verify >/dev/null 2>&1
  sgit "$d" checkout -q -b b1 >/dev/null 2>&1
  printf 't/b1.sh\tt/b1.sh\trun\n' >> "$d/tests/ci_test_map.tsv"
  sgit "$d" commit -q -am b1 --no-verify >/dev/null 2>&1
  sgit "$d" checkout -q base >/dev/null 2>&1
  sgit "$d" checkout -q -b b2 >/dev/null 2>&1
  printf 't/b2.sh\tt/b2.sh\trun\n' >> "$d/tests/ci_test_map.tsv"
  sgit "$d" commit -q -am b2 --no-verify >/dev/null 2>&1
  sgit "$d" merge -q --no-edit b1 >/dev/null 2>&1
  MERGE_RC=$?
}

union_scenario "$TMP/with_attr" 1
M="$TMP/with_attr/tests/ci_test_map.tsv"
if [ "$MERGE_RC" -eq 0 ] && grep -q '^t/b1.sh' "$M" && grep -q '^t/b2.sh' "$M" \
   && ! grep -qE '^(<<<<<<<|=======$|>>>>>>>)' "$M"; then
  ok "union driver: clean merge, both appended rows kept, no markers"
else
  bad "union driver: merge rc=${MERGE_RC}; map: $(tr '\n' '|' < "$M")"
fi

union_scenario "$TMP/no_attr" 0
M2="$TMP/no_attr/tests/ci_test_map.tsv"
if [ "$MERGE_RC" -ne 0 ] && grep -qE '^<<<<<<<' "$M2"; then
  ok "falsification: without the attribute the same merge conflicts"
else
  bad "falsification: no-attribute merge did not conflict (rc=${MERGE_RC})"
fi

# The attribute must be live on the real repo path too.
attr="$(git -C "$REPO_ROOT" check-attr merge -- tests/ci_test_map.tsv 2>/dev/null)"
case "$attr" in
  *"merge: union") ok "real repo: check-attr reports merge=union" ;;
  *) bad "real repo: check-attr says '${attr}'" ;;
esac

echo "Summary: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
