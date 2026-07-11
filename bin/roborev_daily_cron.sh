#!/bin/bash
# roborev_daily_cron.sh — Wrapper for daily roborev snapshot + publish + email.
#
# Steps:
#   1. Generate/refresh daily snapshot:
#      Rscript .claude/scripts/roborev_daily_report.R --apply
#   2. Publish JSON to llmtelemetry data branch:
#      bin/publish_roborev_data.sh
#   3. Send digest email:
#      Rscript .claude/scripts/send_roborev_email.R
#
# All R calls are wrapped in nix-shell per the nix-agent-shell-protocol rule.
# Dry-run mode (DRYRUN=1 / EMAIL_DRY_RUN=1) passes through to child scripts.
#
# Env vars sourced from ~/.claude/env/roborev_email.env if it exists:
#   GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT, ROBOREV_DASHBOARD_URL
#
# Log: ~/.claude/logs/roborev_daily_email.log
#
# Install plist:
#   cp .claude/launchd/com.claude.roborev-daily-email.plist \
#      ~/Library/LaunchAgents/com.claude.roborev-daily-email.plist
#   launchctl load -w ~/Library/LaunchAgents/com.claude.roborev-daily-email.plist
#
# Manual run (dry):
#   DRYRUN=1 EMAIL_DRY_RUN=1 bash bin/roborev_daily_cron.sh
#
# Tracked in llm#287.

set -uo pipefail

# ── PATH (launchd runs with a bare PATH; must resolve nix-shell, Rscript, gh) ──
# /nix/var/nix/profiles/default/bin is the multi-user nix stable profile.
# Mirrors the pattern from .claude/scripts/self_review_stage1.sh.
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ── Recursion / fork-bomb guard ────────────────────────────────────────────────
: "${ROBOREV_CRON_DEPTH:=0}"
if (( ROBOREV_CRON_DEPTH > 0 )); then
  echo "[roborev_daily_cron] ERROR: recursion detected (depth=${ROBOREV_CRON_DEPTH}). Abort." >&2
  exit 1
fi
export ROBOREV_CRON_DEPTH=$(( ROBOREV_CRON_DEPTH + 1 ))

# ── Paths ─────────────────────────────────────────────────────────────────────
# Resolve script location robustly (works when called from launchd with full path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLM_NIX="${REPO_ROOT}/default.nix"
LOG_FILE="${HOME}/.claude/logs/roborev_daily_email.log"
ENV_FILE="${HOME}/.claude/env/roborev_email.env"
LOCK_FILE="/tmp/roborev_daily_cron.lock"

# Dry-run flags (exported so child processes inherit)
DRYRUN="${DRYRUN:-0}"
EMAIL_DRY_RUN="${EMAIL_DRY_RUN:-0}"
export DRYRUN EMAIL_DRY_RUN

# ── Logging ────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s: %s\n' "${ts}" "$1" | tee -a "${LOG_FILE}"
}

log "=== roborev_daily_cron.sh starting (DRYRUN=${DRYRUN} EMAIL_DRY_RUN=${EMAIL_DRY_RUN}) ==="

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

# ── Deploy: pull latest main before running (llm#510, attempt #3) ────────────
# Cron wrappers run against ${REPO_ROOT}; without this step every gh pr merge
# ships nothing — the cron uses whatever was last manually pulled to the main
# checkout. cron_deploy_pull is dirty-tolerant: it auto-stashes and retries
# the ff-only merge instead of silently giving up when the tree is dirty
# (the previous bug — see cron_deploy_pull.sh header for full rationale).
# shellcheck disable=SC1091
source "${REPO_ROOT}/.claude/scripts/cron_deploy_pull.sh"
cron_deploy_pull "${REPO_ROOT}" log
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"

# ── Load credentials from env file ────────────────────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  log "Loading env from ${ENV_FILE}"
  # shellcheck disable=SC1090
  set -a
  # Source only KEY=VALUE lines; skip comments and blanks
  while IFS='=' read -r key val; do
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key}" ]] && continue
    # Strip one layer of surrounding quotes (handles KEY="value" style env files)
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    export "${key}=${val}"
  done < "${ENV_FILE}"
  set +a
else
  log "INFO: ${ENV_FILE} not found — relying on existing environment"
  log "  Create it with: GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT, ROBOREV_DASHBOARD_URL"
fi

# ── Verify nix shell is accessible ────────────────────────────────────────────
if [ ! -f "${LLM_NIX}" ]; then
  log "ERROR: nix file not found at ${LLM_NIX}"
  exit 1
fi

if ! command -v nix-shell > /dev/null 2>&1; then
  log "ERROR: nix-shell not on PATH (${PATH})"
  exit 1
fi

# ── Step 1: Generate/refresh daily snapshot ───────────────────────────────────
log "Step 1: generating roborev daily snapshot..."
REPORT_SCRIPT="${REPO_ROOT}/.claude/scripts/roborev_daily_report.R"

if [ ! -f "${REPORT_SCRIPT}" ]; then
  log "ERROR: roborev_daily_report.R not found at ${REPORT_SCRIPT}"
  exit 1
fi

if [ "${DRYRUN}" = "1" ]; then
  log "  DRYRUN: would run nix-shell ${LLM_NIX} --run 'Rscript ${REPORT_SCRIPT}'"
  STEP1_EXIT=0
else
  nix-shell "${LLM_NIX}" --run "Rscript '${REPORT_SCRIPT}'" >> "${LOG_FILE}" 2>&1
  STEP1_EXIT=$?
fi

if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "WARNING: roborev_daily_report.R exited ${STEP1_EXIT} — may be partial; continuing"
fi
log "Step 1 done (exit=${STEP1_EXIT})"

# ── Step 2: Publish to llmtelemetry data branch ───────────────────────────────
log "Step 2: publishing JSON to llmtelemetry data branch..."
PUBLISH_SCRIPT="${REPO_ROOT}/bin/publish_roborev_data.sh"

if [ ! -f "${PUBLISH_SCRIPT}" ]; then
  log "ERROR: publish_roborev_data.sh not found at ${PUBLISH_SCRIPT}"
  exit 1
fi

bash "${PUBLISH_SCRIPT}" >> "${LOG_FILE}" 2>&1
STEP2_EXIT=$?

if [ "${STEP2_EXIT}" -ne 0 ]; then
  log "ERROR: publish_roborev_data.sh failed (exit=${STEP2_EXIT}) — aborting email step"
  exit "${STEP2_EXIT}"
fi
log "Step 2 done"

# ── Step 3: Send email ─────────────────────────────────────────────────────────
log "Step 3: sending roborev digest email..."
EMAIL_SCRIPT="${REPO_ROOT}/.claude/scripts/send_roborev_email.R"

if [ ! -f "${EMAIL_SCRIPT}" ]; then
  log "ERROR: send_roborev_email.R not found at ${EMAIL_SCRIPT}"
  exit 1
fi

if [ "${DRYRUN}" = "1" ]; then
  log "  DRYRUN: would run nix-shell ${LLM_NIX} --run 'Rscript ${EMAIL_SCRIPT}'"
  STEP3_EXIT=0
elif [ "${EMAIL_DRY_RUN}" = "1" ]; then
  log "  EMAIL_DRY_RUN=1: running script in dry-run mode (body to stdout only)"
  nix-shell "${LLM_NIX}" --run "Rscript '${EMAIL_SCRIPT}'" >> "${LOG_FILE}" 2>&1
  STEP3_EXIT=$?
else
  nix-shell "${LLM_NIX}" --run "Rscript '${EMAIL_SCRIPT}'" >> "${LOG_FILE}" 2>&1
  STEP3_EXIT=$?
fi

if [ "${STEP3_EXIT}" -ne 0 ]; then
  log "ERROR: send_roborev_email.R failed (exit=${STEP3_EXIT})"
  exit "${STEP3_EXIT}"
fi
log "Step 3 done"

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/roborev-daily-email.stamp"

log "=== roborev_daily_cron.sh done ==="
