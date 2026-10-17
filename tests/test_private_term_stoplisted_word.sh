#!/usr/bin/env bash
# test_private_term_stoplisted_word.sh -- the L1 write guard must let an
# ordinary workflow key ("jobs:") into a public repo when the term list does not
# carry that word (private_terms_sync.sh stoplists it). Synthetic data only:
# temp term list, scratch repo, stub visibility; the real term list is never read.
# Falsification: the same Write against a list that DOES carry the word must block.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/.claude/hooks/private_term_write_guard.sh"
CANARY="zzcanary""privterm7q"
WORD="jobs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ptsw_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
unset PRIVATE_TERMS_MAX_AGE_DAYS

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
expect_rc() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (exit $3, want $2)"; fi; }

mkterms() { # FILE TERM...
  local f="$1"; shift
  { printf '# private_terms v1 generated=%s count=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$#"
    local t; for t in "$@"; do printf '%s\n' "$t"; done
  } > "$f"
}

printf '#!/usr/bin/env bash\necho public\n' > "$WORK/vis.sh"
chmod +x "$WORK/vis.sh"
mkdir -p "$WORK/pubrepo"
git -C "$WORK/pubrepo" init -q 2>/dev/null

WITHOUT="$WORK/terms_without.txt"
WITH="$WORK/terms_with.txt"
mkterms "$WITHOUT" "$CANARY" "fakeprojx"
mkterms "$WITH" "$CANARY" "fakeprojx" "$WORD"

WF=$'name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n'
payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$WORK/pubrepo/.github/workflows/ci.yml" "$WF")

run_guard() { # TERMS-FILE -> rc
  printf '%s' "$payload" \
    | env PRIVATE_TERMS_FILE="$1" PTWG_VISIBILITY_CMD="$WORK/vis.sh" bash "$HOOK" --check >/dev/null 2>&1
  echo $?
}

echo "private_term stoplisted-word tests:"
expect_rc "t1: workflow with a jobs: key passes when the list lacks the word" 0 "$(run_guard "$WITHOUT")"
expect_rc "t2 (falsify): the same Write blocks when the list carries the word" 1 "$(run_guard "$WITH")"

echo "  ---"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
