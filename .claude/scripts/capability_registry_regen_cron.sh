#!/bin/bash
# capability_registry_regen_cron.sh — Wrapper for daily regeneration of the
# "Capability Registry — Own Your Context" self-contained HTML file.
#
# RETIRED (launchd job only, 2026-07-23, #766): the launchd job
# com.claude.capability-registry was retired because it only regenerates the
# on-disk HTML — republishing to the live claude.ai artifact needs a session
# (Artifact tool), which headless cron cannot do. No consumer of the on-disk
# file existed. This script remains usable as a MANUAL command; see
# `.claude/launchd/README.md` Retired jobs table for details.
#
# IMPORTANT — republish boundary:
#   Republishing to the LIVE claude.ai artifact URL is a session-only step
#   (the Artifact tool, which needs a Claude Code session + claude.ai auth).
#   This cron CANNOT do that. It only regenerates the file on disk at
#   .claude/reports/capability-registry.html. A session republishes by
#   opening the file and calling the Artifact tool with the SAME artifact
#   URL used previously (Artifact tool `url` parameter redeploys in place).
#
# Steps:
#   0. Write housekeeping_runs start row (if duckdb available)
#   1. Run capability_registry_regen.R to write the HTML file
#   2. Update housekeeping_runs end row
#
# unified.duckdb writes: gracefully skipped when duckdb is absent.
# Tables written: housekeeping_runs (heartbeat only -- this task has no
#   per-item event stream, just a full-inventory regeneration each run).
# See: housekeeping-framework rule, cron-auto-pull-discipline rule, llm#(this PR).
#
# All R calls are wrapped in nix-shell per the nix-agent-shell-protocol rule.
#
# Manual run (dry):
#   DRYRUN=1 bash .claude/scripts/capability_registry_regen_cron.sh
#
# Manual selftest (writes to /tmp, validates output, no repo write):
#   SELFTEST=1 bash .claude/scripts/capability_registry_regen_cron.sh
#
# Install plist:
#   cp .claude/launchd/com.claude.capability-registry.plist \
#      ~/Library/LaunchAgents/com.claude.capability-registry.plist
#   launchctl load -w ~/Library/LaunchAgents/com.claude.capability-registry.plist
#
# Log: ~/.claude/logs/capability_registry.log

set -uo pipefail

# ── PATH (launchd runs with a bare PATH; must resolve nix-shell, Rscript) ─────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ── Recursion / fork-bomb guard ────────────────────────────────────────────────
: "${CAPREG_CRON_DEPTH:=0}"
if (( CAPREG_CRON_DEPTH > 0 )); then
  echo "[capability_registry_regen_cron] ERROR: recursion detected (depth=${CAPREG_CRON_DEPTH}). Abort." >&2
  exit 1
fi
export CAPREG_CRON_DEPTH=$(( CAPREG_CRON_DEPTH + 1 ))

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && cd .. && pwd)"
LLM_NIX="${REPO_ROOT}/default.nix"
LOG_FILE="${HOME}/.claude/logs/capability_registry.log"
LOCK_FILE="/tmp/capability_registry_regen_cron.lock"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"
REGEN_R="${REPO_ROOT}/.claude/scripts/capability_registry_regen.R"
OUT_HTML="${REPO_ROOT}/.claude/reports/capability-registry.html"

DRYRUN="${DRYRUN:-0}"
SELFTEST="${SELFTEST:-0}"
export LLM_REPO_ROOT="${REPO_ROOT}"

# ── Logging ────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s: %s\n' "${ts}" "$1" | tee -a "${LOG_FILE}"
}

log "=== capability_registry_regen_cron.sh starting (DRYRUN=${DRYRUN} SELFTEST=${SELFTEST}) ==="

# ── Lock (prevent concurrent runs) ────────────────────────────────────────────
if [ -f "${LOCK_FILE}" ]; then
  existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
  if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
    log "SKIP: another instance running (PID ${existing_pid})"
    exit 0
  fi
fi
printf '%d' "$$" > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# ── SELFTEST short-circuit (no repo pull, no housekeeping_runs write) ─────────
if [ "${SELFTEST}" = "1" ]; then
  log "SELFTEST=1: delegating to capability_registry_regen.R self-check (writes to /tmp only)"
  if [ ! -f "${LLM_NIX}" ]; then
    log "ERROR: nix file not found at ${LLM_NIX}"
    exit 1
  fi
  SELFTEST=1 nix-shell "${LLM_NIX}" --run "Rscript '${REGEN_R}'" 2>&1 | tee -a "${LOG_FILE}"
  exit "${PIPESTATUS[0]}"
fi

# ── Deploy: pull latest main before running (llm#510, attempt #3) ────────────
# Cron wrappers run against ${REPO_ROOT}; without this step every gh pr merge
# ships nothing -- the cron uses whatever was last manually pulled to the main
# checkout. cron_deploy_pull is dirty-tolerant: it auto-stashes and retries
# the ff-only merge instead of silently giving up when the tree is dirty
# (the previous bug -- see cron_deploy_pull.sh header for full rationale).
# shellcheck disable=SC1091
source "${REPO_ROOT}/.claude/scripts/cron_deploy_pull.sh"
cron_deploy_pull "${REPO_ROOT}" log
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"

# ── Verify nix shell is accessible ────────────────────────────────────────────
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
# entirely -- no network at runtime. The drv root is maintained by
# .claude/scripts/nix_gcroot_refresh.sh (best-effort refresh below; a stale
# root still runs the previously-pinned shell, which beats dying).
GCROOT_DRV="${HOME}/.claude/nix-gcroots/llm-shell.drv"
GCROOT_STAMP="${GCROOT_DRV}.stamp"
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

# ── DuckDB availability check ──────────────────────────────────────────────────
# Gracefully skip all DB writes when duckdb binary or unified.duckdb is absent.
# Same defensive pattern as kb_digest_daily_cron.sh / config_digest_cron.sh.
_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "${UNIFIED_DB}" ]; then
  _duckdb_ok=1
  log "duckdb: available at ${UNIFIED_DB}"
else
  log "duckdb: not available — skipping DB writes (capability_registry_regen.R will also skip HTML write)"
fi

# Run ID for this invocation (bash native — no python3 per llm#569 compliance)
_run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
_run_started="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# ── Step 0: Write housekeeping_runs start row ─────────────────────────────────
if [ "${_duckdb_ok}" = "1" ]; then
  _script_abs="${SCRIPT_DIR}/capability_registry_regen_cron.sh"
  duckdb "${UNIFIED_DB}" "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, status, rows_written)
    VALUES (
      '${_run_id}',
      'capability_registry_regen',
      '${_script_abs}',
      TIMESTAMPTZ '${_run_started}',
      'ok',
      0
    );
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs INSERT failed (non-fatal)"
fi

# ── Step 1: Regenerate the HTML file ──────────────────────────────────────────
log "Step 1: regenerating capability registry HTML..."

if [ ! -f "${REGEN_R}" ]; then
  log "ERROR: capability_registry_regen.R not found at ${REGEN_R}"
  if [ "${_duckdb_ok}" = "1" ]; then
    _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    duckdb "${UNIFIED_DB}" "
      UPDATE housekeeping_runs
      SET ended_at = TIMESTAMPTZ '${_run_ended}', status = 'failed', rows_written = 0
      WHERE id = '${_run_id}';
    " 2>/dev/null || true
  fi
  exit 1
fi

if [ "${DRYRUN}" = "1" ]; then
  log "  DRYRUN: would run nix-shell ${NIX_TARGET} --run 'Rscript ${REGEN_R} --dry-run'"
  STEP1_EXIT=0
  _rows_written=0
else
  UNIFIED_DB_PATH="${UNIFIED_DB}" LLM_REPO_ROOT="${REPO_ROOT}" \
    nix-shell "${NIX_TARGET}" --run "Rscript '${REGEN_R}'" >> "${LOG_FILE}" 2>&1
  STEP1_EXIT=$?
  _rows_written=1
fi

if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "ERROR: capability_registry_regen.R exited ${STEP1_EXIT} — aborting"
  if [ "${_duckdb_ok}" = "1" ]; then
    _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    duckdb "${UNIFIED_DB}" "
      UPDATE housekeeping_runs
      SET ended_at = TIMESTAMPTZ '${_run_ended}', status = 'failed', rows_written = 0
      WHERE id = '${_run_id}';
    " 2>/dev/null || true
  fi
  exit "${STEP1_EXIT}"
fi

if [ -f "${OUT_HTML}" ]; then
  byte_count=$(wc -c < "${OUT_HTML}")
  log "  Output: ${OUT_HTML} (${byte_count} bytes)"
fi

log "Step 1 done (exit=${STEP1_EXIT})"

# ── Step 2: Update housekeeping_runs end row ──────────────────────────────────
if [ "${_duckdb_ok}" = "1" ]; then
  _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  duckdb "${UNIFIED_DB}" "
    UPDATE housekeeping_runs
    SET ended_at = TIMESTAMPTZ '${_run_ended}',
        rows_written = ${_rows_written}
    WHERE id = '${_run_id}';
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs UPDATE failed (non-fatal)"
  log "Step 2: housekeeping_runs updated (rows_written=${_rows_written})"
fi

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/capability-registry.stamp"

log "=== capability_registry_regen_cron.sh done ==="
log "REMINDER: this only regenerated the on-disk file. Republishing to the"
log "  live claude.ai artifact URL requires a session: open ${OUT_HTML}"
log "  and call the Artifact tool with the existing artifact's URL."
