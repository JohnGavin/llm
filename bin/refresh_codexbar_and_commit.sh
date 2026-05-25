#!/bin/bash
# refresh_codexbar_and_commit.sh — Capture CodexBar usage data and commit to llmtelemetry.
#
# INSTALL
# -------
#   launchctl load -w ~/Library/LaunchAgents/com.johngavin.codexbar-refresh.plist
#
# Tracks: llm#184
#
# Mirrors: ~/docs_gh/llm/bin/refresh_ccusage_and_commit.sh

set -uo pipefail
# NOTE: we do NOT use `set -e` unconditionally because we want to handle
# individual step failures explicitly (leak-guard, push warnings, etc.)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

REPO="/Users/johngavin/docs_gh/llmtelemetry"
LOG_FILE="${HOME}/.claude/logs/refresh_codexbar.log"
LOCK_FILE="/tmp/codexbar_refresh_commit.lock"

USAGE_JSON="${REPO}/inst/extdata/codexbar_usage.json"
COST_JSON="${REPO}/inst/extdata/codexbar_cost_daily.json"

# Dry-run mode: set CODEXBAR_REFRESH_DRYRUN=1 to skip git add/commit/push
DRYRUN="${CODEXBAR_REFRESH_DRYRUN:-0}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${LOG_FILE}"
}

log "=== refresh_codexbar_and_commit.sh starting (DRYRUN=${DRYRUN}) ==="

# ---------------------------------------------------------------------------
# Lock (prevent concurrent runs)
# ---------------------------------------------------------------------------
if [ -f "${LOCK_FILE}" ]; then
  existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
  if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
    log "SKIP: another instance running (PID ${existing_pid})"
    exit 0
  fi
fi
printf '%d' "$$" > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# ---------------------------------------------------------------------------
# Graceful skip when codexbar is unavailable (CI / headless)
# ---------------------------------------------------------------------------
if ! command -v codexbar > /dev/null 2>&1; then
  log "SKIP: codexbar not found on PATH — not installed or headless environment"
  exit 0
fi

# ---------------------------------------------------------------------------
# Verify repo exists and is a git repo
# ---------------------------------------------------------------------------
if [ ! -d "${REPO}/.git" ]; then
  log "ERROR: ${REPO} is not a git repository"
  exit 1
fi

# ---------------------------------------------------------------------------
# Run the sanitising capture (writes sanitised JSON to inst/extdata/)
# ---------------------------------------------------------------------------
log "Running exec/refresh_codexbar.sh in ${REPO}"
# refresh_codexbar.sh exits 0 on skip (no codexbar) and handles per-provider
# auth failures internally — we tolerate its exit code.
capture_exit=0
bash "${REPO}/exec/refresh_codexbar.sh" >> "${LOG_FILE}" 2>&1 || capture_exit=$?
if [ "${capture_exit}" -ne 0 ]; then
  log "WARNING: exec/refresh_codexbar.sh exited ${capture_exit} — may be partial; continuing"
fi

# ---------------------------------------------------------------------------
# LEAK GUARD (defense-in-depth)
# Strip PII was exec/refresh_codexbar.sh's job; we double-check before staging.
# If any PII marker is present, abort without touching git.
# ---------------------------------------------------------------------------
if [ -f "${USAGE_JSON}" ]; then
  log "Running leak guard on ${USAGE_JSON}"
  if grep -qE 'accountEmail|accountOrganization|loginMethod|@' "${USAGE_JSON}" 2>/dev/null; then
    log "ERROR: LEAK GUARD TRIGGERED — PII marker detected in ${USAGE_JSON}"
    log "ERROR: Aborting without git add/commit/push. Manual review required."
    exit 1
  fi
  log "Leak guard: PASS (no PII markers detected)"
else
  log "WARNING: ${USAGE_JSON} not found — capture may have been skipped"
fi

# ---------------------------------------------------------------------------
# Dry-run: report what would be committed and exit
# ---------------------------------------------------------------------------
if [ "${DRYRUN}" = "1" ]; then
  log "DRYRUN mode — skipping git add/commit/push"
  log "Would stage: ${USAGE_JSON}"
  log "Would stage: ${COST_JSON}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage the sanitised JSON files
# ---------------------------------------------------------------------------
# Only stage files that exist (cost file may be absent on first run)
staged=0
if [ -f "${USAGE_JSON}" ]; then
  git -C "${REPO}" add "${USAGE_JSON}"
  log "Staged: inst/extdata/codexbar_usage.json"
  staged=1
fi
if [ -f "${COST_JSON}" ]; then
  git -C "${REPO}" add "${COST_JSON}"
  log "Staged: inst/extdata/codexbar_cost_daily.json"
  staged=1
fi

if [ "${staged}" -eq 0 ]; then
  log "No output files found to stage — skipping commit"
  exit 0
fi

# ---------------------------------------------------------------------------
# Commit (skip cleanly if nothing changed)
# ---------------------------------------------------------------------------
if git -C "${REPO}" diff --cached --quiet; then
  log "No changes to commit (files unchanged since last commit)"
  exit 0
fi

commit_msg="chore: Auto-refresh codexbar cache $(date '+%Y-%m-%d %H:%M')"
if git -C "${REPO}" commit -m "${commit_msg}" >> "${LOG_FILE}" 2>&1; then
  log "Committed: ${commit_msg}"
else
  log "ERROR: git commit failed — check ${LOG_FILE}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Push to remote
# ---------------------------------------------------------------------------
log "Pushing to remote"
if git -C "${REPO}" push >> "${LOG_FILE}" 2>&1; then
  log "Push successful"
else
  log "WARNING: Push failed — may need manual intervention (check remote tracking branch)"
fi

log "=== refresh_codexbar_and_commit.sh done ==="
