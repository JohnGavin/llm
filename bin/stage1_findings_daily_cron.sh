#!/bin/bash
# stage1_findings_daily_cron.sh — Daily Stage 1 self-review findings digest email.
#
# Steps:
#   1. Send digest email of self_review_findings_stage1 (last 24h):
#      Rscript .claude/scripts/send_stage1_findings_email.R
#
# No Step 2 (no JSON publishing for this digest — data stays in unified.duckdb).
#
# All R calls are wrapped in nix-shell per the nix-agent-shell-protocol rule.
# EMAIL_DRY_RUN defaults to 1 — must be explicitly set to 0 to send live mail.
#
# Env vars sourced from ~/.claude/env/roborev_email.env if it exists:
#   GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT
#
# Log: ~/.claude/logs/stage1_findings_email.log
#
# Install plist:
#   cp .claude/launchd/com.claude.stage1-findings-email.plist \
#      ~/Library/LaunchAgents/com.claude.stage1-findings-email.plist
#   launchctl load -w ~/Library/LaunchAgents/com.claude.stage1-findings-email.plist
#
# Manual dry-run:
#   EMAIL_DRY_RUN=1 bash bin/stage1_findings_daily_cron.sh
#
# Tracked in llm#436.

set -uo pipefail

# ── PATH (launchd runs with a bare PATH; must resolve nix-shell, Rscript) ────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ── Recursion guard ────────────────────────────────────────────────────────────
: "${STAGE1_EMAIL_CRON_DEPTH:=0}"
if (( STAGE1_EMAIL_CRON_DEPTH > 0 )); then
  echo "[stage1_findings_daily_cron] ERROR: recursion detected (depth=${STAGE1_EMAIL_CRON_DEPTH}). Abort." >&2
  exit 1
fi
export STAGE1_EMAIL_CRON_DEPTH=$(( STAGE1_EMAIL_CRON_DEPTH + 1 ))

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLM_NIX="${REPO_ROOT}/default.nix"
LOG_FILE="${HOME}/.claude/logs/stage1_findings_email.log"
ENV_FILE="${HOME}/.claude/env/roborev_email.env"
LOCK_FILE="${HOME}/.claude/logs/.stage1_findings_email.lock"

# EMAIL_DRY_RUN defaults to 1 — opt-out, not opt-in (must set to "0" to send live)
EMAIL_DRY_RUN="${EMAIL_DRY_RUN:-1}"
export EMAIL_DRY_RUN

# ── Logging ────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s: %s\n' "${ts}" "$1" | tee -a "${LOG_FILE}"
}

log "=== stage1_findings_daily_cron.sh starting (EMAIL_DRY_RUN=${EMAIL_DRY_RUN}) ==="

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

# ── Load credentials from env file ────────────────────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  log "Loading env from ${ENV_FILE}"
  # shellcheck disable=SC1090
  set -a
  # Source only KEY=VALUE lines; skip comments and blanks
  # Quote-stripping fix: handles KEY="value" and KEY='value' style env files
  while IFS='=' read -r key val; do
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key}" ]] && continue
    # Strip one layer of surrounding quotes
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    export "${key}=${val}"
  done < "${ENV_FILE}"
  set +a
else
  log "INFO: ${ENV_FILE} not found — relying on existing environment"
  log "  Create it with: GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT"
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

# ── Step 1: Send Stage 1 findings digest email ────────────────────────────────
log "Step 1: sending Stage 1 findings digest email (EMAIL_DRY_RUN=${EMAIL_DRY_RUN})..."
EMAIL_SCRIPT="${REPO_ROOT}/.claude/scripts/send_stage1_findings_email.R"

if [ ! -f "${EMAIL_SCRIPT}" ]; then
  log "ERROR: send_stage1_findings_email.R not found at ${EMAIL_SCRIPT}"
  exit 1
fi

nix-shell "${LLM_NIX}" --run "Rscript '${EMAIL_SCRIPT}'" >> "${LOG_FILE}" 2>&1
STEP1_EXIT=$?

if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "ERROR: send_stage1_findings_email.R failed (exit=${STEP1_EXIT})"
  exit "${STEP1_EXIT}"
fi
log "Step 1 done (exit=${STEP1_EXIT})"

log "=== stage1_findings_daily_cron.sh done ==="
