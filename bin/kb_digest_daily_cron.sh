#!/bin/bash
# kb_digest_daily_cron.sh — Wrapper for daily knowledge-base digest email.
#
# Steps:
#   1. Run kb_digest.R to compute sanitised aggregates into a temp file.
#   2. Send email locally via blastula+SMTP (NOT via gh workflow run).
#      The email body must NOT pass through CI logs — KB may contain PHI.
#
# PRIVACY CONTRACT:
#   - The digest is computed on THIS machine from the LOCAL knowledge repo.
#   - The email is sent directly via SMTP, never via GitHub Actions inputs.
#   - ~/.claude/logs/kb_digest.log logs only counts/metadata, never content.
#
# All R calls are wrapped in nix-shell per the nix-agent-shell-protocol rule.
# Dry-run mode (DRYRUN=1 / EMAIL_DRY_RUN=1) passes through to child scripts.
#
# Env vars sourced from ~/.claude/env/kb_digest.env if it exists:
#   GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT
#
# Optional env vars:
#   KB_KNOWLEDGE_REPO   Path to knowledge repo (default: ~/docs_gh/llm/knowledge)
#   KB_SINCE            ISO timestamp cutoff  (default: 24h ago)
#
# Log: ~/.claude/logs/kb_digest.log
#
# Install plist:
#   cp .claude/launchd/com.claude.kb-digest-email.plist \
#      ~/Library/LaunchAgents/com.claude.kb-digest-email.plist
#   launchctl load -w ~/Library/LaunchAgents/com.claude.kb-digest-email.plist
#
# Manual run (dry):
#   DRYRUN=1 EMAIL_DRY_RUN=1 bash bin/kb_digest_daily_cron.sh
#
# Tracked in llm#298.

set -uo pipefail

# ── PATH (launchd runs with a bare PATH; must resolve nix-shell, Rscript) ─────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ── Recursion / fork-bomb guard ────────────────────────────────────────────────
: "${KB_DIGEST_CRON_DEPTH:=0}"
if (( KB_DIGEST_CRON_DEPTH > 0 )); then
  echo "[kb_digest_daily_cron] ERROR: recursion detected (depth=${KB_DIGEST_CRON_DEPTH}). Abort." >&2
  exit 1
fi
export KB_DIGEST_CRON_DEPTH=$(( KB_DIGEST_CRON_DEPTH + 1 ))

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLM_NIX="${REPO_ROOT}/default.nix"
LOG_FILE="${HOME}/.claude/logs/kb_digest.log"
ENV_FILE="${HOME}/.claude/env/kb_digest.env"
LOCK_FILE="/tmp/kb_digest_daily_cron.lock"

# Dry-run flags
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

log "=== kb_digest_daily_cron.sh starting (DRYRUN=${DRYRUN} EMAIL_DRY_RUN=${EMAIL_DRY_RUN}) ==="

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

# ── Load credentials from env file ────────────────────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  log "Loading env from ${ENV_FILE}"
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

# ── Step 1: Generate sanitised digest to temp file ────────────────────────────
log "Step 1: generating knowledge-base digest..."

DIGEST_SCRIPT="${REPO_ROOT}/.claude/scripts/kb_digest.R"
DIGEST_TMPFILE="$(mktemp /tmp/kb_digest_XXXXXX.md)"
trap 'rm -f "${LOCK_FILE}" "${DIGEST_TMPFILE}"' EXIT

if [ ! -f "${DIGEST_SCRIPT}" ]; then
  log "ERROR: kb_digest.R not found at ${DIGEST_SCRIPT}"
  exit 1
fi

# Default knowledge repo (can be overridden via env)
KB_KNOWLEDGE_REPO="${KB_KNOWLEDGE_REPO:-${HOME}/docs_gh/llm/knowledge}"
KB_SINCE="${KB_SINCE:-}"

if [ "${DRYRUN}" = "1" ]; then
  log "  DRYRUN: would run nix-shell ${LLM_NIX} --run 'Rscript ${DIGEST_SCRIPT}'"
  # Create minimal stub for email script to consume
  echo "## Knowledge Base Digest — $(date +%Y-%m-%d)" > "${DIGEST_TMPFILE}"
  echo "" >> "${DIGEST_TMPFILE}"
  echo "_DRYRUN mode — no actual KB analysis performed._" >> "${DIGEST_TMPFILE}"
  STEP1_EXIT=0
else
  SINCE_ARG=""
  [ -n "${KB_SINCE}" ] && SINCE_ARG="--since ${KB_SINCE}"

  nix-shell "${LLM_NIX}" --run \
    "Rscript '${DIGEST_SCRIPT}' --knowledge-repo '${KB_KNOWLEDGE_REPO}' ${SINCE_ARG} --out '${DIGEST_TMPFILE}'" \
    >> "${LOG_FILE}" 2>&1
  STEP1_EXIT=$?
fi

if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "ERROR: kb_digest.R exited ${STEP1_EXIT} — aborting"
  exit "${STEP1_EXIT}"
fi

# Log sanitised headline counts only (no content)
if [ -f "${DIGEST_TMPFILE}" ]; then
  line_count=$(wc -l < "${DIGEST_TMPFILE}")
  byte_count=$(wc -c < "${DIGEST_TMPFILE}")
  log "  Digest: ${line_count} lines, ${byte_count} bytes (sanitised aggregates only)"
fi

log "Step 1 done (exit=${STEP1_EXIT})"

# ── Step 2: Send email locally via blastula ────────────────────────────────────
# NOTE: NOT via `gh workflow run` — the body must NOT pass through CI logs.
log "Step 2: sending knowledge-base digest email via local SMTP..."

EMAIL_SCRIPT="${REPO_ROOT}/.claude/scripts/send_kb_digest_email.R"

if [ ! -f "${EMAIL_SCRIPT}" ]; then
  log "ERROR: send_kb_digest_email.R not found at ${EMAIL_SCRIPT}"
  exit 1
fi

if [ "${DRYRUN}" = "1" ]; then
  log "  DRYRUN: would run nix-shell ${LLM_NIX} --run 'Rscript ${EMAIL_SCRIPT}'"
  STEP2_EXIT=0
elif [ "${EMAIL_DRY_RUN}" = "1" ]; then
  log "  EMAIL_DRY_RUN=1: running script in dry-run mode (body to stdout only)"
  KB_DIGEST_FILE="${DIGEST_TMPFILE}" \
    nix-shell "${LLM_NIX}" --run "Rscript '${EMAIL_SCRIPT}'" >> "${LOG_FILE}" 2>&1
  STEP2_EXIT=$?
else
  KB_DIGEST_FILE="${DIGEST_TMPFILE}" \
    nix-shell "${LLM_NIX}" --run "Rscript '${EMAIL_SCRIPT}'" >> "${LOG_FILE}" 2>&1
  STEP2_EXIT=$?
fi

if [ "${STEP2_EXIT}" -ne 0 ]; then
  log "ERROR: send_kb_digest_email.R failed (exit=${STEP2_EXIT})"
  exit "${STEP2_EXIT}"
fi
log "Step 2 done"

log "=== kb_digest_daily_cron.sh done ==="
