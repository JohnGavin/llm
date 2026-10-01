#!/usr/bin/env bash
# tests/test_roborev_merge_gate.sh
#
# Test suite for bin/roborev_merge_gate.sh
#
# Uses:
#   - A synthetic SQLite fixture with reviews data
#   - A mock `gh` wrapper that returns preset JSON
#   - A mock git repo so commit-message parsing works
#
# Exits 0 if all tests pass, 1 on any failure.
#
# Tracked in JohnGavin/llm#241.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/../bin/roborev_merge_gate.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_merge_gate_XXXXXX)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

# ── Test helpers ─────────────────────────────────────────────────────────────

pass() { echo "PASS: $1"; (( PASS += 1 )); }
fail() { echo "FAIL: $1 — ${2:-}"; (( FAIL += 1 )); }

assert_exit() {
  local desc="$1" expected_exit="$2"
  shift 2
  local actual_exit=0
  "$@" > /dev/null 2>&1 || actual_exit=$?
  if [ "$actual_exit" = "$expected_exit" ]; then
    pass "$desc"
  else
    fail "$desc" "expected exit=$expected_exit got exit=$actual_exit"
  fi
}

assert_output_contains() {
  local desc="$1" needle="$2"
  shift 2
  local out
  out=$("$@" 2>&1) || true
  if echo "$out" | grep -qF "$needle"; then
    pass "$desc"
  else
    fail "$desc" "expected output to contain '${needle}' but got: $out"
  fi
}

# ── Fixture builder ──────────────────────────────────────────────────────────

# Creates a minimal SQLite DB at $1 with synthetic data.
# Inserts:
#   repo id=1, root_path=/tmp/fakerepo
#   commit sha=aaa001 (has HIGH finding, id=1)
#   commit sha=bbb002 (has HIGH finding, id=2, will be cited)
#   commit sha=ccc003 (has MEDIUM finding only, id=3)
#   commit sha=ddd004 (has HIGH finding, id=4, will be acked via acks.jsonl)
#   review_jobs and reviews for each
make_fixture_db() {
  local db="$1"
  /usr/bin/python3 - "$db" <<'PYEOF'
import sqlite3, sys

db = sys.argv[1]
con = sqlite3.connect(db)
cur = con.cursor()

# Minimal schema
cur.executescript("""
  CREATE TABLE repos (
    id INTEGER PRIMARY KEY,
    root_path TEXT NOT NULL,
    name TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    identity TEXT
  );
  CREATE TABLE commits (
    id INTEGER PRIMARY KEY,
    repo_id INTEGER NOT NULL,
    sha TEXT NOT NULL,
    author TEXT NOT NULL,
    subject TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
  );
  CREATE TABLE review_jobs (
    id INTEGER PRIMARY KEY,
    repo_id INTEGER NOT NULL,
    commit_id INTEGER,
    git_ref TEXT NOT NULL,
    branch TEXT,
    session_id TEXT,
    agent TEXT NOT NULL DEFAULT 'codex',
    model TEXT,
    reasoning TEXT NOT NULL DEFAULT 'thorough',
    status TEXT NOT NULL DEFAULT 'done',
    enqueued_at TEXT NOT NULL DEFAULT (datetime('now')),
    min_severity TEXT NOT NULL DEFAULT '',
    job_type TEXT NOT NULL DEFAULT 'review'
  );
  CREATE TABLE reviews (
    id INTEGER PRIMARY KEY,
    job_id INTEGER NOT NULL,
    agent TEXT NOT NULL,
    prompt TEXT NOT NULL DEFAULT '',
    output TEXT NOT NULL,
    structured_output TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    closed INTEGER NOT NULL DEFAULT 0,
    verdict_bool INTEGER DEFAULT 0
  );
""")

# Repo
cur.execute("INSERT INTO repos VALUES (1, '/tmp/fakerepo', 'fakerepo', datetime('now'), NULL)")

# Commits: sha => (id, subject)
commits = [
    (1, 'aaa001aaa001aaa001aaa001aaa001aaa001aaa001', 'Add feature A'),    # HIGH open
    (2, 'bbb002bbb002bbb002bbb002bbb002bbb002bbb002', 'Fix bug B'),         # HIGH open → will be cited
    (3, 'ccc003ccc003ccc003ccc003ccc003ccc003ccc003', 'Refactor C'),        # MEDIUM open only
    (4, 'ddd004ddd004ddd004ddd004ddd004ddd004ddd004', 'Update docs D'),     # HIGH open → will be acked
    # llm#1146 regression fixtures below
    (5, 'eee005eee005eee005eee005eee005eee005eee005', 'Fix bug E'),         # HIGH open, NON-BOLD marker
    (6, 'fff006fff006fff006fff006fff006fff006fff006', 'Touch F'),          # unparseable ("not_reviewed"), uncited
    (7, 'ggg007ggg007ggg007ggg007ggg007ggg007ggg007', 'Touch G'),          # unparseable ("not_reviewed"), will be cited
    (8, 'hhh008hhh008hhh008hhh008hhh008hhh008hhh008', 'Touch H'),          # unparseable but "passed"-shaped text
    # llm#1265 regression fixture: roborev v0.68.2 schema — `output` is
    # empty, the real finding lives in `structured_output` (v2 JSON).
    (9, 'iii009iii009iii009iii009iii009iii009iii009', 'Touch I'),          # structured_output-only, HIGH, open
    # PR #1269 round 3 regression fixture: real max severity is MEDIUM, but
    # the finding's own problem/fix prose QUOTES "Severity: High"/
    # "**Severity**: Critical" as an illustrative example — the exact shape
    # of live review ids 10523/10524 in ~/.roborev/reviews.db, which the
    # regex-over-rendered-text path misread as High/Critical.
    (10, 'jjj010jjj010jjj010jjj010jjj010jjj010jjj010', 'Touch J'),        # structured_output-only, true MEDIUM, quoted-High-in-prose
    # llm#1274 fixtures: review-job COMPLETENESS, not severity content.
    (15, 'kkk015kkk015kkk015kkk015kkk015kkk015kkk015', 'WIP: still running'),   # job status='running', no reviews row
    (16, 'lll016lll016lll016lll016lll016lll016lll016', 'Attempt review, agent crashed'), # job status='failed', no reviews row
    (17, 'mmm017mmm017mmm017mmm017mmm017mmm017mmm017', 'Totally clean change'), # job status='done', reviews row is clean
]
for cid, sha, subj in commits:
    cur.execute(
        "INSERT INTO commits VALUES (?,1,?,?,?,?,datetime('now'))",
        (cid, sha, 'author', subj, '2026-01-01T00:00:00Z')
    )

# review_jobs — status defaults to 'done' for the severity-content fixtures
# above (1-10). llm#1274 fixtures (15-17) need explicit non-default
# statuses to exercise the completeness check.
for jid, cid in [(1,1),(2,2),(3,3),(4,4),(5,5),(6,6),(7,7),(8,8),(9,9),(10,10)]:
    cur.execute(
        "INSERT INTO review_jobs (id,repo_id,commit_id,git_ref) VALUES (?,1,?,?)",
        (jid, cid, f'refs/heads/feat/test')
    )
for jid, cid, status in [(15, 15, 'running'), (16, 16, 'failed'), (17, 17, 'done')]:
    cur.execute(
        "INSERT INTO review_jobs (id,repo_id,commit_id,git_ref,status) VALUES (?,1,?,?,?)",
        (jid, cid, 'refs/heads/feat/test', status)
    )
# Commit 18 (sha only, no fixture row at all in `commits` or `review_jobs`)
# represents a PR commit roborev has never even seen — the "no_job" case
# where the commit itself is unknown to reviews.db, not just missing a
# job. See SHA_NO_JOB below; nothing is inserted for it here.

# reviews — severity is embedded in output text
HIGH_OUTPUT = """\
## Review findings

**Severity**: High
**Location**: R/foo.R:42
**Problem**: Missing input validation before division by zero.
"""
MEDIUM_OUTPUT = """\
## Review findings

**Severity**: Medium
**Location**: R/bar.R:10
**Problem**: Variable naming could be clearer.
"""
# llm#1146: the exact non-bold shape the pre-fix regex could not see. Proof
# text from the issue itself: '- Severity: High' (no ** markers).
NONBOLD_HIGH_OUTPUT = """\
## Review findings

- Severity: High
- Location: R/baz.R:7
- Problem: Off-by-one error in loop bound.
"""
# llm#1146: genuinely unparseable text — no Severity marker at all, and it
# matches roborev_classify's NOT_REVIEWED_PATTERNS, not PASSED_PATTERNS —
# so it must surface as unparseable (INDETERMINATE), never be silently
# dropped.
UNPARSEABLE_NOT_REVIEWED_OUTPUT = (
    "I am unable to read the diff file because it is ignored by "
    "configured ignore patterns."
)
# llm#1146: no Severity marker, but text matches PASSED_PATTERNS ("no
# issues found") — this is the llm#972-cause-2 DB inconsistency case
# (verdict_bool=0 recorded even though the text says nothing was found).
# It must be silently dropped, exactly like before — NOT counted as a
# finding and NOT surfaced as unparseable/indeterminate, or the gate would
# cry wolf on ordinary "no issues found" reviews.
PASSED_SHAPED_OUTPUT = "No issues found."

# llm#1265: roborev v0.68.2 schema. `output` is '' on this row; the real
# finding (HIGH) lives entirely in structured_output as v2 JSON.
V2_STRUCTURED_HIGH = (
    '{"schema_version":2,"summary":"one high finding","verdict":"fail",'
    '"findings":[{"severity":"high","problem":"Missing input validation.",'
    '"location":"R/qux.R:9","fix":"Add a guard clause."}]}'
)

# PR #1269 round 3: true max severity is MEDIUM. The finding's OWN
# problem/fix text quotes "Severity: High" and "**Severity**: Critical" as
# an illustrative example of a DIFFERENT bug it is describing — the exact
# live shape of review ids 10523/10524. A regex over the rendered markdown
# (the pre-fix behaviour) would read Critical (4); review_severity_ordinal()
# must read the JSON severity field directly and report medium (2).
V2_STRUCTURED_MEDIUM_QUOTED_HIGH = (
    '{"schema_version":2,"summary":"one medium finding, prose quotes higher '
    'severities as an example","verdict":"fail",'
    '"findings":[{"severity":"medium",'
    '"problem":"Add a fixture where output holds a real Severity: High review.",'
    '"location":"R/quux.R:5",'
    '"fix":"Emit **Severity**: Critical only when genuinely critical."}]}'
)

reviews = [
    (1, 1, HIGH_OUTPUT,   None, 0, 0),   # id=1, job=1 (aaa001), HIGH, open
    (2, 2, HIGH_OUTPUT,   None, 0, 0),   # id=2, job=2 (bbb002), HIGH, open → cited
    (3, 3, MEDIUM_OUTPUT, None, 0, 0),   # id=3, job=3 (ccc003), MEDIUM, open
    (4, 4, HIGH_OUTPUT,   None, 0, 0),   # id=4, job=4 (ddd004), HIGH, open → acked
    (5, 5, NONBOLD_HIGH_OUTPUT,             None, 0, 0),  # id=5, job=5 (eee005), HIGH non-bold, open
    (6, 6, UNPARSEABLE_NOT_REVIEWED_OUTPUT, None, 0, 0),  # id=6, job=6 (fff006), unparseable, open, uncited
    (7, 7, UNPARSEABLE_NOT_REVIEWED_OUTPUT, None, 0, 0),  # id=7, job=7 (ggg007), unparseable, open → cited
    (8, 8, PASSED_SHAPED_OUTPUT,            None, 0, 0),  # id=8, job=8 (hhh008), "passed"-shaped noise
    (9, 9, "", V2_STRUCTURED_HIGH,          0, 0),  # id=9, job=9 (iii009), v0.68.2 schema, HIGH, open
    (10, 10, "", V2_STRUCTURED_MEDIUM_QUOTED_HIGH, 0, 0),  # id=10, job=10 (jjj010), true MEDIUM, quoted-High prose, open
    # llm#1274: commit 17's job is 'done' and genuinely clean — no reviews
    # rows exist for commits 15 (running) or 16 (failed); a job that never
    # completed has no review output to insert.
    (17, 17, PASSED_SHAPED_OUTPUT,           None, 0, 0),  # id=17, job=17 (mmm017), done + clean
]
for rid, jid, out, structured, closed, verdict in reviews:
    cur.execute(
        "INSERT INTO reviews (id,job_id,agent,output,structured_output,closed,verdict_bool) VALUES (?,?,'codex',?,?,?,?)",
        (rid, jid, out, structured, closed, verdict)
    )

con.commit()
con.close()
PYEOF
}

# Creates a minimal git repo with commits corresponding to our fixture SHAs.
# Because we can't control git's SHA, we instead create a git repo and then
# create commit-message files separately for the citation parser.
# The test injects commit messages directly via a mock git log wrapper.
make_git_repo() {
  local dir="$1"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "Test"
  echo "init" > "$dir/README"
  git -C "$dir" add README
  git -C "$dir" commit -qm "init" 2>/dev/null
}

# Write a mock `gh` script to $1/gh that echoes preset JSON.
# $2 = JSON array of commit oid strings
make_mock_gh() {
  local bin_dir="$1"
  local commits_json="$2"
  cat > "$bin_dir/gh" <<MOCKEOF
#!/usr/bin/env bash
# Mock gh that echoes preset commit SHAs for 'pr view'
if [[ "\$*" == *"--json commits"* ]]; then
  # gh pr view <n> --repo <r> --json commits --jq '.commits[].oid'
  echo '${commits_json}' | /usr/bin/python3 -c "
import sys, json
data = json.load(sys.stdin)
for oid in data:
    print(oid)
"
  exit 0
fi
# gh repo view
if [[ "\$*" == *"nameWithOwner"* ]]; then
  echo "JohnGavin/fakerepo"
  exit 0
fi
exit 0
MOCKEOF
  chmod +x "$bin_dir/gh"
}

# ── Build shared fixtures ─────────────────────────────────────────────────────

FIXTURE_DIR="${TMPDIR_ROOT}/fixture"
mkdir -p "$FIXTURE_DIR"

FIXTURE_DB="${FIXTURE_DIR}/reviews.db"
make_fixture_db "$FIXTURE_DB"

GIT_REPO="${FIXTURE_DIR}/repo"
mkdir -p "$GIT_REPO"
make_git_repo "$GIT_REPO"

# SHA values matching DB
SHA_HIGH_OPEN="aaa001aaa001aaa001aaa001aaa001aaa001aaa001"
SHA_HIGH_CITED="bbb002bbb002bbb002bbb002bbb002bbb002bbb002"
SHA_MEDIUM_ONLY="ccc003ccc003ccc003ccc003ccc003ccc003ccc003"
SHA_HIGH_ACKED="ddd004ddd004ddd004ddd004ddd004ddd004ddd004"
# llm#1146 regression fixtures
SHA_HIGH_NONBOLD="eee005eee005eee005eee005eee005eee005eee005"
SHA_UNPARSEABLE_OPEN="fff006fff006fff006fff006fff006fff006fff006"
SHA_UNPARSEABLE_CITED="ggg007ggg007ggg007ggg007ggg007ggg007ggg007"
SHA_PASSED_SHAPED="hhh008hhh008hhh008hhh008hhh008hhh008hhh008"
# llm#1265: roborev v0.68.2 schema — output='' but structured_output carries
# a real HIGH finding as v2 JSON.
SHA_V2_STRUCTURED_HIGH="iii009iii009iii009iii009iii009iii009iii009"
# PR #1269 round 3: true severity MEDIUM, problem/fix prose quotes a higher
# severity as an example (review ids 10523/10524 live shape).
SHA_V2_STRUCTURED_MEDIUM_QUOTED_HIGH="jjj010jjj010jjj010jjj010jjj010jjj010jjj010"
# llm#1274: review-job COMPLETENESS fixtures (severity content is
# irrelevant to these — none of them have a completed review at all).
SHA_JOB_RUNNING="kkk015kkk015kkk015kkk015kkk015kkk015kkk015"
SHA_JOB_FAILED="lll016lll016lll016lll016lll016lll016lll016"
SHA_ALL_CLEAN="mmm017mmm017mmm017mmm017mmm017mmm017mmm017"
# Not present ANYWHERE in the fixture DB (no commits row, no review_jobs
# row) — the "roborev has never even seen this commit" case.
SHA_NO_JOB="nnn018nnn018nnn018nnn018nnn018nnn018nnn018"

# Acks file
ACKS_FILE="${FIXTURE_DIR}/acks.jsonl"
printf '{"id":4,"reason":"false positive — test fixture","pr":99,"acked_at":"2026-01-01T00:00:00","acked_by":"test"}\n' \
  > "$ACKS_FILE"

# ── Helper to run the gate in an isolated env ─────────────────────────────────
# Takes: mock_gh_dir commits_json cited_msg test_name expected_exit
run_gate() {
  local bin_dir="$1"     # directory with mock gh
  local commits_json="$2"  # JSON array
  local cite_msg="$3"    # commit message text (or empty) to inject
  local args_after="$4"  # extra args to gate (e.g. "--min-severity Medium")
  local expected_exit="$5"
  local test_name="$6"

  make_mock_gh "$bin_dir" "$commits_json"

  # If we have a citation message, put it in a git commit on our test repo
  # so git log can read it.  We create a new file each time to force a commit.
  local git_sha=""
  if [ -n "$cite_msg" ]; then
    local tmpfile
    tmpfile=$(mktemp "${GIT_REPO}/cite_XXXXXX")
    echo "$cite_msg" > "$tmpfile"
    git -C "$GIT_REPO" add "$(basename "$tmpfile")" 2>/dev/null
    git -C "$GIT_REPO" commit -qm "$cite_msg" 2>/dev/null
    git_sha=$(git -C "$GIT_REPO" rev-parse HEAD 2>/dev/null)

    # llm#1274: this scaffold commit exists ONLY so _parse_citations can
    # find the citation text via `git log` — it is not meant to represent
    # a real PR commit under the new review-completeness check added in
    # this round. Without a "done" job of its own, every test that uses a
    # citation message would now ALSO see this commit as "no_job" (roborev
    # never reviewed the fixture's scaffold text) and INDETERMINATE would
    # mask the PASS/BLOCK verdict the test actually exercises. Mark it
    # reviewed-and-clean so it never affects the completeness check.
    if [ -n "$git_sha" ]; then
      /usr/bin/python3 - "$FIXTURE_DB" "$git_sha" <<'PYEOF'
import sqlite3, sys
db, sha = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute("SELECT id FROM commits WHERE sha=?", (sha,))
if cur.fetchone() is None:
    cid = cur.execute("SELECT COALESCE(MAX(id),0)+1 FROM commits").fetchone()[0]
    cur.execute(
        "INSERT INTO commits (id,repo_id,sha,author,subject,timestamp) "
        "VALUES (?,1,?,'test','scaffold citation commit','2026-01-01T00:00:00Z')",
        (cid, sha),
    )
    jid = cur.execute("SELECT COALESCE(MAX(id),0)+1 FROM review_jobs").fetchone()[0]
    cur.execute(
        "INSERT INTO review_jobs (id,repo_id,commit_id,git_ref,status) "
        "VALUES (?,1,?,'refs/heads/feat/test','done')",
        (jid, cid),
    )
    con.commit()
con.close()
PYEOF
    fi
  fi

  # Build the SHA list including real git SHA if we have it
  local shas_list
  shas_list=$(echo "$commits_json" | /usr/bin/python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data:
    print(s)
")
  # Add the real git SHA so _parse_citations can find the commit message
  if [ -n "$git_sha" ]; then
    shas_list="${shas_list}"$'\n'"${git_sha}"
  fi

  # Create a per-test mock gh that outputs both DB shas AND the real git sha
  # (for commit-message parsing)
  local all_shas_json
  all_shas_json=$(echo "$shas_list" | /usr/bin/python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps(lines))
")
  make_mock_gh "$bin_dir" "$all_shas_json"

  local actual_exit=0
  local out
  out=$(
    GH="$bin_dir/gh" \
    ROBOREV_DB="$FIXTURE_DB" \
    ACKS_JSONL="$ACKS_FILE" \
    GIT_DIR="$GIT_REPO/.git" \
    GIT_WORK_TREE="$GIT_REPO" \
      bash "$GATE" $args_after 99 2>&1
  ) || actual_exit=$?

  if [ "$actual_exit" = "$expected_exit" ]; then
    pass "$test_name"
  else
    fail "$test_name" "expected exit=${expected_exit} got=${actual_exit} | output: ${out}"
  fi
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# Test 1 — PR with no commits → exit 0 (fail-open)
BIN1="${TMPDIR_ROOT}/bin1"
mkdir -p "$BIN1"
cat > "$BIN1/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--json commits"* ]]; then exit 0; fi
if [[ "$*" == *"nameWithOwner"* ]]; then echo "JohnGavin/fakerepo"; fi
exit 0
EOF
chmod +x "$BIN1/gh"

actual_exit=0
GH="$BIN1/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
  bash "$GATE" 99 2>/dev/null || actual_exit=$?
if [ "$actual_exit" = "0" ]; then
  pass "test1: gh answers 'no commits' → exit 0 (real negative, not fail-open)"
else
  fail "test1: gh answers 'no commits' → exit 0 (real negative, not fail-open)" "got exit=$actual_exit"
fi

# Test 2 — PR with open HIGH finding, no citation → exit 1 (BLOCK)
BIN2="${TMPDIR_ROOT}/bin2"
mkdir -p "$BIN2"
run_gate "$BIN2" \
  "[\"${SHA_HIGH_OPEN}\"]" \
  "" \
  "--min-severity High" \
  "1" \
  "test2: open HIGH finding uncited → exit 1 (BLOCK)"

# Test 3 — PR with open HIGH finding cited via 'closes roborev #1' → exit 0 (PASS)
BIN3="${TMPDIR_ROOT}/bin3"
mkdir -p "$BIN3"
run_gate "$BIN3" \
  "[\"${SHA_HIGH_CITED}\"]" \
  "closes roborev #2" \
  "--min-severity High" \
  "0" \
  "test3: open HIGH finding cited via closes roborev #2 → exit 0 (PASS)"

# Test 4 — PR with open HIGH finding acked via acks.jsonl → exit 0 (PASS)
# finding id=4 is in acks.jsonl
BIN4="${TMPDIR_ROOT}/bin4"
mkdir -p "$BIN4"
run_gate "$BIN4" \
  "[\"${SHA_HIGH_ACKED}\"]" \
  "" \
  "--min-severity High" \
  "0" \
  "test4: open HIGH finding acked via acks.jsonl → exit 0 (PASS)"

# Test 5 — PR with MEDIUM-only finding, threshold=High → exit 0 (below threshold)
BIN5="${TMPDIR_ROOT}/bin5"
mkdir -p "$BIN5"
run_gate "$BIN5" \
  "[\"${SHA_MEDIUM_ONLY}\"]" \
  "" \
  "--min-severity High" \
  "0" \
  "test5: MEDIUM-only finding below High threshold → exit 0"

# Test 6 — syntax check
bash_n_exit=0
bash -n "$GATE" 2>/dev/null || bash_n_exit=$?
if [ "$bash_n_exit" = "0" ]; then
  pass "test6: bash -n syntax check passes"
else
  fail "test6: bash -n syntax check passes" "bash -n exited $bash_n_exit"
fi

# Test 7 — --json flag emits JSON with verdict=pass when no unresolved findings
BIN7="${TMPDIR_ROOT}/bin7"
mkdir -p "$BIN7"
make_mock_gh "$BIN7" "[\"${SHA_MEDIUM_ONLY}\"]"

json_out=""
json_exit=0
json_out=$(
  GH="$BIN7/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --json --min-severity High 99 2>&1
) || json_exit=$?

if echo "$json_out" | /usr/bin/python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('verdict') == 'pass', f'verdict={d.get(\"verdict\")}'
" 2>/dev/null; then
  pass "test7: --json emits verdict=pass"
else
  fail "test7: --json emits verdict=pass" "got: $json_out"
fi

# Test 8 — --json flag emits JSON with verdict=block when open findings
BIN8="${TMPDIR_ROOT}/bin8"
mkdir -p "$BIN8"
make_mock_gh "$BIN8" "[\"${SHA_HIGH_OPEN}\"]"

json_out8=""
json_exit8=0
json_out8=$(
  GH="$BIN8/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --json --min-severity High 99 2>&1
) || json_exit8=$?

if echo "$json_out8" | /usr/bin/python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('verdict') == 'block', f'verdict={d.get(\"verdict\")}'
assert d.get('unresolved_count', 0) > 0
" 2>/dev/null; then
  pass "test8: --json emits verdict=block with unresolved_count>0"
else
  fail "test8: --json emits verdict=block with unresolved_count>0" "got: $json_out8"
fi

# ═══════════════════════════════════════════════════════════════════════════
# llm#1012 — "could not ask" must not exit like "nothing to report"
# ═══════════════════════════════════════════════════════════════════════════
#
# Every test below drives the gate into a state where it CANNOT reach
# reviews.db, and asserts two things each time:
#   (a) the exit code is 3, not 0
#   (b) the word PASS does not appear in the output
#
# (b) matters independently of (a).  The bug that shipped was readable on
# screen — `merge-gate: PASS (no commits found — fail-open)` — long before
# anyone looked at $?.  A future refactor that returns 3 while still printing
# "PASS" would re-create the failure for every human reader.

# Test 9 — gh binary does not exist (the llm#1012 headline case).
BIN9="${TMPDIR_ROOT}/bin9"
mkdir -p "$BIN9"
out9=""
exit9=0
out9=$(
  GH="/nonexistent/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo 99 2>&1
) || exit9=$?

if [ "$exit9" = "3" ]; then
  pass "test9: missing gh binary → exit 3 (INDETERMINATE)"
else
  fail "test9: missing gh binary → exit 3 (INDETERMINATE)" "got exit=$exit9 | output: $out9"
fi

if echo "$out9" | grep -q "PASS"; then
  fail "test9b: missing gh binary output must not contain 'PASS'" "output: $out9"
else
  pass "test9b: missing gh binary output must not contain 'PASS'"
fi

# Test 10 — gh exists but fails at runtime (auth rejected / network down).
# This is the shape a stale GH_TOKEN produces, and it is NOT covered by
# fixing the path alone.
BIN10="${TMPDIR_ROOT}/bin10"
mkdir -p "$BIN10"
cat > "$BIN10/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh that always fails the way a revoked token does.
echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2
exit 1
EOF
chmod +x "$BIN10/gh"

out10=""
exit10=0
out10=$(
  GH="$BIN10/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo 99 2>&1
) || exit10=$?

if [ "$exit10" = "3" ]; then
  pass "test10: gh exits non-zero (401) → exit 3 (INDETERMINATE)"
else
  fail "test10: gh exits non-zero (401) → exit 3 (INDETERMINATE)" "got exit=$exit10 | output: $out10"
fi

if echo "$out10" | grep -q "PASS"; then
  fail "test10b: gh-failure output must not contain 'PASS'" "output: $out10"
else
  pass "test10b: gh-failure output must not contain 'PASS'"
fi

# The failure REASON must reach the operator.  Without it the message says
# "could not evaluate" and leaves them to guess which of four causes it was;
# with it, the 401 names the revoked token directly.  This regressed once
# already during development (the reason was set inside a command-substitution
# subshell and never escaped), so it is asserted rather than assumed.
if echo "$out10" | grep -q "Bad credentials"; then
  pass "test10c: gh's own error text is surfaced in the reason"
else
  fail "test10c: gh's own error text is surfaced in the reason" "output: $out10"
fi

# Test 11 — reviews.db absent is also "could not ask", not "no findings".
BIN11="${TMPDIR_ROOT}/bin11"
mkdir -p "$BIN11"
make_mock_gh "$BIN11" "[\"${SHA_HIGH_OPEN}\"]"

out11=""
exit11=0
out11=$(
  GH="$BIN11/gh" ROBOREV_DB="${TMPDIR_ROOT}/no_such_reviews.db" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo 99 2>&1
) || exit11=$?

if [ "$exit11" = "3" ]; then
  pass "test11: reviews.db absent → exit 3 (INDETERMINATE)"
else
  fail "test11: reviews.db absent → exit 3 (INDETERMINATE)" "got exit=$exit11 | output: $out11"
fi

if echo "$out11" | grep -q "PASS"; then
  fail "test11b: db-absent output must not contain 'PASS'" "output: $out11"
else
  pass "test11b: db-absent output must not contain 'PASS'"
fi

# Test 12 — MERGE_GATE_FAIL_OPEN=1 downgrades the exit but NOT the wording.
# Fail-open stays available for callers that want it; what it must never do is
# become indistinguishable from a real pass again.
out12=""
exit12=0
out12=$(
  MERGE_GATE_FAIL_OPEN=1 GH="/nonexistent/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo 99 2>&1
) || exit12=$?

if [ "$exit12" = "0" ]; then
  pass "test12: MERGE_GATE_FAIL_OPEN=1 downgrades exit 3 → 0"
else
  fail "test12: MERGE_GATE_FAIL_OPEN=1 downgrades exit 3 → 0" "got exit=$exit12 | output: $out12"
fi

if echo "$out12" | grep -q "INDETERMINATE"; then
  pass "test12b: fail-open still says INDETERMINATE, never PASS"
else
  fail "test12b: fail-open still says INDETERMINATE, never PASS" "output: $out12"
fi

# Test 13 — --json carries the indeterminate verdict too, so scripted callers
# see it as clearly as humans do.
out13=""
exit13=0
out13=$(
  GH="/nonexistent/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --json --repo JohnGavin/fakerepo 99 2>&1
) || exit13=$?

if echo "$out13" | /usr/bin/python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert d.get('verdict') == 'indeterminate', d.get('verdict')
assert d.get('failed_open') is False
" 2>/dev/null; then
  pass "test13: --json emits verdict=indeterminate"
else
  fail "test13: --json emits verdict=indeterminate" "got: $out13"
fi

# Test 14 — the control.  With everything working the gate must still reach a
# real verdict; otherwise tests 9-13 could be satisfied by a gate that has
# simply stopped working altogether.
BIN14="${TMPDIR_ROOT}/bin14"
mkdir -p "$BIN14"
make_mock_gh "$BIN14" "[\"${SHA_HIGH_OPEN}\"]"

out14=""
exit14=0
out14=$(
  GH="$BIN14/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo --min-severity High 99 2>&1
) || exit14=$?

if [ "$exit14" = "1" ]; then
  pass "test14 (control): working gh + real finding → exit 1 (BLOCK)"
else
  fail "test14 (control): working gh + real finding → exit 1 (BLOCK)" "got exit=$exit14 | output: $out14"
fi

# ═══════════════════════════════════════════════════════════════════════════
# JohnGavin/llm#1146 — non-bold "Severity: High" must not be invisible to
# the gate, and an unresolved unparseable severity must be INDETERMINATE
# (exit 3), never a silent PASS.
# ═══════════════════════════════════════════════════════════════════════════

# Test 15 — the exact regression: a NON-BOLD "- Severity: High" marker,
# uncited. Before llm#1146 the gate's inline regex required "**Severity**:"
# and silently skipped this row ("conservative: don't block on
# unparseable") -- so this test is RED against the pre-fix script (see the
# falsification block below) and must be GREEN (exit 1, BLOCK) against the
# fix.
BIN15="${TMPDIR_ROOT}/bin15"
mkdir -p "$BIN15"
run_gate "$BIN15" \
  "[\"${SHA_HIGH_NONBOLD}\"]" \
  "" \
  "--min-severity High" \
  "1" \
  "test15: non-bold 'Severity: High' uncited → exit 1 (BLOCK, was invisible pre-#1146)"

# Test 16 — a genuinely unparseable severity (no marker at all, and the
# text matches roborev_classify's NOT_REVIEWED shape, not the PASSED
# shape), uncited. Must be INDETERMINATE (exit 3), never absorbed into
# "no findings at this severity" (which would print exit 0/PASS).
BIN16="${TMPDIR_ROOT}/bin16"
mkdir -p "$BIN16"
run_gate "$BIN16" \
  "[\"${SHA_UNPARSEABLE_OPEN}\"]" \
  "" \
  "--min-severity High" \
  "3" \
  "test16: unparseable severity, uncited → exit 3 (INDETERMINATE)"

# Confirm the message distinguishes "could not parse" from "no findings",
# and that the word PASS never appears next to it (same discipline as
# tests 9b/10b/11b for the llm#1012 cases).
out16=""
out16=$(
  GH="$BIN16/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo --min-severity High 99 2>&1
) || true
if echo "$out16" | grep -q "PASS"; then
  fail "test16b: unparseable-severity output must not contain 'PASS'" "output: $out16"
else
  pass "test16b: unparseable-severity output must not contain 'PASS'"
fi
if echo "$out16" | grep -q "could not parse"; then
  pass "test16c: message says severity could not be parsed (not 'no findings')"
else
  fail "test16c: message says severity could not be parsed (not 'no findings')" "output: $out16"
fi

# Test 17 — the same unparseable shape, but explicitly resolved via
# "closes roborev #7". Citation/ack resolution must apply to unparseable
# findings exactly as it does to parseable ones -- an operator who has
# already addressed the finding is not blocked by the gate's inability to
# parse a severity word out of text they've already handled.
BIN17="${TMPDIR_ROOT}/bin17"
mkdir -p "$BIN17"
run_gate "$BIN17" \
  "[\"${SHA_UNPARSEABLE_CITED}\"]" \
  "closes roborev #7" \
  "--min-severity High" \
  "0" \
  "test17: unparseable severity, cited via closes roborev #7 → exit 0 (PASS)"

# Test 18 — "no issues found" text (the llm#972-cause-2 DB-inconsistency
# shape: verdict_bool=0 recorded despite text saying nothing was found).
# Must be silently dropped exactly as before -- NOT a finding, NOT
# indeterminate. A gate that cries wolf on ordinary clean reviews gets
# bypassed (verification-before-completion's "too loud is also broken").
BIN18="${TMPDIR_ROOT}/bin18"
mkdir -p "$BIN18"
run_gate "$BIN18" \
  "[\"${SHA_PASSED_SHAPED}\"]" \
  "" \
  "--min-severity High" \
  "0" \
  "test18: 'no issues found' text (verdict_bool=0 noise) → exit 0 (PASS, not INDETERMINATE)"

# Test 19 — llm#1265: roborev v0.68.2 schema migration. `output` is empty on
# this row; the real HIGH finding lives entirely in `structured_output` (v2
# JSON). Uncited/unacked → the gate must reach a REAL verdict (BLOCK, exit 1)
# via the shared review_output_text() reader, NOT fall through to
# INDETERMINATE (exit 3) the way it did before this fix landed (the bug
# llm#1265 exists to close: bin/roborev_merge_gate.sh 1264 returned
# INDETERMINATE/unparseable_severity for exactly this shape on the live DB).
BIN19="${TMPDIR_ROOT}/bin19"
mkdir -p "$BIN19"
run_gate "$BIN19" \
  "[\"${SHA_V2_STRUCTURED_HIGH}\"]" \
  "" \
  "--min-severity High" \
  "1" \
  "test19: v2 structured_output-only HIGH finding, uncited → exit 1 (BLOCK, a real verdict — not INDETERMINATE)"

# Test 19b — same fixture, cited via 'closes roborev #9' → exit 0 (PASS).
# Confirms the structured_output path reaches an ordinary resolvable
# verdict, not just a block.
run_gate "$BIN19" \
  "[\"${SHA_V2_STRUCTURED_HIGH}\"]" \
  "fix: thing (closes roborev #9)" \
  "--min-severity High" \
  "0" \
  "test19b: v2 structured_output-only HIGH finding, cited via closes roborev #9 → exit 0 (PASS)"

# Test 20 — llm#1265 finding 7: the BLOCK-listing path (_print_table) must
# render its table without ever raising a Python-level crash. Reuses the
# test19 BLOCK scenario (v2 structured_output HIGH finding, uncited) but
# captures and inspects the raw output text directly, rather than only the
# exit code — a regression here previously crashed with "SyntaxError:
# 'return' outside function" right after printing the BLOCK summary line
# (reproduced live before this fix: `bin/roborev_merge_gate.sh --repo
# JohnGavin/llm --min-severity Medium 1269`). `return` at Python module top
# level is a COMPILE-time SyntaxError, so it fired regardless of whether
# the `if not findings:` branch it sat in was actually taken.
BIN20="${TMPDIR_ROOT}/bin20"
mkdir -p "$BIN20"
make_mock_gh "$BIN20" "[\"${SHA_V2_STRUCTURED_HIGH}\"]"
out20=$(
  GH="$BIN20/gh" \
  ROBOREV_DB="$FIXTURE_DB" \
  ACKS_JSONL="$ACKS_FILE" \
  GIT_DIR="$GIT_REPO/.git" \
  GIT_WORK_TREE="$GIT_REPO" \
    bash "$GATE" --min-severity High 99 2>&1
) || true
if echo "$out20" | grep -qE "Traceback|SyntaxError"; then
  fail "test20: BLOCK-listing output must not contain a Python Traceback/SyntaxError" "output: $out20"
else
  pass "test20: BLOCK-listing output must not contain a Python Traceback/SyntaxError"
fi
if echo "$out20" | grep -q "BLOCK"; then
  pass "test20b: BLOCK-listing reaches a real BLOCK verdict"
else
  fail "test20b: BLOCK-listing reaches a real BLOCK verdict" "output: $out20"
fi
if echo "$out20" | grep -qE "ID +Severity"; then
  pass "test20c: BLOCK-listing table header actually rendered (proves _print_table ran to completion, not just that it didn't crash)"
else
  fail "test20c: BLOCK-listing table header actually rendered (proves _print_table ran to completion, not just that it didn't crash)" "output: $out20"
fi

# Test 21 — PR #1269 round 3 (the headline bug this round fixes): a finding
# whose real max severity is MEDIUM, but whose own problem/fix prose quotes
# "Severity: High"/"**Severity**: Critical" as an illustrative example, must
# NOT be read as High/Critical. At --min-severity High (above the true
# severity) this must PASS (exit 0) — before the fix, the regex-over-
# rendered-text path read Critical from the quoted example text and BLOCKed.
BIN21="${TMPDIR_ROOT}/bin21"
mkdir -p "$BIN21"
run_gate "$BIN21" \
  "[\"${SHA_V2_STRUCTURED_MEDIUM_QUOTED_HIGH}\"]" \
  "" \
  "--min-severity High" \
  "0" \
  "test21: v2 finding, real severity Medium but problem/fix prose quotes High/Critical → exit 0 (PASS, not inflated)"

# Test 21b — same fixture, at --min-severity Medium (AT the true severity)
# must BLOCK — proves the real medium severity is still correctly detected
# and used for the threshold comparison, not silently dropped to "no
# severity found" while fixing the inflation bug.
run_gate "$BIN21" \
  "[\"${SHA_V2_STRUCTURED_MEDIUM_QUOTED_HIGH}\"]" \
  "" \
  "--min-severity Medium" \
  "1" \
  "test21b: same fixture at --min-severity Medium → exit 1 (BLOCK, true medium severity correctly detected)"

# Test 21c — the BLOCK-listing table (at Medium threshold) must show
# "Medium" as the severity, and the finding's REAL location/problem (JSON-
# direct via review_top_finding()), never a location/problem harvested from
# the quoted example markers inside the finding's own problem/fix text.
out21c=$(
  GH="$BIN21/gh" \
  ROBOREV_DB="$FIXTURE_DB" \
  ACKS_JSONL="$ACKS_FILE" \
  GIT_DIR="$GIT_REPO/.git" \
  GIT_WORK_TREE="$GIT_REPO" \
    bash "$GATE" --min-severity Medium 99 2>&1
) || true
if echo "$out21c" | grep -q "Medium"; then
  pass "test21c: BLOCK-listing shows severity=Medium (JSON-direct, not inflated)"
else
  fail "test21c: BLOCK-listing shows severity=Medium (JSON-direct, not inflated)" "output: $out21c"
fi
if echo "$out21c" | grep -q "R/quux.R:5"; then
  pass "test21d: BLOCK-listing shows the REAL location (R/quux.R:5) from JSON, not a corrupted regex match"
else
  fail "test21d: BLOCK-listing shows the REAL location (R/quux.R:5) from JSON, not a corrupted regex match" "output: $out21c"
fi

# ═══════════════════════════════════════════════════════════════════════════
# JohnGavin/llm#1267 "Also found" — a reviews.db QUERY failure (the file
# EXISTS, but the SELECT itself raises: locked, corrupt, schema drift) must
# be INDETERMINATE (exit 3), never a silent PASS. Distinct from test11
# (db_absent — the file does not exist at all, caught by _main()'s `-f`
# check BEFORE the query ever runs); this exercises the `except Exception`
# inside _query_open_findings's own SQL query, which used to print
# `{"findings":[],"unparseable":[]}` and exit 0 ("fail-open: DB error →
# pass gate") — collapsing "could not ask the question" into "the answer is
# clean", exactly the shape checks-must-distinguish-unknown forbids.
# ═══════════════════════════════════════════════════════════════════════════

# Test 22 — a reviews.db that EXISTS but is not a valid SQLite file (passes
# the `-f` preflight, then sqlite3 raises DatabaseError on the SELECT).
CORRUPT_DB="${TMPDIR_ROOT}/corrupt_reviews.db"
printf 'not a real sqlite database, but a real file\n' > "$CORRUPT_DB"

BIN22="${TMPDIR_ROOT}/bin22"
mkdir -p "$BIN22"
make_mock_gh "$BIN22" "[\"${SHA_HIGH_OPEN}\"]"

out22=""
exit22=0
out22=$(
  GH="$BIN22/gh" ROBOREV_DB="$CORRUPT_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo 99 2>&1
) || exit22=$?

if [ "$exit22" = "3" ]; then
  pass "test22: reviews.db query failure (corrupt file) → exit 3 (INDETERMINATE)"
else
  fail "test22: reviews.db query failure (corrupt file) → exit 3 (INDETERMINATE)" "got exit=$exit22 | output: $out22"
fi

if echo "$out22" | grep -q "PASS"; then
  fail "test22b: db-query-failure output must not contain 'PASS'" "output: $out22"
else
  pass "test22b: db-query-failure output must not contain 'PASS'"
fi

# The failure reason must reach the operator (same discipline as test10c for
# the gh-401 case) — otherwise "could not evaluate" leaves them guessing
# among db_absent/gh_unavailable/db_query_failed/etc.
if echo "$out22" | grep -q "reviews.db query failed"; then
  pass "test22c: db-query-failure reason is surfaced to the operator"
else
  fail "test22c: db-query-failure reason is surfaced to the operator" "output: $out22"
fi

# Test 22d — MERGE_GATE_FAIL_OPEN=1 downgrades this exit too, same as test12
# for db_absent — the escape hatch is uniform across every INDETERMINATE
# cause, not special-cased per reason.
out22d=""
exit22d=0
out22d=$(
  MERGE_GATE_FAIL_OPEN=1 GH="$BIN22/gh" ROBOREV_DB="$CORRUPT_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo 99 2>&1
) || exit22d=$?

if [ "$exit22d" = "0" ] && echo "$out22d" | grep -q "INDETERMINATE"; then
  pass "test22d: MERGE_GATE_FAIL_OPEN=1 downgrades exit 3 → 0, but still says INDETERMINATE (never PASS)"
else
  fail "test22d: MERGE_GATE_FAIL_OPEN=1 downgrades exit 3 → 0, but still says INDETERMINATE (never PASS)" "got exit=$exit22d | output: $out22d"
fi

# Falsification (verification-before-completion: a check must be shown red
# before it is trusted green). Run the SAME corrupt-DB fixture against the
# script as it existed at HEAD — i.e. before this fix's edits to the
# `except Exception` block inside _query_open_findings. Confirmed manually
# during development: HEAD (d1ece921, JohnGavin/llm#1273) prints
# "merge-gate: PASS (no unresolved High-severity findings)" and exits 0 on
# this exact fixture — reproducing the "Also found" bug in llm#1267 exactly.
# This block is not run automatically (a moving HEAD would make it meaningless
# once this fix is committed); it is recorded here as the falsification
# evidence for test22, run once by hand:
#   git show HEAD:bin/roborev_merge_gate.sh > /tmp/pre_fix_gate.sh
#   GH="$BIN22/gh" ROBOREV_DB="$CORRUPT_DB" ACKS_JSONL="$ACKS_FILE" \
#     bash /tmp/pre_fix_gate.sh --repo JohnGavin/fakerepo 99
#   # -> exit 0, "merge-gate: PASS ..." (RED — confirms test22 exercises the
#   #    real fix, not a check that was always green)

# ═══════════════════════════════════════════════════════════════════════════
# JohnGavin/llm#1274 — a commit with no completed roborev review must be
# INDETERMINATE, never a silent PASS. On 2026-09-25 `bin/roborev_merge_gate.sh
# 1269` returned PASS while roborev was still reviewing the PR's only commit
# (job 13649, status running); that review then failed with a High finding.
# A missing review produced zero rows from the findings query — identical
# to a genuinely clean review.
# ═══════════════════════════════════════════════════════════════════════════

# Test 23 — a PR commit whose only review_jobs row is still 'running',
# uncited. Must be INDETERMINATE (exit 3), never PASS.
BIN23="${TMPDIR_ROOT}/bin23"
mkdir -p "$BIN23"
run_gate "$BIN23" \
  "[\"${SHA_JOB_RUNNING}\"]" \
  "" \
  "--min-severity High" \
  "3" \
  "test23: PR commit with a running review job, uncited → exit 3 (INDETERMINATE)"

out23=$(
  GH="$BIN23/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo --min-severity High 99 2>&1
) || true
if echo "$out23" | grep -q "review_pending"; then
  pass "test23b: message names the reason review_pending"
else
  fail "test23b: message names the reason review_pending" "output: $out23"
fi
if echo "$out23" | grep -q "PASS"; then
  fail "test23c: running-job output must not contain 'PASS'" "output: $out23"
else
  pass "test23c: running-job output must not contain 'PASS'"
fi

# Falsification (verification-before-completion: a check must be shown red
# before it is trusted green). Run the SAME fixture (commit 15, job status
# 'running', no reviews row) against the script as it existed at HEAD --
# i.e. before this round's _query_review_completeness addition. Confirmed
# manually during development against the PR #1275 branch tip
# (bin/roborev_merge_gate.sh with no completeness check): the pre-fix
# script prints "merge-gate: PASS (no unresolved High-severity findings)"
# and exits 0 on this exact fixture -- reproducing the #1269 bug exactly.
# Reproduce by hand:
#   git show origin/fix/merge-gate-db-error-indeterminate:bin/roborev_merge_gate.sh \
#     > /tmp/pre_fix_gate.sh
#   GH="$BIN23/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
#     bash /tmp/pre_fix_gate.sh --repo JohnGavin/fakerepo --min-severity High 99
#   # -> exit 0, "merge-gate: PASS ..." (RED)

# Test 24 — a PR commit roborev has never even seen: no row in `commits`,
# no row in `review_jobs`. Must be INDETERMINATE (exit 3), reason
# review_pending (status "no_job"), never PASS.
BIN24="${TMPDIR_ROOT}/bin24"
mkdir -p "$BIN24"
run_gate "$BIN24" \
  "[\"${SHA_NO_JOB}\"]" \
  "" \
  "--min-severity High" \
  "3" \
  "test24: PR commit with no review_jobs row at all → exit 3 (INDETERMINATE)"

out24=$(
  GH="$BIN24/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo --min-severity High 99 2>&1
) || true
if echo "$out24" | grep -q "review_pending"; then
  pass "test24b: message names the reason review_pending"
else
  fail "test24b: message names the reason review_pending" "output: $out24"
fi
if echo "$out24" | grep -q "no_job"; then
  pass "test24c: detail names the no_job status"
else
  fail "test24c: detail names the no_job status" "output: $out24"
fi

# Test 25 — a PR commit whose only review attempt 'failed' (the agent
# crashed / hit a quota). The commit is effectively unreviewed and must be
# INDETERMINATE (exit 3), reason review_failed, never PASS.
BIN25="${TMPDIR_ROOT}/bin25"
mkdir -p "$BIN25"
run_gate "$BIN25" \
  "[\"${SHA_JOB_FAILED}\"]" \
  "" \
  "--min-severity High" \
  "3" \
  "test25: PR commit whose only review attempt failed, uncited → exit 3 (INDETERMINATE)"

out25=$(
  GH="$BIN25/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
    bash "$GATE" --repo JohnGavin/fakerepo --min-severity High 99 2>&1
) || true
if echo "$out25" | grep -q "review_failed"; then
  pass "test25b: message names the reason review_failed"
else
  fail "test25b: message names the reason review_failed" "output: $out25"
fi
if echo "$out25" | grep -q "PASS"; then
  fail "test25c: failed-job output must not contain 'PASS'" "output: $out25"
else
  pass "test25c: failed-job output must not contain 'PASS'"
fi

# Test 26 (control) — a PR commit whose review job is 'done' and genuinely
# clean (no findings at all — not just below threshold). With the
# completeness check now running BEFORE the findings query, this control
# proves the new check does not itself block a real clean PR.
BIN26="${TMPDIR_ROOT}/bin26"
mkdir -p "$BIN26"
run_gate "$BIN26" \
  "[\"${SHA_ALL_CLEAN}\"]" \
  "" \
  "--min-severity High" \
  "0" \
  "test26 (control): PR commit reviewed and clean → exit 0 (PASS)"

# Test 27 — a PR commit whose changed files are ALL covered by this repo's
# .roborev.toml exclude_patterns. roborev legitimately never creates a job
# for it (verified against the live DB: real llm commits with no
# review_jobs row at all exist alongside commits that DO get reviewed --
# see _query_review_completeness's own comment), so it must NOT block the
# gate forever the way a genuine "no_job" commit does in test24. Uses its
# own throwaway git repo (not $GIT_REPO) so a real .roborev.toml can sit at
# the toplevel _query_review_completeness's `git rev-parse --show-toplevel`
# call resolves to.
EXCLUDED_REPO="${TMPDIR_ROOT}/excluded_repo"
mkdir -p "$EXCLUDED_REPO"
make_git_repo "$EXCLUDED_REPO"
cat > "${EXCLUDED_REPO}/.roborev.toml" <<'EOF'
exclude_patterns = [
  "EXCLUDED.md",
]
EOF
echo "excluded content" > "${EXCLUDED_REPO}/EXCLUDED.md"
git -C "$EXCLUDED_REPO" add EXCLUDED.md
git -C "$EXCLUDED_REPO" commit -qm "docs: update excluded-only file" 2>/dev/null
EXCLUDED_SHA=$(git -C "$EXCLUDED_REPO" rev-parse HEAD 2>/dev/null)

BIN27="${TMPDIR_ROOT}/bin27"
mkdir -p "$BIN27"
make_mock_gh "$BIN27" "[\"${EXCLUDED_SHA}\"]"

out27=""
exit27=0
out27=$(
  GH="$BIN27/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
  GIT_DIR="${EXCLUDED_REPO}/.git" GIT_WORK_TREE="$EXCLUDED_REPO" \
    bash "$GATE" --repo JohnGavin/fakerepo --min-severity High 99 2>&1
) || exit27=$?

if [ "$exit27" = "0" ]; then
  pass "test27: PR commit touching only .roborev.toml-excluded files, no job → exit 0 (PASS, not blocked forever)"
else
  fail "test27: PR commit touching only .roborev.toml-excluded files, no job → exit 0 (PASS, not blocked forever)" "got exit=$exit27 | output: $out27"
fi
if echo "$out27" | grep -q "PASS"; then
  pass "test27b: excluded-only commit reaches a real PASS message"
else
  fail "test27b: excluded-only commit reaches a real PASS message" "output: $out27"
fi

# Test 27c — the same excluded-only SHA, but with .roborev.toml absent (a
# repo with no exclude_patterns at all). Must fall back to blocking
# (INDETERMINATE, review_pending) — exclusion must be PROVEN from an
# actual config, never assumed just because the commit is small.
NOEXCLUDE_REPO="${TMPDIR_ROOT}/noexclude_repo"
mkdir -p "$NOEXCLUDE_REPO"
make_git_repo "$NOEXCLUDE_REPO"
echo "some content" > "${NOEXCLUDE_REPO}/PLAIN.md"
git -C "$NOEXCLUDE_REPO" add PLAIN.md
git -C "$NOEXCLUDE_REPO" commit -qm "docs: update plain file" 2>/dev/null
NOEXCLUDE_SHA=$(git -C "$NOEXCLUDE_REPO" rev-parse HEAD 2>/dev/null)

BIN27C="${TMPDIR_ROOT}/bin27c"
mkdir -p "$BIN27C"
make_mock_gh "$BIN27C" "[\"${NOEXCLUDE_SHA}\"]"

exit27c=0
out27c=$(
  GH="$BIN27C/gh" ROBOREV_DB="$FIXTURE_DB" ACKS_JSONL="$ACKS_FILE" \
  GIT_DIR="${NOEXCLUDE_REPO}/.git" GIT_WORK_TREE="$NOEXCLUDE_REPO" \
    bash "$GATE" --repo JohnGavin/fakerepo --min-severity High 99 2>&1
) || exit27c=$?

if [ "$exit27c" = "3" ]; then
  pass "test27c: same shape but no .roborev.toml exclude_patterns → exit 3 (INDETERMINATE, exclusion not assumed)"
else
  fail "test27c: same shape but no .roborev.toml exclude_patterns → exit 3 (INDETERMINATE, exclusion not assumed)" "got exit=$exit27c | output: $out27c"
fi

# ═══════════════════════════════════════════════════════════════════════════
# JohnGavin/llm#1274 option A — REPORT-ONLY supersession by a clean range
# review. A completed `range` review job whose git_ref is "<base>..<tip>"
# (commit_id NULL), where tip is the PR's last commit and base is NOT one of
# the PR's own commits (so the range covers the whole PR), and whose review
# has no finding at/above the threshold, supersedes earlier per-commit open
# findings for display: they are reported as "superseded by review N" and
# left out of the BLOCK count. Nothing is closed. A range review that has
# findings, is not done, or only partially covers the PR supersedes nothing.
# ═══════════════════════════════════════════════════════════════════════════

SHA_RANGE_BASE="bas000bas000bas000bas000bas000bas000bas000"

# add_range_job DB GIT_REF STATUS REVIEW_ID OUTPUT   (job id = review id + 1000)
add_range_job() {
  local db="$1" ref="$2" status="$3" rid="$4" out="$5"
  /usr/bin/python3 - "$db" "$ref" "$status" "$rid" "$out" <<'PYEOF'
import sqlite3, sys
db, ref, status, rid, out = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
con = sqlite3.connect(db)
jid = rid + 1000
con.execute("INSERT INTO review_jobs (id,repo_id,commit_id,git_ref,status,job_type) "
            "VALUES (?,1,NULL,?,?,'range')", (jid, ref, status))
if status == "done":
    con.execute("INSERT INTO reviews (id,job_id,agent,output,structured_output,closed,verdict_bool) "
                "VALUES (?,?,'codex',?,NULL,0,?)", (rid, jid, out, 1 if "No issues" in out else 0))
con.commit()
con.close()
PYEOF
}

# run_supersede_gate DB EXPECTED_EXIT NAME EXTRA_ARGS COMMITS_JSON  -> sets SUP_OUT
run_supersede_gate() {
  local db="$1" expected="$2" name="$3" extra="$4" commits="$5"
  local bd="${TMPDIR_ROOT}/bin_sup_$RANDOM"
  mkdir -p "$bd"
  make_mock_gh "$bd" "$commits"
  local rc=0
  SUP_OUT=$(
    GH="$bd/gh" ROBOREV_DB="$db" ACKS_JSONL="$ACKS_FILE" \
    GIT_DIR="$GIT_REPO/.git" GIT_WORK_TREE="$GIT_REPO" \
      bash "$GATE" $extra --repo JohnGavin/fakerepo --min-severity High 99 2>&1
  ) || rc=$?
  if [ "$rc" = "$expected" ]; then pass "$name"
  else fail "$name" "expected exit=$expected got=$rc | output: $SUP_OUT"; fi
}

SUP_COMMITS="[\"${SHA_HIGH_OPEN}\",\"${SHA_ALL_CLEAN}\"]"
CLEAN_RANGE_REF="${SHA_RANGE_BASE}..${SHA_ALL_CLEAN}"

# S1 — open High on commit A + clean range review covering A..tip → superseded
DB_S1="${TMPDIR_ROOT}/sup1.db"; cp "$FIXTURE_DB" "$DB_S1"
add_range_job "$DB_S1" "$CLEAN_RANGE_REF" done 50 "No issues found."
run_supersede_gate "$DB_S1" 0 "test28: High on earlier commit + clean covering range review → exit 0 (superseded)" "" "$SUP_COMMITS"
if echo "$SUP_OUT" | grep -qF "superseded by review 50"; then
  pass "test28b: output reports 'superseded by review 50'"
else
  fail "test28b: output reports 'superseded by review 50'" "output: $SUP_OUT"
fi
# Report-only: the superseded review must still be open in the DB.
closed_n=$(/usr/bin/python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select closed from reviews where id=1').fetchone()[0])" "$DB_S1")
if [ "$closed_n" = "0" ]; then pass "test28c: supersession closes nothing (review 1 still closed=0)"
else fail "test28c: supersession closes nothing" "closed=$closed_n"; fi

# S1j — --json carries the superseded list
run_supersede_gate "$DB_S1" 0 "test28d: --json with supersession → exit 0" "--json" "$SUP_COMMITS"
if echo "$SUP_OUT" | /usr/bin/python3 -c "
import sys, json
d = json.loads(sys.stdin.read().strip().splitlines()[-1])
s = d.get('superseded', [])
sys.exit(0 if d['verdict']=='pass' and len(s)==1 and s[0]['id']==1 and s[0]['superseded_by_review']==50 else 1)"; then
  pass "test28e: JSON lists superseded id=1 by review 50"
else
  fail "test28e: JSON lists superseded id=1 by review 50" "output: $SUP_OUT"
fi

# S2 — range review itself has a High finding → nothing superseded → BLOCK
DB_S2="${TMPDIR_ROOT}/sup2.db"; cp "$FIXTURE_DB" "$DB_S2"
add_range_job "$DB_S2" "$CLEAN_RANGE_REF" done 51 "$(printf '**Severity**: High\n**Location**: R/foo.R:1\n**Problem**: still broken.\n')"
run_supersede_gate "$DB_S2" 1 "test29: range review with a High finding → no supersession → exit 1 (BLOCK)" "" "$SUP_COMMITS"

# S3 — no range job at all → unchanged (BLOCK)
run_supersede_gate "$FIXTURE_DB" 1 "test30: no range job → unchanged → exit 1 (BLOCK)" "" "$SUP_COMMITS"

# S4 — range job still running → no supersession
DB_S4="${TMPDIR_ROOT}/sup4.db"; cp "$FIXTURE_DB" "$DB_S4"
add_range_job "$DB_S4" "$CLEAN_RANGE_REF" running 52 ""
run_supersede_gate "$DB_S4" 1 "test31: range job running → no supersession → exit 1 (BLOCK)" "" "$SUP_COMMITS"

# S5 — range job failed → no supersession
DB_S5="${TMPDIR_ROOT}/sup5.db"; cp "$FIXTURE_DB" "$DB_S5"
add_range_job "$DB_S5" "$CLEAN_RANGE_REF" failed 53 ""
run_supersede_gate "$DB_S5" 1 "test32: range job failed → no supersession → exit 1 (BLOCK)" "" "$SUP_COMMITS"

# S6 — clean range whose base is one of the PR's own commits (covers only the
# tail of the PR, not commit A) → not a covering range → BLOCK
DB_S6="${TMPDIR_ROOT}/sup6.db"; cp "$FIXTURE_DB" "$DB_S6"
add_range_job "$DB_S6" "${SHA_HIGH_OPEN}..${SHA_ALL_CLEAN}" done 54 "No issues found."
run_supersede_gate "$DB_S6" 1 "test33: clean range that starts inside the PR (does not cover A) → exit 1 (BLOCK)" "" "$SUP_COMMITS"

# S7 — clean range with a different tip than the PR head → not covering → BLOCK
DB_S7="${TMPDIR_ROOT}/sup7.db"; cp "$FIXTURE_DB" "$DB_S7"
add_range_job "$DB_S7" "${SHA_RANGE_BASE}..${SHA_HIGH_NONBOLD}" done 55 "No issues found."
run_supersede_gate "$DB_S7" 1 "test34: clean range with a different tip → exit 1 (BLOCK)" "" "$SUP_COMMITS"

# S8 — the tip commit's OWN finding is never superseded
DB_S8="${TMPDIR_ROOT}/sup8.db"; cp "$FIXTURE_DB" "$DB_S8"
add_range_job "$DB_S8" "${SHA_RANGE_BASE}..${SHA_HIGH_OPEN}" done 56 "No issues found."
run_supersede_gate "$DB_S8" 1 "test35: High on the tip commit itself is not superseded → exit 1 (BLOCK)" "" "[\"${SHA_ALL_CLEAN}\",\"${SHA_HIGH_OPEN}\"]"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
