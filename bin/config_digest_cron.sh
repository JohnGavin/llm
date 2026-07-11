#!/bin/bash
# config_digest_cron.sh -- Wrapper for daily config-change digest email.
#
# Steps:
#   0. Write housekeeping_runs start row (if duckdb available)
#   1. Generate markdown digest via config_change_digest.R
#   1b. Write config_events rows to unified.duckdb for each detected change
#   2. Send digest email via send_config_digest_email.R
#   3. Update housekeeping_runs end row
#
# unified.duckdb writes: gracefully skipped when duckdb is absent.
# Tables written: housekeeping_runs, config_events
# See: unified-observability-schema rule, llm#552, llm#550
#
# All R calls wrapped in nix-shell per nix-agent-shell-protocol rule.
# Dry-run mode (EMAIL_DRY_RUN=1) passes through to child scripts.
#
# Env vars sourced from ~/.claude/env/roborev_email.env if it exists:
#   GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT
#
# Log: ~/.claude/logs/config_digest_email.log
#
# Manual run (dry):
#   EMAIL_DRY_RUN=1 bash bin/config_digest_cron.sh
#
# Tracked in llm#297, llm#552.

set -uo pipefail

# ── PATH (launchd runs with a bare PATH) ──────────────────────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ── Recursion guard ───────────────────────────────────────────────────────────
: "${CONFIG_DIGEST_DEPTH:=0}"
if (( CONFIG_DIGEST_DEPTH > 0 )); then
  echo "[config_digest_cron] ERROR: recursion detected (depth=${CONFIG_DIGEST_DEPTH}). Abort." >&2
  exit 1
fi
export CONFIG_DIGEST_DEPTH=$(( CONFIG_DIGEST_DEPTH + 1 ))

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLM_NIX="${REPO_ROOT}/default.nix"
LOG_FILE="${HOME}/.claude/logs/config_digest_email.log"
ENV_FILE="${HOME}/.claude/env/roborev_email.env"
LOCK_FILE="/tmp/config_digest_cron.lock"
DIGEST_PATH="${HOME}/.claude/logs/config_digest_$(date +%Y-%m-%d).md"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"

EMAIL_DRY_RUN="${EMAIL_DRY_RUN:-0}"
export EMAIL_DRY_RUN LLM_REPO_ROOT="${REPO_ROOT}"

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s: %s\n' "${ts}" "$1" | tee -a "${LOG_FILE}"
}

log "=== config_digest_cron.sh starting (EMAIL_DRY_RUN=${EMAIL_DRY_RUN}) ==="

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

# ── Deploy: pull latest main before running (llm#510, attempt #3) ────────────
# Cron wrappers run against ${REPO_ROOT}; without this step every gh pr merge
# ships nothing. cron_deploy_pull is dirty-tolerant: it auto-stashes and
# retries the ff-only merge instead of silently giving up when the tree is
# dirty (the previous bug — see cron_deploy_pull.sh header for rationale).
# shellcheck disable=SC1091
source "${REPO_ROOT}/.claude/scripts/cron_deploy_pull.sh"
cron_deploy_pull "${REPO_ROOT}" log
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"

# ── Load credentials ──────────────────────────────────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  log "Loading env from ${ENV_FILE}"
  set -a
  while IFS='=' read -r key val; do
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key}" ]] && continue
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    export "${key}=${val}"
  done < "${ENV_FILE}"
  set +a
else
  log "INFO: ${ENV_FILE} not found — relying on existing environment"
fi

# ── Check nix ────────────────────────────────────────────────────────────────
if [ ! -f "${LLM_NIX}" ]; then
  log "ERROR: nix file not found at ${LLM_NIX}"
  exit 1
fi
if ! command -v nix-shell > /dev/null 2>&1; then
  log "ERROR: nix-shell not on PATH (${PATH})"
  exit 1
fi

# ── Resolve nix target: GC-rooted drv preferred (llm#596) ─────────────────────
# Evaluating ${LLM_NIX} re-fetches the unhashed nixpkgs tarball once the
# tarball TTL lapses; the launchd environment cannot resolve github.com, so
# the job dies before doing any work. `nix-shell <drv>` skips evaluation
# entirely — no network at runtime. The drv root is maintained by
# .claude/scripts/nix_gcroot_refresh.sh (best-effort refresh below; a stale
# root still runs the previously-pinned shell, which beats dying).
GCROOT_DRV="${HOME}/.claude/nix-gcroots/llm-shell.drv"
GCROOT_STAMP="${GCROOT_DRV}.stamp"
# Freshness compares against the .stamp file, NOT the drv symlink — store
# paths have mtime=1970 so the symlink always reads stale.
if [ ! -e "${GCROOT_DRV}" ] || [ ! -e "${GCROOT_STAMP}" ] || [ "${LLM_NIX}" -nt "${GCROOT_STAMP}" ]; then
  "${REPO_ROOT}/.claude/scripts/nix_gcroot_refresh.sh" "${LLM_NIX}" >> "${LOG_FILE}" 2>&1 || true
fi
if [ -e "${GCROOT_DRV}" ]; then
  NIX_TARGET="${GCROOT_DRV}"
  if [ -e "${GCROOT_STAMP}" ] && [ "${LLM_NIX}" -nt "${GCROOT_STAMP}" ]; then
    log "nix WARN: gcroot stale — running stale-but-cached shell (llm#596)"
  else
    log "nix: using GC-rooted drv (no network needed)"
  fi
else
  NIX_TARGET="${LLM_NIX}"
  log "nix WARN: no gcroot — falling back to nix-shell evaluation (needs network, llm#596)"
fi

# ── DuckDB availability check (llm#552) ───────────────────────────────────────
# Gracefully skip all DB writes when duckdb binary or unified.duckdb is absent.
# Same defensive pattern as worktree_gc.sh.
_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "${UNIFIED_DB}" ]; then
  _duckdb_ok=1
  log "duckdb: available at ${UNIFIED_DB}"
else
  log "duckdb: not available — skipping DB writes"
fi

# Run ID for this invocation
_run_id="$(python3 -c 'import uuid; print(str(uuid.uuid4()))')"
_run_started="$(python3 -c 'import datetime; print(datetime.datetime.utcnow().isoformat() + "Z")')"

# ── Step 0: Write housekeeping_runs start row ─────────────────────────────────
if [ "${_duckdb_ok}" = "1" ]; then
  _script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/config_digest_cron.sh"
  duckdb "${UNIFIED_DB}" "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, status, rows_written)
    VALUES (
      '${_run_id}',
      'config_digest',
      '${_script_abs}',
      TIMESTAMPTZ '${_run_started}',
      'ok',
      0
    );
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs INSERT failed (non-fatal)"
fi

# ── Step 1: Generate digest ───────────────────────────────────────────────────
log "Step 1: generating config-change digest..."

AGGREGATOR="${REPO_ROOT}/.claude/scripts/config_change_digest.R"
if [ ! -f "${AGGREGATOR}" ]; then
  log "ERROR: config_change_digest.R not found at ${AGGREGATOR}"
  exit 1
fi

SINCE="$(date -v -24H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '')"
if [ -z "${SINCE}" ]; then
  SINCE="$(date '+%Y-%m-%d')T00:00:00"
fi
log "  since=${SINCE}"

nix-shell "${NIX_TARGET}" --run \
  "Rscript '${AGGREGATOR}' --since '${SINCE}' --out '${DIGEST_PATH}'" \
  >> "${LOG_FILE}" 2>&1
STEP1_EXIT=$?

_step1_failed=0
if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "WARNING: config_change_digest.R exited ${STEP1_EXIT} — continuing"
  # Final housekeeping_runs row must not read 'ok' when the digest step
  # failed (llm#596 item 3) — Step 3 downgrades it to 'partial'.
  _step1_failed=1
fi
log "Step 1 done (exit=${STEP1_EXIT})"

# ── Step 1b: Write config_events rows (llm#552 Phase A) ──────────────────────
# Query git for config-file changes in the same 24h window as the R digest.
# Writes one row per (commit_sha, file_path) pair in monitored categories.
# Category paths mirror the CATEGORIES list in config_change_digest.R.
_EVENTS_WRITTEN=0

if [ "${_duckdb_ok}" = "1" ]; then
  log "Step 1b: writing config_events to unified.duckdb..."

  # Category path prefixes -- mirrors CATEGORIES in config_change_digest.R
  _CONFIG_PATHS=(
    ".claude/skills"
    ".claude/agents"
    ".claude/rules"
    ".claude/memory"
    ".claude/hooks"
    ".claude/scripts"
    ".claude/templates"
    ".claude/commands"
  )

  _now_ts="$(python3 -c 'import datetime; print(datetime.datetime.utcnow().isoformat() + "Z")')"
  _cur_sha=""

  for _cat_path in "${_CONFIG_PATHS[@]}"; do
    # git log --numstat: COMMIT:<sha> header then numstat lines then blank lines.
    # Process substitution avoids subshell (loop vars persist across iterations).
    while IFS= read -r _gl; do
      [ -z "${_gl}" ] && continue
      if [[ "${_gl}" == COMMIT:* ]]; then
        _cur_sha="${_gl#COMMIT:}"
        continue
      fi
      _added="$(printf '%s' "${_gl}" | cut -f1)"
      _deleted="$(printf '%s' "${_gl}" | cut -f2)"
      _fpath="$(printf '%s' "${_gl}" | cut -f3-)"
      [ -z "${_fpath}" ] && continue
      [ -z "${_cur_sha}" ] && continue
      if [ "${_added}" = "-" ] || [ "${_deleted}" = "-" ]; then
        _change_type="modified" ; _diff_lines=0
      elif [ "${_deleted}" = "0" ] && [ "${_added}" != "0" ]; then
        _change_type="added" ; _diff_lines="${_added}"
      elif [ "${_added}" = "0" ] && [ "${_deleted}" != "0" ]; then
        _change_type="removed" ; _diff_lines="${_deleted}"
      else
        _change_type="modified"
        _diff_lines=$(( _added + _deleted )) 2>/dev/null || _diff_lines=0
      fi
      _short_sha="${_cur_sha:0:7}"
      _evt_id="$(python3 -c 'import uuid; print(str(uuid.uuid4()))')"
      _fpath_sql="${_fpath//"'"/"''"}"
      duckdb "${UNIFIED_DB}" "
        INSERT OR IGNORE INTO config_events
          (id, fired_at, source, file_path, change_type, diff_lines, commit_sha)
        VALUES (
          '${_evt_id}',
          TIMESTAMPTZ '${_now_ts}',
          'config_digest_cron.sh',
          '${_fpath_sql}',
          '${_change_type}',
          ${_diff_lines},
          '${_short_sha}'
        );
      " 2>/dev/null || true
      _EVENTS_WRITTEN=$(( _EVENTS_WRITTEN + 1 ))
    done < <(git -C "${REPO_ROOT}" log --numstat \
      --pretty="tformat:COMMIT:%H" \
      --since="${SINCE}" \
      -- "${_cat_path}" 2>/dev/null || true)
  done

  log "Step 1b done: ${_EVENTS_WRITTEN} config_events rows written"
else
  log "Step 1b: skipped (duckdb not available)"
fi

# ── Step 2: Send email ────────────────────────────────────────────────────────
log "Step 2: sending config digest email..."
EMAIL_SCRIPT="${REPO_ROOT}/.claude/scripts/send_config_digest_email.R"

if [ ! -f "${EMAIL_SCRIPT}" ]; then
  log "ERROR: send_config_digest_email.R not found at ${EMAIL_SCRIPT}"
  exit 1
fi

nix-shell "${NIX_TARGET}" --run \
  "CONFIG_DIGEST_PATH='${DIGEST_PATH}' CONFIG_DIGEST_SINCE='${SINCE}' Rscript '${EMAIL_SCRIPT}'" \
  >> "${LOG_FILE}" 2>&1
STEP2_EXIT=$?

if [ "${STEP2_EXIT}" -ne 0 ]; then
  log "ERROR: send_config_digest_email.R exited ${STEP2_EXIT}"
  # Update housekeeping_runs with failed status before exiting
  if [ "${_duckdb_ok}" = "1" ]; then
    _run_ended="$(python3 -c 'import datetime; print(datetime.datetime.utcnow().isoformat() + "Z")')"
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
  _run_ended="$(python3 -c 'import datetime; print(datetime.datetime.utcnow().isoformat() + "Z")')"
  _final_status="ok"
  [ "${_step1_failed}" = "1" ] && _final_status="partial"
  duckdb "${UNIFIED_DB}" "
    UPDATE housekeeping_runs
    SET ended_at = TIMESTAMPTZ '${_run_ended}',
        status = '${_final_status}',
        rows_written = ${_EVENTS_WRITTEN}
    WHERE id = '${_run_id}';
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs UPDATE failed (non-fatal)"
  log "Step 3: housekeeping_runs updated (status=${_final_status} rows_written=${_EVENTS_WRITTEN})"
fi

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/config-digest.stamp"

log "=== config_digest_cron.sh done ==="
