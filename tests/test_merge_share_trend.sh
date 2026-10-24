#!/usr/bin/env bash
# tests/test_merge_share_trend.sh -- week-over-week trend in merge_history_check.sh --daily.
# Throwaway temp DBs only (never the real unified.duckdb); synthetic repo names.
# Exit: 0 all pass, 1 a check failed, 3 INDETERMINATE (duckdb missing).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/.claude/scripts/merge_history_check.sh"
SCHEMA="$ROOT/.claude/scripts/housekeeping_schema_init.sql"
REAL_TGT="$ROOT/.claude/state/merge_share_target.tsv"

if ! command -v duckdb >/dev/null 2>&1; then
  echo "INDETERMINATE: duckdb is needed; merge share trend NOT exercised"
  exit 3
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/merge_share_trend_test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
has() { if grep -qF -- "$2" "$1"; then ok; else bad "$3 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then bad "$3 (unexpected: $2)"; else ok; fi; }

export MERGE_SHARE_TARGET_FILE="$REAL_TGT"
export MERGE_HISTORY_LOCK_SLEEP=1

# mkdb FILE CUR_OWNER CUR_AUTO PREV_OWNER PREV_AUTO : rows spread over the two windows.
n=0
mkdb() {
  local db="$1" co="$2" ca="$3" po="$4" pa="$5" i
  rm -f "$db"; duckdb -init /dev/null "$db" < "$SCHEMA" >/dev/null 2>&1
  ins() {  # path count first_offset
    for ((i = 0; i < $2; i++)); do
      n=$((n + 1))
      duckdb -init /dev/null "$db" -c "INSERT INTO merge_events (repo, pr_number, merged_at, merge_path, approval, class, source, recorded_at)
        VALUES ('owner/repo-a', $n, current_timestamp - INTERVAL ($(( $3 + i % 6 ))) DAY, '$1', 'none', 'auto-unlisted', 'sync', current_timestamp);" >/dev/null 2>&1
    done
  }
  ins owner-verb "$co" 1; ins sweep "$ca" 1
  ins owner-verb "$po" 8; ins sweep "$pa" 8
}

run() { bash "$CHECK" --db "$1" --daily > "$2" 2>&1; echo $? > "$2.rc"; }

# (a) improving: owner 8 -> 4, automatic 2 -> 6
mkdb "$W/a.db" 4 6 8 2
run "$W/a.db" "$W/a.out"
has "$W/a.out" "owner-approved improving | automatic improving" "(a) improving direction"
has "$W/a.out" "owner-approved 4 vs 8 (-4) | automatic 6 vs 2 (+4)" "(a) signed deltas"
hasnt "$W/a.out" "below target by" "(a) share 60% meets the target"
has "$W/a.out" "at or above target" "(a) at/above target"
has "$W/a.out" "reverts: not tracked" "(a) reverts not tracked"
has "$W/a.out" "fewer owner decisions at constant safety" "(a) header aim"

# (b) worse: swapped windows -> direction flips (FALSIFICATION of (a))
mkdb "$W/b.db" 8 2 4 6
run "$W/b.db" "$W/b.out"
has "$W/b.out" "owner-approved worse | automatic worse" "(b) worse direction (falsifies (a))"
hasnt "$W/b.out" "improving" "(b) no 'improving' anywhere once windows are swapped"
has "$W/b.out" "below target by" "(b) 20% share is below target"

# (c) fewer than 5 merges in a window
mkdb "$W/c.db" 1 1 8 2
run "$W/c.db" "$W/c.out"
has "$W/c.out" "owner-approved INSUFFICIENT-DATA | automatic INSUFFICIENT-DATA" "(c) insufficient data"
hasnt "$W/c.out" "improving" "(c) never 'improving' on thin data"

# (d) missing target file, and an unparseable one -> exit 3
MERGE_SHARE_TARGET_FILE="$W/nope.tsv" bash "$CHECK" --db "$W/a.db" --daily > "$W/d.out" 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then ok; else bad "(d) missing target file exit $rc, want 3"; fi
printf 'key\tvalue\tnote\ntarget_auto_share_pct\tabc\tx\ntolerance_pct\t5\tx\n' > "$W/bad.tsv"
MERGE_SHARE_TARGET_FILE="$W/bad.tsv" bash "$CHECK" --db "$W/a.db" --daily > "$W/d2.out" 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then ok; else bad "(d) unparseable target exit $rc, want 3"; fi

# (e) repo with owner rows and no sweep rows; a repo with a sweep row is not listed
duckdb -init /dev/null "$W/a.db" -c "INSERT INTO merge_events (repo, pr_number, merged_at, merge_path, approval, class, source, recorded_at)
  VALUES ('owner/repo-z', 9001, current_timestamp - INTERVAL (2) DAY, 'owner-verb', 'none', 'auto-unlisted', 'sync', current_timestamp);" >/dev/null 2>&1
run "$W/a.db" "$W/e.out"
has "$W/e.out" "no sweep covers this repo" "(e) line present"
has "$W/e.out" "owner/repo-z" "(e) names the uncovered repo"
if grep "no sweep covers" "$W/e.out" | grep -qF "owner/repo-a"; then bad "(e) repo-a has sweep rows, must not be listed"; else ok; fi
hasnt "$W/a.out" "no sweep covers this repo" "(e) absent when every repo has a sweep row"

# exit 0 on the normal runs
for f in a b c; do
  if [ "$(cat "$W/$f.out.rc")" = "0" ]; then ok; else bad "($f) exit code $(cat "$W/$f.out.rc"), want 0"; fi
done

# target is one home: no literal copy of the placeholder value in the script
TGTVAL="$(awk -F'\t' '$1=="target_auto_share_pct"{print $2}' "$REAL_TGT")"
if [ -n "$TGTVAL" ] && grep -nw -- "$TGTVAL" "$CHECK" | grep -v '^[0-9]*:#' | grep -q .; then bad "target value $TGTVAL appears as a literal in merge_history_check.sh"; else ok; fi
if [ -n "$TGTVAL" ]; then ok; else bad "real target file has no target_auto_share_pct"; fi

echo "merge_share_trend: pass=$PASS fail=$FAIL"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
