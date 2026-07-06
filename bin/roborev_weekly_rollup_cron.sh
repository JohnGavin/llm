#!/usr/bin/env bash
# roborev_weekly_rollup_cron.sh — wrapper for the weekly roborev rollup.
#
# 1. Sources ~/.claude/env/roborev_email.env (credentials, optional).
# 2. Generates the weekly markdown rollup via roborev_weekly_rollup.R.
# 3. Sends the digest email via send_roborev_weekly_rollup_email.R.
#
# Usage:
#   bin/roborev_weekly_rollup_cron.sh
#   DRYRUN=1 EMAIL_DRY_RUN=1 bin/roborev_weekly_rollup_cron.sh
#
# Called by:
#   com.claude.roborev-weekly-rollup-email.plist (Sunday 09:15 local)
#
# Tracked in llm#356.

set -uo pipefail

export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$REPO_DIR/.claude/scripts"
LLM_NIX="$REPO_DIR/default.nix"
NIX_SHELL_BIN="/nix/var/nix/profiles/default/bin/nix-shell"

LOG="$HOME/.claude/logs/roborev_weekly_rollup.log"
mkdir -p "$(dirname "$LOG")"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) $*" | tee -a "$LOG"; }

DRYRUN="${DRYRUN:-0}"
EMAIL_DRY_RUN="${EMAIL_DRY_RUN:-0}"
[ "$DRYRUN" = "1" ] && EMAIL_DRY_RUN=1
export EMAIL_DRY_RUN

log "START roborev_weekly_rollup_cron.sh dryrun=$DRYRUN"

# ── Load credentials (if available) ──────────────────────────────────────────
ENV_FILE="$HOME/.claude/env/roborev_email.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
  log "credentials loaded from $ENV_FILE"
else
  log "no credentials file at $ENV_FILE — EMAIL_DRY_RUN forced to 1"
  EMAIL_DRY_RUN=1
  export EMAIL_DRY_RUN
fi

# ── Deploy: pull latest main before running (llm#510) ─────────────────────────
# Cron wrappers run against ${REPO_DIR}; without this step every gh pr merge
# ships nothing — the cron uses whatever was last manually pulled to the main
# checkout. The fast-forward is silent on success and never overwrites local
# work because of --ff-only.
if [ -z "${SKIP_CRON_PULL:-}" ]; then
    git -C "${REPO_DIR}" fetch origin main 2>/dev/null
    if git -C "${REPO_DIR}" merge --ff-only origin/main 2>/dev/null; then
        log "deploy: ff to $(git -C "${REPO_DIR}" rev-parse --short HEAD)"
    else
        log "deploy WARN: ff-only failed — running against $(git -C "${REPO_DIR}" rev-parse --short HEAD)"
    fi
fi
log "HEAD: $(git -C "${REPO_DIR}" rev-parse --short HEAD) $(git -C "${REPO_DIR}" log -1 --format='%s')"

# ── Verify nix-shell is accessible (mirrors roborev_daily_cron.sh) ────────────
if [ ! -f "$LLM_NIX" ]; then
  log "ERROR: nix file not found at $LLM_NIX"
  exit 1
fi
if [ ! -x "$NIX_SHELL_BIN" ]; then
  log "ERROR: nix-shell not found at $NIX_SHELL_BIN (PATH=$PATH)"
  exit 1
fi
log "using nix-shell: $NIX_SHELL_BIN"

# ── Step 1: generate rollup markdown ─────────────────────────────────────────
ROLLUP_SCRIPT="$SCRIPTS_DIR/roborev_weekly_rollup.R"
if [ ! -f "$ROLLUP_SCRIPT" ]; then
  log "ERROR: rollup script not found at $ROLLUP_SCRIPT"
  exit 1
fi

log "running $ROLLUP_SCRIPT via nix-shell"
"$NIX_SHELL_BIN" "$LLM_NIX" --run "Rscript '${ROLLUP_SCRIPT}'" 2>&1 | tee -a "$LOG"
rollup_rc=${PIPESTATUS[0]}
if [ "$rollup_rc" -ne 0 ]; then
  # #736: a non-zero exit from the rollup script means its fail-loud guard
  # tripped (evidence of done reviews exists but the rollup would render
  # all-zero) or the reviews.db connection itself failed. Either way this is
  # a real bug, not a legitimately empty week (which exits 0) — surface the
  # failure to launchd and do NOT send a misleading all-zero digest email.
  log "ERROR: rollup script exited $rollup_rc — aborting before email step (#736 fail-loud guard)"
  exit "$rollup_rc"
fi

# ── Step 2: send email ────────────────────────────────────────────────────────
EMAIL_SCRIPT="$SCRIPTS_DIR/send_roborev_weekly_rollup_email.R"
if [ ! -f "$EMAIL_SCRIPT" ]; then
  log "ERROR: email script not found at $EMAIL_SCRIPT"
  exit 1
fi

log "running $EMAIL_SCRIPT via nix-shell (EMAIL_DRY_RUN=$EMAIL_DRY_RUN)"
"$NIX_SHELL_BIN" "$LLM_NIX" --run "Rscript '${EMAIL_SCRIPT}'" 2>&1 | tee -a "$LOG"
email_rc=${PIPESTATUS[0]}

if [ "$email_rc" -ne 0 ]; then
  log "ERROR: email script exited $email_rc"
  exit "$email_rc"
fi

log "DONE roborev_weekly_rollup_cron.sh"
