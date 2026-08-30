#!/usr/bin/env bash
# tests/test_roborev_auto_verify_predictions.sh
#
# Integration tests for the prediction/outcome logging wired into
# roborev_auto_verify.sh (Component 4 — adversarial-verify) by
# JohnGavin/llm#839 Phase 1-2.
#
# The dashboard's Reliability Diagram / Brier Score Trend plots have no real
# data because nothing in this codebase ever called record_prediction.sh.
# This test proves that roborev_auto_verify.sh's approved-fix re-review path
# now: (1) logs a prediction the moment it triggers the adversarial
# re-review of a "closes roborev #N" commit — BEFORE the re-review's
# verdict is known — and (2) logs the matching outcome the moment the
# verdict IS known (verdict_bool=1 -> outcome=true, verdict_bool=0 ->
# outcome=false). It also proves the wontfix path and the no-citation path
# correctly log NOTHING, because no adversarial verify happens on those
# paths (there is no "prediction vs later-known-outcome" pair to record).
#
# Uses the same synthetic-git-repo + mock-roborev-binary + fixture-SQLite-DB
# pattern as tests/test_roborev_verify_closure.sh. HOME is overridden per
# scenario so predictions land under $HOME/.claude/predictions/ in a scratch
# dir — this NEVER touches the real ~/.claude/predictions/.
#
# Issue: JohnGavin/llm#839 (Phase 1-2)

set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PASS=0
FAIL=0

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_TEST_DIR}/.." && pwd)"
AUTO_VERIFY="${_REPO_ROOT}/.claude/scripts/roborev_auto_verify.sh"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

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

if [ ! -f "$AUTO_VERIFY" ]; then
  echo "SKIP: roborev_auto_verify.sh not found at ${AUTO_VERIFY}"
  exit 0
fi

# ── Helper: create a fixture DB with migration-v2 schema + one repo row ──────
# _create_db <db_path> <root_path>

_create_db() {
  local db_path="$1" root_path="$2"
  /usr/bin/python3 - "$db_path" "$root_path" <<'PY'
import sqlite3, sys

db, root_path = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
c = conn.cursor()

c.executescript("""
CREATE TABLE repos (
  id INTEGER PRIMARY KEY,
  root_path TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  identity TEXT
);

CREATE TABLE commits (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL REFERENCES repos(id),
  sha TEXT NOT NULL,
  UNIQUE(repo_id, sha)
);

CREATE TABLE review_jobs (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL REFERENCES repos(id),
  commit_id INTEGER REFERENCES commits(id),
  git_ref TEXT NOT NULL,
  branch TEXT,
  agent TEXT NOT NULL DEFAULT 'codex',
  status TEXT NOT NULL DEFAULT 'queued',
  enqueued_at TEXT NOT NULL DEFAULT (datetime('now')),
  started_at TEXT,
  finished_at TEXT,
  job_type TEXT NOT NULL DEFAULT 'review',
  review_type TEXT NOT NULL DEFAULT ''
);

CREATE TABLE reviews (
  id INTEGER PRIMARY KEY,
  job_id INTEGER UNIQUE NOT NULL REFERENCES review_jobs(id),
  agent TEXT NOT NULL,
  prompt TEXT NOT NULL DEFAULT '',
  output TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  closed INTEGER NOT NULL DEFAULT 0,
  verdict_bool INTEGER
);

CREATE TABLE closures (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_id INTEGER NOT NULL REFERENCES reviews(id),
  closure_commit_sha TEXT NOT NULL,
  closure_review_job_id INTEGER REFERENCES review_jobs(id),
  closure_type TEXT NOT NULL,
  closure_reason TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE fix_rejected_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_ids_json TEXT NOT NULL,
  fix_commit_sha TEXT NOT NULL,
  rejection_job_id INTEGER REFERENCES review_jobs(id),
  rejection_summary TEXT,
  attempted_at TEXT NOT NULL DEFAULT (datetime('now')),
  resolved INTEGER NOT NULL DEFAULT 0,
  resolved_at TEXT
);
""")
c.execute("INSERT INTO repos (id, root_path, name) VALUES (1, ?, 'test_repo')", (root_path,))
conn.commit()
conn.close()
PY
}

# ── Helper: seed an open finding (a prior review_jobs+reviews row) ───────────
# _seed_finding <db> <finding_id> <output_text>

_seed_finding() {
  local db="$1" fid="$2" output="$3"
  /usr/bin/python3 - "$db" "$fid" "$output" <<'PY'
import sqlite3, sys
db, fid = sys.argv[1], int(sys.argv[2])
output = sys.argv[3]
conn = sqlite3.connect(db)
conn.execute(
    "INSERT INTO review_jobs (id, repo_id, git_ref, status) VALUES (?, 1, 'original_sha', 'done')",
    (fid,)
)
conn.execute(
    "INSERT INTO reviews (id, job_id, agent, output, closed) VALUES (?, ?, 'codex', ?, 0)",
    (fid, fid, output)
)
conn.commit()
conn.close()
PY
}

# ── Helper: write a mock roborev binary ───────────────────────────────────────
# Responds to: review --commit <SHA>  (inserts review_jobs+reviews, status=done)
#              close <id>             (no-op)
# Env vars read: MOCK_DB, MOCK_VERDICT_BOOL (1|0)

_write_mock_roborev() {
  local mock_path="$1"
  cat > "$mock_path" <<'MOCK'
#!/usr/bin/env bash
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

case "${1:-}" in
  review)
    SHA=""
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --commit) shift; SHA="$1" ;;
        *) ;;
      esac
      shift
    done
    DB="${MOCK_DB:-}"
    VERDICT="${MOCK_VERDICT_BOOL:-1}"
    JOB_ID=$(/usr/bin/python3 - "$DB" "$SHA" "$VERDICT" <<'PY'
import sqlite3, sys
db_path, sha, verdict = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db_path)
c = conn.cursor()
row = c.execute("SELECT id FROM commits WHERE sha = ?", (sha,)).fetchone()
if row:
    commit_id = row[0]
else:
    c.execute("INSERT INTO commits (repo_id, sha) VALUES (1, ?)", (sha,))
    commit_id = c.lastrowid
c.execute(
    "INSERT INTO review_jobs (repo_id, commit_id, git_ref, status, finished_at, started_at) "
    "VALUES (1, ?, ?, 'done', datetime('now'), datetime('now'))",
    (commit_id, sha)
)
job_id = c.lastrowid
c.execute(
    "INSERT INTO reviews (job_id, agent, output, verdict_bool) VALUES (?, 'codex', 'mock verify output', ?)",
    (job_id, int(verdict))
)
conn.commit()
conn.close()
print(job_id)
PY
    )
    echo "Enqueued re-review job_id: ${JOB_ID} for ${SHA:0:7} (agent: codex)"
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

# ── Helper: create a real git repo with one fix commit ────────────────────────
# _make_fix_commit <repo_dir> <commit_message> -> prints the commit SHA

_make_fix_commit() {
  local repo_dir="$1" msg="$2"
  git init --quiet "$repo_dir"
  git -C "$repo_dir" config user.email "test@example.com"
  git -C "$repo_dir" config user.name "Test"
  git -C "$repo_dir" commit --quiet --allow-empty -m "$msg"
  git -C "$repo_dir" rev-parse HEAD
}

# ── Helper: seed a commits row for the fix commit itself ─────────────────────
# roborev_auto_verify.sh resolves the repo name (and this patch's project
# root path) by joining commits -> repos on the FIX commit's sha — a real
# roborev post-commit hook would already have this row (roborev records
# every commit it reviews). _seed_commit <db> <sha>

_seed_commit() {
  local db="$1" sha="$2"
  /usr/bin/python3 - "$db" "$sha" <<'PY'
import sqlite3, sys
db, sha = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
conn.execute("INSERT INTO commits (repo_id, sha) VALUES (1, ?)", (sha,))
conn.commit()
conn.close()
PY
}

# ── Test 1: approved verdict -> prediction logged, outcome=true ──────────────

echo "Test 1: approved verdict (verdict_bool=1) logs prediction + outcome=true"

T1="${SCRATCH}/t1"
mkdir -p "$T1"
T1_HOME="${T1}/home"
mkdir -p "$T1_HOME/.claude/logs"
T1_REPO="${T1}/repo"
T1_DB="${T1}/reviews.db"
T1_MOCK="${T1}/roborev"

_create_db "$T1_DB" "$T1_REPO"
_seed_finding "$T1_DB" 501 "## Review Findings\n- **Severity**: High\n- **Problem**: thing"
_write_mock_roborev "$T1_MOCK"

FIX_SHA_1=$(_make_fix_commit "$T1_REPO" "fix(x): resolve thing (closes roborev #501)")
_seed_commit "$T1_DB" "$FIX_SHA_1"

(
  cd "$T1_REPO"
  ROBOREV="$T1_MOCK" \
  ROBOREV_DB="$T1_DB" \
  MOCK_DB="$T1_DB" \
  MOCK_VERDICT_BOOL="1" \
  HOME="$T1_HOME" \
    bash "$AUTO_VERIFY" --apply --no-auto-close --commit "$FIX_SHA_1" >/dev/null 2>&1
)

T1_SLUG=$(printf '%s' "$T1_REPO" | tr '/' '-')
T1_JSONL="${T1_HOME}/.claude/predictions/${T1_SLUG}.jsonl"

if [ -f "$T1_JSONL" ]; then
  _check "t1-prediction-file-written" "pass"
  T1_RESULT=$(/usr/bin/python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    lines = [json.loads(l) for l in f if l.strip()]
errs = []
if len(lines) < 2:
    errs.append(f'expected >=2 lines (predict+outcome), got {len(lines)}')
else:
    pred = lines[0]
    outc = lines[-1]
    if pred.get('outcome') is not None: errs.append('predict-line-outcome-not-null')
    if not (0.0 <= pred.get('p_success', -1) <= 1.0): errs.append('p_success-out-of-range')
    if outc.get('prediction_id') != pred.get('prediction_id'): errs.append('outcome-prediction-id-mismatch')
    if outc.get('outcome') is not True: errs.append(f'outcome-not-true (got {outc.get(\"outcome\")})')
print(','.join(errs) if errs else 'ok')
" "$T1_JSONL")
  if [ "$T1_RESULT" = "ok" ]; then
    _check "t1-predict-then-outcome-true" "pass"
  else
    _check "t1-predict-then-outcome-true" "fail: ${T1_RESULT}"
  fi
else
  _check "t1-prediction-file-written" "fail: ${T1_JSONL} not found"
  _check "t1-predict-then-outcome-true" "fail: no file"
fi

# ── Test 2: rejected verdict -> prediction logged, outcome=false ─────────────

echo ""
echo "Test 2: rejected verdict (verdict_bool=0) logs prediction + outcome=false"

T2="${SCRATCH}/t2"
mkdir -p "$T2"
T2_HOME="${T2}/home"
mkdir -p "$T2_HOME/.claude/logs"
T2_REPO="${T2}/repo"
T2_DB="${T2}/reviews.db"
T2_MOCK="${T2}/roborev"

_create_db "$T2_DB" "$T2_REPO"
_seed_finding "$T2_DB" 502 "## Review Findings\n- **Severity**: Medium\n- **Problem**: other thing"
_write_mock_roborev "$T2_MOCK"

FIX_SHA_2=$(_make_fix_commit "$T2_REPO" "fix(y): attempt fix (closes roborev #502)")
_seed_commit "$T2_DB" "$FIX_SHA_2"

(
  cd "$T2_REPO"
  ROBOREV="$T2_MOCK" \
  ROBOREV_DB="$T2_DB" \
  MOCK_DB="$T2_DB" \
  MOCK_VERDICT_BOOL="0" \
  HOME="$T2_HOME" \
    bash "$AUTO_VERIFY" --apply --no-auto-close --commit "$FIX_SHA_2" >/dev/null 2>&1
)

T2_SLUG=$(printf '%s' "$T2_REPO" | tr '/' '-')
T2_JSONL="${T2_HOME}/.claude/predictions/${T2_SLUG}.jsonl"

if [ -f "$T2_JSONL" ]; then
  T2_RESULT=$(/usr/bin/python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    lines = [json.loads(l) for l in f if l.strip()]
errs = []
if len(lines) < 2:
    errs.append(f'expected >=2 lines, got {len(lines)}')
else:
    outc = lines[-1]
    if outc.get('outcome') is not False: errs.append(f'outcome-not-false (got {outc.get(\"outcome\")})')
print(','.join(errs) if errs else 'ok')
" "$T2_JSONL")
  if [ "$T2_RESULT" = "ok" ]; then
    _check "t2-predict-then-outcome-false" "pass"
  else
    _check "t2-predict-then-outcome-false" "fail: ${T2_RESULT}"
  fi
else
  _check "t2-predict-then-outcome-false" "fail: ${T2_JSONL} not found"
fi

# ── Test 3: wontfix commit -> NO prediction (no adversarial verify happens) ──

echo ""
echo "Test 3: wontfix commit logs NO prediction (no re-review is triggered)"

T3="${SCRATCH}/t3"
mkdir -p "$T3"
T3_HOME="${T3}/home"
mkdir -p "$T3_HOME/.claude/logs"
T3_REPO="${T3}/repo"
T3_DB="${T3}/reviews.db"
T3_MOCK="${T3}/roborev"

_create_db "$T3_DB" "$T3_REPO"
_seed_finding "$T3_DB" 503 "## Review Findings\n- **Severity**: Low\n- **Problem**: nit"
_write_mock_roborev "$T3_MOCK"

FIX_SHA_3=$(_make_fix_commit "$T3_REPO" "chore: not a real bug (wontfix roborev #503)")
_seed_commit "$T3_DB" "$FIX_SHA_3"

(
  cd "$T3_REPO"
  ROBOREV="$T3_MOCK" \
  ROBOREV_DB="$T3_DB" \
  MOCK_DB="$T3_DB" \
  HOME="$T3_HOME" \
    bash "$AUTO_VERIFY" --apply --no-auto-close --commit "$FIX_SHA_3" >/dev/null 2>&1
)

T3_SLUG=$(printf '%s' "$T3_REPO" | tr '/' '-')
T3_JSONL="${T3_HOME}/.claude/predictions/${T3_SLUG}.jsonl"

if [ ! -f "$T3_JSONL" ]; then
  _check "t3-wontfix-no-prediction" "pass"
else
  _check "t3-wontfix-no-prediction" "fail: prediction file unexpectedly created for wontfix commit"
fi

# ── Test 4: no-citation commit -> NO prediction ───────────────────────────────

echo ""
echo "Test 4: commit with no roborev citation logs NO prediction"

T4="${SCRATCH}/t4"
mkdir -p "$T4"
T4_HOME="${T4}/home"
mkdir -p "$T4_HOME/.claude/logs"
T4_REPO="${T4}/repo"
T4_DB="${T4}/reviews.db"
T4_MOCK="${T4}/roborev"

_create_db "$T4_DB" "$T4_REPO"
_write_mock_roborev "$T4_MOCK"

FIX_SHA_4=$(_make_fix_commit "$T4_REPO" "docs: routine update")
_seed_commit "$T4_DB" "$FIX_SHA_4"

(
  cd "$T4_REPO"
  ROBOREV="$T4_MOCK" \
  ROBOREV_DB="$T4_DB" \
  MOCK_DB="$T4_DB" \
  HOME="$T4_HOME" \
    bash "$AUTO_VERIFY" --apply --no-auto-close --commit "$FIX_SHA_4" >/dev/null 2>&1
)

T4_SLUG=$(printf '%s' "$T4_REPO" | tr '/' '-')
T4_JSONL="${T4_HOME}/.claude/predictions/${T4_SLUG}.jsonl"

if [ ! -f "$T4_JSONL" ]; then
  _check "t4-no-citation-no-prediction" "pass"
else
  _check "t4-no-citation-no-prediction" "fail: prediction file unexpectedly created with no citation"
fi

# ── Summary ────────────────────────────────────────────────────────────────────

TOTAL=$((PASS+FAIL))
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "${PASS}/${TOTAL} PASS"
  exit 0
else
  echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
  exit 1
fi
