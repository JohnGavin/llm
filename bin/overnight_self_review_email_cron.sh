#!/bin/bash
# overnight_self_review_email_cron.sh — Wrapper for 06:30 overnight digest email.
#
# Same pattern as kb_digest_daily_cron.sh: launchd cannot inherit ~/.zshenv,
# so SMTP creds (GMAIL_USERNAME / GMAIL_APP_PASSWORD / REPORT_RECIPIENT) must be
# sourced from ~/.claude/env/overnight_self_review.env before invoking Rscript.
#
# Env vars sourced from ~/.claude/env/overnight_self_review.env:
#   GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT
#
# All R execution wrapped in nix-shell per nix-agent-shell-protocol rule.
# Auto-pulls main per cron-auto-pull-discipline rule.
#
# Manual run (dry — no email send):
#   EMAIL_DRY_RUN=1 bash bin/overnight_self_review_email_cron.sh
#
# Manual run (live):
#   bash bin/overnight_self_review_email_cron.sh
#
# Log: ~/.claude/logs/overnight_self_review_email_launchd.log
#
# Tracked in llm#559.

set -uo pipefail

# ── PATH (launchd runs with a bare PATH; must resolve nix-shell, Rscript) ─────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ── Recursion guard ───────────────────────────────────────────────────────────
: "${OVERNIGHT_DIGEST_CRON_DEPTH:=0}"
if (( OVERNIGHT_DIGEST_CRON_DEPTH > 0 )); then
  echo "[overnight_self_review_email_cron] ERROR: recursion detected (depth=${OVERNIGHT_DIGEST_CRON_DEPTH}). Abort." >&2
  exit 1
fi
export OVERNIGHT_DIGEST_CRON_DEPTH=$(( OVERNIGHT_DIGEST_CRON_DEPTH + 1 ))

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLM_NIX="${REPO_ROOT}/default.nix"
LOG_FILE="${HOME}/.claude/logs/overnight_self_review_email_launchd.log"
ENV_FILE="${HOME}/.claude/env/overnight_self_review.env"
LOCK_FILE="/tmp/overnight_self_review_email_cron.lock"

# Dry-run flag (passes through to the R script)
EMAIL_DRY_RUN="${EMAIL_DRY_RUN:-0}"
export EMAIL_DRY_RUN

# Explicit DB path — the R script's %||% operator treats empty string as
# truthy, so Sys.getenv("UNIFIED_DB_PATH") = "" never falls through to the
# default. Export the canonical path here so nix-shell sees it.
export UNIFIED_DB_PATH="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s: %s\n' "${ts}" "$1" | tee -a "${LOG_FILE}"
}

log "=== overnight_self_review_email_cron.sh starting (EMAIL_DRY_RUN=${EMAIL_DRY_RUN}) ==="

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

# ── Deploy: pull latest main before running (cron-auto-pull-discipline) ───────
if [ -z "${SKIP_CRON_PULL:-}" ]; then
    git -C "${REPO_ROOT}" fetch origin main 2>/dev/null
    if git -C "${REPO_ROOT}" merge --ff-only origin/main 2>/dev/null; then
        log "deploy: ff to $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    else
        log "deploy WARN: ff-only failed — running against $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    fi
fi
log "HEAD: $(git -C "${REPO_ROOT}" rev-parse --short HEAD) $(git -C "${REPO_ROOT}" log -1 --format='%s')"

# ── Load credentials (bws injection takes priority over flat file) ─────────────
if [[ -n "${GMAIL_USERNAME:-}" ]]; then
  log "Credentials in environment (bws injection)"
elif [ -f "${ENV_FILE}" ]; then
  log "Loading env from ${ENV_FILE} (flat-file fallback)"
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
  log "  Create it with: GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT"
fi

# ── Verify nix shell ──────────────────────────────────────────────────────────
if [ ! -f "${LLM_NIX}" ]; then
  log "ERROR: nix file not found at ${LLM_NIX}"
  exit 1
fi

if ! command -v nix-shell > /dev/null 2>&1; then
  log "ERROR: nix-shell not on PATH (${PATH})"
  exit 1
fi

# ── Run digest ────────────────────────────────────────────────────────────────
log "Running send_overnight_self_review_email.R via nix-shell..."

R_SCRIPT="${REPO_ROOT}/.claude/scripts/send_overnight_self_review_email.R"
if [ ! -f "${R_SCRIPT}" ]; then
  log "ERROR: R script not found at ${R_SCRIPT}"
  exit 1
fi

set +e
nix-shell "${LLM_NIX}" --run "Rscript ${R_SCRIPT}" >> "${LOG_FILE}" 2>&1
rc=$?
set -e

if [ $rc -eq 0 ]; then
  # Stamp for cron_catchup.sh catch-up detection
  mkdir -p "${HOME}/.claude/logs/stamps"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/overnight-email.stamp"
  log "=== overnight_self_review_email_cron.sh completed OK ==="
else
  log "=== overnight_self_review_email_cron.sh FAILED (exit ${rc}) ==="
fi

exit $rc
