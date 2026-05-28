#!/bin/bash
# publish_roborev_data.sh — Push daily roborev JSON snapshot to llmtelemetry `data` branch.
#
# Mirrors the codexbar data-branch publish pattern (#306):
#   - Throwaway worktree (never touches main checkout)
#   - Leak guard: verifies only data/ paths are written
#   - DRYRUN=1 support: prints what it would do without touching git
#   - Idempotent: run twice in a day → same result
#
# Data written to llmtelemetry `data` branch:
#   data/roborev/latest.json       ← always overwritten
#   data/roborev/YYYY-MM-DD.json   ← archive, idempotent per day
#
# Commit message: "data: roborev daily report YYYY-MM-DD [skip review] [skip ci]"
#
# Required:
#   llmtelemetry repo at ~/docs_gh/llmtelemetry with origin pointing to
#   JohnGavin/llmtelemetry.
#
# Env vars:
#   ROBOREV_DAILY_DIR   Override source dir (default ~/.claude/logs/roborev_daily_report/)
#   DRYRUN              Set to "1" to skip git operations
#   AGENT_PUSH_OK       Set to "1" to bypass protected-branch push guard
#
# Tracked in llm#287.

set -uo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

TELEMETRY_REPO="${HOME}/docs_gh/llmtelemetry"
ROBOREV_DAILY_DIR="${ROBOREV_DAILY_DIR:-${HOME}/.claude/logs/roborev_daily_report}"
LOG_FILE="${HOME}/.claude/logs/publish_roborev_data.log"
LOCK_FILE="/tmp/publish_roborev_data.lock"
WORKTREE_DIR="/tmp/publish_roborev_data_worktree_$$"
DRYRUN="${DRYRUN:-0}"

# ── Logging ────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "${LOG_FILE}"
}

log "=== publish_roborev_data.sh starting (DRYRUN=${DRYRUN}) ==="

# ── Self-test mode ─────────────────────────────────────────────────────────────
if [ "${SELFTEST:-0}" = "1" ]; then
  log "SELFTEST: DRYRUN path verification"
  if [ "${DRYRUN}" = "1" ]; then
    log "SELFTEST PASS: DRYRUN=1 would skip git operations"
    exit 0
  fi
  log "SELFTEST: to test dry-run, set DRYRUN=1"
  exit 0
fi

# ── Lock (prevent concurrent runs) ────────────────────────────────────────────
if [ -f "${LOCK_FILE}" ]; then
  existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
  if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
    log "SKIP: another instance running (PID ${existing_pid})"
    exit 0
  fi
fi
printf '%d' "$$" > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"; if [ -d "${WORKTREE_DIR}" ]; then git -C "${TELEMETRY_REPO}" worktree remove --force "${WORKTREE_DIR}" 2>/dev/null || true; fi' EXIT

# ── Verify repos ────────────────────────────────────────────────────────────────
if [ ! -d "${TELEMETRY_REPO}/.git" ]; then
  log "ERROR: llmtelemetry repo not found at ${TELEMETRY_REPO}"
  exit 1
fi

# ── Dry-run: report what would happen and exit early (before file checks) ─────
if [ "${DRYRUN}" = "1" ]; then
  log "DRYRUN: source dir would be: ${ROBOREV_DAILY_DIR}"
  log "DRYRUN: would create throwaway worktree at ${WORKTREE_DIR}"
  log "DRYRUN: would fetch + checkout data branch"
  log "DRYRUN: would write to data/roborev/latest.json"
  log "DRYRUN: would write to data/roborev/<YYYY-MM-DD>.json"
  log "DRYRUN: would commit: data: roborev daily report <date> [skip review] [skip ci]"
  log "DRYRUN: would push to origin data (with AGENT_PUSH_OK=1)"
  log "DRYRUN: skipping all git operations"
  exit 0
fi

# ── Find latest snapshot ───────────────────────────────────────────────────────
if [ ! -d "${ROBOREV_DAILY_DIR}" ]; then
  log "ERROR: source directory not found: ${ROBOREV_DAILY_DIR}"
  exit 1
fi

# Most recently modified .json file in the daily dir
LATEST_JSON="$(ls -t "${ROBOREV_DAILY_DIR}"/*.json 2>/dev/null | head -1)"
if [ -z "${LATEST_JSON}" ]; then
  log "ERROR: no JSON snapshots found in ${ROBOREV_DAILY_DIR}"
  exit 1
fi

REPORT_DATE="$(basename "${LATEST_JSON}" .json)"
log "Source snapshot: ${LATEST_JSON} (date=${REPORT_DATE})"

# ── Create throwaway worktree (data branch) ────────────────────────────────────
log "Fetching origin/data..."
git -C "${TELEMETRY_REPO}" fetch origin data >> "${LOG_FILE}" 2>&1

log "Creating worktree at ${WORKTREE_DIR}..."
git -C "${TELEMETRY_REPO}" worktree add "${WORKTREE_DIR}" origin/data >> "${LOG_FILE}" 2>&1
git -C "${WORKTREE_DIR}" checkout -b "publish-roborev-${REPORT_DATE}-$$" 2>/dev/null || true

# ── Write files ────────────────────────────────────────────────────────────────
TARGET_DIR="${WORKTREE_DIR}/data/roborev"
mkdir -p "${TARGET_DIR}"

cp "${LATEST_JSON}" "${TARGET_DIR}/latest.json"
log "Wrote: data/roborev/latest.json"

cp "${LATEST_JSON}" "${TARGET_DIR}/${REPORT_DATE}.json"
log "Wrote: data/roborev/${REPORT_DATE}.json"

# ── LEAK GUARD ─────────────────────────────────────────────────────────────────
# Only data/roborev/ paths should be modified. Any other diff is a bug.
LEAK_PATHS="$(git -C "${WORKTREE_DIR}" diff --name-only HEAD 2>/dev/null | grep -v '^data/' || true)"
UNTRACKED_OUTSIDE="$(git -C "${WORKTREE_DIR}" ls-files --others --exclude-standard 2>/dev/null | grep -v '^data/' || true)"

if [ -n "${LEAK_PATHS}" ] || [ -n "${UNTRACKED_OUTSIDE}" ]; then
  log "ERROR: LEAK GUARD — modified paths outside data/:"
  log "  diff: ${LEAK_PATHS}"
  log "  untracked: ${UNTRACKED_OUTSIDE}"
  log "Aborting without commit/push."
  exit 1
fi
log "Leak guard: PASS (only data/ paths modified)"

# ── Commit ─────────────────────────────────────────────────────────────────────
git -C "${WORKTREE_DIR}" add data/roborev/latest.json
git -C "${WORKTREE_DIR}" add "data/roborev/${REPORT_DATE}.json"

if git -C "${WORKTREE_DIR}" diff --cached --quiet; then
  log "No changes to commit (files unchanged since last push)"
  exit 0
fi

COMMIT_MSG="data: roborev daily report ${REPORT_DATE} [skip review] [skip ci]"
if git -C "${WORKTREE_DIR}" commit -m "${COMMIT_MSG}" >> "${LOG_FILE}" 2>&1; then
  log "Committed: ${COMMIT_MSG}"
else
  log "ERROR: git commit failed"
  exit 1
fi

# ── Push to origin/data ────────────────────────────────────────────────────────
log "Pushing to origin/data..."
# AGENT_PUSH_OK=1 bypasses the agent_push_guard.sh hook for this legitimate
# orchestrator push to the data branch. The data branch is not a protected main/master
# branch but the hook pattern triggers on all worktrees — use the escape hatch.
if AGENT_PUSH_OK=1 git -C "${WORKTREE_DIR}" push origin "HEAD:data" >> "${LOG_FILE}" 2>&1; then
  log "Push successful → origin/data"
else
  log "WARNING: push failed — data committed in worktree; will be cleaned up"
  log "  Manual recovery: git -C ${TELEMETRY_REPO} fetch origin; git cherry-pick ..."
  exit 1
fi

log "=== publish_roborev_data.sh done ==="
