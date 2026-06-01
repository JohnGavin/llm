#!/usr/bin/env bash
# roborev_auto_close.sh — safe auto-close with four hard safety guards.
#
# Called by the Component 4 verifier (roborev_auto_verify.sh) after a
# re-review produces a verdict.  Can also be called directly.
#
# FOUR HARD SAFETY GUARDS (in evaluation order):
#   1. Severity downgrade-attack guard:
#      NEVER auto-close a Critical or High severity finding when the
#      approving review is Medium-only severity.
#   2. Security / error-handling queue guard:
#      Security and error-handling findings are NOT auto-closed. They are
#      inserted into fix_rejected_queue for human dispatch.
#   3. Won't-fix tag guard:
#      Won't-fix closures require a "[reason: ...]" tag in the commit
#      message. The closure is rejected without this tag.
#   4. Stale closure (informational — handled separately by roborev_autoclose.sh):
#      When called with --type stale, the guard is bypassed and the finding
#      is closed with closure_type='stale' plus a mandatory audit log line.
#
# Usage:
#   bash roborev_auto_close.sh \
#     --finding-id <N> \
#     --approving-review-id <M> \
#     --commit <SHA> \
#     [--type approved|wontfix|stale] \
#     [--reason "human readable reason"]
#
#   Returns structured output on stdout:
#     CLOSED=1  closure_type=approved finding_id=<N>
#     QUEUED=1  queue_reason=security_finding  finding_id=<N>
#     REJECTED=1  reject_reason=<text>  finding_id=<N>
#
# Exit codes:
#   0 = closed or queued (expected outcomes — check CLOSED/QUEUED to distinguish)
#   1 = guard rejected the closure (REJECTED=1)
#   2 = hard error (DB unavailable, bad arguments)
#
# Self-test:
#   CLAUDE_HOOK_SELFTEST=1 bash roborev_auto_close.sh
#
# Log: ~/.claude/logs/roborev_auto_close.log
# Issue: JohnGavin/llm#354, parent #163

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROBOREV_DB="${ROBOREV_DB:-${HOME}/.roborev/reviews.db}"
SQLITE3="${SQLITE3:-$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)}"
LOGFILE="${HOME}/.claude/logs/roborev_auto_close.log"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s %s\n' "$ts" "$*" >> "$LOGFILE"
}

# ── Severity helpers ──────────────────────────────────────────────────────────

# Parse the maximum severity from a review output string.
# Returns: Critical | High | Medium | Low | unknown
_parse_max_severity() {
  local output="$1"
  /usr/bin/python3 - "$output" <<'PY'
import sys, re

text = sys.argv[1] if len(sys.argv) > 1 else ""
PATTERN = r'\*\*Severity\*\*:\s*(Critical|High|Medium|Low)'
LEVELS   = {"Low": 1, "Medium": 2, "High": 3, "Critical": 4}

matches = re.findall(PATTERN, text, re.IGNORECASE)
if not matches:
    print("unknown")
else:
    best = max(matches, key=lambda s: LEVELS.get(s.capitalize(), 0))
    print(best.capitalize())
PY
}

# Return ordinal for severity name (Critical=4, High=3, Medium=2, Low=1, unknown=0)
_severity_ordinal() {
  case "${1,,}" in
    critical) echo 4 ;;
    high)     echo 3 ;;
    medium)   echo 2 ;;
    low)      echo 1 ;;
    *)        echo 0 ;;
  esac
}

# ── Self-test ──────────────────────────────────────────────────────────────────

if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  _check() {
    local label="$1" result="$2"
    if [ "$result" = "pass" ]; then
      PASS=$((PASS+1)); echo "  PASS [$label]"
    else
      FAIL=$((FAIL+1)); echo "  FAIL [$label]: $result"
    fi
  }

  unset CLAUDE_HOOK_SELFTEST

  FIXTURE_DB="$(mktemp "${TMPDIR:-/tmp}/roborev_ac_test_XXXXXX")".db
  rm -f "${FIXTURE_DB%.db}"
  trap 'rm -f "$FIXTURE_DB"' EXIT

  # Seed fixture DB with minimal schema + data
  "$SQLITE3" "$FIXTURE_DB" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, status TEXT DEFAULT 'done');
CREATE TABLE reviews (
  id INTEGER PRIMARY KEY,
  job_id INTEGER NOT NULL,
  closed INTEGER NOT NULL DEFAULT 0,
  verdict_bool INTEGER,
  output TEXT DEFAULT '',
  updated_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE closures (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_id INTEGER NOT NULL,
  closure_commit TEXT,
  closure_review_id INTEGER,
  closure_type TEXT NOT NULL CHECK(closure_type IN ('approved','wontfix','manual','stale')),
  closure_reason TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE fix_rejected_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_ids TEXT NOT NULL,
  fix_commit TEXT NOT NULL,
  rejection_review_id INTEGER,
  rejection_summary TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  resolved INTEGER NOT NULL DEFAULT 0,
  resolved_at TEXT
);
INSERT INTO repos VALUES (1, 'llm');
INSERT INTO review_jobs VALUES (1, 1, 'done');
INSERT INTO review_jobs VALUES (2, 1, 'done');
-- finding 1: High severity open
INSERT INTO reviews VALUES (1, 1, 0, 0, '**Severity**: High
**Location**: R/foo.R:10
**Problem**: dangerous', NULL);
-- finding 2: High severity; approving review is Medium-only (downgrade attack test)
INSERT INTO reviews VALUES (2, 2, 0, 0, '**Severity**: High
**Problem**: issue', NULL);
-- finding 3: security finding
INSERT INTO reviews VALUES (3, 1, 0, 0, '**Severity**: Medium
**Category**: security
**Problem**: token leakage', NULL);
-- finding 4: error-handling finding
INSERT INTO reviews VALUES (4, 1, 0, 0, '**Severity**: Low
**Category**: error-handling
**Problem**: missing tryCatch', NULL);
-- finding 5: High severity, approving review also High — should close
INSERT INTO reviews VALUES (5, 1, 0, 0, '**Severity**: High
**Problem**: issue', NULL);
-- approving review for finding 5 (review_id=6): also High → OK to close
INSERT INTO review_jobs VALUES (6, 1, 'done');
INSERT INTO reviews VALUES (6, 6, 0, 1, '**Severity**: High
**Problem**: still issue', NULL);
-- approving review for downgrade attack (review_id=7): Medium only
INSERT INTO review_jobs VALUES (7, 1, 'done');
INSERT INTO reviews VALUES (7, 7, 0, 1, '**Severity**: Medium
**Problem**: fine', NULL);
SQL

  # ── Test 1: High severity + High approve → closes ─────────────────────────
  OUT=$(ROBOREV_DB="$FIXTURE_DB" bash "$0" \
    --finding-id 5 --approving-review-id 6 --commit "aaa111" --type approved 2>&1)
  if echo "$OUT" | grep -q "^CLOSED=1"; then
    _check "high-severity-high-approve-closes" "pass"
    # Verify row was actually written
    N=$("$SQLITE3" "$FIXTURE_DB" \
      "SELECT COUNT(*) FROM closures WHERE finding_id=5 AND closure_type='approved'")
    if [ "$N" = "1" ]; then
      _check "high-severity-closes-db-row" "pass"
    else
      _check "high-severity-closes-db-row" "fail: closures rows=$N"
    fi
  else
    _check "high-severity-high-approve-closes" "fail: got '$OUT'"
    _check "high-severity-closes-db-row" "fail: not closed"
  fi

  # ── Test 2: High severity + Medium approve → does NOT close (guard 1) ─────
  OUT=$(ROBOREV_DB="$FIXTURE_DB" bash "$0" \
    --finding-id 2 --approving-review-id 7 --commit "bbb222" --type approved 2>&1)
  if echo "$OUT" | grep -q "^REJECTED=1"; then
    _check "high-severity-medium-approve-rejected" "pass"
  else
    _check "high-severity-medium-approve-rejected" "fail: got '$OUT'"
  fi

  # ── Test 3: security finding → queued to fix_rejected_queue (guard 2) ────
  OUT=$(ROBOREV_DB="$FIXTURE_DB" bash "$0" \
    --finding-id 3 --approving-review-id 6 --commit "ccc333" --type approved 2>&1)
  if echo "$OUT" | grep -q "^QUEUED=1"; then
    _check "security-finding-queued" "pass"
    N=$("$SQLITE3" "$FIXTURE_DB" \
      "SELECT COUNT(*) FROM fix_rejected_queue WHERE fix_commit='ccc333'")
    if [ "$N" = "1" ]; then
      _check "security-finding-db-row" "pass"
    else
      _check "security-finding-db-row" "fail: frq rows=$N"
    fi
  else
    _check "security-finding-queued" "fail: got '$OUT'"
    _check "security-finding-db-row" "fail: not queued"
  fi

  # ── Test 4: won't-fix without [reason:] tag → rejected (guard 3) ──────────
  OUT=$(ROBOREV_DB="$FIXTURE_DB" bash "$0" \
    --finding-id 1 --approving-review-id 6 --commit "ddd444" --type wontfix 2>&1)
  if echo "$OUT" | grep -q "^REJECTED=1"; then
    _check "wontfix-without-reason-rejected" "pass"
  else
    _check "wontfix-without-reason-rejected" "fail: got '$OUT'"
  fi

  # ── Test 5: won't-fix WITH [reason:] tag → closes ─────────────────────────
  OUT=$(ROBOREV_DB="$FIXTURE_DB" bash "$0" \
    --finding-id 1 --approving-review-id 6 --commit "eee555" \
    --type wontfix --reason "deprecated API, no active users" 2>&1)
  if echo "$OUT" | grep -q "^CLOSED=1"; then
    _check "wontfix-with-reason-closes" "pass"
    N=$("$SQLITE3" "$FIXTURE_DB" \
      "SELECT COUNT(*) FROM closures WHERE finding_id=1 AND closure_type='wontfix'")
    if [ "$N" = "1" ]; then
      _check "wontfix-with-reason-db-row" "pass"
    else
      _check "wontfix-with-reason-db-row" "fail: closures rows=$N"
    fi
  else
    _check "wontfix-with-reason-closes" "fail: got '$OUT'"
    _check "wontfix-with-reason-db-row" "fail: not closed"
  fi

  # ── Test 6: stale closure → closes as 'stale' (guard 4 bypassed) ──────────
  OUT=$(ROBOREV_DB="$FIXTURE_DB" bash "$0" \
    --finding-id 4 --approving-review-id 6 --commit "" --type stale 2>&1)
  if echo "$OUT" | grep -q "^CLOSED=1"; then
    _check "stale-closure-closes" "pass"
    N=$("$SQLITE3" "$FIXTURE_DB" \
      "SELECT COUNT(*) FROM closures WHERE finding_id=4 AND closure_type='stale'")
    if [ "$N" = "1" ]; then
      _check "stale-closure-db-row" "pass"
    else
      _check "stale-closure-db-row" "fail: closures rows=$N"
    fi
  else
    _check "stale-closure-closes" "fail: got '$OUT'"
    _check "stale-closure-db-row" "fail: not closed"
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

# ── Argument parsing ───────────────────────────────────────────────────────────

FINDING_ID=""
APPROVING_REVIEW_ID=""
COMMIT_SHA=""
CLOSURE_TYPE="approved"
CLOSURE_REASON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --finding-id)
      shift; [ $# -gt 0 ] || { echo "ERROR: --finding-id requires an argument" >&2; exit 2; }
      FINDING_ID="$1"; shift ;;
    --approving-review-id)
      shift; [ $# -gt 0 ] || { echo "ERROR: --approving-review-id requires an argument" >&2; exit 2; }
      APPROVING_REVIEW_ID="$1"; shift ;;
    --commit)
      shift; [ $# -gt 0 ] || { echo "ERROR: --commit requires an argument" >&2; exit 2; }
      COMMIT_SHA="$1"; shift ;;
    --type)
      shift; [ $# -gt 0 ] || { echo "ERROR: --type requires an argument" >&2; exit 2; }
      CLOSURE_TYPE="$1"; shift ;;
    --reason)
      shift; [ $# -gt 0 ] || { echo "ERROR: --reason requires an argument" >&2; exit 2; }
      CLOSURE_REASON="$1"; shift ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -40
      exit 0 ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$FINDING_ID" ]; then
  echo "ERROR: --finding-id is required" >&2; exit 2
fi
if [ -z "$APPROVING_REVIEW_ID" ] && [ "$CLOSURE_TYPE" != "stale" ] && [ "$CLOSURE_TYPE" != "wontfix" ]; then
  echo "ERROR: --approving-review-id is required for closure type '$CLOSURE_TYPE'" >&2; exit 2
fi

# Validate closure_type
case "$CLOSURE_TYPE" in
  approved|wontfix|stale|manual) ;;
  *) echo "ERROR: --type must be one of: approved wontfix stale manual" >&2; exit 2 ;;
esac

# ── Prerequisites ──────────────────────────────────────────────────────────────

if [ ! -f "$ROBOREV_DB" ]; then
  log "SKIP: reviews.db not found at ${ROBOREV_DB}"
  echo "ERROR: reviews.db not found at ${ROBOREV_DB}" >&2
  exit 2
fi

if [ ! -x "$SQLITE3" ]; then
  echo "ERROR: sqlite3 not found" >&2
  exit 2
fi

# ── Guard 3: wontfix requires [reason: ...] ───────────────────────────────────

if [ "$CLOSURE_TYPE" = "wontfix" ] && [ -z "$CLOSURE_REASON" ]; then
  log "REJECTED: finding_id=${FINDING_ID} type=wontfix — missing [reason:] tag"
  printf 'REJECTED=1  reject_reason=wontfix_requires_reason  finding_id=%s\n' "$FINDING_ID"
  exit 1
fi

# ── Guard 4: stale — bypass all other guards, write with audit log ────────────

if [ "$CLOSURE_TYPE" = "stale" ]; then
  log "STALE: auto-closing finding_id=${FINDING_ID} as stale (no follow-up commit in >30 days)"
  "$SQLITE3" "$ROBOREV_DB" <<SQL
PRAGMA busy_timeout=5000;
INSERT INTO closures (finding_id, closure_commit, closure_review_id, closure_type, closure_reason)
VALUES (${FINDING_ID}, $([ -n "$COMMIT_SHA" ] && echo "'${COMMIT_SHA}'" || echo "NULL"),
        NULL, 'stale', 'auto-closed: no follow-up commit within 30 days');
SQL
  RC=$?
  if [ "$RC" -eq 0 ]; then
    log "CLOSED: finding_id=${FINDING_ID} type=stale"
    printf 'CLOSED=1  closure_type=stale  finding_id=%s\n' "$FINDING_ID"
    exit 0
  else
    log "ERR: DB write failed for stale closure finding_id=${FINDING_ID} rc=${RC}"
    exit 2
  fi
fi

# ── Fetch finding severity from DB ────────────────────────────────────────────

FINDING_OUTPUT=$("$SQLITE3" "$ROBOREV_DB" \
  "SELECT output FROM reviews WHERE id=${FINDING_ID} LIMIT 1")
if [ -z "$FINDING_OUTPUT" ]; then
  log "WARN: finding_id=${FINDING_ID} not found in DB or has empty output"
  FINDING_OUTPUT=""
fi
FINDING_SEVERITY=$(_parse_max_severity "$FINDING_OUTPUT")

# ── Fetch approving review severity from DB ───────────────────────────────────

APPROVING_OUTPUT=""
if [ -n "$APPROVING_REVIEW_ID" ]; then
  APPROVING_OUTPUT=$("$SQLITE3" "$ROBOREV_DB" \
    "SELECT output FROM reviews WHERE id=${APPROVING_REVIEW_ID} LIMIT 1")
fi
APPROVING_SEVERITY=$(_parse_max_severity "$APPROVING_OUTPUT")

# ── Guard 2: security / error-handling → queue ────────────────────────────────

IS_SECURITY_FINDING=0
if echo "$FINDING_OUTPUT" | grep -iqE '\*\*Category\*\*:[[:space:]]*(security|error.?handling)'; then
  IS_SECURITY_FINDING=1
fi

if [ "$IS_SECURITY_FINDING" -eq 1 ]; then
  log "QUEUE: finding_id=${FINDING_ID} — security/error-handling finding queued for human dispatch"
  # Insert into fix_rejected_queue
  REASON_SQL="'security or error-handling finding queued for human dispatch'"
  COMMIT_SQL=$([ -n "$COMMIT_SHA" ] && echo "'${COMMIT_SHA}'" || echo "''")
  REVIEW_SQL=$([ -n "$APPROVING_REVIEW_ID" ] && echo "${APPROVING_REVIEW_ID}" || echo "NULL")
  "$SQLITE3" "$ROBOREV_DB" <<SQL
PRAGMA busy_timeout=5000;
INSERT INTO fix_rejected_queue
  (finding_ids, fix_commit, rejection_review_id, rejection_summary)
VALUES ('[${FINDING_ID}]', ${COMMIT_SQL}, ${REVIEW_SQL}, ${REASON_SQL});
SQL
  RC=$?
  if [ "$RC" -eq 0 ]; then
    log "QUEUED: finding_id=${FINDING_ID} commit=${COMMIT_SHA} (security/error-handling guard)"
    printf 'QUEUED=1  queue_reason=security_finding  finding_id=%s\n' "$FINDING_ID"
    exit 0
  else
    log "ERR: DB write to fix_rejected_queue failed rc=${RC} finding_id=${FINDING_ID}"
    exit 2
  fi
fi

# ── Guard 1: severity downgrade-attack ───────────────────────────────────────
#
# NEVER auto-close a Critical or High severity finding when the approving
# review is Medium-only severity.

FINDING_ORD=$(_severity_ordinal "$FINDING_SEVERITY")
APPROVING_ORD=$(_severity_ordinal "$APPROVING_SEVERITY")

# Guard fires when: finding is High/Critical (ord >= 3) AND approving review
# is Medium or lower (ord <= 2).
if [ "$FINDING_ORD" -ge 3 ] && [ "$APPROVING_ORD" -le 2 ] && [ "$APPROVING_ORD" -gt 0 ]; then
  log "REJECTED: finding_id=${FINDING_ID} finding_severity=${FINDING_SEVERITY} approving_severity=${APPROVING_SEVERITY} — downgrade-attack guard"
  printf 'REJECTED=1  reject_reason=severity_downgrade_guard  finding_severity=%s  approving_severity=%s  finding_id=%s\n' \
    "$FINDING_SEVERITY" "$APPROVING_SEVERITY" "$FINDING_ID"
  exit 1
fi

# ── All guards passed — write to closures ─────────────────────────────────────

COMMIT_SQL=$([ -n "$COMMIT_SHA" ] && echo "'${COMMIT_SHA}'" || echo "NULL")
REVIEW_SQL=$([ -n "$APPROVING_REVIEW_ID" ] && echo "${APPROVING_REVIEW_ID}" || echo "NULL")
REASON_SQL=$([ -n "$CLOSURE_REASON" ] && echo "'$(echo "$CLOSURE_REASON" | sed "s/'/''/g")'" || echo "NULL")

"$SQLITE3" "$ROBOREV_DB" <<SQL
PRAGMA busy_timeout=5000;
INSERT INTO closures
  (finding_id, closure_commit, closure_review_id, closure_type, closure_reason)
VALUES
  (${FINDING_ID}, ${COMMIT_SQL}, ${REVIEW_SQL}, '${CLOSURE_TYPE}', ${REASON_SQL});
SQL
RC=$?

if [ "$RC" -ne 0 ]; then
  log "ERR: DB write failed for finding_id=${FINDING_ID} type=${CLOSURE_TYPE} rc=${RC}"
  exit 2
fi

log "CLOSED: finding_id=${FINDING_ID} type=${CLOSURE_TYPE} commit=${COMMIT_SHA} approving_review=${APPROVING_REVIEW_ID}"
printf 'CLOSED=1  closure_type=%s  finding_id=%s\n' "$CLOSURE_TYPE" "$FINDING_ID"
exit 0
