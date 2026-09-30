#!/usr/bin/env bash
# tests/test_roborev_merge_gate_severity.sh
#
# JohnGavin/llm#1307 — .claude/scripts/roborev_merge_gate.sh must judge each open
# review by the severity of its OWN findings (reviews.structured_output), not by
# review_jobs.min_severity (the job's reporting threshold, usually '' -> 'medium'),
# and a query error / unparseable review must be INDETERMINATE, never a pass.
#
# Fixture SQLite DBs + a mock `gh` (selected via the script's GH env var).
# Also runs the script's own SELFTEST.  Exits 0 if all pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/../.claude/scripts/roborev_merge_gate.sh"
PY=/usr/bin/python3

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_gate_sev_XXXXXX)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — ${2:-}"; FAIL=$((FAIL + 1)); }

DB="${TMPDIR_ROOT}/reviews.db"
"$PY" - "$DB" <<'PYEOF'
import sqlite3, sys, json
con = sqlite3.connect(sys.argv[1])
con.executescript("""
CREATE TABLE commits (id INTEGER PRIMARY KEY, sha TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, commit_id INTEGER,
  status TEXT NOT NULL DEFAULT 'done', min_severity TEXT NOT NULL DEFAULT '');
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL,
  output TEXT NOT NULL DEFAULT '', structured_output TEXT,
  closed INTEGER NOT NULL DEFAULT 0);
""")
def v2(findings):
    return json.dumps({"schema_version": 2, "summary": "s",
                       "verdict": "fail" if findings else "pass",
                       "findings": [{"severity": s, "problem": "p", "location": "a:1", "fix": "f"}
                                    for s in findings]})
cases = {
    "LOW":       v2(["low", "low"]),          # only Lows
    "CLEAN":     v2([]),                      # ran, found nothing
    "MEDLOW":    v2(["medium", "low"]),       # one Medium + one Low
    "HIGH":      v2(["low", "high"]),
    "CRITICAL":  v2(["critical"]),
    "MALFORMED": "{not json",
    "CITED":     v2(["high"]),
}
for i, (name, so) in enumerate(cases.items(), start=1):
    sha = (name.lower() + "000000000000000000000000000000000000000")[:40]
    con.execute("INSERT INTO commits VALUES (?,?)", (i, sha))
    con.execute("INSERT INTO review_jobs (id,commit_id) VALUES (?,?)", (i, i))
    con.execute("INSERT INTO reviews (id,job_id,output,structured_output) VALUES (?,?,?,?)",
                (i, i, "", so))
con.commit()
PYEOF

sha_of() { "$PY" -c "import sys; print((sys.argv[1].lower()+'0'*40)[:40])" "$1"; }

# Mock gh: prints the SHAs in $MOCK_SHAS (one per line) for `pr view --json commits`.
MOCK_GH="${TMPDIR_ROOT}/gh"
cat > "$MOCK_GH" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--json commits"* ]]; then
  printf '%s\n' $MOCK_SHAS
fi
exit 0
EOF
chmod +x "$MOCK_GH"

EMPTY_ACKS="${TMPDIR_ROOT}/acks.jsonl"
: > "$EMPTY_ACKS"
LOG="${TMPDIR_ROOT}/gate.log"

# run_gate <db> <mode-flag> <name> [commit-msg-repo-dir]; sets OUT, RC
run_gate() {
  local db="$1" flag="$2" name="$3" repo="${4:-}"
  RC=0
  if [ -n "$repo" ]; then
    OUT=$(GH="$MOCK_GH" MOCK_SHAS="$(sha_of "$name")" ROBOREV_DB="$db" ACKS_JSONL="$EMPTY_ACKS" \
          MERGE_GATE_LOG="$LOG" GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" \
          bash "$GATE" $flag 99 2>&1) || RC=$?
  else
    OUT=$(GH="$MOCK_GH" MOCK_SHAS="$(sha_of "$name")" ROBOREV_DB="$db" ACKS_JSONL="$EMPTY_ACKS" \
          MERGE_GATE_LOG="$LOG" bash "$GATE" $flag 99 2>&1) || RC=$?
  fi
}

expect() { # <label> <verdict-tag> <enforce-exit>
  local label="$1" tag="$2" want_rc="$3" name="$4"
  run_gate "$DB" --dry-run "$name"
  if echo "$OUT" | grep -qF "[$tag]"; then pass "$label: dry-run verdict [$tag]"
  else fail "$label: dry-run verdict [$tag]" "output: $OUT"; fi
  run_gate "$DB" --enforce "$name"
  if [ "$RC" = "$want_rc" ]; then pass "$label: --enforce exit $want_rc"
  else fail "$label: --enforce exit $want_rc" "got rc=$RC output: $OUT"; fi
}

expect "Low-only review (min_severity '')"  gate-pass          0 LOW
expect "clean review (no findings)"         gate-pass          0 CLEAN
expect "Medium + Low review"                gate-warn          0 MEDLOW
expect "High review"                        gate-block         1 HIGH
expect "Critical review"                    gate-block         1 CRITICAL
expect "malformed structured_output"        gate-indeterminate 3 MALFORMED

# dry-run must never read as pass for indeterminate, and must exit 0 (documented).
run_gate "$DB" --dry-run MALFORMED
if [ "$RC" = "0" ] && ! echo "$OUT" | grep -q "gate-pass"; then
  pass "malformed: dry-run exit 0 and never says gate-pass"
else
  fail "malformed: dry-run exit 0 and never says gate-pass" "rc=$RC output: $OUT"
fi

# DB query error: file exists (passes -f) but is not SQLite.
CORRUPT="${TMPDIR_ROOT}/corrupt.db"
printf 'not a sqlite db\n' > "$CORRUPT"
run_gate "$CORRUPT" --dry-run HIGH
if echo "$OUT" | grep -q "gate-indeterminate" && ! echo "$OUT" | grep -q "gate-pass"; then
  pass "DB query error: dry-run verdict gate-indeterminate (not pass)"
else
  fail "DB query error: dry-run verdict gate-indeterminate (not pass)" "output: $OUT"
fi
run_gate "$CORRUPT" --enforce HIGH
if [ "$RC" = "3" ]; then pass "DB query error: --enforce exit 3"
else fail "DB query error: --enforce exit 3" "got rc=$RC output: $OUT"; fi

# Missing DB is also "could not ask".
run_gate "${TMPDIR_ROOT}/nope.db" --enforce HIGH
if [ "$RC" = "3" ] && echo "$OUT" | grep -q "gate-indeterminate"; then
  pass "missing DB: --enforce exit 3, gate-indeterminate"
else
  fail "missing DB: --enforce exit 3, gate-indeterminate" "got rc=$RC output: $OUT"
fi

# Citation logic still works: a High review cited via "closes roborev #7".
REPO="${TMPDIR_ROOT}/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.local
git -C "$REPO" config user.name T
echo x > "$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -q -m "fix thing (closes roborev #77)"
CITE_SHA=$(git -C "$REPO" rev-parse HEAD)
"$PY" - "$DB" "$CITE_SHA" <<'PYEOF'
import sqlite3, sys, json
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO commits VALUES (50,?)", (sys.argv[2],))
con.execute("INSERT INTO review_jobs (id,commit_id) VALUES (50,50)")
so = json.dumps({"schema_version": 2, "summary": "s", "verdict": "fail",
                 "findings": [{"severity": "high", "problem": "p"}]})
con.execute("INSERT INTO reviews (id,job_id,output,structured_output) VALUES (77,50,'',?)", (so,))
con.commit()
PYEOF
RC=0
OUT=$(GH="$MOCK_GH" MOCK_SHAS="$CITE_SHA" ROBOREV_DB="$DB" ACKS_JSONL="$EMPTY_ACKS" \
      MERGE_GATE_LOG="$LOG" GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" \
      bash "$GATE" --enforce 99 2>&1) || RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "gate-pass"; then
  pass "citation: High review cited via 'closes roborev #77' -> gate-pass, exit 0"
else
  fail "citation: High review cited via 'closes roborev #77' -> gate-pass, exit 0" "rc=$RC output: $OUT"
fi

# The script's own SELFTEST.
RC=0
OUT=$(SELFTEST=1 bash "$GATE" 2>&1) || RC=$?
if [ "$RC" = "0" ]; then pass "script SELFTEST=1 passes"
else fail "script SELFTEST=1 passes" "rc=$RC output: $OUT"; fi

echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
