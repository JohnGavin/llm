#!/usr/bin/env bash
# incident_response.sh — Credential incident response SKELETON (DRY-RUN ONLY)
#
# PURPOSE
#   Guides a human through the steps needed to revoke and rotate credentials
#   after a suspected leak. This version prints rotation URLs and commands
#   WITHOUT calling them — it is purely informational.
#
# STATUS: SKELETON — DRY-RUN ONLY
#   Live credential revocation logic (API calls, automated rotation) is
#   intentionally absent from this file and will be added in a follow-up PR.
#   The only action this script takes is logging and printing instructions.
#
# SAFETY CONSTRAINTS (all enforced at runtime, not by convention):
#   1. DRY_RUN is hard-coded to "true" — it can only be changed by editing
#      this file (there is no --no-dry-run flag).
#   2. Refuses to run if CLAUDE_AGENT=1 is set (human-only).
#   3. Requires INCIDENT_CONFIRM="I AM ROTATING CREDENTIALS" — anything else
#      aborts immediately.
#   4. All invocations are logged to ~/.claude/logs/incident_response.log.
#   5. macOS alert fires only with --alert flag (prevents alarm during tests).
#
# USAGE (human-only, from terminal — NOT from Claude Code):
#   INCIDENT_CONFIRM="I AM ROTATING CREDENTIALS" bash incident_response.sh [--alert]
#
# TESTING (dry-run output only, no side effects):
#   INCIDENT_CONFIRM="I AM ROTATING CREDENTIALS" bash incident_response.sh
#
# See JohnGavin/llm#376.

set -euo pipefail

# ── Hard-coded safety switches ───────────────────────────────────────────────
# DRY_RUN can ONLY be set to false by editing this file.
# There is no flag or env-var override — this is intentional.
DRY_RUN=true
readonly DRY_RUN

# ── Logging ──────────────────────────────────────────────────────────────────
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/incident_response.log"
mkdir -p "$LOG_DIR"

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

log_only() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

# ── Parse flags ──────────────────────────────────────────────────────────────
_ALERT=false
for _arg in "$@"; do
  case "$_arg" in
    --alert) _ALERT=true ;;
    *) printf 'Unknown flag: %s\n' "$_arg" >&2; exit 2 ;;
  esac
done

# ── Log every invocation (before any checks) ─────────────────────────────────
log_only "INVOKE" "invoked: user=${USER:-unknown} pid=$$ dry_run=$DRY_RUN agent=${CLAUDE_AGENT:-0} alert=$_ALERT"

# ── Guard: agent context ─────────────────────────────────────────────────────
if [ "${CLAUDE_AGENT:-0}" = "1" ]; then
  log "ABORT" "CLAUDE_AGENT=1 detected — this script is human-only. Refusing to run."
  exit 1
fi

# ── Guard: confirmation phrase ───────────────────────────────────────────────
_REQUIRED_PHRASE="I AM ROTATING CREDENTIALS"
_PROVIDED="${INCIDENT_CONFIRM:-}"

if [ "$_PROVIDED" != "$_REQUIRED_PHRASE" ]; then
  log "ABORT" "confirmation phrase missing or incorrect. Provide: INCIDENT_CONFIRM=\"$_REQUIRED_PHRASE\""
  printf '\nTo run this script, set:\n' >&2
  printf '  INCIDENT_CONFIRM="%s" bash %s\n\n' "$_REQUIRED_PHRASE" "$(basename "$0")" >&2
  exit 1
fi

log "CONFIRMED" "phrase accepted, proceeding (dry_run=$DRY_RUN)"

# ── Optional macOS alert ──────────────────────────────────────────────────────
if [ "$_ALERT" = "true" ]; then
  osascript -e 'display alert "CREDENTIAL INCIDENT RESPONSE" message "Running incident_response.sh — check terminal." as critical' 2>/dev/null || true
fi

# ── Dry-run banner ───────────────────────────────────────────────────────────
printf '\n'
printf '═══════════════════════════════════════════════════════════════════\n'
printf '  INCIDENT RESPONSE — DRY-RUN MODE\n'
printf '  No API calls, no revocations, no mutations.\n'
printf '  Review the steps below and execute them manually.\n'
printf '═══════════════════════════════════════════════════════════════════\n\n'

# ── Step 1: GitHub token rotation ────────────────────────────────────────────
printf '── Step 1: GitHub Personal Access Tokens ──────────────────────────\n'
printf 'Revoke ALL active tokens:\n'
printf '  URL: https://github.com/settings/tokens\n'
printf '  Action: Identify tokens named GITHUB_TOKEN / GITHUB_TOKEN_READ / GITHUB_TOKEN_WRITE\n'
printf '          Click "Delete" on each.\n'
printf 'Create replacement tokens:\n'
printf '  URL: https://github.com/settings/personal-access-tokens/new\n'
printf '  Action: Create new tokens with minimum required scopes.\n'
printf '          For read-only CI: contents:read, metadata:read\n'
printf '          For write CI: contents:write, pull_requests:write\n'
printf 'Update .Renviron:\n'
printf '  GITHUB_TOKEN_READ=<new-read-token>\n'
printf '  GITHUB_TOKEN_WRITE=<new-write-token>\n'
printf '  GITHUB_TOKEN=<new-token>\n\n'

log "DRY-RUN" "Step 1 printed (GitHub token rotation)"

# ── Step 2: Anthropic API key rotation ───────────────────────────────────────
printf '── Step 2: Anthropic API Key ───────────────────────────────────────\n'
printf 'Revoke current key:\n'
printf '  URL: https://console.anthropic.com/account/keys\n'
printf '  Action: Locate active key(s), click "Revoke".\n'
printf 'Create replacement key:\n'
printf '  URL: https://console.anthropic.com/account/keys\n'
printf '  Action: "Create Key", copy immediately (shown only once).\n'
printf 'Update .Renviron:\n'
printf '  ANTHROPIC_API_KEY=<new-key>\n\n'

log "DRY-RUN" "Step 2 printed (Anthropic API key rotation)"

# ── Step 3: OpenAI API key rotation ──────────────────────────────────────────
printf '── Step 3: OpenAI API Key ──────────────────────────────────────────\n'
printf 'Revoke current key:\n'
printf '  URL: https://platform.openai.com/api-keys\n'
printf '  Action: Locate active key(s), click "Revoke".\n'
printf 'Create replacement key:\n'
printf '  URL: https://platform.openai.com/api-keys\n'
printf '  Action: "+ Create new secret key", copy immediately.\n'
printf 'Update .Renviron:\n'
printf '  OPENAI_API_KEY=<new-key>\n\n'

log "DRY-RUN" "Step 3 printed (OpenAI API key rotation)"

# ── Step 4: Gmail app password rotation ──────────────────────────────────────
printf '── Step 4: Gmail App Password ──────────────────────────────────────\n'
printf 'Revoke current app password:\n'
printf '  URL: https://myaccount.google.com/apppasswords\n'
printf '  Action: Delete the "Claude Code" or relevant app password.\n'
printf 'Create replacement:\n'
printf '  URL: https://myaccount.google.com/apppasswords\n'
printf '  Action: Generate a new app password for "Mail" / "Other".\n'
printf 'Update .Renviron:\n'
printf '  GMAIL_APP_PASSWORD=<new-app-password>\n\n'

log "DRY-RUN" "Step 4 printed (Gmail app password rotation)"

# ── Step 5: Post-rotation verification ───────────────────────────────────────
printf '── Step 5: Verification ────────────────────────────────────────────\n'
printf 'After updating .Renviron, restart Claude Code and verify:\n'
printf '  bash ~/.claude/scripts/credential_tier_lookup.sh ANTHROPIC_API_KEY\n'
printf '  # Expected output: ask\n'
printf 'Test that the new keys work:\n'
printf '  gh auth status  # GitHub\n'
printf '  Rscript -e '"'"'cat(nchar(Sys.getenv("ANTHROPIC_API_KEY")), "chars\n")'"'"'\n\n'

log "DRY-RUN" "Step 5 printed (post-rotation verification)"

# ── Summary ──────────────────────────────────────────────────────────────────
printf '═══════════════════════════════════════════════════════════════════\n'
printf '  DRY-RUN COMPLETE. No credentials were modified.\n'
printf '  Log: %s\n' "$LOG_FILE"
printf '═══════════════════════════════════════════════════════════════════\n\n'

log "COMPLETE" "dry-run finished — 4 providers printed, no mutations"
