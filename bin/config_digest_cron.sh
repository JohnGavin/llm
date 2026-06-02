#!/bin/bash
# config_digest_cron.sh — Wrapper for daily config-change digest email.
#
# Steps:
#   1. Generate markdown digest:
#      Rscript .claude/scripts/config_change_digest.R --since <24h-ago>
#   2. Send digest email:
#      Rscript .claude/scripts/send_config_digest_email.R
#
# All R calls wrapped in nix-shell per nix-agent-shell-protocol rule.
# Dry-run mode (EMAIL_DRY_RUN=1) passes through to child scripts.
#
# Env vars sourced from ~/.claude/env/roborev_email.env if it exists:
#   GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT
#
# Log: ~/.claude/logs/config_digest_email.log
#
# Install plist:
#   cp .claude/launchd/com.claude.config-digest-email.plist \
#      ~/Library/LaunchAgents/com.claude.config-digest-email.plist
#   launchctl load -w ~/Library/LaunchAgents/com.claude.config-digest-email.plist
#
# Manual run (dry):
#   EMAIL_DRY_RUN=1 bash bin/config_digest_cron.sh
#
# Tracked in llm#297.

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

# ── Load credentials ──────────────────────────────────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  log "Loading env from ${ENV_FILE}"
  set -a
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

# ── Step 1: Generate digest ───────────────────────────────────────────────────
log "Step 1: generating config-change digest..."

AGGREGATOR="${REPO_ROOT}/.claude/scripts/config_change_digest.R"
if [ ! -f "${AGGREGATOR}" ]; then
  log "ERROR: config_change_digest.R not found at ${AGGREGATOR}"
  exit 1
fi

SINCE="$(date -v -24H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '')"
if [ -z "${SINCE}" ]; then
  # Fallback: yesterday noon
  SINCE="$(date '+%Y-%m-%d')T00:00:00"
fi
log "  since=${SINCE}"

nix-shell "${LLM_NIX}" --run \
  "Rscript '${AGGREGATOR}' --since '${SINCE}' --out '${DIGEST_PATH}'" \
  >> "${LOG_FILE}" 2>&1
STEP1_EXIT=$?

if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "WARNING: config_change_digest.R exited ${STEP1_EXIT} — continuing"
fi
log "Step 1 done (exit=${STEP1_EXIT})"

# ── Step 2: Send email ────────────────────────────────────────────────────────
log "Step 2: sending config digest email..."
EMAIL_SCRIPT="${REPO_ROOT}/.claude/scripts/send_config_digest_email.R"

if [ ! -f "${EMAIL_SCRIPT}" ]; then
  log "ERROR: send_config_digest_email.R not found at ${EMAIL_SCRIPT}"
  exit 1
fi

nix-shell "${LLM_NIX}" --run \
  "CONFIG_DIGEST_PATH='${DIGEST_PATH}' CONFIG_DIGEST_SINCE='${SINCE}' Rscript '${EMAIL_SCRIPT}'" \
  >> "${LOG_FILE}" 2>&1
STEP2_EXIT=$?

if [ "${STEP2_EXIT}" -ne 0 ]; then
  log "ERROR: send_config_digest_email.R exited ${STEP2_EXIT}"
  exit "${STEP2_EXIT}"
fi
log "Step 2 done"

log "=== config_digest_cron.sh done ==="
