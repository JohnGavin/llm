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
#
# INTERIM #229: publishes sanitised data to the unprotected `data` branch
# (main is protected by required pr-checks). Clean up when #229 is resolved.

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

# ── INTERIM #229: publish sanitised data to the unprotected `data` branch ──────
# main is protected (required pr-checks) so direct push is rejected. Publish to a
# `data` branch via a throwaway worktree instead. CLEAN UP when #229 is resolved.
if [ "${DRYRUN}" = "1" ]; then
  log "DRYRUN — would publish codexbar_*.json to origin/data branch"
else
  DATA_WT="$(mktemp -d /tmp/llmtel-data.XXXXXX)"
  git -C "${REPO}" fetch origin data >/dev/null 2>&1 || true
  if git -C "${REPO}" show-ref --verify --quiet refs/remotes/origin/data; then
    git -C "${REPO}" worktree add --force "${DATA_WT}" -B data origin/data >> "${LOG_FILE}" 2>&1
  else
    git -C "${REPO}" worktree add --force "${DATA_WT}" -b data origin/main >> "${LOG_FILE}" 2>&1
  fi
  mkdir -p "${DATA_WT}/inst/extdata"
  if [ -f "${USAGE_JSON}" ]; then
    cp "${USAGE_JSON}" "${DATA_WT}/inst/extdata/"
  fi
  if [ -f "${COST_JSON}" ]; then
    cp "${COST_JSON}" "${DATA_WT}/inst/extdata/"
  fi
  git -C "${DATA_WT}" add inst/extdata/codexbar_usage.json inst/extdata/codexbar_cost_daily.json
  if git -C "${DATA_WT}" diff --cached --quiet; then
    log "No codexbar data changes to publish"
  else
    git -C "${DATA_WT}" commit -m "data: codexbar refresh $(date '+%Y-%m-%d %H:%M') [INTERIM #229]" >> "${LOG_FILE}" 2>&1
    if git -C "${DATA_WT}" push origin data >> "${LOG_FILE}" 2>&1; then
      log "Published codexbar data to origin/data"
    else
      log "ERROR: push to data branch failed"
    fi
  fi
  git -C "${REPO}" worktree remove --force "${DATA_WT}" >> "${LOG_FILE}" 2>&1 || true
fi

log "=== refresh_codexbar_and_commit.sh done ==="
