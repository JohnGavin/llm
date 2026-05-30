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
    min_severity TEXT NOT NULL DEFAULT ''
  );
  CREATE TABLE reviews (
    id INTEGER PRIMARY KEY,
    job_id INTEGER NOT NULL,
    agent TEXT NOT NULL,
    prompt TEXT NOT NULL DEFAULT '',
    output TEXT NOT NULL,
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
]
for cid, sha, subj in commits:
    cur.execute(
        "INSERT INTO commits VALUES (?,1,?,?,?,?,datetime('now'))",
        (cid, sha, 'author', subj, '2026-01-01T00:00:00Z')
    )

# review_jobs
for jid, cid in [(1,1),(2,2),(3,3),(4,4)]:
    cur.execute(
        "INSERT INTO review_jobs (id,repo_id,commit_id,git_ref) VALUES (?,1,?,?)",
        (jid, cid, f'refs/heads/feat/test')
    )

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

reviews = [
    (1, 1, HIGH_OUTPUT,   0, 0),   # id=1, job=1 (aaa001), HIGH, open
    (2, 2, HIGH_OUTPUT,   0, 0),   # id=2, job=2 (bbb002), HIGH, open → cited
    (3, 3, MEDIUM_OUTPUT, 0, 0),   # id=3, job=3 (ccc003), MEDIUM, open
    (4, 4, HIGH_OUTPUT,   0, 0),   # id=4, job=4 (ddd004), HIGH, open → acked
]
for rid, jid, out, closed, verdict in reviews:
    cur.execute(
        "INSERT INTO reviews (id,job_id,agent,output,closed,verdict_bool) VALUES (?,?,'codex',?,?,?)",
        (rid, jid, out, closed, verdict)
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
  pass "test1: no commits → exit 0 (fail-open)"
else
  fail "test1: no commits → exit 0 (fail-open)" "got exit=$actual_exit"
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

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
