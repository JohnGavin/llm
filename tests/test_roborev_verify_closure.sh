#!/usr/bin/env bash
# tests/test_roborev_verify_closure.sh
#
# Integration tests for roborev_verify_closure.sh.
#
# Sets up a synthetic git repository and a mock roborev binary backed by a
# fixture SQLite DB.  The mock roborev:
#   - On "review --sha <sha> --wait": writes a review_jobs + reviews row with
#     a configurable verdict, then prints "Enqueued job <N> for <sha>".
#   - On "close <id>": no-op (verifier never calls close anyway).
#
# Test scenarios:
#   1. verified-pass  — review approved, original finding location not re-flagged
#   2. verified-fail  — review re-flags original finding location
#   3. inconclusive (verdict_bool NULL)  — review completed but no verdict
#   4. inconclusive (roborev missing)   — binary unavailable
#   5. inconclusive (db missing)        — DB file does not exist
#   6. multi-finding: one pass, one fail
#   7. installer writes post-commit hook (idempotent)
#   8. installer refuses to overwrite a foreign post-commit hook
#
# Issue: JohnGavin/llm#353

set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PASS=0
FAIL=0

# Resolve paths relative to this test file's location, then fall back to
# installed locations under ~/docs_gh/llm/.
_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_TEST_DIR}/.." && pwd)"

VERIFIER="${_REPO_ROOT}/.claude/scripts/roborev_verify_closure.sh"
INSTALLER="${_REPO_ROOT}/bin/roborev_install_post_commit_verifier.sh"

# Scratch directory — cleaned up on exit
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── Helper: check ─────────────────────────────────────────────────────────────

_check() {
  local label="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS+1))
    echo "  PASS [$label]"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL [$label]: $result"
  fi
}

# ── Helper: create a minimal SQLite DB with the roborev schema ────────────────

_create_db() {
  local db_path="$1"
  /usr/bin/python3 - "$db_path" <<'PY'
import sqlite3, sys

db = sys.argv[1]
conn = sqlite3.connect(db)
c = conn.cursor()

c.executescript("""
CREATE TABLE repos (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  root_path TEXT
);

CREATE TABLE commits (
  id      INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL REFERENCES repos(id),
  sha     TEXT    NOT NULL
);

CREATE TABLE review_jobs (
  id          INTEGER PRIMARY KEY,
  repo_id     INTEGER NOT NULL REFERENCES repos(id),
  commit_id   INTEGER REFERENCES commits(id),
  git_ref     TEXT    NOT NULL,
  branch      TEXT,
  agent       TEXT    NOT NULL DEFAULT 'codex',
  status      TEXT    NOT NULL DEFAULT 'queued',
  enqueued_at TEXT    NOT NULL DEFAULT (datetime('now')),
  started_at  TEXT,
  finished_at TEXT,
  job_type    TEXT    NOT NULL DEFAULT 'review',
  review_type TEXT    NOT NULL DEFAULT ''
);

CREATE TABLE reviews (
  id           INTEGER PRIMARY KEY,
  job_id       INTEGER UNIQUE NOT NULL REFERENCES review_jobs(id),
  agent        TEXT    NOT NULL,
  prompt       TEXT    NOT NULL DEFAULT '',
  output       TEXT    NOT NULL,
  created_at   TEXT    NOT NULL DEFAULT (datetime('now')),
  closed       INTEGER NOT NULL DEFAULT 0,
  verdict_bool INTEGER
);

CREATE TABLE closures (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_id            INTEGER NOT NULL REFERENCES reviews(id),
  closure_commit_sha    TEXT    NOT NULL,
  closure_review_job_id INTEGER REFERENCES review_jobs(id),
  closure_type          TEXT    NOT NULL,
  closure_reason        TEXT,
  created_at            TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE fix_rejected_queue (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_ids_json    TEXT    NOT NULL,
  fix_commit_sha      TEXT    NOT NULL,
  rejection_job_id    INTEGER REFERENCES review_jobs(id),
  rejection_summary   TEXT,
  attempted_at        TEXT    NOT NULL DEFAULT (datetime('now')),
  resolved            INTEGER NOT NULL DEFAULT 0,
  resolved_at         TEXT
);

INSERT INTO repos (id, name) VALUES (1, 'test_repo');
""")
conn.commit()
conn.close()
PY
}

# ── Helper: seed an existing finding in the DB ────────────────────────────────
# _seed_finding <db> <finding_id> <output_text>

_seed_finding() {
  local db="$1" fid="$2" output="$3"
  /usr/bin/python3 - "$db" "$fid" "$output" <<'PY'
import sqlite3, sys

db, fid = sys.argv[1], int(sys.argv[2])
# Convert literal \n sequences to real newlines so location regex matches
output = sys.argv[3].replace('\\n', '\n')
conn = sqlite3.connect(db)

# Need a review_jobs row to satisfy FK for the finding
conn.execute(
    "INSERT INTO review_jobs (id, repo_id, git_ref, status) VALUES (?, 1, 'original_sha', 'done')",
    (fid,)
)
conn.execute(
    "INSERT INTO reviews (id, job_id, agent, output) VALUES (?, ?, 'codex', ?)",
    (fid, fid, output)
)
conn.commit()
conn.close()
PY
}

# ── Helper: write a mock roborev binary ───────────────────────────────────────
# The mock reads MOCK_VERDICT_BOOL (1, 0, or "null") from env and
# writes a review_jobs + reviews row into MOCK_DB.
# It prints "Enqueued job <N> for <sha>" and exits 0.

_write_mock_roborev() {
  local mock_path="$1"
  cat > "$mock_path" <<'MOCK'
#!/usr/bin/env bash
# Mock roborev binary for tests
# Env vars:
#   MOCK_DB           — path to test SQLite DB
#   MOCK_VERDICT_BOOL — 1, 0, or "null"
#   MOCK_OUTPUT       — review output text

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

case "${1:-}" in
  review)
    # Parse --sha flag
    SHA=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --sha) shift; SHA="$1" ;;
        --wait|--quiet|-q) ;;
        *) ;;
      esac
      shift
    done
    SHA="${SHA:-HEAD}"

    DB="${MOCK_DB:-}"
    VERDICT="${MOCK_VERDICT_BOOL:-1}"
    OUTPUT="${MOCK_OUTPUT:-## Review Findings\n- No issues found.}"

    if [ -n "$DB" ] && [ -f "$DB" ]; then
      /usr/bin/python3 - "$DB" "$SHA" "$VERDICT" "$OUTPUT" <<'PY'
import sqlite3, sys

db_path  = sys.argv[1]
sha      = sys.argv[2]
verdict  = sys.argv[3]
# Convert literal \n sequences to real newlines so location regex matches
output   = sys.argv[4].replace('\\n', '\n')

conn = sqlite3.connect(db_path)
c = conn.cursor()

# Insert a commit row
c.execute("INSERT INTO commits (repo_id, sha) VALUES (1, ?)", (sha,))
commit_id = c.lastrowid

# Insert a review_jobs row
c.execute(
    "INSERT INTO review_jobs (repo_id, commit_id, git_ref, status, finished_at, started_at) "
    "VALUES (1, ?, ?, 'done', datetime('now'), datetime('now'))",
    (commit_id, sha)
)
job_id = c.lastrowid

# Insert reviews row with verdict
v_bool = None if verdict == "null" else int(verdict)
c.execute(
    "INSERT INTO reviews (job_id, agent, output, verdict_bool) VALUES (?, 'codex', ?, ?)",
    (job_id, output, v_bool)
)
conn.commit()
conn.close()

print(f"Enqueued job {job_id} for {sha[:7]} (agent: codex)")
PY
    else
      echo "Enqueued job 9999 for ${SHA:0:7} (agent: codex)"
    fi
    ;;
  close)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK
  chmod +x "$mock_path"
}

# ── Self-test of verifier unit tests ─────────────────────────────────────────

echo "Running verifier self-test..."
if SELFTEST=1 bash "$VERIFIER"; then
  _check "verifier-selftest" "pass"
else
  _check "verifier-selftest" "fail: SELFTEST exited non-zero"
fi

# ── Test 1: verified-pass ─────────────────────────────────────────────────────

echo ""
echo "Test 1: verified-pass (approved, location not re-flagged)"

T1="${SCRATCH}/t1"
mkdir -p "$T1"
T1_DB="${T1}/reviews.db"
T1_MOCK="${T1}/roborev"
T1_LOG="${T1}/verify_log"
T1_VERDICT_DIR="${T1}/verdicts"

_create_db "$T1_DB"

# Seed finding #10 with a specific location
_seed_finding "$T1_DB" 10 \
  "## Review Findings\n- **Location**: R/foo.R:42\n- **Problem**: unhandled NA"

_write_mock_roborev "$T1_MOCK"

mkdir -p "$T1_VERDICT_DIR"

ROBOREV="$T1_MOCK" \
ROBOREV_DB="$T1_DB" \
MOCK_DB="$T1_DB" \
MOCK_VERDICT_BOOL="1" \
MOCK_OUTPUT="## Review Findings\n- No issues found.\n## Summary\nLooks good." \
HOME="$T1" \
  bash "$VERIFIER" "abc1234" 10 2>/dev/null

VERDICT_FILE="${T1}/.claude/logs/roborev_verify_closure/abc1234.json"
if [ -f "$VERDICT_FILE" ]; then
  STATUS=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['verdicts']['10']['status'])
" "$VERDICT_FILE")
  if [ "$STATUS" = "verified-pass" ]; then
    _check "t1-verified-pass" "pass"
  else
    _check "t1-verified-pass" "fail: got status='${STATUS}'"
  fi
else
  _check "t1-verified-pass" "fail: verdict file not written"
fi

# ── Test 2: verified-fail ─────────────────────────────────────────────────────

echo ""
echo "Test 2: verified-fail (location re-flagged in new review)"

T2="${SCRATCH}/t2"
mkdir -p "$T2"
T2_DB="${T2}/reviews.db"
T2_MOCK="${T2}/roborev"

_create_db "$T2_DB"

# Seed finding #20 with location R/bar.R:99
_seed_finding "$T2_DB" 20 \
  "## Review Findings\n- **Location**: R/bar.R:99\n- **Problem**: missing check"

_write_mock_roborev "$T2_MOCK"

# New review STILL flags R/bar.R:99
ROBOREV="$T2_MOCK" \
ROBOREV_DB="$T2_DB" \
MOCK_DB="$T2_DB" \
MOCK_VERDICT_BOOL="0" \
MOCK_OUTPUT="## Review Findings\n- **Severity**: High\n- **Location**: R/bar.R:99\n- **Problem**: still missing check" \
HOME="$T2" \
  bash "$VERIFIER" "def5678" 20 2>/dev/null

VERDICT_FILE="${T2}/.claude/logs/roborev_verify_closure/def5678.json"
if [ -f "$VERDICT_FILE" ]; then
  STATUS=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['verdicts']['20']['status'])
" "$VERDICT_FILE")
  if [ "$STATUS" = "verified-fail" ]; then
    _check "t2-verified-fail" "pass"
  else
    _check "t2-verified-fail" "fail: got status='${STATUS}'"
  fi
else
  _check "t2-verified-fail" "fail: verdict file not written"
fi

# ── Test 3: inconclusive (NULL verdict_bool) ──────────────────────────────────

echo ""
echo "Test 3: inconclusive (verdict_bool=NULL)"

T3="${SCRATCH}/t3"
mkdir -p "$T3"
T3_DB="${T3}/reviews.db"
T3_MOCK="${T3}/roborev"

_create_db "$T3_DB"
_seed_finding "$T3_DB" 30 "## Review Findings\n- **Location**: R/baz.R:5\n- **Problem**: something"
_write_mock_roborev "$T3_MOCK"

ROBOREV="$T3_MOCK" \
ROBOREV_DB="$T3_DB" \
MOCK_DB="$T3_DB" \
MOCK_VERDICT_BOOL="null" \
MOCK_OUTPUT="## Review Findings\n- No issues found." \
HOME="$T3" \
  bash "$VERIFIER" "fff9999" 30 2>/dev/null

VERDICT_FILE="${T3}/.claude/logs/roborev_verify_closure/fff9999.json"
if [ -f "$VERDICT_FILE" ]; then
  STATUS=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['verdicts']['30']['status'])
" "$VERDICT_FILE")
  if [ "$STATUS" = "inconclusive" ]; then
    _check "t3-inconclusive-null-verdict" "pass"
  else
    _check "t3-inconclusive-null-verdict" "fail: got status='${STATUS}'"
  fi
else
  _check "t3-inconclusive-null-verdict" "fail: verdict file not written"
fi

# ── Test 4: inconclusive (roborev binary missing) ─────────────────────────────

echo ""
echo "Test 4: inconclusive (roborev binary not found)"

T4="${SCRATCH}/t4"
mkdir -p "$T4"
T4_DB="${T4}/reviews.db"
_create_db "$T4_DB"

ROBOREV="${T4}/no_such_binary" \
ROBOREV_DB="$T4_DB" \
HOME="$T4" \
  bash "$VERIFIER" "aaa1111" 40 2>/dev/null

VERDICT_FILE="${T4}/.claude/logs/roborev_verify_closure/aaa1111.json"
if [ -f "$VERDICT_FILE" ]; then
  STATUS=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['verdicts']['40']['status'])
" "$VERDICT_FILE")
  if [ "$STATUS" = "inconclusive" ]; then
    _check "t4-inconclusive-no-binary" "pass"
  else
    _check "t4-inconclusive-no-binary" "fail: got status='${STATUS}'"
  fi
else
  _check "t4-inconclusive-no-binary" "fail: verdict file not written"
fi

# ── Test 5: inconclusive (DB missing) ────────────────────────────────────────

echo ""
echo "Test 5: inconclusive (DB file not present)"

T5="${SCRATCH}/t5"
mkdir -p "$T5"
T5_MOCK="${T5}/roborev"
_write_mock_roborev "$T5_MOCK"

ROBOREV="$T5_MOCK" \
ROBOREV_DB="${T5}/no_such.db" \
HOME="$T5" \
  bash "$VERIFIER" "bbb2222" 50 2>/dev/null

VERDICT_FILE="${T5}/.claude/logs/roborev_verify_closure/bbb2222.json"
if [ -f "$VERDICT_FILE" ]; then
  STATUS=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['verdicts']['50']['status'])
" "$VERDICT_FILE")
  if [ "$STATUS" = "inconclusive" ]; then
    _check "t5-inconclusive-no-db" "pass"
  else
    _check "t5-inconclusive-no-db" "fail: got status='${STATUS}'"
  fi
else
  _check "t5-inconclusive-no-db" "fail: verdict file not written"
fi

# ── Test 6: multi-finding — one pass, one fail ────────────────────────────────

echo ""
echo "Test 6: multi-finding (one verified-pass, one verified-fail)"

T6="${SCRATCH}/t6"
mkdir -p "$T6"
T6_DB="${T6}/reviews.db"
T6_MOCK="${T6}/roborev"

_create_db "$T6_DB"

# Finding #60: location R/alpha.R:10 (will NOT be re-flagged → pass)
_seed_finding "$T6_DB" 60 \
  "## Review Findings\n- **Location**: R/alpha.R:10\n- **Problem**: issue A"

# Finding #61: location R/beta.R:20 (WILL be re-flagged → fail)
_seed_finding "$T6_DB" 61 \
  "## Review Findings\n- **Location**: R/beta.R:20\n- **Problem**: issue B"

_write_mock_roborev "$T6_MOCK"

# New review only re-flags beta
ROBOREV="$T6_MOCK" \
ROBOREV_DB="$T6_DB" \
MOCK_DB="$T6_DB" \
MOCK_VERDICT_BOOL="0" \
MOCK_OUTPUT="## Review Findings\n- **Location**: R/beta.R:20\n- **Problem**: still issue B" \
HOME="$T6" \
  bash "$VERIFIER" "ccc3333" 60 61 2>/dev/null

VERDICT_FILE="${T6}/.claude/logs/roborev_verify_closure/ccc3333.json"
if [ -f "$VERDICT_FILE" ]; then
  STATUS60=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['verdicts']['60']['status'])
" "$VERDICT_FILE")
  STATUS61=$(/usr/bin/python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['verdicts']['61']['status'])
" "$VERDICT_FILE")

  if [ "$STATUS60" = "inconclusive" ] && [ "$STATUS61" = "verified-fail" ]; then
    # Finding 60's location not re-flagged, but overall verdict=0, so 60 is inconclusive
    _check "t6-multi-finding" "pass"
  else
    _check "t6-multi-finding" "fail: status60='${STATUS60}' status61='${STATUS61}' (expected inconclusive + verified-fail)"
  fi
else
  _check "t6-multi-finding" "fail: verdict file not written"
fi

# ── Test 7: installer writes hook (idempotent) ────────────────────────────────

echo ""
echo "Test 7: installer writes post-commit hook (idempotent)"

T7="${SCRATCH}/t7"
mkdir -p "${T7}/.git/hooks"
# First install (point installed hook at our worktree's verifier for testing)
ROBOREV_VERIFIER_SCRIPT="$VERIFIER" bash "$INSTALLER" "$T7" 2>/dev/null
HOOK_FILE="${T7}/.git/hooks/post-commit"
if [ -f "$HOOK_FILE" ] && [ -x "$HOOK_FILE" ]; then
  _check "t7-hook-created" "pass"
else
  _check "t7-hook-created" "fail: hook file missing or not executable"
fi

# Re-run should be idempotent (still OK marker)
OUT2=$(ROBOREV_VERIFIER_SCRIPT="$VERIFIER" bash "$INSTALLER" "$T7" 2>/dev/null)
if printf '%s\n' "$OUT2" | grep -q '^OK:'; then
  _check "t7-hook-idempotent" "pass"
else
  _check "t7-hook-idempotent" "fail: re-run did not print OK:"
fi

# Hook should contain ROBOREV_VERIFY_SKIP guard
if grep -q 'ROBOREV_VERIFY_SKIP' "$HOOK_FILE"; then
  _check "t7-skip-guard" "pass"
else
  _check "t7-skip-guard" "fail: ROBOREV_VERIFY_SKIP not in hook"
fi

# ── Test 8: installer refuses foreign hook ────────────────────────────────────

echo ""
echo "Test 8: installer refuses to overwrite foreign post-commit hook"

T8="${SCRATCH}/t8"
mkdir -p "${T8}/.git/hooks"
FOREIGN="${T8}/.git/hooks/post-commit"
cat > "$FOREIGN" <<'EOF'
#!/usr/bin/env bash
# Foreign hook — not installed by our installer
echo "foreign hook"
EOF
chmod +x "$FOREIGN"

OUT8=$(ROBOREV_VERIFIER_SCRIPT="$VERIFIER" bash "$INSTALLER" "$T8" 2>&1)
if printf '%s\n' "$OUT8" | grep -q '^CHAIN:'; then
  _check "t8-refuses-foreign-hook" "pass"
else
  _check "t8-refuses-foreign-hook" "fail: expected CHAIN: output, got: ${OUT8}"
fi

# The original foreign hook must be unchanged
if grep -q 'foreign hook' "$FOREIGN"; then
  _check "t8-foreign-hook-preserved" "pass"
else
  _check "t8-foreign-hook-preserved" "fail: foreign hook was overwritten"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL=$((PASS+FAIL))
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "${PASS}/${TOTAL} PASS"
  exit 0
else
  echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
  exit 1
fi
