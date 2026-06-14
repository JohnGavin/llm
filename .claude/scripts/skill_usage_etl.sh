#!/usr/bin/env bash
# skill_usage_etl.sh — bash wrapper for skill usage ETL.
#
# Flags:
#   --dry-run   (default) print proposed records; no DB writes
#   --apply     write to ~/.claude/logs/unified.duckdb
#   --since YYYY-MM-DD  re-scan from this date (default: yesterday)
#   --all       scan all JSONL files regardless of mtime
#   --help      usage
#
# Runs nightly at 03:30 via com.claude.skill-usage-etl.plist.
# Uses GC-rooted nix-shell (llm#596) — zero eval, zero network under launchd.

export PATH="/usr/local/bin:/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

REPO_ROOT="/Users/johngavin/docs_gh/llm"
LLM_NIX="${REPO_ROOT}/default.nix"
ETL_SCRIPT="${REPO_ROOT}/.claude/scripts/skill_usage_etl.R"
LOG_FILE="${HOME}/.claude/logs/skill_usage_etl.log"
GCROOT_DRV="${HOME}/.claude/nix-gcroots/llm-shell.drv"
GCROOT_STAMP="${GCROOT_DRV}.stamp"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"; }

# ── Args ──────────────────────────────────────────────────────────────────────
APPLY_FLAG=""
SINCE_FLAG=""
ALL_FLAG=""

for arg in "$@"; do
  case "$arg" in
    --help)
      echo "Usage: skill_usage_etl.sh [--apply] [--since YYYY-MM-DD] [--all]"
      exit 0 ;;
    --apply)     APPLY_FLAG="--apply" ;;
    --dry-run)   ;;  # default
    --all)       ALL_FLAG="--all" ;;
    --since)     ;;  # handled by next arg
    *)
      if [ "${PREV:-}" = "--since" ]; then SINCE_FLAG="--since $arg"; fi ;;
  esac
  PREV="$arg"
done

log "skill_usage_etl START apply=${APPLY_FLAG:-dry-run} since=${SINCE_FLAG:-yesterday} all=${ALL_FLAG:-no}"

# ── nix-shell target ──────────────────────────────────────────────────────────
if ! command -v nix-shell > /dev/null 2>&1; then
  log "ERROR: nix-shell not on PATH"
  exit 1
fi

if [ "${LLM_NIX}" -nt "${GCROOT_STAMP}" ] 2>/dev/null || [ ! -e "${GCROOT_DRV}" ]; then
  log "Refreshing GC root..."
  "${REPO_ROOT}/.claude/scripts/nix_gcroot_refresh.sh" "${LLM_NIX}" >> "${LOG_FILE}" 2>&1 || true
fi

if [ -e "${GCROOT_DRV}" ]; then
  NIX_TARGET="${GCROOT_DRV}"
  log "Using GC-rooted drv: ${NIX_TARGET}"
else
  NIX_TARGET="${LLM_NIX}"
  log "WARN: no gcroot — falling back to nix-shell evaluation (needs network, llm#596)"
fi

# ── Run ETL ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2086
nix-shell "${NIX_TARGET}" --run \
  "Rscript '${ETL_SCRIPT}' ${APPLY_FLAG} ${SINCE_FLAG} ${ALL_FLAG}" \
  >> "${LOG_FILE}" 2>&1

log "skill_usage_etl END"
