#!/bin/bash
# kb_digest_daily_cron.sh — Wrapper for daily knowledge-base digest email.
#
# Steps:
#   0. Write housekeeping_runs start row (if duckdb available)
#   1. Run kb_digest.R to compute sanitised aggregates into a temp file.
#   1b. Write kb_events rows to unified.duckdb for each detected KB change
#   2. Send email locally via blastula+SMTP (NOT via gh workflow run).
#      The email body must NOT pass through CI logs — KB may contain PHI.
#   3. Update housekeeping_runs end row
#
# unified.duckdb writes: gracefully skipped when duckdb is absent.
# Tables written: housekeeping_runs, kb_events
# See: unified-observability-schema rule, llm#553, llm#550
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
# Tracked in llm#298, llm#553.

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
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME}/.claude/logs/unified.duckdb}"

# Dry-run flags
DRYRUN="${DRYRUN:-0}"
EMAIL_DRY_RUN="${EMAIL_DRY_RUN:-0}"
export DRYRUN EMAIL_DRY_RUN LLM_REPO_ROOT="${REPO_ROOT}"

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

# ── DuckDB availability check (llm#553) ───────────────────────────────────────
# Gracefully skip all DB writes when duckdb binary or unified.duckdb is absent.
# Same defensive pattern as config_digest_cron.sh (merged via #566).
_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "${UNIFIED_DB}" ]; then
  _duckdb_ok=1
  log "duckdb: available at ${UNIFIED_DB}"
else
  log "duckdb: not available — skipping DB writes"
fi

# Run ID for this invocation (bash native — no python3 per llm#569 compliance)
_run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
_run_started="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# ── Step 0: Write housekeeping_runs start row ─────────────────────────────────
if [ "${_duckdb_ok}" = "1" ]; then
  _script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/kb_digest_daily_cron.sh"
  duckdb "${UNIFIED_DB}" "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, status, rows_written)
    VALUES (
      '${_run_id}',
      'kb_digest',
      '${_script_abs}',
      TIMESTAMPTZ '${_run_started}',
      'ok',
      0
    );
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs INSERT failed (non-fatal)"
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

# Compute the 24h look-back timestamp (macOS/GNU compatible)
SINCE="$(date -v -24H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '')"
if [ -z "${SINCE}" ]; then
  SINCE="$(date '+%Y-%m-%d')T00:00:00"
fi
log "  since=${SINCE}"

if [ "${DRYRUN}" = "1" ]; then
  log "  DRYRUN: would run nix-shell ${NIX_TARGET} --run 'Rscript ${DIGEST_SCRIPT}'"
  # Create minimal stub for email script to consume
  printf '## Knowledge Base Digest — %s\n\n_DRYRUN mode — no actual KB analysis performed._\n' \
    "$(date +%Y-%m-%d)" > "${DIGEST_TMPFILE}"
  STEP1_EXIT=0
else
  SINCE_ARG=""
  [ -n "${KB_SINCE}" ] && SINCE_ARG="--since ${KB_SINCE}"

  nix-shell "${NIX_TARGET}" --run \
    "Rscript '${DIGEST_SCRIPT}' --knowledge-repo '${KB_KNOWLEDGE_REPO}' ${SINCE_ARG} --out '${DIGEST_TMPFILE}'" \
    >> "${LOG_FILE}" 2>&1
  STEP1_EXIT=$?
fi

if [ "${STEP1_EXIT}" -ne 0 ]; then
  log "ERROR: kb_digest.R exited ${STEP1_EXIT} — aborting"
  # Update housekeeping_runs with failed status before exiting
  if [ "${_duckdb_ok}" = "1" ]; then
    _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    duckdb "${UNIFIED_DB}" "
      UPDATE housekeeping_runs
      SET ended_at = TIMESTAMPTZ '${_run_ended}',
          status = 'failed',
          rows_written = 0
      WHERE id = '${_run_id}';
    " 2>/dev/null || true
  fi
  exit "${STEP1_EXIT}"
fi

# Log sanitised headline counts only (no content)
if [ -f "${DIGEST_TMPFILE}" ]; then
  line_count=$(wc -l < "${DIGEST_TMPFILE}")
  byte_count=$(wc -c < "${DIGEST_TMPFILE}")
  log "  Digest: ${line_count} lines, ${byte_count} bytes (sanitised aggregates only)"
fi

log "Step 1 done (exit=${STEP1_EXIT})"

# ── Step 1b: Write kb_events rows (llm#553 Phase A) ──────────────────────────
# Query git log on the knowledge repo for file changes in the same 24h window.
# Writes one row per (commit_sha, file_path) pair, keyed by KB layer.
# Layer is derived from the file path prefix: raw/ | wiki/ | outputs/.
# Uses process-substitution while-loop to avoid subshell (vars persist).
# Bash native UUID + ISO timestamp — no python3 per llm#569 compliance.
_EVENTS_WRITTEN=0

if [ "${_duckdb_ok}" = "1" ]; then
  log "Step 1b: writing kb_events to unified.duckdb..."

  _now_ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  _cur_sha=""

  # Walk git log on KB repo for last 24h; parse COMMIT header + numstat lines.
  # Layer prefixes correspond to the three knowledge base subdirectories.
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

    # Derive layer from path prefix
    _layer="outputs"
    case "${_fpath}" in
      raw/*)     _layer="raw" ;;
      wiki/*)    _layer="wiki" ;;
      outputs/*) _layer="outputs" ;;
    esac

    # Derive action from numstat columns
    if [ "${_added}" = "-" ] || [ "${_deleted}" = "-" ]; then
      _action="modified"          # binary file
    elif [ "${_deleted}" = "0" ] && [ "${_added}" != "0" ]; then
      _action="created"
    elif [ "${_added}" = "0" ] && [ "${_deleted}" != "0" ]; then
      _action="modified"          # all lines removed = file cleared (rare for KB)
    else
      _action="modified"
    fi

    _short_sha="${_cur_sha:0:7}"
    # TODO: see llm#567 — UNIQUE constraint on (commit_sha, path) for dedup
    _evt_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    _fpath_sql="${_fpath//"'"/"''"}"
    duckdb "${UNIFIED_DB}" "
      INSERT OR IGNORE INTO kb_events
        (id, fired_at, source, layer, path, action, commit_sha)
      VALUES (
        '${_evt_id}',
        TIMESTAMPTZ '${_now_ts}',
        'kb_digest_daily_cron.sh',
        '${_layer}',
        '${_fpath_sql}',
        '${_action}',
        '${_short_sha}'
      );
    " 2>/dev/null || true
    _EVENTS_WRITTEN=$(( _EVENTS_WRITTEN + 1 ))
  done < <(git -C "${KB_KNOWLEDGE_REPO}" log --numstat \
    --pretty="tformat:COMMIT:%H" \
    --since="${SINCE}" \
    -- "raw/" "wiki/" "outputs/" 2>/dev/null || true)

  log "Step 1b done: ${_EVENTS_WRITTEN} kb_events rows written"
else
  log "Step 1b: skipped (duckdb not available)"
fi

# ── Step 2: Send email locally via blastula ────────────────────────────────────
# NOTE: NOT via `gh workflow run` — the body must NOT pass through CI logs.
log "Step 2: sending knowledge-base digest email via local SMTP..."

EMAIL_SCRIPT="${REPO_ROOT}/.claude/scripts/send_kb_digest_email.R"

if [ ! -f "${EMAIL_SCRIPT}" ]; then
  log "ERROR: send_kb_digest_email.R not found at ${EMAIL_SCRIPT}"
  exit 1
fi

if [ "${DRYRUN}" = "1" ]; then
  log "  DRYRUN: would run nix-shell ${NIX_TARGET} --run 'Rscript ${EMAIL_SCRIPT}'"
  STEP2_EXIT=0
elif [ "${EMAIL_DRY_RUN}" = "1" ]; then
  log "  EMAIL_DRY_RUN=1: running script in dry-run mode (body to stdout only)"
  KB_DIGEST_FILE="${DIGEST_TMPFILE}" \
    nix-shell "${NIX_TARGET}" --run "Rscript '${EMAIL_SCRIPT}'" >> "${LOG_FILE}" 2>&1
  STEP2_EXIT=$?
else
  KB_DIGEST_FILE="${DIGEST_TMPFILE}" \
    nix-shell "${NIX_TARGET}" --run "Rscript '${EMAIL_SCRIPT}'" >> "${LOG_FILE}" 2>&1
  STEP2_EXIT=$?
fi

if [ "${STEP2_EXIT}" -ne 0 ]; then
  log "ERROR: send_kb_digest_email.R failed (exit=${STEP2_EXIT})"
  # Update housekeeping_runs with failed status before exiting
  if [ "${_duckdb_ok}" = "1" ]; then
    _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
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
  _run_ended="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  duckdb "${UNIFIED_DB}" "
    UPDATE housekeeping_runs
    SET ended_at = TIMESTAMPTZ '${_run_ended}',
        rows_written = ${_EVENTS_WRITTEN}
    WHERE id = '${_run_id}';
  " 2>/dev/null || log "duckdb WARN: housekeeping_runs UPDATE failed (non-fatal)"
  log "Step 3: housekeeping_runs updated (rows_written=${_EVENTS_WRITTEN})"
fi

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/kb-digest.stamp"

log "=== kb_digest_daily_cron.sh done ==="
