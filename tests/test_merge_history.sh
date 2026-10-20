#!/usr/bin/env bash
# tests/test_merge_history.sh -- merge_events sync + detection (llm#1471).
#   .claude/scripts/merge_history_sync.sh   merged PRs -> merge_events (classified)
#   .claude/scripts/merge_history_check.sh  rules R1..R5 over merge_events
#   .claude/scripts/lib/merge_classify.sh   classification shared with the sweep
# `gh` is a stub on PATH, every DB is a throwaway temp file (never the real
# unified.duckdb), network-free. bash 3.2 / BSD+GNU portable.
#
# Exit codes: 0 all pass, 1 a check failed, 3 INDETERMINATE (duckdb or python3
# missing, so nothing can be exercised: reported, never a silent pass).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/.claude/scripts/merge_history_sync.sh"
CHECK="$ROOT/.claude/scripts/merge_history_check.sh"
SCHEMA="$ROOT/.claude/scripts/housekeeping_schema_init.sql"
REAL_EXCL="$ROOT/.claude/state/auto_merge_exclusions.txt"

if ! command -v duckdb >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "INDETERMINATE: duckdb and python3 are both needed; merge history NOT exercised"
  exit 3
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/merge_history_test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB="$W/stub"; BIN="$W/bin"; FAKE="$W/repo"
mkdir -p "$STUB" "$BIN" "$FAKE/.claude/state" "$FAKE/.claude/launchd" "$FAKE/bin/launchd-recorders"
cp "$REAL_EXCL" "$FAKE/.claude/state/auto_merge_exclusions.txt"
printf '<string>/x/.claude/scripts/zzz_nightly.sh</string>\n' > "$FAKE/.claude/launchd/com.t.plist"
printf '#!/bin/sh\nexec other_job.sh\n' > "$FAKE/bin/launchd-recorders/rec"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
d="$STUB_DIR"
echo "$*" >> "$d/calls.log"
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "O/R"; exit 0 ;;
  "pr list") if [ -f "$d/list.json" ]; then cat "$d/list.json"; exit 0; else exit 1; fi ;;
esac
if [ "$1" = "api" ]; then
  case "$2" in
    repos/O/R/pulls/*/files) p="${2%/files}"; n="${p##*/}"
             if [ -f "$d/flaky_$n" ] && [ ! -f "$d/flaky_seen_$n" ]; then : > "$d/flaky_seen_$n"; exit 1; fi
             if [ -f "$d/files_$n" ]; then cat "$d/files_$n"; exit 0; else exit 1; fi ;;
  esac
fi
exit 0
EOF
chmod +x "$BIN/gh"
export STUB_DIR="$STUB" PATH="$BIN:$PATH"
export AUTO_MERGE_REPO_DIR="$FAKE"
export MERGE_HISTORY_LOCK_SLEEP=1 MERGE_HISTORY_API_SLEEP=0
unset UNIFIED_DB_PATH

q() { duckdb -init /dev/null -csv -noheader "$1" -c "$2" 2>&1; }          # q DB SQL
newdb() { rm -f "$1"; duckdb -init /dev/null "$1" < "$SCHEMA" >/dev/null 2>&1; }

# ---- fixture: merged PR list ---------------------------------------------------
ROLL_OK='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
ROLL_BAD='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]'
ITEMS=""
# lpr N "labels" "body" "files(tab rows joined by @)" ROLLUP   (files "-" = files endpoint fails)
lpr() {
  local n="$1" labels="$2" body="$3" files="$4" roll="$5" lj="" l nf=0 row
  for l in $labels; do if [ -n "$lj" ]; then lj="$lj,"; fi; lj="$lj{\"name\":\"$l\"}"; done
  rm -f "$STUB/files_$n"
  if [ "$files" != "-" ]; then
    : > "$STUB/files_$n"
    local oldifs="$IFS"; IFS='@'
    for row in $files; do printf '%b\n' "$row" >> "$STUB/files_$n"; nf=$((nf + 1)); done
    IFS="$oldifs"
  fi
  local item
  item="$(printf '{"number":%s,"mergedAt":"2026-10-1%sT10:00:00Z","labels":[%s],"body":"%s","headRefOid":"sha%s","additions":10,"deletions":2,"changedFiles":%s,"statusCheckRollup":%s}' \
    "$n" "$((n % 10))" "$lj" "$body" "$n" "$nf" "$roll")"
  if [ -n "$ITEMS" ]; then ITEMS="$ITEMS,"; fi
  ITEMS="$ITEMS$item"
}
finish_list() { printf '[%s]\n' "$ITEMS" > "$STUB/list.json"; }

lpr 1 ""                  ""                          'R/a.R\t\t5\t1'                                  "$ROLL_OK"
lpr 2 ""                  ""                          '.claude/hooks/x.sh\t\t1\t0'                      "$ROLL_OK"
lpr 3 ""                  ""                          'scripts/x.sh\t.claude/hooks/x.sh\t0\t0'          "$ROLL_OK"
lpr 4 ""                  ""                          '.claude/scripts/zzz_nightly.sh\t\t2\t2'          "$ROLL_OK"
lpr 5 "auto-merged"       ""                          'R/b.R\t\t3\t0'                                  "$ROLL_OK"
lpr 6 "auto-merged tier2" "Summary\\nTier-2-Class: robustness" '.claude/scripts/zzz_nightly.sh\t\t10\t2@tests/test_z.sh\t\t5\t0' "$ROLL_OK"
lpr 7 "auto-merged"       ""                          '.claude/rules/a.md\t\t1\t0'                      "$ROLL_OK"
lpr 8 ""                  ""                          '-'                                               "$ROLL_OK"
lpr 9 ""                  ""                          'R/c.R\t\t1\t1'                                  "$ROLL_BAD"
lpr 10 ""                 ""                          'R/d.R\t\t1\t1'                                  '[]'
lpr 11 ""                 ""                          'R/e.R\t\t1\t1'                                  "$ROLL_OK"
: > "$STUB/flaky_11"   # PR 11: the files call fails once, then answers (a transient GitHub error)
finish_list

DB="$W/t.duckdb"; newdb "$DB"
export UNIFIED_DB_PATH="$DB"
cell() { q "$DB" "SELECT $2 FROM merge_events WHERE repo='O/R' AND pr_number=$1;"; }   # cell PR EXPR
n_rows() { q "$DB" "SELECT count(*) FROM merge_events;"; }

OUT="$(bash "$SYNC" --repo O/R 2>"$W/err")"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'listed=11 upserted=11 unknown=1'; then ok; else bad "first sync rc=$RC out=$OUT err=$(cat "$W/err")"; fi
[ "$(n_rows)" = "11" ] && ok || bad "expected 11 rows, got $(n_rows)"

# ---- 1. classification ---------------------------------------------------------
chk_row() {  # label pr "path|approval|class"
  local got; got="$(cell "$2" "merge_path || '|' || approval || '|' || class")"
  if [ "$got" = "$3" ]; then ok; else bad "$1: PR $2 got '$got', wanted '$3'"; fi
}
chk_row "unlisted path"              1 "owner-verb|owner-verb|auto-unlisted"
chk_row "excluded path"              2 "owner-verb|owner-verb|excluded:path"
chk_row "rename OUT of excluded"     3 "owner-verb|owner-verb|excluded:path"
chk_row "scheduled script by plist"  4 "owner-verb|owner-verb|excluded:scheduled-script"
chk_row "auto-merged label -> sweep" 5 "sweep|none|auto-unlisted"
chk_row "tier2 label + trailer"      6 "sweep|veto-lapsed|tier2:robustness"
chk_row "sweep merge of excluded"    7 "sweep|none|excluded:path"
chk_row "files unreadable"           8 "owner-verb|owner-verb|unknown"
chk_row "transient files error is retried" 11 "owner-verb|owner-verb|auto-unlisted"
[ "$(cell 5 auto_merged_label)" = "true" ] && [ "$(cell 1 auto_merged_label)" = "false" ] && ok || bad "auto_merged_label wrong"
[ "$(cell 6 excluded_reasons)" = "scheduled-script" ] && ok || bad "tier2 PR reasons: '$(cell 6 excluded_reasons)'"
[ "$(cell 2 excluded_reasons)" = "path" ] && ok || bad "excluded PR reasons: '$(cell 2 excluded_reasons)'"
[ "$(cell 1 files_changed || true)" = "1" ] && [ "$(cell 1 additions)" = "10" ] && [ "$(cell 1 deletions)" = "2" ] && ok || bad "counts not recorded"
[ "$(cell 9 ci_state)" = "failure" ] && [ "$(cell 10 ci_state)" = "NA" ] && [ "$(cell 1 ci_state)" = "success" ] && ok || bad "ci_state derivation: $(cell 9 ci_state)/$(cell 10 ci_state)/$(cell 1 ci_state)"
[ "$(cell 1 gate_result)" = "NA" ] && [ "$(cell 1 source)" = "sync" ] && ok || bad "historical row gate/source: $(cell 1 gate_result)/$(cell 1 source)"

# nothing but classes, reasons and counts is stored: no column can hold a path or a title
cols="$(q "$DB" "SELECT string_agg(column_name, ',') FROM duckdb_columns() WHERE table_name='merge_events';")"
if printf '%s' "$cols" | grep -qiE 'title|body|path_|file_path|filename'; then bad "merge_events has a content-bearing column: $cols"; else ok; fi
if q "$DB" "SELECT * FROM merge_events;" | grep -qE 'hooks/x.sh|zzz_nightly|Tier-2-Class|Summary'; then bad "a path or body text leaked into merge_events"; else ok; fi

# ---- 2. idempotent re-run ------------------------------------------------------------
: > "$STUB/calls.log"
bash "$SYNC" --repo O/R >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ "$(n_rows)" = "11" ]; then ok; else bad "re-run changed the row count: $(n_rows) rc=$RC"; fi
if grep -q '^api .*pulls/.*/files' "$STUB/calls.log"; then bad "re-run re-fetched files of recorded PRs"; else ok; fi
bash "$SYNC" --repo O/R --refresh >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ "$(n_rows)" = "11" ] && [ "$(q "$DB" "SELECT count(*) FROM (SELECT repo, pr_number FROM merge_events GROUP BY ALL HAVING count(*) > 1);")" = "0" ]; then ok; else bad "--refresh duplicated rows: $(n_rows)"; fi

# falsification of the retry: with a single attempt the flaky PR must come out 'unknown'
rm -f "$STUB/flaky_seen_11"; DBR="$W/retry.duckdb"; newdb "$DBR"
MERGE_HISTORY_API_TRIES=1 bash "$SYNC" --repo O/R --db "$DBR" >/dev/null 2>&1
if [ "$(q "$DBR" "SELECT class FROM merge_events WHERE pr_number=11;")" = "unknown" ]; then ok; else bad "with API_TRIES=1 the flaky PR should be unknown (the retry test could not go red)"; fi

# ---- 3. facts from the sweep are kept -------------------------------------------------
printf '5\tsuccess\tPASS\n' > "$W/facts.tsv"
bash "$SYNC" --repo O/R --facts "$W/facts.tsv" >/dev/null 2>&1
[ "$(cell 5 "gate_result || '|' || ci_state || '|' || source")" = "PASS|success|sweep" ] && ok || bad "facts not applied: $(cell 5 "gate_result || '|' || ci_state || '|' || source")"
bash "$SYNC" --repo O/R --refresh >/dev/null 2>&1
[ "$(cell 5 "gate_result || '|' || source")" = "PASS|sweep" ] && ok || bad "a later refresh downgraded the sweep facts: $(cell 5 "gate_result || '|' || source")"

# ---- 4. --since marks backfill and filters ------------------------------------------------
DB2="$W/since.duckdb"; newdb "$DB2"
UNIFIED_DB_PATH="$DB2" bash "$SYNC" --repo O/R --since 2026-10-15 --db "$DB2" >/dev/null 2>&1
if [ "$(q "$DB2" "SELECT count(*) FROM merge_events WHERE merged_at < TIMESTAMPTZ '2026-10-15 00:00:00+00';")" = "0" ] \
   && [ "$(q "$DB2" "SELECT count(DISTINCT source) FROM merge_events;")" = "1" ] \
   && [ "$(q "$DB2" "SELECT min(source) FROM merge_events;")" = "backfill" ] \
   && [ "$(q "$DB2" "SELECT count(*) FROM merge_events;")" -gt 0 ]; then ok; else bad "--since filter / backfill source"; fi

# ---- 5. heartbeat -----------------------------------------------------------------------------
hb() { q "$DB" "SELECT count(*) FROM housekeeping_runs WHERE task='merge_history_sync' $1;"; }
if [ "$(hb "AND status='ok' AND ended_at IS NOT NULL")" -ge 4 ] && [ "$(hb "AND status='running'")" = "0" ]; then ok; else bad "heartbeat rows: ok=$(hb "AND status='ok'") running=$(hb "AND status='running'")"; fi
[ "$(hb "AND status='ok' AND rows_written=11")" -ge 1 ] && ok || bad "first run heartbeat rows_written should be 11"
mv "$STUB/list.json" "$STUB/list.json.off"
bash "$SYNC" --repo O/R >/dev/null 2>"$W/err"; RC=$?
if [ "$RC" -eq 3 ] && [ "$(hb "AND status='failed'")" = "1" ] && grep -q 'gh pr list failed' "$W/err"; then ok; else bad "gh failure: rc=$RC failed rows=$(hb "AND status='failed'") err=$(cat "$W/err")"; fi
mv "$STUB/list.json.off" "$STUB/list.json"

# ---- 6. duckdb missing -> loud + exit 3 ---------------------------------------------------------
MERGE_HISTORY_DUCKDB=/nonexistent/duckdb bash "$SYNC" --repo O/R >/dev/null 2>"$W/err"; RC=$?
if [ "$RC" -eq 3 ] && grep -qi 'duckdb is not available' "$W/err"; then ok; else bad "sync without duckdb: rc=$RC err=$(cat "$W/err")"; fi
MERGE_HISTORY_DUCKDB=/nonexistent/duckdb bash "$CHECK" --db "$DB" >/dev/null 2>"$W/err"; RC=$?
if [ "$RC" -eq 3 ] && grep -qi 'duckdb is not available' "$W/err"; then ok; else bad "check without duckdb: rc=$RC err=$(cat "$W/err")"; fi

# ---- 7. usage errors -----------------------------------------------------------------------------
for a in "--bogus" "--since 2026/10/01" "--limit 0" "--repo noslash" "--facts /no/such/file"; do
  bash "$SYNC" $a >/dev/null 2>&1; RC=$?
  if [ "$RC" -eq 2 ]; then ok; else bad "sync '$a': exit $RC, wanted 2"; fi
done
for a in "--bogus" "--days 0" "--days x"; do
  bash "$CHECK" $a >/dev/null 2>&1; RC=$?
  if [ "$RC" -eq 2 ]; then ok; else bad "check '$a': exit $RC, wanted 2"; fi
done

# ---- 8. detection rules R1..R5 ----------------------------------------------------------------------
# ins DB PR path approval class ci gate [hours_ago]; merged_at is 2 UTC days ago + PR minutes,
# so every row of a scenario falls on one UTC day inside a 7-day window.
ins() {
  q "$1" "SET TimeZone='UTC'; INSERT INTO merge_events VALUES ('O/R', $2, date_trunc('day', current_timestamp) - INTERVAL 2 DAY + INTERVAL ($2) MINUTE,
          '$3', '$4', '$5', '', 1, 1, 1, '$6', '$7', $( [ "$3" = sweep ] && echo true || echo false ), 'sha$2', 'sync', current_timestamp);" >/dev/null
}
# fill DB N_OWNER: owner-verb filler so the automation share stays low
fill() { local i=0; while [ "$i" -lt "$2" ]; do ins "$1" $((900 + i)) owner-verb owner-verb auto-unlisted success NA; i=$((i + 1)); done; }
scenario() { local f="$W/sc_$1.duckdb"; newdb "$f"; echo "$f"; }
runchk() { OUT="$(bash "$CHECK" --db "$1" --days 7 2>"$W/err")"; RC=$?; }
rule_is() {  # label rule expected-word
  if printf '%s\n' "$OUT" | grep -q "^$2 .*: *$3"; then ok; else bad "$1: rule $2 expected $3; out: $OUT"; fi
}

D="$(scenario clean)"; fill "$D" 6; ins "$D" 1 sweep none auto-unlisted success PASS; ins "$D" 2 sweep none auto-unlisted success PASS
runchk "$D"
if [ "$RC" -eq 0 ]; then ok; else bad "clean DB: exit $RC; out: $OUT"; fi
rule_is "clean" R1 OK; rule_is "clean" R2 OK; rule_is "clean" R3 OK; rule_is "clean" R4 OK; rule_is "clean" R5 OK
if printf '%s\n' "$OUT" | grep -q 'merges by (merge_path, approval, class)' && printf '%s\n' "$OUT" | grep -q '  6  owner-verb  owner-verb  auto-unlisted' && printf '%s\n' "$OUT" | grep -q '  2  sweep  none  auto-unlisted'; then ok; else bad "frequency table missing: $OUT"; fi
if printf '%s\n' "$OUT" | grep -q '^summary: days=7 total=8 owner_verb=6 auto=2 tier2=0 alerts=0'; then ok; else bad "summary line: $OUT"; fi
OUTJ="$(bash "$CHECK" --db "$D" --days 7 --json)"
if printf '%s' "$OUTJ" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["total"]==8 and d["alerts"]==0 and d["rules"]["R1"]["status"]=="OK"'; then ok; else bad "--json not valid or wrong: $OUTJ"; fi

D="$(scenario r1)"; fill "$D" 10; ins "$D" 1 sweep none excluded:path success PASS
runchk "$D"; rule_is "R1 fires" R1 ALERT; [ "$RC" -eq 1 ] && ok || bad "R1 should exit 1, got $RC"
D="$(scenario r1b)"; fill "$D" 10; ins "$D" 1 owner-verb owner-verb excluded:path success NA
runchk "$D"; rule_is "R1 quiet for an owner-verb excluded merge" R1 OK; [ "$RC" -eq 0 ] && ok || bad "owner-verb excluded merge must not alert, got $RC"

D="$(scenario r2a)"; fill "$D" 10; ins "$D" 1 sweep none auto-unlisted success BLOCK
runchk "$D"; rule_is "R2 fires on gate not PASS" R2 ALERT; [ "$RC" -eq 1 ] && ok || bad "R2 gate should exit 1, got $RC"
D="$(scenario r2b)"; fill "$D" 10; ins "$D" 1 sweep none auto-unlisted failure PASS
runchk "$D"; rule_is "R2 fires on CI not success" R2 ALERT
D="$(scenario r2c)"; fill "$D" 10; ins "$D" 1 sweep none auto-unlisted NA NA
runchk "$D"; rule_is "R2 quiet when unknown (NA)" R2 OK; [ "$RC" -eq 0 ] && ok || bad "unknown values must not alert R2, got $RC"

# The cap has ONE home, DAILY_CAP in the script under test; the fixtures derive from it.
CAP="$(sed -n 's/^DAILY_CAP=\([0-9][0-9]*\).*/\1/p' "$CHECK")"
case "$CAP" in ""|*[!0-9]*) bad "cannot read DAILY_CAP from $CHECK"; CAP=10 ;; esac
CAP1=$((CAP + 1))
D="$(scenario r3a)"; fill "$D" $((CAP * 6)); i=1; while [ "$i" -le "$CAP1" ]; do ins "$D" "$i" sweep none auto-unlisted success PASS; i=$((i + 1)); done
runchk "$D"; rule_is "R3 fires at $CAP1 sweep merges in a UTC day" R3 ALERT; [ "$RC" -eq 1 ] && ok || bad "R3 should exit 1, got $RC"
D="$(scenario r3b)"; fill "$D" $((CAP * 6)); i=1; while [ "$i" -le "$CAP" ]; do ins "$D" "$i" sweep none auto-unlisted success PASS; i=$((i + 1)); done
runchk "$D"; rule_is "R3 quiet at exactly $CAP (the cap)" R3 OK; [ "$RC" -eq 0 ] && ok || bad "$CAP sweep merges must not alert, got $RC (out: $OUT)"

D="$(scenario r4a)"; fill "$D" 10; ins "$D" 1 sweep none tier2:robustness success PASS
runchk "$D"; rule_is "R4 fires: tier2 without veto-lapsed" R4 ALERT; [ "$RC" -eq 1 ] && ok || bad "R4 should exit 1, got $RC"
D="$(scenario r4b)"; fill "$D" 10; ins "$D" 1 sweep veto-lapsed tier2:robustness success PASS
runchk "$D"; rule_is "R4 quiet: tier2 with veto-lapsed" R4 OK; [ "$RC" -eq 0 ] && ok || bad "valid tier2 merge must not alert, got $RC"
if printf '%s\n' "$OUT" | grep -q 'summary: .*tier2=1'; then ok; else bad "tier2 count in summary: $OUT"; fi

D="$(scenario r5a)"; i=1; while [ "$i" -le 4 ]; do ins "$D" "$i" sweep none auto-unlisted success PASS; i=$((i + 1)); done
runchk "$D"; rule_is "R5 insufficient data (4 merges)" R5 INSUFFICIENT-DATA
if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -q '^R5 .*: OK'; then ok; else bad "insufficient data must not read as OK/exit 1: rc=$RC $OUT"; fi
D="$(scenario r5b)"; i=1; while [ "$i" -le 5 ]; do ins "$D" "$i" sweep none auto-unlisted success PASS; i=$((i + 1)); done
runchk "$D"; rule_is "R5 fires at 5/5 automated" R5 ALERT; [ "$RC" -eq 1 ] && ok || bad "R5 should exit 1, got $RC"
D="$(scenario r5c)"; ins "$D" 900 owner-verb owner-verb auto-unlisted success NA; i=1; while [ "$i" -le 4 ]; do ins "$D" "$i" sweep none auto-unlisted success PASS; i=$((i + 1)); done
runchk "$D"; rule_is "R5 quiet at exactly 0.80 (boundary, not above)" R5 OK; [ "$RC" -eq 0 ] && ok || bad "share == threshold must not alert, got $RC"

# indeterminate: empty table, missing table, missing DB
D="$(scenario empty)"; runchk "$D"
if [ "$RC" -eq 3 ] && grep -q 'no rows at all' "$W/err"; then ok; else bad "empty merge_events: rc=$RC err=$(cat "$W/err")"; fi
D="$W/notable.duckdb"; rm -f "$D"; duckdb -init /dev/null "$D" -c "CREATE TABLE x(a INT);" >/dev/null 2>&1
runchk "$D"
if [ "$RC" -eq 3 ] && grep -q 'merge_events is not in' "$W/err"; then ok; else bad "no table: rc=$RC err=$(cat "$W/err")"; fi
runchk "$W/does-not-exist.duckdb"
if [ "$RC" -eq 3 ]; then ok; else bad "missing DB: rc=$RC"; fi

# ---- 9. falsification: break the SQL, the matching test must go red ----------------------------------
D="$(scenario fals)"; fill "$D" 30; ins "$D" 1 sweep none excluded:path success PASS
i=10; while [ "$i" -le $((10 + CAP)) ]; do ins "$D" "$i" sweep none auto-unlisted success PASS; i=$((i + 1)); done
runchk "$D"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^R1 .*: *ALERT' && printf '%s\n' "$OUT" | grep -q '^R3 .*: *ALERT'; then ok; else bad "falsification fixture should alert R1 and R3 (rc=$RC): $OUT"; fi
sed "s/class LIKE 'excluded:%'/class LIKE 'zzz:%'/" "$CHECK" > "$W/mut_r1.sh"
if cmp -s "$CHECK" "$W/mut_r1.sh"; then bad "R1 mutant did not change the script"; else
  OUT="$(bash "$W/mut_r1.sh" --db "$D" --days 7 2>/dev/null)"
  if printf '%s\n' "$OUT" | grep -q '^R1 .*: *ALERT'; then bad "R1 MUTANT still alerts: the R1 test cannot go red"; else ok; fi
fi
sed 's/HAVING count(\*) > \$DAILY_CAP/HAVING count(*) > 99/' "$CHECK" > "$W/mut_r3.sh"
if cmp -s "$CHECK" "$W/mut_r3.sh"; then bad "R3 mutant did not change the script"; else
  OUT="$(bash "$W/mut_r3.sh" --db "$D" --days 7 2>/dev/null)"
  if printf '%s\n' "$OUT" | grep -q '^R3 .*: *ALERT'; then bad "R3 MUTANT still alerts: the R3 test cannot go red"; else ok; fi
fi
# falsification of classification: an empty exclusion set must change a result
sed 's/\[ -n "\$MC_PATH_HIT" \]; then MC_REASONS="path"/[ -n "" ]; then MC_REASONS="path"/' "$ROOT/.claude/scripts/lib/merge_classify.sh" > "$W/mut_lib.sh"
DB3="$W/mutlib.duckdb"; newdb "$DB3"
if cmp -s "$ROOT/.claude/scripts/lib/merge_classify.sh" "$W/mut_lib.sh"; then ok; else
  MERGE_HISTORY_LIB="$W/mut_lib.sh" bash "$SYNC" --repo O/R --db "$DB3" >/dev/null 2>&1
  if [ "$(q "$DB3" "SELECT coalesce(excluded_reasons, '') = '' FROM merge_events WHERE pr_number=2;")" = "true" ]; then ok; else bad "lib mutant should lose the excluded reason (got: $(q "$DB3" "SELECT excluded_reasons FROM merge_events WHERE pr_number=2;"))"; fi
fi

# ---- 9b. read-only checker list (llm#1471): R1 must not fire on a listed script ------------------------
# A second fake repo holds the owner-signed list (.claude/scripts/zzz_nightly.sh is listed;
# other_job.sh is scheduled via the recorder but NOT listed). Its own gh stub dir and DBs.
FAKE2="$W/repo2"; STUB2="$W/stub2"
mkdir -p "$FAKE2" "$STUB2"
cp -R "$FAKE/.claude" "$FAKE2/.claude"; cp -R "$FAKE/bin" "$FAKE2/bin"
printf '# fake owner-signed list\n.claude/scripts/zzz_nightly.sh\n' > "$FAKE2/.claude/state/readonly_checkers.txt"
SAVE_STUB="$STUB"; STUB="$STUB2"; ITEMS=""
RO_BODY='Summary\nTier-2-Class: readonly-checker'
lpr 21 "auto-merged"       ""       '.claude/scripts/zzz_nightly.sh\t\t2\t2'                                              "$ROLL_OK"
lpr 22 "auto-merged"       ""       '.claude/scripts/other_job.sh\t\t2\t2'                                                "$ROLL_OK"
lpr 23 "auto-merged tier2" "$RO_BODY" '.claude/scripts/zzz_nightly.sh\t\t2\t2@tests/test_z.sh\t\t5\t0'                  "$ROLL_OK"
lpr 24 "auto-merged tier2" "$RO_BODY" '.claude/scripts/zzz_nightly.sh\t\t2\t2@.claude/scripts/other_job.sh\t\t1\t0@tests/test_z.sh\t\t5\t0' "$ROLL_OK"
lpr 25 ""                  ""       '.claude/scripts/zzz_nightly.sh\t\t2\t2'                                              "$ROLL_OK"
lpr 26 "auto-merged"       ""       '.claude/scripts/zzz_nightly.sh\t\t1\t0@.claude/scripts/other_job.sh\t\t1\t0'         "$ROLL_OK"
finish_list
STUB="$SAVE_STUB"
printf '#!/bin/sh\nexec other_job.sh\n' > "$FAKE2/bin/launchd-recorders/rec"

DB4="$W/ro.duckdb"; newdb "$DB4"
STUB_DIR="$STUB2" AUTO_MERGE_REPO_DIR="$FAKE2" UNIFIED_DB_PATH="$DB4" bash "$SYNC" --repo O/R --db "$DB4" >/dev/null 2>"$W/err"; RC=$?
runchk_long() { OUT="$(bash "$CHECK" --db "$1" --days 3650 2>"$W/err")"; RC=$?; }   # the synced rows carry fixed 2026-10 dates
c4() { q "$DB4" "SELECT merge_path || '|' || approval || '|' || class || '|' || excluded_reasons FROM merge_events WHERE pr_number=$1;"; }
if [ "$RC" -eq 0 ]; then ok; else bad "readonly sync rc=$RC err=$(cat "$W/err")"; fi
[ "$(c4 21)" = "sweep|none|readonly-checker|readonly-checker" ] && ok || bad "listed script, sweep merge: '$(c4 21)'"
[ "$(c4 22)" = "sweep|none|excluded:scheduled-script|scheduled-script" ] && ok || bad "unlisted scheduled script, sweep merge: '$(c4 22)'"
[ "$(c4 23)" = "sweep|veto-lapsed|tier2:readonly-checker|readonly-checker" ] && ok || bad "tier2 readonly-checker, listed only: '$(c4 23)'"
[ "$(c4 24)" = "sweep|none|excluded:scheduled-script|scheduled-script" ] && ok || bad "tier2 readonly-checker with an unlisted script: '$(c4 24)'"
[ "$(c4 25)" = "owner-verb|owner-verb|excluded:scheduled-script|scheduled-script" ] && ok || bad "owner-verb merge of a listed script keeps its class: '$(c4 25)'"
[ "$(c4 26)" = "sweep|none|excluded:scheduled-script|scheduled-script" ] && ok || bad "listed + unlisted mixed: '$(c4 26)'"
# R1: unlisted scheduled scripts in a sweep merge alert (22, 24, 26); listed ones do not
runchk_long "$DB4"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^R1 .*: *ALERT (n=3'; then ok; else bad "R1 must alert on exactly 3 unlisted sweep merges (rc=$RC): $OUT"; fi
DB5="$W/ro_listed_only.duckdb"; cp "$DB4" "$DB5"
q "$DB5" "DELETE FROM merge_events WHERE pr_number IN (22, 24, 26);" >/dev/null
runchk_long "$DB5"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^R1 .*: *OK (n=0'; then ok; else bad "R1 must be quiet for listed read-only checkers (rc=$RC): $OUT"; fi
# a list that cannot be read relaxes nothing: the listed script is excluded again
DB6="$W/ro_nolist.duckdb"; newdb "$DB6"
mv "$FAKE2/.claude/state/readonly_checkers.txt" "$W/ro_list.bak"
STUB_DIR="$STUB2" AUTO_MERGE_REPO_DIR="$FAKE2" UNIFIED_DB_PATH="$DB6" bash "$SYNC" --repo O/R --db "$DB6" >/dev/null 2>&1
mv "$W/ro_list.bak" "$FAKE2/.claude/state/readonly_checkers.txt"
if [ "$(q "$DB6" "SELECT class FROM merge_events WHERE pr_number=21;")" = "excluded:scheduled-script" ]; then ok; else bad "without the list a listed script must be excluded again (falsification)"; fi
# falsification of the lib: a list lookup that never matches must turn R1 red on the listed-only data
sed 's/grep -F -x -q -- "\$1" "\$MC_RO_FILE"/false/' "$ROOT/.claude/scripts/lib/merge_classify.sh" > "$W/mut_ro_lib.sh"
DB7="$W/ro_mut.duckdb"; newdb "$DB7"
if cmp -s "$ROOT/.claude/scripts/lib/merge_classify.sh" "$W/mut_ro_lib.sh"; then bad "read-only lookup mutant did not change the lib"; else
  STUB_DIR="$STUB2" AUTO_MERGE_REPO_DIR="$FAKE2" UNIFIED_DB_PATH="$DB7" MERGE_HISTORY_LIB="$W/mut_ro_lib.sh" bash "$SYNC" --repo O/R --db "$DB7" >/dev/null 2>&1
  q "$DB7" "DELETE FROM merge_events WHERE pr_number IN (22, 24, 26);" >/dev/null
  runchk_long "$DB7"
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^R1 .*: *ALERT'; then ok; else bad "MUTANT (list never matches) must make R1 alert, proving the R1 listed-only test can go red (rc=$RC): $OUT"; fi
fi

# ---- 10. DB lock: bounded retry ------------------------------------------------------------------------
cat > "$W/ddwrap" <<'EOF'
#!/usr/bin/env bash
echo x >> "$DD_LOG"
exec duckdb "$@"
EOF
chmod +x "$W/ddwrap"
LDB="$W/lock.duckdb"; newdb "$LDB"; ins "$LDB" 1 sweep none auto-unlisted success PASS
export DD_LOG="$W/dd.log"
# holder: a duckdb process that opens the DB read-write and keeps it for N seconds
hold() { { echo "SELECT 1;"; sleep "$1"; } | duckdb -init /dev/null "$LDB" >/dev/null 2>&1 & }
: > "$DD_LOG"; hold 3; sleep 1
OUT="$(MERGE_HISTORY_DUCKDB="$W/ddwrap" MERGE_HISTORY_LOCK_TRIES=8 MERGE_HISTORY_LOCK_SLEEP=1 bash "$CHECK" --db "$LDB" --days 7 2>"$W/err")"; RC=$?
wait
calls="$(wc -l < "$DD_LOG" | tr -d ' ')"
if [ "$RC" -eq 0 ] && [ "$calls" -gt 2 ]; then ok; else bad "check should retry through a short lock (rc=$RC duckdb calls=$calls err=$(cat "$W/err"))"; fi
: > "$DD_LOG"; hold 8; sleep 1
OUT="$(MERGE_HISTORY_DUCKDB="$W/ddwrap" MERGE_HISTORY_LOCK_TRIES=2 MERGE_HISTORY_LOCK_SLEEP=1 bash "$CHECK" --db "$LDB" --days 7 2>"$W/err")"; RC=$?
calls="$(wc -l < "$DD_LOG" | tr -d ' ')"
if [ "$RC" -eq 3 ] && [ "$calls" -eq 2 ]; then ok; else bad "check must give up after the bounded retries (rc=$RC calls=$calls err=$(cat "$W/err"))"; fi
wait
newdb "$LDB"; : > "$DD_LOG"; hold 3; sleep 1
UNIFIED_DB_PATH="$LDB" MERGE_HISTORY_DUCKDB="$W/ddwrap" MERGE_HISTORY_LOCK_TRIES=8 MERGE_HISTORY_LOCK_SLEEP=1 bash "$SYNC" --repo O/R --db "$LDB" >/dev/null 2>"$W/err"; RC=$?
wait
if [ "$RC" -eq 0 ] && [ "$(q "$LDB" "SELECT count(*) FROM merge_events;")" = "11" ]; then ok; else bad "sync should retry through a short lock (rc=$RC err=$(cat "$W/err"))"; fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
exit 0
