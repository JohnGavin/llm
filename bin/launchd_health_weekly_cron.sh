#!/usr/bin/env bash
# launchd_health_weekly_cron.sh — Cron wrapper for the weekly launchd health check.
#
# Steps:
#   0. Write housekeeping_runs start row (if duckdb available)
#   1. Generate the markdown report via launchd_health_report.R
#   1b. Write launchd_health_events rows to unified.duckdb (one per canonical plist)
#   2. Send the email via send_launchd_health_email.R
#   3. Update housekeeping_runs end row
#
# unified.duckdb writes: gracefully skipped when duckdb is absent.
# Tables written: housekeeping_runs, launchd_health_events
# See: unified-observability-schema rule, llm#554, llm#550
#
# Invoked by: com.claude.launchd-health-weekly.plist (Sunday 09:00)
#
# Environment variables (set in ~/.claude/.env or plist EnvironmentVariables):
#   GMAIL_USERNAME        Gmail sender
#   GMAIL_APP_PASSWORD    Gmail app password
#   REPORT_RECIPIENT      Override recipient
#   EMAIL_DRY_RUN         Set to 1 to print body without sending
#   LAUNCHD_LEDGER        Override DuckDB ledger path
#   CLOUD_REPOS           Override repos for cloud-cron enumeration
#   SKIP_CRON_PULL        Set to 1 to skip git ff-only pull (testing only)
#   UNIFIED_DB_PATH       Override unified DuckDB path
#
# Manual run (dry):
#   EMAIL_DRY_RUN=1 SKIP_CRON_PULL=1 bash bin/launchd_health_weekly_cron.sh
#
# Tracked in llm#300, llm#554.

set -uo pipefail

# ── PATH (launchd runs with a bare PATH) ──────────────────────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ── Paths ──────────────────────────────────────────────────────────────────────

REPO_ROOT="${REPO_ROOT:-$HOME/docs_gh/llm}"
SCRIPTS_DIR="$REPO_ROOT/.claude/scripts"
LAUNCHD_DIR="$REPO_ROOT/.claude/launchd"
LOG_DIR="${LOG_DIR:-$HOME/.claude/logs}"
LOG_FILE="$LOG_DIR/launchd_health_weekly.log"
REPORT_OUT="$LOG_DIR/launchd_health_report_$(date +%Y-%m-%d).md"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"
LOCK_FILE="/tmp/launchd_health_weekly_cron.lock"

EMAIL_DRY_RUN="${EMAIL_DRY_RUN:-0}"
export EMAIL_DRY_RUN

# ── Logging ────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s: launchd_health_weekly_cron %s\n' "${ts}" "$1" | tee -a "${LOG_FILE}"
}

log "=== launchd_health_weekly_cron.sh starting (EMAIL_DRY_RUN=${EMAIL_DRY_RUN}) ==="

# ── Lock ──────────────────────────────────────────────────────────────────────
if [ -f "${LOCK_FILE}" ]; then
  existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
  if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
    log "SKIP: another instance running (PID ${existing_pid})"
    exit 0
  fi
fi
printf '%d' "$$" > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# ── Source credentials if available ───────────────────────────────────────────

ENV_FILE="$HOME/.claude/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  log "sourced credentials from $ENV_FILE"
fi

# GMAIL creds for the Step 2 health email live in a separate secured env file
# (the same one the roborev email cron sources — bin/roborev_weekly_rollup_cron.sh).
# Without this, send_launchd_health_email.R aborts with "GMAIL_USERNAME or
# GMAIL_APP_PASSWORD not set" and the whole job exits 1 (#749 Part A).
EMAIL_ENV_FILE="$HOME/.claude/env/roborev_email.env"
if [[ -f "$EMAIL_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$EMAIL_ENV_FILE"
  log "sourced email credentials from $EMAIL_ENV_FILE"
fi

# ── Deploy: pull latest main before running (llm#510) ─────────────────────────
# Cron wrappers run against ${REPO_ROOT}; without this step every gh pr merge
# ships nothing — the cron uses whatever was last manually pulled to the main
# checkout. The fast-forward is silent on success and never overwrites local
# work because of --ff-only.
if [ -z "${SKIP_CRON_PULL:-}" ]; then
    git -C "${REPO_ROOT}" fetch origin main 2>/dev/null
    if git -C "${REPO_ROOT}" merge --ff-only origin/main 2>/dev/null; then
        log "deploy: ff to $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    else
        log "deploy WARN: ff-only failed — running against $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    fi
fi
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"

# ── Verify nix-shell is accessible (mirrors roborev_daily_cron.sh) ────────────
# All R calls use nix-shell so R_LIBS_SITE and the full package environment
# are inherited — calling the Rscript binary directly loses those.

LLM_NIX="${REPO_ROOT}/default.nix"
NIX_SHELL_BIN="/nix/var/nix/profiles/default/bin/nix-shell"

if [ ! -f "${LLM_NIX}" ]; then
  log "ERROR: nix file not found at ${LLM_NIX}"
  exit 1
fi
if [ ! -x "${NIX_SHELL_BIN}" ]; then
  log "ERROR: nix-shell not found at ${NIX_SHELL_BIN} (PATH=${PATH})"
  exit 1
fi
log "using nix-shell: ${NIX_SHELL_BIN}"

# ── DuckDB availability check (llm#554) ───────────────────────────────────────
# Gracefully skip all DB writes when duckdb binary or unified.duckdb is absent.
# Same defensive pattern as config_digest_cron.sh (llm#552).
_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "${UNIFIED_DB}" ]; then
  _duckdb_ok=1
  log "duckdb: available at ${UNIFIED_DB}"
else
  log "duckdb: not available — skipping DB writes"
fi

# Run ID and start timestamp for this invocation (bash-native, no python3 — llm#569)
_run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
_run_started="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# ── Step 0: Write housekeeping_runs start row ─────────────────────────────────
if [ "${_duckdb_ok}" = "1" ]; then
  _script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/launchd_health_weekly_cron.sh"
  duckdb "${UNIFIED_DB}" "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, status, rows_written)
    VALUES (
      '${_run_id}',
      'launchd_health',
      '${_script_abs}',
      TIMESTAMPTZ '${_run_started}',
      'ok',
      0
    );
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs INSERT failed (non-fatal)"
fi

# ── Step 1: Generate markdown report ─────────────────────────────────────────

log "Step 1: generating launchd health report → ${REPORT_OUT}"
"${NIX_SHELL_BIN}" "${LLM_NIX}" --run "Rscript '${SCRIPTS_DIR}/launchd_health_report.R' --out '${REPORT_OUT}'" 2>>"${LOG_FILE}"
STEP1_EXIT=$?
if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "WARNING: launchd_health_report.R exited ${STEP1_EXIT} — continuing"
fi
log "Step 1 done (exit=${STEP1_EXIT}, $(wc -l < "${REPORT_OUT}" 2>/dev/null || echo '?') lines)"

# ── Step 1b: Write launchd_health_events rows (llm#554 Phase A) ──────────────
# Enumerate every canonical plist (com.claude.*.plist, excluding .deprecated*).
# For each plist label, query launchctl for its state and write one row.
#
# launchctl print output (macOS):
#   - "state = not running" | "state = running"
#   - "runs = N"           (0 if never run)
#   - "last exit code = N" | "last exit code = (never exited)"
#
# Note: launchctl print does not expose next_fire_at / last_fired_at in a
# stable parseable format across macOS versions, so those columns are NULL.
# This is documented in the schema comment.
#
# Bash-native UUID and ISO timestamp (no python3 — complies with llm#569).
_EVENTS_WRITTEN=0
_fired_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
_uid="$(id -u)"

if [ "${_duckdb_ok}" = "1" ]; then
  log "Step 1b: writing launchd_health_events to unified.duckdb..."

  for _plist_path in "${LAUNCHD_DIR}"/com.claude.*.plist; do
    # Skip deprecated plists (e.g. .plist.deprecated-YYYY-MM-DD)
    case "${_plist_path}" in
      *.deprecated*) continue ;;
    esac

    # Extract label from filename: com.claude.worktree-gc.plist → com.claude.worktree-gc
    _plist_file="$(basename "${_plist_path}")"
    _label="${_plist_file%.plist}"

    # Query launchctl for this plist's state
    # launchctl print exits non-zero (e.g. 113) if the service is not loaded.
    # We capture stdout and a separate exit code via a temp file to avoid
    # the || true masking the exit code.
    _lctl_out=""
    _lctl_exit=0
    _lctl_out="$(launchctl print "gui/${_uid}/${_label}" 2>/dev/null)" || _lctl_exit=$?

    _state="unloaded"
    _last_exit_code_raw=""
    _exit_code_val=""
    _detail=""

    if [ "${_lctl_exit}" -ne 0 ] || [ -z "${_lctl_out}" ]; then
      # launchctl returned non-zero or empty: service is not loaded
      _state="unloaded"
      _detail="launchctl print exited ${_lctl_exit} (service not loaded or not found)"
    else
      # Parse "last exit code = N" or "last exit code = (never exited)"
      _last_exit_code_raw="$(printf '%s' "${_lctl_out}" | grep 'last exit code' | head -1 | sed 's/.*last exit code = //' | tr -d '[:space:]')"

      if [ -z "${_last_exit_code_raw}" ]; then
        # Could not parse exit code — service is loaded but state unknown
        _state="missing"
        _detail="launchctl output parsed but 'last exit code' line not found"
      elif [ "${_last_exit_code_raw}" = "(neverexited)" ] || [ "${_last_exit_code_raw}" = "(never" ]; then
        # Never exited → loaded, never run → loaded_ok (exit code is effectively 0)
        _exit_code_val=""  # NULL in DB — never ran
        _state="loaded_ok"
        _detail="loaded; never run (runs=0)"
      else
        # Numeric exit code
        _exit_code_val="${_last_exit_code_raw}"
        # Parse "runs = N" to include in detail
        _runs="$(printf '%s' "${_lctl_out}" | grep '^\s*runs = ' | head -1 | sed 's/.*runs = //' | tr -d '[:space:]')"

        # Exit code 78 = launchd "no more processes" (normal scheduled job idle state)
        # Exit code 0 = success
        if [ "${_exit_code_val}" = "0" ] || [ "${_exit_code_val}" = "78" ]; then
          _state="loaded_ok"
          _detail="runs=${_runs:-?}; last_exit=${_exit_code_val}"
        else
          _state="loaded_recent_fail"
          _detail="runs=${_runs:-?}; last_exit=${_exit_code_val}"
        fi
      fi
    fi

    # Generate UUID for the row (bash-native)
    _evt_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

    # Build the INSERT — handle NULL exit code when never exited
    if [ -n "${_exit_code_val}" ]; then
      _exit_col="${_exit_code_val}"
    else
      _exit_col="NULL"
    fi

    # Escape single quotes in detail string
    _detail_sql="${_detail//"'"/"''"}"

    duckdb "${UNIFIED_DB}" "
      INSERT OR IGNORE INTO launchd_health_events
        (id, fired_at, source, plist_label, state, last_exit_code, last_fired_at, next_fire_at, detail)
      VALUES (
        '${_evt_id}',
        TIMESTAMPTZ '${_fired_at}',
        'launchd_health_weekly_cron.sh',
        '${_label}',
        '${_state}',
        ${_exit_col},
        NULL,
        NULL,
        '${_detail_sql}'
      );
    " 2>/dev/null || log "duckdb WARN: launchd_health_events INSERT failed for ${_label} (non-fatal)"

    _EVENTS_WRITTEN=$(( _EVENTS_WRITTEN + 1 ))
    log "  ${_label}: ${_state} (exit=${_exit_code_val:-never})"
  done

  log "Step 1b done: ${_EVENTS_WRITTEN} launchd_health_events rows written"
else
  log "Step 1b: skipped (duckdb not available)"
fi

# ── Step 2: Send email ─────────────────────────────────────────────────────────

export LAUNCHD_SCRIPTS_DIR="${SCRIPTS_DIR}"
log "Step 2: sending launchd health email..."
"${NIX_SHELL_BIN}" "${LLM_NIX}" --run "Rscript '${SCRIPTS_DIR}/send_launchd_health_email.R'" 2>>"${LOG_FILE}"
STEP2_EXIT=$?

if [ "${STEP2_EXIT}" -ne 0 ]; then
  log "ERROR: send_launchd_health_email.R exited ${STEP2_EXIT}"
  # Update housekeeping_runs with failed status before exiting
  if [ "${_duckdb_ok}" = "1" ]; then
    _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    duckdb "${UNIFIED_DB}" "
      UPDATE housekeeping_runs
      SET ended_at = TIMESTAMPTZ '${_run_ended}',
          status = 'failed',
          rows_written = ${_EVENTS_WRITTEN}
      WHERE id = '${_run_id}';
    " 2>/dev/null || true
  fi
  exit "${STEP2_EXIT}"
fi
log "Step 2 done"

# ── Step 3: Update housekeeping_runs end row ──────────────────────────────────
if [ "${_duckdb_ok}" = "1" ]; then
  _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  duckdb "${UNIFIED_DB}" "
    UPDATE housekeeping_runs
    SET ended_at = TIMESTAMPTZ '${_run_ended}',
        rows_written = ${_EVENTS_WRITTEN}
    WHERE id = '${_run_id}';
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs UPDATE failed (non-fatal)"
  log "Step 3: housekeeping_runs updated (rows_written=${_EVENTS_WRITTEN})"
fi

# ── Step 4: Prune old reports (keep 30 days) ──────────────────────────────────

find "${LOG_DIR}" -name "launchd_health_report_*.md" -mtime +30 -delete 2>/dev/null || true
log "Step 4: pruned old reports"

log "=== launchd_health_weekly_cron.sh done ==="
