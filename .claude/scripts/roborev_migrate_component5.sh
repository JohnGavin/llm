#!/usr/bin/env bash
# roborev_migrate_component5.sh — DB schema migration for Component 5 of #163.
#
# Adds two tables to ~/.roborev/reviews.db:
#   closures           — one row per auto-closed finding (approved/wontfix/manual/stale)
#   fix_rejected_queue — fix commits that re-review rejected; held for human triage
#
# This is the authoritative migration for these tables. The earlier
# roborev_schema_migration_v2.sql contained draft definitions; this script
# supersedes them with the final column names used by roborev_auto_close.sh.
#
# IDEMPOTENT: uses CREATE TABLE IF NOT EXISTS throughout.
# Safe to re-run on an already-migrated DB — no existing rows are touched.
#
# Usage:
#   bash roborev_migrate_component5.sh              # applies migration
#   ROBOREV_DB=/other/path.db bash roborev_migrate_component5.sh
#
# Self-test (fixture DB — does NOT touch ~/.roborev/reviews.db):
#   CLAUDE_HOOK_SELFTEST=1 bash roborev_migrate_component5.sh
#
# Exit codes:
#   0 = success
#   1 = migration failed (DB locked, SQL error, etc.)
#
# Issue: JohnGavin/llm#354, parent #163

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
SQLITE3="${SQLITE3:-$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)}"

# ── Self-test ──────────────────────────────────────────────────────────────────

if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  _check() {
    local label="$1"
    local result="$2"
    if [ "$result" = "pass" ]; then
      PASS=$((PASS+1))
      echo "  PASS [$label]"
    else
      FAIL=$((FAIL+1))
      echo "  FAIL [$label]: $result"
    fi
  }

  unset CLAUDE_HOOK_SELFTEST

  FIXTURE_DB="$(mktemp "${TMPDIR:-/tmp}/roborev_c5_test_XXXXXX")".db
  rm -f "${FIXTURE_DB%.db}"
  trap 'rm -f "$FIXTURE_DB"' EXIT

  # Create minimal stub tables needed for FK references
  "$SQLITE3" "$FIXTURE_DB" <<'SQL'
CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, status TEXT,
  enqueued_at TEXT DEFAULT (datetime('now')));
CREATE TABLE reviews (
  id INTEGER PRIMARY KEY,
  job_id INTEGER NOT NULL,
  closed INTEGER NOT NULL DEFAULT 0,
  verdict_bool INTEGER,
  output TEXT,
  updated_at TEXT DEFAULT (datetime('now'))
);
INSERT INTO repos VALUES (1, 'llm');
INSERT INTO review_jobs VALUES (1, 1, 'done', datetime('now'));
INSERT INTO reviews VALUES (1, 1, 0, 0, '**Severity**: High', NULL);
INSERT INTO reviews VALUES (2, 1, 0, 0, '**Severity**: Medium', NULL);
SQL

  # Test 1: migrate creates both tables in a fresh DB
  ROBOREV_DB="$FIXTURE_DB" bash "$0"
  RC=$?
  if [ "$RC" -eq 0 ]; then
    _check "migration-exit-0" "pass"
  else
    _check "migration-exit-0" "fail: exit code $RC"
  fi

  CLOSURES_EXISTS=$("$SQLITE3" "$FIXTURE_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='closures'")
  if [ "$CLOSURES_EXISTS" = "1" ]; then
    _check "closures-table-created" "pass"
  else
    _check "closures-table-created" "fail: got '$CLOSURES_EXISTS'"
  fi

  FRQ_EXISTS=$("$SQLITE3" "$FIXTURE_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='fix_rejected_queue'")
  if [ "$FRQ_EXISTS" = "1" ]; then
    _check "fix_rejected_queue-table-created" "pass"
  else
    _check "fix_rejected_queue-table-created" "fail: got '$FRQ_EXISTS'"
  fi

  # Test 2: idempotent — second run is also exit 0
  ROBOREV_DB="$FIXTURE_DB" bash "$0"
  RC2=$?
  if [ "$RC2" -eq 0 ]; then
    _check "idempotent-second-run" "pass"
  else
    _check "idempotent-second-run" "fail: exit code $RC2"
  fi

  # Test 3: closures schema — insert a row with type='approved' succeeds
  "$SQLITE3" "$FIXTURE_DB" \
    "INSERT INTO closures (finding_id, closure_commit, closure_review_id, closure_type)
     VALUES (1, 'abc123', 1, 'approved')" 2>/dev/null
  RC3=$?
  if [ "$RC3" -eq 0 ]; then
    _check "closures-insert-approved" "pass"
  else
    _check "closures-insert-approved" "fail: insert failed rc=$RC3"
  fi

  # Test 4: closures CHECK constraint rejects invalid closure_type
  "$SQLITE3" "$FIXTURE_DB" \
    "INSERT INTO closures (finding_id, closure_commit, closure_type)
     VALUES (1, 'abc', 'invalid_type')" 2>/dev/null
  RC4=$?
  if [ "$RC4" -ne 0 ]; then
    _check "closures-check-constraint" "pass"
  else
    _check "closures-check-constraint" "fail: expected constraint violation, got exit 0"
  fi

  # Test 5: fix_rejected_queue — insert a row succeeds
  "$SQLITE3" "$FIXTURE_DB" \
    "INSERT INTO fix_rejected_queue (finding_ids, fix_commit, rejection_review_id, rejection_summary)
     VALUES ('[1,2]', 'def456', 1, 'still has issues')" 2>/dev/null
  RC5=$?
  if [ "$RC5" -eq 0 ]; then
    _check "fix_rejected_queue-insert" "pass"
  else
    _check "fix_rejected_queue-insert" "fail: insert failed rc=$RC5"
  fi

  # Test 6: indexes created
  IDX_COUNT=$("$SQLITE3" "$FIXTURE_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND tbl_name IN ('closures','fix_rejected_queue')")
  if [ "${IDX_COUNT:-0}" -ge 3 ]; then
    _check "indexes-created" "pass"
  else
    _check "indexes-created" "fail: expected >=3 indexes, got $IDX_COUNT"
  fi

  # Test 7: no rows were left in closures or frq from the tests above
  CLOSURES_N=$("$SQLITE3" "$FIXTURE_DB" "SELECT COUNT(*) FROM closures")
  FRQ_N=$("$SQLITE3" "$FIXTURE_DB" "SELECT COUNT(*) FROM fix_rejected_queue")
  if [ "$CLOSURES_N" -gt 0 ] && [ "$FRQ_N" -gt 0 ]; then
    _check "rows-written-during-tests" "pass"
  else
    _check "rows-written-during-tests" "fail: closures=$CLOSURES_N frq=$FRQ_N"
  fi

  TOTAL=$((PASS+FAIL))
  echo ""
  if [ "$FAIL" -eq 0 ]; then
    echo "${PASS}/${TOTAL} PASS"
    exit 0
  else
    echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
    exit 1
  fi
fi

# ── Prerequisites ──────────────────────────────────────────────────────────────

if [ ! -x "$SQLITE3" ]; then
  echo "ERROR: sqlite3 not found at $SQLITE3" >&2
  exit 1
fi

if [ ! -f "$ROBOREV_DB" ]; then
  echo "ERROR: reviews.db not found at $ROBOREV_DB" >&2
  echo "  Set ROBOREV_DB env var or ensure ~/.roborev/ is initialised." >&2
  exit 1
fi

# ── Apply migration ────────────────────────────────────────────────────────────

echo "roborev_migrate_component5: applying migration to ${ROBOREV_DB}"

"$SQLITE3" "$ROBOREV_DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=10000;

-- ── closures ────────────────────────────────────────────────────────────────
-- One row per auto-closed finding.
-- closure_type values:
--   'approved'  = re-review passed; auto-closed by Component 5
--   'wontfix'   = commit message used "wontfix roborev #N"
--   'manual'    = closed by a human via `roborev close`
--   'stale'     = no follow-up commit within 30 days
--
-- FK references are kept loose (no FOREIGN KEY constraint) to avoid
-- migration-order failures on partial DBs.

CREATE TABLE IF NOT EXISTS closures (
  id                    INTEGER  PRIMARY KEY AUTOINCREMENT,
  finding_id            INTEGER  NOT NULL,
  closure_commit        TEXT,
  closure_review_id     INTEGER,
  closure_type          TEXT     NOT NULL
                          CHECK(closure_type IN ('approved','wontfix','manual','stale')),
  closure_reason        TEXT,
  created_at            TEXT     NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_closures_finding_id
  ON closures(finding_id);

CREATE INDEX IF NOT EXISTS idx_closures_commit
  ON closures(closure_commit);

CREATE INDEX IF NOT EXISTS idx_closures_type
  ON closures(closure_type);

-- ── fix_rejected_queue ───────────────────────────────────────────────────────
-- One row per fix commit that re-review rejected.
-- finding_ids is a JSON array of integers, e.g. [1551, 1545].
-- resolved = 0 → needs human triage; 1 → triaged.

CREATE TABLE IF NOT EXISTS fix_rejected_queue (
  id                   INTEGER  PRIMARY KEY AUTOINCREMENT,
  finding_ids          TEXT     NOT NULL,
  fix_commit           TEXT     NOT NULL,
  rejection_review_id  INTEGER,
  rejection_summary    TEXT,
  created_at           TEXT     NOT NULL DEFAULT (datetime('now')),
  resolved             INTEGER  NOT NULL DEFAULT 0,
  resolved_at          TEXT
);

CREATE INDEX IF NOT EXISTS idx_frq_resolved
  ON fix_rejected_queue(resolved)
  WHERE resolved = 0;

CREATE INDEX IF NOT EXISTS idx_frq_fix_commit
  ON fix_rejected_queue(fix_commit);

-- Verify tables exist
SELECT
  'migration_component5' AS label,
  (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='closures')           AS closures_exists,
  (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='fix_rejected_queue') AS frq_exists;
SQL

RC=$?
if [ "$RC" -ne 0 ]; then
  echo "ERROR: migration SQL failed (rc=$RC)" >&2
  exit 1
fi

echo "roborev_migrate_component5: done"
