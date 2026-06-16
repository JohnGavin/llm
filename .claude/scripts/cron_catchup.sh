#!/bin/bash
# cron_catchup.sh — Anacron-style catch-up for launchd jobs missed during sleep.
#
# macOS launchd skips StartCalendarInterval firings while the Mac is asleep.
# This script runs every 15 min (StartInterval=900) and re-runs any job whose
# stamp file is older than max_age_hours.
#
# Stamp files: ~/.claude/logs/stamps/<label>.stamp
# Log: ~/.claude/logs/cron_catchup.log
#
# Tracked in llm#640.

set -uo pipefail

export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

STAMP_DIR="${HOME}/.claude/logs/stamps"
LOG_FILE="${HOME}/.claude/logs/cron_catchup.log"
BWS_LAUNCHER="/Users/johngavin/docs_gh/llm/.claude/scripts/bws_launcher.sh"

mkdir -p "${STAMP_DIR}"
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "${LOG_FILE}"
}

# Prevent concurrent runs
LOCK_FILE="/tmp/cron_catchup.lock"
if [[ -f "${LOCK_FILE}" ]]; then
  existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
  if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
    exit 0
  fi
fi
printf '%d' "$$" > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# Returns 0 (true) if stamp is stale or missing
is_stale() {
  local label="$1" max_age_h="$2"
  local stamp="${STAMP_DIR}/${label}.stamp"
  if [[ ! -f "${stamp}" ]]; then
    return 0
  fi
  local stamp_epoch file_epoch age_s max_s
  file_epoch=$(date -r "${stamp}" +%s 2>/dev/null || stat -c %Y "${stamp}" 2>/dev/null || echo 0)
  stamp_epoch=$(date +%s)
  age_s=$(( stamp_epoch - file_epoch ))
  max_s=$(( max_age_h * 3600 ))
  (( age_s > max_s ))
}

write_stamp() {
  local label="$1"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${STAMP_DIR}/${label}.stamp"
}

run_job() {
  local label="$1" cmd="$2"
  log "CATCHUP: running ${label}"
  local start_s end_s rc
  start_s=$(date +%s)
  set +e
  eval "${cmd}" >> "${LOG_FILE}" 2>&1
  rc=$?
  set -e
  end_s=$(date +%s)
  if [[ $rc -eq 0 ]]; then
    write_stamp "${label}"
    log "CATCHUP: ${label} OK ($(( end_s - start_s ))s)"
  else
    log "CATCHUP: ${label} FAILED (exit ${rc}, $(( end_s - start_s ))s)"
  fi
}

# Registry: "label|max_age_hours|command"
# max_age_hours: 26 for daily jobs (24h + 2h grace); 10 for 3x/day jobs
REGISTRY=(
  "self-review-stage1|26|/Users/johngavin/docs_gh/llm/.claude/scripts/self_review_stage1.sh"
  "codex-overnight|26|python3 /Users/johngavin/docs_gh/llm/.claude/scripts/codex_overnight_learning.py"
  "overnight-email|26|${BWS_LAUNCHER} /Users/johngavin/docs_gh/llm/bin/overnight_self_review_email_cron.sh"
  "roborev-daily-email|26|/Users/johngavin/docs_gh/llm/bin/roborev_daily_cron.sh"
  "kb-digest|26|/Users/johngavin/docs_gh/llm/bin/kb_digest_daily_cron.sh"
  "config-digest|26|/Users/johngavin/docs_gh/llm/bin/config_digest_cron.sh"
  "roborev-metrics-etl|26|/bin/bash /Users/johngavin/.claude/scripts/roborev_metrics_etl.sh --apply"
  "roborev-daily-backlog|26|/Users/johngavin/docs_gh/llm/.claude/scripts/roborev_daily_backlog_aggregator.sh"
  "branch-gc|26|/Users/johngavin/docs_gh/llm/.claude/scripts/branch_gc.sh"
  "worktree-gc|26|/Users/johngavin/docs_gh/llm/.claude/scripts/worktree_gc.sh"
  "unified-duckdb-backup|26|/Users/johngavin/.claude/scripts/unified_duckdb_backup.sh"
  "config-pulse|26|/Users/johngavin/docs_gh/llm/.claude/scripts/config_pulse.sh"
  "knowledge-pulse|26|/Users/johngavin/docs_gh/llm/.claude/scripts/knowledge_pulse.sh"
  "wiki-health-pulse|26|/Users/johngavin/docs_gh/llm/.claude/scripts/wiki_health_check.sh"
  "pr-status-pulse|10|/Users/johngavin/docs_gh/llm/.claude/scripts/pr_status_pulse.sh"
)

CHECKED=0
STALE=0
RAN=0

for entry in "${REGISTRY[@]}"; do
  IFS='|' read -r label max_age cmd <<< "${entry}"
  (( CHECKED++ ))
  if is_stale "${label}" "${max_age}"; then
    (( STALE++ ))
    run_job "${label}" "${cmd}"
    (( RAN++ ))
  fi
done

if (( STALE > 0 )); then
  log "SUMMARY: checked=${CHECKED} stale=${STALE} ran=${RAN}"
fi
