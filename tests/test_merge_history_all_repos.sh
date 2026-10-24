#!/usr/bin/env bash
# tests/test_merge_history_all_repos.sh -- merge history across ALL owner repos (llm#1471).
#   .claude/scripts/merge_history_sync_all.sh   loops the owner's repos
#   .claude/scripts/merge_history_check.sh --daily   owner-approved vs automatic per day
# `gh` is a stub on PATH, every DB is a throwaway temp file (never the real
# unified.duckdb), network-free. Repo names are synthetic (owner/repo-a ...).
#
# Exit codes: 0 all pass, 1 a check failed, 3 INDETERMINATE (duckdb or python3
# missing, so nothing can be exercised: reported, never a silent pass).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL="$ROOT/.claude/scripts/merge_history_sync_all.sh"
CHECK="$ROOT/.claude/scripts/merge_history_check.sh"
SCHEMA="$ROOT/.claude/scripts/housekeeping_schema_init.sql"
REAL_EXCL="$ROOT/.claude/state/auto_merge_exclusions.txt"

if ! command -v duckdb >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "INDETERMINATE: duckdb and python3 are both needed; all-repos merge history NOT exercised"
  exit 3
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/merge_history_all_test.XXXXXX")"
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
slug() { printf '%s' "$1" | tr '/' '_'; }
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo list") if [ -f "$d/repolist_fail" ]; then exit 1; fi; cat "$d/repos.json"; exit 0 ;;
  "pr list")
    repo=""; prev=""
    for a in "$@"; do if [ "$prev" = "--repo" ]; then repo="$a"; fi; prev="$a"; done
    s="$(slug "$repo")"
    if [ -f "$d/fail_$s" ] || [ ! -f "$d/list_$s.json" ]; then exit 1; fi
    cat "$d/list_$s.json"; exit 0 ;;
esac
if [ "$1" = "api" ]; then
  p="${2#repos/}"; p="${p%/files}"; n="${p##*/}"; r="${p%/pulls/*}"
  f="$d/files_$(slug "$r")_$n"
  if [ -f "$f" ]; then cat "$f"; exit 0; else exit 1; fi
fi
exit 0
EOF
chmod +x "$BIN/gh"
export STUB_DIR="$STUB" PATH="$BIN:$PATH"
export AUTO_MERGE_REPO_DIR="$FAKE"
export MERGE_HISTORY_LOCK_SLEEP=1 MERGE_HISTORY_API_SLEEP=0
unset UNIFIED_DB_PATH MERGE_HISTORY_OWNER MERGE_HISTORY_LIST_LIMIT MERGE_HISTORY_SYNC

q() { duckdb -init /dev/null -csv -noheader "$1" -c "$2" 2>&1; }
newdb() { rm -f "$1"; duckdb -init /dev/null "$1" < "$SCHEMA" >/dev/null 2>&1; }

# ---- fixture: two repos, merged yesterday / two days ago (UTC) --------------------
python3 -I - "$STUB" <<'PYEOF'
import json, sys, datetime
d = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
def at(days): return (now - datetime.timedelta(days=days)).strftime("%Y-%m-%dT10:00:00Z")
ROLL = [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"}]
def pr(n, days, label):
    return {"number": n, "mergedAt": at(days), "labels": ([{"name": label}] if label else []), "body": "",
            "headRefOid": "sha%d" % n, "additions": 1, "deletions": 0, "changedFiles": 1, "statusCheckRollup": ROLL}
repos = {
    "owner_repo-a": ([pr(1, 1, ""), pr(2, 1, ""), pr(3, 1, "auto-merged")],
                     {1: ".claude/hooks/x.sh", 2: "R/a.R", 3: "R/b.R"}),
    "owner_repo-b": ([pr(1, 1, "auto-merged"), pr(2, 1, "auto-merged"), pr(3, 2, "")],
                     {1: "R/c.R", 2: "R/d.R", 3: ".claude/hooks/y.sh"}),
}
for slug, (prs, files) in repos.items():
    json.dump(prs, open("%s/list_%s.json" % (d, slug), "w"))
    for n, f in files.items():
        open("%s/files_%s_%d" % (d, slug, n), "w").write("%s\t\t1\t0\n" % f)
json.dump([
    {"nameWithOwner": "owner/repo-a", "isArchived": False, "isFork": False},
    {"nameWithOwner": "owner/repo-b", "isArchived": False, "isFork": False},
    {"nameWithOwner": "owner/repo-old", "isArchived": True, "isFork": False},
    {"nameWithOwner": "owner/repo-fork", "isArchived": False, "isFork": True},
], open(d + "/repos.json", "w"))
PYEOF

# ---- (a) both synthetic repos get rows; archived and fork are skipped -----------------
DB="$W/t.duckdb"; newdb "$DB"; export UNIFIED_DB_PATH="$DB"
OUT="$(bash "$ALL" 2>"$W/err")"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'repos=2 ok=2 failed=0'; then ok; else bad "(a) all-repo sync rc=$RC out=$OUT err=$(cat "$W/err")"; fi
[ "$(q "$DB" "SELECT count(*) FROM merge_events WHERE repo='owner/repo-a';")" = "3" ] && ok || bad "(a) repo-a should have 3 rows"
[ "$(q "$DB" "SELECT count(*) FROM merge_events WHERE repo='owner/repo-b';")" = "3" ] && ok || bad "(a) repo-b should have 3 rows"
if grep -q -e 'repo-old' -e 'repo-fork' "$STUB/calls.log"; then bad "(a) an archived or forked repo was inspected"; else ok; fi
[ "$(q "$DB" "SELECT status FROM housekeeping_runs WHERE task='merge_history_sync' ORDER BY started_at DESC LIMIT 1;")" = "ok" ] && ok || bad "(a) newest sync heartbeat should be ok"
OUTD="$(bash "$ALL" --dry-run 2>&1)"; RCD=$?
if [ "$RCD" -eq 0 ] && printf '%s' "$OUTD" | grep -q 'dry-run .*repos=2 ' && ! printf '%s' "$OUTD" | grep -q 'repo-a'; then ok; else bad "(a) --dry-run: rc=$RCD out=$OUTD"; fi

# ---- (c) the report: owner-approved vs automatic, per-repo split, reasons ---------------
REP="$(bash "$CHECK" --db "$DB" --daily 2>"$W/rerr")"; RRC=$?
[ "$RRC" -eq 0 ] && ok || bad "(c) --daily rc=$RRC err=$(cat "$W/rerr")"
YD="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).strftime("%Y-%m-%d"))')"
printf '%s' "$REP" | grep -qF "yesterday ($YD): owner-approved 2 | automatic 3 | share auto 60%" && ok || bad "(c) yesterday line wrong: $(printf '%s' "$REP" | grep yesterday)"
printf '%s' "$REP" | grep -qF 'last 7 days: owner-approved 3 | automatic 3 | share auto 50%' && ok || bad "(c) 7-day line wrong"
printf '%s' "$REP" | grep -qF 'owner/repo-a owner 2 auto 1; owner/repo-b owner 1 auto 2' && ok || bad "(c) per-repo split wrong: $(printf '%s' "$REP" | grep 'by repo')"
printf '%s' "$REP" | grep -qF 'path 2, unclassified 1' && ok || bad "(c) reason counts wrong: $(printf '%s' "$REP" | grep 'why you')"
printf '%s' "$REP" | grep -qF 'owner-approved = you typed a merge verb; automatic = the sweep merged it' && ok || bad "(c) terms are not defined in the report"
if printf '%s' "$REP" | grep -qE 'hooks/|R/a.R|x.sh'; then bad "(c) a path leaked into the report"; else ok; fi
# FALSIFY (c): move one owner-approved merge to the sweep; the numbers must follow.
q "$DB" "UPDATE merge_events SET merge_path='sweep', approval='none' WHERE repo='owner/repo-a' AND pr_number=2;" >/dev/null
REP2="$(bash "$CHECK" --db "$DB" --daily 2>/dev/null)"
printf '%s' "$REP2" | grep -qF "yesterday ($YD): owner-approved 1 | automatic 4 | share auto 80%" && ok || bad "(c) falsification: report did not follow the data: $(printf '%s' "$REP2" | grep yesterday)"
newdb "$W/empty.duckdb"
bash "$CHECK" --db "$W/empty.duckdb" --daily >"$W/e.out" 2>&1; ERC=$?
if [ "$ERC" -eq 3 ] && grep -q 'INDETERMINATE' "$W/e.out" && ! grep -q 'owner-approved 0' "$W/e.out"; then ok; else bad "(c) empty merge_events must be exit 3 INDETERMINATE, got rc=$ERC"; fi

# ---- (b) one repo failing: exit 3, the other repo's rows still written ------------------
DB2="$W/b.duckdb"; newdb "$DB2"; export UNIFIED_DB_PATH="$DB2"
: > "$STUB/fail_owner_repo-b"
OUT="$(bash "$ALL" 2>"$W/err")"; RC=$?
if [ "$RC" -eq 3 ] && grep -q 'FAILED: .*owner/repo-b' "$W/err"; then ok; else bad "(b) a failing repo must give exit 3 naming it (rc=$RC)"; fi
[ "$(q "$DB2" "SELECT count(*) FROM merge_events WHERE repo='owner/repo-a';")" = "3" ] && ok || bad "(b) repo-a rows must still be written"
[ "$(q "$DB2" "SELECT count(*) FROM merge_events WHERE repo='owner/repo-b';")" = "0" ] && ok || bad "(b) repo-b has no rows"
[ "$(q "$DB2" "SELECT status FROM housekeeping_runs WHERE task='merge_history_sync' ORDER BY started_at DESC LIMIT 1;")" = "failed" ] && ok || bad "(b) newest sync heartbeat should be failed"
rm -f "$STUB/fail_owner_repo-b"

# ---- (d) FALSIFY: an empty repo list is exit 3, never "0 merges" -------------------------
printf '[]' > "$STUB/repos.json"
DB3="$W/d.duckdb"; newdb "$DB3"; export UNIFIED_DB_PATH="$DB3"
OUT="$(bash "$ALL" 2>"$W/err")"; RC=$?
if [ "$RC" -eq 3 ] && grep -q 'INDETERMINATE' "$W/err" && ! printf '%s' "$OUT" | grep -q 'failed=0'; then ok; else bad "(d) empty repo list must be exit 3 (rc=$RC out=$OUT)"; fi
[ "$(q "$DB3" "SELECT count(*) FROM merge_events;")" = "0" ] && ok || bad "(d) nothing should be written"
# a list of only archived/fork repos is equally empty
printf '[{"nameWithOwner":"owner/repo-old","isArchived":true,"isFork":false}]' > "$STUB/repos.json"
bash "$ALL" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok || bad "(d) only-archived list must be exit 3 (rc=$RC)"
# a failed listing and a possibly truncated listing are exit 3 too
touch "$STUB/repolist_fail"
bash "$ALL" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok || bad "(d) failed repo listing must be exit 3 (rc=$RC)"
rm -f "$STUB/repolist_fail"
python3 -I - "$STUB" <<'PYEOF'
import json, sys
json.dump([{"nameWithOwner": "owner/repo-a", "isArchived": False, "isFork": False},
           {"nameWithOwner": "owner/repo-b", "isArchived": False, "isFork": False}], open(sys.argv[1] + "/repos.json", "w"))
PYEOF
MERGE_HISTORY_LIST_LIMIT=2 bash "$ALL" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok || bad "(d) a list that reaches the limit must be exit 3 (rc=$RC)"
bash "$ALL" --days 0 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "usage error must be exit 2 (rc=$RC)"

echo "merge_history_all_repos: pass=$PASS fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
