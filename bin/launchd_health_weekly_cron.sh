#!/usr/bin/env bash
# launchd_health_weekly_cron.sh — Cron wrapper for the weekly health email.
#
# Steps:
#   1. Generate the markdown report via launchd_health_report.R
#   2. Send the email via send_launchd_health_email.R
#   3. Log the run
#
# Invoked by: com.claude.launchd-health-weekly.plist (Sunday 09:00)
#
# Environment variables (set in ~/.claude/.env or plist EnvironmentVariables):
#   GMAIL_USERNAME        Gmail sender
#   GMAIL_APP_PASSWORD    Gmail app password
#   REPORT_RECIPIENT      Override recipient
#   EMAIL_DRY_RUN         Set to 1 to print body without sending
#   LAUNCHD_LEDGER        Override DuckDB ledger path
#   CLOUD_REPOS           Override repos for cloud-cron enumeration
#
# Tracked in llm#300.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────

REPO_ROOT="${REPO_ROOT:-$HOME/docs_gh/llm}"
SCRIPTS_DIR="$REPO_ROOT/.claude/scripts"
LOG_DIR="${LOG_DIR:-$HOME/.claude/logs}"
LOG_FILE="$LOG_DIR/launchd_health_weekly.log"
REPORT_OUT="$LOG_DIR/launchd_health_report_$(date +%Y-%m-%d).md"

# Bring Nix-shell R into PATH if needed
if [[ -f "$REPO_ROOT/default.nix" ]]; then
  NIX_R="$(/usr/bin/env nix-shell "$REPO_ROOT/default.nix" --run "which Rscript" 2>/dev/null || true)"
  if [[ -n "$NIX_R" ]]; then
    export PATH="$(dirname "$NIX_R"):$PATH"
  fi
fi

RSCRIPT="${RSCRIPT:-Rscript}"

# ── Logging ────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') launchd_health_weekly_cron $*" >> "$LOG_FILE"
}

log "START"

# ── Source credentials if available ───────────────────────────────────────────

ENV_FILE="$HOME/.claude/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  log "sourced credentials from $ENV_FILE"
fi

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

# ── Step 1: Generate markdown report ─────────────────────────────────────────

log "running aggregator → $REPORT_OUT"
"$RSCRIPT" "$SCRIPTS_DIR/launchd_health_report.R" --out "$REPORT_OUT" 2>>"$LOG_FILE"
log "aggregator done ($(wc -l < "$REPORT_OUT") lines)"

# ── Step 2: Send email ─────────────────────────────────────────────────────────

export LAUNCHD_SCRIPTS_DIR="$SCRIPTS_DIR"
log "sending email"
"$RSCRIPT" "$SCRIPTS_DIR/send_launchd_health_email.R" 2>>"$LOG_FILE"
log "email send complete"

# ── Step 3: Prune old reports (keep 30 days) ──────────────────────────────────

find "$LOG_DIR" -name "launchd_health_report_*.md" -mtime +30 -delete 2>/dev/null || true
log "pruned old reports"

log "DONE"
