#!/bin/bash
# roborev_bridge_to_unified.sh -- Daily bridge: roborev SQLite -> unified.duckdb.
#
# Reads per-project aggregates from roborev's own SQLite DB (~/.roborev/reviews.db)
# and writes summary rows to unified.duckdb. This is a READ-ONLY mirror --
# roborev keeps owning its data; we never write to roborev's DB.
#
# Roborev SQLite schema observed 2026-06-08 (~/.roborev/reviews.db):
#   repos(id, root_path, name, created_at, identity)
#   review_jobs(id, repo_id, commit_id, git_ref, branch, status, finished_at, ...)
#   reviews(id, job_id, agent, output, created_at, closed, verdict_bool, ...)
#   closures(id, finding_id, closure_commit_sha, closure_type, created_at, ...)
#
# Key schema notes:
#   - No dedicated severity column; severity is embedded in reviews.output text
#     as markdown: "**Severity**: High|Medium|Low"
#   - Canonical project name = repos.name (lowercase basename stored by roborev)
#   - autoclose is identified by closures.closure_type = 'stale'
#
# Severity terminology (actual roborev values): High | Medium | Low
#   (NOT Critical/Major/Minor -- issue #555 body used different names)
#
# Canonical project naming: data-glossary-and-entity-resolution rule (#474).
#   We use repos.name directly from roborev (already canonical; no alias map needed).
#
# Steps:
#   0. Write housekeeping_runs start row (if duckdb available)
#   1. Locate and validate roborev SQLite DB (graceful skip if absent)
#   2. Query per-project aggregates for the 24h window
#   3. INSERT rows into roborev_daily_summary (INSERT OR IGNORE -- idempotent)
#   4. Update housekeeping_runs end row
#
# UUID generation: uuidgen | tr '[:upper:]' '[:lower:]' (no python3, per llm#569)
# ISO UTC: date -u +'%Y-%m-%dT%H:%M:%SZ'
# Read-only from roborev: NEVER runs INSERT/UPDATE/DELETE on ROBOREV_DB.
#
# Log: ~/.claude/logs/roborev_bridge.log
#
# Manual dry-run (logs what would be inserted, no DB writes):
#   BRIDGE_DRY_RUN=1 bash .claude/scripts/roborev_bridge_to_unified.sh
#
# Skip git pull:
#   SKIP_CRON_PULL=1 BRIDGE_DRY_RUN=1 bash .claude/scripts/roborev_bridge_to_unified.sh
#
# Tracked in llm#555 Phase A.

set -uo pipefail

# -- PATH (launchd runs with a bare PATH) -------------------------------------
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# -- Recursion guard ----------------------------------------------------------
: "${ROBOREV_BRIDGE_DEPTH:=0}"
if (( ROBOREV_BRIDGE_DEPTH > 0 )); then
  echo "[roborev_bridge] ERROR: recursion detected (depth=${ROBOREV_BRIDGE_DEPTH}). Abort." >&2
  exit 1
fi
export ROBOREV_BRIDGE_DEPTH=$(( ROBOREV_BRIDGE_DEPTH + 1 ))

# -- Paths --------------------------------------------------------------------
# SCRIPT_DIR resolves through symlinks so REPO_ROOT is correct whether called
# via ~/.claude/scripts/ symlink or directly from the worktree path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_FILE="${HOME}/.claude/logs/roborev_bridge.log"
LOCK_FILE="/tmp/roborev_bridge_to_unified.lock"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"
ROBOREV_DB="${ROBOREV_DB_PATH:-${HOME}/.roborev/reviews.db}"

BRIDGE_DRY_RUN="${BRIDGE_DRY_RUN:-0}"

# -- Logging ------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s: %s\n' "${ts}" "$1" | tee -a "${LOG_FILE}"
}

log "=== roborev_bridge_to_unified.sh starting (BRIDGE_DRY_RUN=${BRIDGE_DRY_RUN}) ==="

# -- Lock ---------------------------------------------------------------------
if [ -f "${LOCK_FILE}" ]; then
  existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
  if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
    log "SKIP: another instance running (PID ${existing_pid})"
    exit 0
  fi
fi
printf '%d' "$$" > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# -- Deploy: pull latest main (cron-auto-pull-discipline, llm#510) ------------
# Without this step every gh pr merge ships nothing to the cron.
if [ -z "${SKIP_CRON_PULL:-}" ]; then
    git -C "${REPO_ROOT}" fetch origin main 2>/dev/null
    if git -C "${REPO_ROOT}" merge --ff-only origin/main 2>/dev/null; then
        log "deploy: ff to $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    else
        log "deploy WARN: ff-only failed -- running against $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    fi
fi
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"

# -- DuckDB availability check ------------------------------------------------
# Gracefully skip all DB writes when duckdb binary or unified.duckdb is absent.
# Same defensive pattern as config_digest_cron.sh (PR #566).
_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "${UNIFIED_DB}" ]; then
  _duckdb_ok=1
  log "duckdb: available at ${UNIFIED_DB}"
else
  log "duckdb: not available -- skipping DB writes"
fi

# Run ID and timestamps (bash-native, no python3 per llm#569)
_run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
_run_started="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# -- Step 0: Write housekeeping_runs start row --------------------------------
if [ "${_duckdb_ok}" = "1" ] && [ "${BRIDGE_DRY_RUN}" != "1" ]; then
  _script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  duckdb "${UNIFIED_DB}" "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, status, rows_written)
    VALUES (
      '${_run_id}',
      'roborev_bridge',
      '${_script_abs}',
      TIMESTAMPTZ '${_run_started}',
      'ok',
      0
    );
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs INSERT failed (non-fatal)"
fi

# Helper: update housekeeping_runs on failure and exit
_fail_and_exit() {
  local _msg="$1"
  local _exit_code="${2:-1}"
  log "ERROR: ${_msg}"
  if [ "${_duckdb_ok}" = "1" ] && [ "${BRIDGE_DRY_RUN}" != "1" ]; then
    local _ended
    _ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    local _msg_sql="${_msg//"'"/"''"}"
    duckdb "${UNIFIED_DB}" "
      UPDATE housekeeping_runs
      SET ended_at = TIMESTAMPTZ '${_ended}',
          status = 'failed',
          error_text = '${_msg_sql}'
      WHERE id = '${_run_id}';
    " 2>/dev/null || true
  fi
  exit "${_exit_code}"
}

# -- Step 1: Locate and validate roborev SQLite DB ---------------------------
log "Step 1: checking roborev SQLite at ${ROBOREV_DB}..."

if [ ! -f "${ROBOREV_DB}" ]; then
  # Graceful skip: roborev not installed or DB path differs.
  # Update housekeeping_runs with partial status so the digest can detect the gap.
  log "Step 1 SKIP: roborev DB not found at ${ROBOREV_DB} -- nothing to mirror"
  if [ "${_duckdb_ok}" = "1" ] && [ "${BRIDGE_DRY_RUN}" != "1" ]; then
    _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    duckdb "${UNIFIED_DB}" "
      UPDATE housekeeping_runs
      SET ended_at = TIMESTAMPTZ '${_run_ended}',
          status = 'partial',
          error_text = 'roborev DB not found'
      WHERE id = '${_run_id}';
    " 2>/dev/null || true
  fi
  log "=== roborev_bridge_to_unified.sh done (skip: no DB) ==="
  exit 0
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  _fail_and_exit "sqlite3 not on PATH -- cannot read ${ROBOREV_DB}"
fi

# Sanity check: DB is readable and has the repos table
_db_repo_count="$(sqlite3 "${ROBOREV_DB}" "SELECT COUNT(*) FROM repos;" 2>&1)"
_db_exit=$?
if [ "${_db_exit}" -ne 0 ]; then
  _fail_and_exit "roborev DB not readable (sqlite3 exit=${_db_exit}): ${_db_repo_count}"
fi
log "Step 1 done: roborev DB readable, ${_db_repo_count} repos"

# -- Step 2+3: Query per-project aggregates and INSERT rows ------------------
# Window: 24h ending now.
_now_ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
_since_ts="$(date -u -v -24H +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '24 hours ago' +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u +'%Y-%m-%dT00:00:00Z')"
_window_date="$(date -u +'%Y-%m-%d')"

log "Step 2: querying roborev per-project aggregates (window: ${_since_ts} -> ${_now_ts})..."

_ROWS_WRITTEN=0
_ROWS_ATTEMPTED=0

# Aggregation SQL.
# Severity is embedded in reviews.output as markdown: "**Severity**: High|Medium|Low".
# autoclose_today = closures with closure_type='stale' in last 24h.
#   closures may legitimately have 0 rows (e.g. before any stale auto-closures
#   accrue); COALESCE(,0) returns 0 in that case -- not a bug.
# oldest_open_days = max age in days of any open finding via review_jobs.finished_at.
# Only returns projects with open reviews OR recent activity.
# LEFT JOIN review_jobs: intentionally no review_jobs.status filter -- jobs that
#   crashed before producing a reviews row (status='failed' after #677 reclassify)
#   still surface their reviews rows if present; jobs with no reviews row yield
#   NULL columns, all handled by the COALESCE(,0) wrappers above.
_SQLITE_QUERY="
SELECT
  r.name AS project,
  COALESCE(SUM(CASE WHEN rv.closed = 0 THEN 1 ELSE 0 END), 0) AS total_open,
  COALESCE(SUM(CASE
    WHEN rv.closed = 1
     AND datetime(rv.created_at) >= datetime('now', '-1 day')
    THEN 1 ELSE 0 END), 0) AS closed_today,
  COALESCE(SUM(CASE
    WHEN rv.closed = 0
     AND (rv.output LIKE '%Severity**: High%'
       OR rv.output LIKE '%severity**: high%'
       OR rv.output LIKE '%**Severity**: High%')
    THEN 1 ELSE 0 END), 0) AS high_open,
  COALESCE(SUM(CASE
    WHEN rv.closed = 0
     AND (rv.output LIKE '%Severity**: Medium%'
       OR rv.output LIKE '%severity**: medium%'
       OR rv.output LIKE '%**Severity**: Medium%')
    THEN 1 ELSE 0 END), 0) AS medium_open,
  COALESCE(SUM(CASE
    WHEN rv.closed = 0
     AND (rv.output LIKE '%Severity**: Low%'
       OR rv.output LIKE '%severity**: low%'
       OR rv.output LIKE '%**Severity**: Low%')
    THEN 1 ELSE 0 END), 0) AS low_open,
  COALESCE(MAX(CASE
    WHEN rv.closed = 0 AND rj.finished_at IS NOT NULL
    THEN CAST((julianday('now') - julianday(rj.finished_at)) AS INTEGER)
    ELSE 0 END), 0) AS oldest_open_days,
  COALESCE(SUM(CASE
    WHEN cl.closure_type = 'stale'
     AND datetime(cl.created_at) >= datetime('now', '-1 day')
    THEN 1 ELSE 0 END), 0) AS autoclose_today
FROM repos r
LEFT JOIN review_jobs rj ON rj.repo_id = r.id
LEFT JOIN reviews rv ON rv.job_id = rj.id
LEFT JOIN closures cl ON cl.finding_id = rv.id
GROUP BY r.name
HAVING total_open > 0 OR closed_today > 0 OR autoclose_today > 0
ORDER BY total_open DESC;
"

log "Step 3: INSERTing roborev_daily_summary rows to unified.duckdb..."

while IFS='|' read -r _project _total_open _closed_today _high _medium _low _oldest_days _autoclose; do
  [ -z "${_project}" ] && continue
  _ROWS_ATTEMPTED=$(( _ROWS_ATTEMPTED + 1 ))

  # Deterministic PK from md5("<project>:<window_date>") formatted as UUID.
  # Ensures INSERT OR IGNORE is a true no-op on re-runs within the same day.
  _pk_seed="${_project}:${_window_date}"
  if command -v md5sum >/dev/null 2>&1; then
    _pk_hex="$(printf '%s' "${_pk_seed}" | md5sum | cut -c1-32)"
  elif command -v md5 >/dev/null 2>&1; then
    _pk_hex="$(printf '%s' "${_pk_seed}" | md5 | cut -c1-32)"
  else
    # Fallback: random UUID (loses within-day idempotency, but safe)
    _pk_hex="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  fi
  _row_id="${_pk_hex:0:8}-${_pk_hex:8:4}-${_pk_hex:12:4}-${_pk_hex:16:4}-${_pk_hex:20:12}"

  # SQL-escape single quotes in project name
  _project_sql="${_project//"'"/"''"}"

  # Top-3 findings snippet for digest context (highest severity first)
  _detail_json="null"
  _top3_output="$(sqlite3 "${ROBOREV_DB}" "
    SELECT substr(rv.output, 1, 200)
    FROM reviews rv
    JOIN review_jobs rj ON rv.job_id = rj.id
    JOIN repos r ON rj.repo_id = r.id
    WHERE r.name = '${_project}' AND rv.closed = 0
    ORDER BY
      CASE
        WHEN rv.output LIKE '%Severity**: High%' OR rv.output LIKE '%severity**: high%' THEN 1
        WHEN rv.output LIKE '%Severity**: Medium%' OR rv.output LIKE '%severity**: medium%' THEN 2
        ELSE 3
      END,
      rv.created_at DESC
    LIMIT 3;
  " 2>/dev/null || true)"

  if [ -n "${_top3_output}" ]; then
    _top3_clean="$(printf '%s' "${_top3_output}" | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-500)"
    _detail_json="\"${_top3_clean}\""
  fi

  if [ "${BRIDGE_DRY_RUN}" = "1" ]; then
    log "  DRY-RUN: project=${_project} open=${_total_open} high=${_high} med=${_medium} low=${_low} oldest=${_oldest_days}d autoclose=${_autoclose}"
    _ROWS_WRITTEN=$(( _ROWS_WRITTEN + 1 ))
    continue
  fi

  if [ "${_duckdb_ok}" = "1" ]; then
    duckdb "${UNIFIED_DB}" "
      INSERT OR IGNORE INTO roborev_daily_summary
        (id, fired_at, window_start, window_end, project,
         total_reviews_open, total_reviews_closed_today,
         high_open, medium_open, low_open,
         oldest_open_days, autoclose_today,
         source_db_path, detail_json)
      VALUES (
        '${_row_id}',
        TIMESTAMPTZ '${_now_ts}',
        TIMESTAMPTZ '${_since_ts}',
        TIMESTAMPTZ '${_now_ts}',
        '${_project_sql}',
        ${_total_open},
        ${_closed_today},
        ${_high},
        ${_medium},
        ${_low},
        ${_oldest_days},
        ${_autoclose},
        '${ROBOREV_DB}',
        ${_detail_json}
      );
    " 2>/dev/null || log "  WARN: INSERT failed for project=${_project} (INSERT OR IGNORE -- non-fatal)"
    _ROWS_WRITTEN=$(( _ROWS_WRITTEN + 1 ))
    log "  inserted: project=${_project} open=${_total_open} high=${_high} med=${_medium} low=${_low} oldest=${_oldest_days}d"
  else
    log "  SKIP (duckdb unavailable): project=${_project} open=${_total_open}"
  fi
done < <(sqlite3 "${ROBOREV_DB}" "${_SQLITE_QUERY}" 2>/dev/null || true)

log "Step 3 done: attempted=${_ROWS_ATTEMPTED} written=${_ROWS_WRITTEN}"

# Anomaly detection: warn if DB has repos but zero active projects found.
# Signals roborev's own writer may be broken.
if [ "${_ROWS_ATTEMPTED}" = "0" ] && [ "${_db_repo_count:-0}" != "0" ]; then
  log "WARN: roborev DB has ${_db_repo_count} repos but zero active projects -- roborev writer may be broken"
fi

# -- Step 4: Update housekeeping_runs end row ---------------------------------
if [ "${_duckdb_ok}" = "1" ] && [ "${BRIDGE_DRY_RUN}" != "1" ]; then
  _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  duckdb "${UNIFIED_DB}" "
    UPDATE housekeeping_runs
    SET ended_at = TIMESTAMPTZ '${_run_ended}',
        rows_written = ${_ROWS_WRITTEN}
    WHERE id = '${_run_id}';
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs UPDATE failed (non-fatal)"
  log "Step 4: housekeeping_runs updated (rows_written=${_ROWS_WRITTEN})"
fi

log "=== roborev_bridge_to_unified.sh done ==="
