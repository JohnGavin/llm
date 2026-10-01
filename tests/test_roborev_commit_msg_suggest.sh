#!/usr/bin/env bash
# tests/test_roborev_commit_msg_suggest.sh
#
# JohnGavin/llm#1274 option B — the commit-msg hook
# (.claude/scripts/roborev_commit_msg_validator.sh) prints
# "suggest: closes roborev #N" hints to stderr for open reviews (this repo,
# closed=0, verdict_bool=0) whose recorded finding location overlaps the
# staged files. It must NEVER change the exit code or block a commit.
#
# Uses a synthetic reviews.db and a throwaway git repo with staged files.
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../.claude/scripts/roborev_commit_msg_validator.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_cm_suggest_XXXXXX)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

pass() { echo "PASS: $1"; (( PASS += 1 )); }
fail() { echo "FAIL: $1 — ${2:-}"; (( FAIL += 1 )); }

REPO="${TMPDIR_ROOT}/repo"
mkdir -p "$REPO/R"
git -C "$REPO" init -q
git -C "$REPO" config user.email "t@t.local"
git -C "$REPO" config user.name "T"
echo init > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -qm init
TOPLEVEL="$(git -C "$REPO" rev-parse --show-toplevel)"

DB="${TMPDIR_ROOT}/reviews.db"
/usr/bin/python3 - "$DB" "$TOPLEVEL" <<'PYEOF'
import sqlite3, sys, json
db, top = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT NOT NULL, name TEXT NOT NULL, identity TEXT);
CREATE TABLE commits (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, sha TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, commit_id INTEGER,
                          git_ref TEXT NOT NULL DEFAULT 'x', status TEXT NOT NULL DEFAULT 'done',
                          job_type TEXT NOT NULL DEFAULT 'review');
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, output TEXT NOT NULL DEFAULT '',
                      structured_output TEXT, closed INTEGER NOT NULL DEFAULT 0, verdict_bool INTEGER DEFAULT 0);
""")
con.execute("INSERT INTO repos VALUES (1, ?, 'repo', NULL)", (top,))
con.execute("INSERT INTO repos VALUES (2, '/somewhere/else', 'other', NULL)")
def structured(loc):
    return json.dumps({"schema_version": 2, "summary": "s", "verdict": "fail",
                       "findings": [{"severity": "high", "problem": "p", "location": loc, "fix": "f"}]})
# (review id, repo, closed, structured, legacy output)
rows = [
    (1, 1, 0, structured("R/foo.R:42"), ""),                       # open, this repo, overlaps R/foo.R
    (2, 1, 0, structured("R/other.R:1"), ""),                      # open, this repo, different file
    (3, 2, 0, structured("R/foo.R:5"), ""),                        # other repo
    (4, 1, 1, structured("R/foo.R:9"), ""),                        # closed
    (5, 1, 0, None, "**Severity**: High\n**Location**: R/legacy.R:7\n**Problem**: x\n"),  # legacy text
]
for rid, repo, closed, st, out in rows:
    con.execute("INSERT INTO commits VALUES (?,?,?)", (rid, repo, f"sha{rid}"))
    con.execute("INSERT INTO review_jobs (id,repo_id,commit_id) VALUES (?,?,?)", (rid, repo, rid))
    con.execute("INSERT INTO reviews (id,job_id,output,structured_output,closed,verdict_bool) VALUES (?,?,?,?,?,0)",
                (rid, rid, out, st, closed))
con.commit()
con.close()
PYEOF

# stage_only FILE...  — reset the index to HEAD, then stage exactly these files
stage_only() {
  git -C "$REPO" reset -q
  local f
  for f in "$@"; do
    mkdir -p "$REPO/$(dirname "$f")"
    echo "change $RANDOM" > "$REPO/$f"
    git -C "$REPO" add "$f"
  done
}

# run_hook MSG DB  -> sets HOOK_RC, HOOK_ERR
run_hook() {
  local msg="$1" db="$2" mf="${TMPDIR_ROOT}/msg.txt"
  printf '%s' "$msg" > "$mf"
  HOOK_RC=0
  HOOK_ERR=$(cd "$REPO" && env -u GIT_DIR -u GIT_WORK_TREE ROBOREV_DB="$db" bash "$HOOK" "$mf" 2>&1 >/dev/null) || HOOK_RC=$?
}

# Test 1 — staged R/foo.R: hint for #1 only (not #2 other file, #3 other repo, #4 closed)
stage_only R/foo.R
run_hook "fix: foo" "$DB"
if [ "$HOOK_RC" = "0" ]; then pass "test1: exit 0 with hints"; else fail "test1: exit 0 with hints" "rc=$HOOK_RC $HOOK_ERR"; fi
if echo "$HOOK_ERR" | grep -qF "suggest: closes roborev #1"; then pass "test1b: hint for overlapping open review #1"
else fail "test1b: hint for overlapping open review #1" "stderr: $HOOK_ERR"; fi
for n in 2 3 4 5; do
  if echo "$HOOK_ERR" | grep -qF "closes roborev #${n}"; then
    fail "test1c: no hint for #${n}" "stderr: $HOOK_ERR"
  else
    pass "test1c: no hint for #${n}"
  fi
done

# Test 2 — unrelated staged file → no hint, exit 0
stage_only docs/unrelated.md
run_hook "docs: unrelated" "$DB"
if [ "$HOOK_RC" = "0" ] && ! echo "$HOOK_ERR" | grep -qF "suggest:"; then
  pass "test2: unrelated staged file → no hint, exit 0"
else
  fail "test2: unrelated staged file → no hint, exit 0" "rc=$HOOK_RC stderr: $HOOK_ERR"
fi

# Test 3 — DB missing → no hint, same exit (0, fail-open path unchanged)
stage_only R/foo.R
run_hook "fix: foo" "/nonexistent/reviews.db"
if [ "$HOOK_RC" = "0" ] && ! echo "$HOOK_ERR" | grep -qF "suggest:"; then
  pass "test3: DB missing → no hint, exit 0"
else
  fail "test3: DB missing → no hint, exit 0" "rc=$HOOK_RC stderr: $HOOK_ERR"
fi

# Test 3b — DB present but not SQLite → no hint, exit 0, no traceback
echo "not a database" > "${TMPDIR_ROOT}/bad.db"
run_hook "fix: foo" "${TMPDIR_ROOT}/bad.db"
if [ "$HOOK_RC" = "0" ] && ! echo "$HOOK_ERR" | grep -qE "suggest:|Traceback"; then
  pass "test3b: corrupt DB → no hint, no traceback, exit 0"
else
  fail "test3b: corrupt DB → no hint, no traceback, exit 0" "rc=$HOOK_RC stderr: $HOOK_ERR"
fi

# Test 4 — legacy text-only review location is matched
stage_only R/legacy.R
run_hook "fix: legacy" "$DB"
if echo "$HOOK_ERR" | grep -qF "suggest: closes roborev #5"; then pass "test4: legacy **Location** text matched"
else fail "test4: legacy **Location** text matched" "stderr: $HOOK_ERR"; fi

# Test 5 — an id already cited in the message is not re-suggested
stage_only R/foo.R
run_hook "fix: foo (closes roborev #1)" "$DB"
if [ "$HOOK_RC" = "0" ] && ! echo "$HOOK_ERR" | grep -qF "suggest: closes roborev #1"; then
  pass "test5: already-cited id not re-suggested"
else
  fail "test5: already-cited id not re-suggested" "rc=$HOOK_RC stderr: $HOOK_ERR"
fi

# Test 6 — validation failure keeps exit 1 and prints no hints
stage_only R/foo.R
run_hook "fix: foo (closes roborev #99999)" "$DB"
if [ "$HOOK_RC" = "1" ] && ! echo "$HOOK_ERR" | grep -qF "suggest:"; then
  pass "test6: bad citation still exit 1, no hints"
else
  fail "test6: bad citation still exit 1, no hints" "rc=$HOOK_RC stderr: $HOOK_ERR"
fi

# Test 7 — SKIP bypass unchanged
HOOK_RC=0
printf '%s' "fix: foo" > "${TMPDIR_ROOT}/msg.txt"
(cd "$REPO" && env -u GIT_DIR -u GIT_WORK_TREE ROBOREV_DB="$DB" SKIP_ROBOREV_VALIDATOR=1 bash "$HOOK" "${TMPDIR_ROOT}/msg.txt" >/dev/null 2>&1) || HOOK_RC=$?
if [ "$HOOK_RC" = "0" ]; then pass "test7: SKIP bypass exit 0"; else fail "test7: SKIP bypass exit 0" "rc=$HOOK_RC"; fi

# Test 8 — existing self-test still passes
if bash "$HOOK" --self-test >/dev/null 2>&1; then pass "test8: validator --self-test still passes"
else fail "test8: validator --self-test still passes"; fi

echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
[ "${FAIL}" -gt 0 ] && exit 1
exit 0
