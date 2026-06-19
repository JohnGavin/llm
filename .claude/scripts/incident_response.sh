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
# PROVIDER COVERAGE (Change 3 — llm#376 Phase 1/2 hardening):
#   Step 1: GitHub tokens (GITHUB_TOKEN, GITHUB_TOKEN_READ, GITHUB_TOKEN_WRITE)
#   Step 2: Anthropic API key (ANTHROPIC_API_KEY)
#   Step 3: OpenAI API key (OPENAI_API_KEY)
#   Step 4: FRED API key (FRED_API_KEY)
#   Step 5: Bitwarden Secrets Manager access token (BWS_ACCESS_TOKEN)
#             — stored in macOS Keychain (service=claude-cron, account=bws)
#             — bws-stored secrets in claude-llm-creds project
#   Step 6: Gmail app password (GMAIL_APP_PASSWORD)
#   Step 7: Post-rotation verification
#
#   Each provider is structured as:
#     ROTATE  — instructions to create new credential
#     REVOKE  — instructions to invalidate old credential
#     UPDATE-STORE — where to persist the new credential
#       For secrets migrated to BW SM: UPDATE-STORE = bws CLI, NOT .Renviron
#       For non-BW-SM secrets: UPDATE-STORE = .Renviron
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
printf '  Providers: GitHub · Anthropic · OpenAI · FRED · BW SM · Gmail\n'
printf '═══════════════════════════════════════════════════════════════════\n\n'

# ── Step 1: GitHub token rotation ────────────────────────────────────────────
printf '── Step 1: GitHub Personal Access Tokens ──────────────────────────\n'
printf '  ROTATE:\n'
printf '    URL: https://github.com/settings/personal-access-tokens/new\n'
printf '    Action: Create new tokens with minimum required scopes.\n'
printf '      Read-only CI (GITHUB_TOKEN_READ): contents:read, metadata:read\n'
printf '      Write CI (GITHUB_TOKEN_WRITE):   contents:write, pull_requests:write\n'
printf '      General (GITHUB_TOKEN):          minimum scopes for your workflow\n'
printf '  REVOKE:\n'
printf '    URL: https://github.com/settings/tokens\n'
printf '    Action: Locate OLD tokens (GITHUB_TOKEN / GITHUB_TOKEN_READ / GITHUB_TOKEN_WRITE).\n'
printf '            Click "Delete" on each.\n'
printf '    CHECKPOINT: confirm old tokens are gone from the list.\n'
printf '  UPDATE-STORE (.Renviron — these are NOT yet in BW SM):\n'
printf '    GITHUB_TOKEN_READ=<new-read-token>\n'
printf '    GITHUB_TOKEN_WRITE=<new-write-token>\n'
printf '    GITHUB_TOKEN=<new-token>\n\n'

log "DRY-RUN" "Step 1 printed (GitHub token rotation)"

# ── Step 2: Anthropic API key rotation ───────────────────────────────────────
printf '── Step 2: Anthropic API Key ───────────────────────────────────────\n'
printf '  ROTATE:\n'
printf '    URL: https://console.anthropic.com/account/keys\n'
printf '    Action: "Create Key", copy immediately (shown only once).\n'
printf '  REVOKE:\n'
printf '    URL: https://console.anthropic.com/account/keys\n'
printf '    Action: Locate active key(s), click "Revoke".\n'
printf '    CHECKPOINT: verify old key is no longer listed as active.\n'
printf '  UPDATE-STORE (Bitwarden SM — bws CLI):\n'
printf '    bws secret edit <secret-id-for-ANTHROPIC_API_KEY> --value <new-key>\n'
printf '    # Verify: bws secret get <secret-id> | jq .value | wc -c  (should be >0)\n'
printf '    # The bws_launcher.sh will pick up the new value on next run.\n\n'

log "DRY-RUN" "Step 2 printed (Anthropic API key rotation)"

# ── Step 3: OpenAI API key rotation ──────────────────────────────────────────
printf '── Step 3: OpenAI API Key ──────────────────────────────────────────\n'
printf '  ROTATE:\n'
printf '    URL: https://platform.openai.com/api-keys\n'
printf '    Action: "+ Create new secret key", copy immediately.\n'
printf '  REVOKE:\n'
printf '    URL: https://platform.openai.com/api-keys\n'
printf '    Action: Locate active key(s), click "Revoke".\n'
printf '    CHECKPOINT: verify old key is no longer listed as active.\n'
printf '  UPDATE-STORE (Bitwarden SM — bws CLI):\n'
printf '    bws secret edit <secret-id-for-OPENAI_API_KEY> --value <new-key>\n'
printf '    # Verify: bws secret get <secret-id> | jq .value | wc -c\n\n'

log "DRY-RUN" "Step 3 printed (OpenAI API key rotation)"

# ── Step 4: FRED API key rotation ────────────────────────────────────────────
printf '── Step 4: FRED API Key (FRED_API_KEY) ────────────────────────────\n'
printf '  ROTATE:\n'
printf '    URL: https://fred.stlouisfed.org/docs/api/api_key.html\n'
printf '    Action: Log in → My Account → API Keys → Request API Key (or regenerate).\n'
printf '            Copy the new key.\n'
printf '  REVOKE:\n'
printf '    FRED does not support explicit key revocation via the web UI.\n'
printf '    Revoking is achieved by replacing the key and confirming the old key\n'
printf '    is no longer accepted.\n'
printf '    CHECKPOINT: confirm old key no longer works:\n'
printf '      curl -s "https://api.stlouisfed.org/fred/series?series_id=GDP&api_key=<OLD>&file_type=json" | grep -c "error"\n'
printf '  UPDATE-STORE (.Renviron — FRED_API_KEY is in the [auto] tier, not BW SM):\n'
printf '    FRED_API_KEY=<new-key>\n\n'

log "DRY-RUN" "Step 4 printed (FRED API key rotation)"

# ── Step 5: Bitwarden SM access token (BWS_ACCESS_TOKEN) ─────────────────────
printf '── Step 5: Bitwarden SM Access Token (BWS_ACCESS_TOKEN) ───────────\n'
printf '  NOTE: BWS_ACCESS_TOKEN is in the [ask] tier. It grants access to the\n'
printf '        claude-llm-creds BW SM project and is stored ONLY in macOS Keychain\n'
printf '        (service=claude-cron, account=bws). Never written to .Renviron.\n'
printf '\n'
printf '  ROTATE:\n'
printf '    1. Log in to Bitwarden SM:\n'
printf '       https://vault.bitwarden.com/  →  Secrets Manager → Machine Accounts → claude-cron\n'
printf '    2. Click "New Access Token" → set expiry / scopes → copy immediately.\n'
printf '       Scope: Read access to claude-llm-creds project at minimum.\n'
printf '    CHECKPOINT: new token created and copied.\n'
printf '\n'
printf '  REVOKE:\n'
printf '    In the Bitwarden SM UI:\n'
printf '      Machine Accounts → claude-cron → existing token → "Revoke".\n'
printf '    CHECKPOINT: old token listed as revoked in the UI.\n'
printf '\n'
printf '  UPDATE-STORE (macOS Keychain — NOT .Renviron):\n'
printf '    security add-generic-password -a bws -s claude-cron -w <new-token> -U\n'
printf '    # -U updates the entry if it already exists.\n'
printf '    # Verify Keychain entry is non-empty:\n'
printf '    #   security find-generic-password -a bws -s claude-cron -w | wc -c\n'
printf '\n'
printf '  RE-SCOPE (if machine account permissions changed):\n'
printf '    In Bitwarden SM UI: confirm claude-cron machine account has correct\n'
printf '    project access. Re-add the claude-llm-creds project if needed.\n'
printf '\n'
printf '  BW SM SECRETS (within claude-llm-creds project — verify after token rotation):\n'
printf '    bws secret list 2>&1 | grep -c "key"  # should list all secrets\n'
printf '    CHECKPOINT: bws can list secrets with the new access token.\n\n'

log "DRY-RUN" "Step 5 printed (Bitwarden SM access token rotation)"

# ── Step 6: Gmail app password rotation ──────────────────────────────────────
printf '── Step 6: Gmail App Password ──────────────────────────────────────\n'
printf '  ROTATE:\n'
printf '    URL: https://myaccount.google.com/apppasswords\n'
printf '    Action: Generate a new app password for "Mail" / "Other".\n'
printf '            Copy the new password (shown only once).\n'
printf '  REVOKE:\n'
printf '    URL: https://myaccount.google.com/apppasswords\n'
printf '    Action: Delete the OLD "Claude Code" or relevant app password entry.\n'
printf '    CHECKPOINT: old entry no longer visible in the list.\n'
printf '  UPDATE-STORE (Bitwarden SM — bws CLI):\n'
printf '    bws secret edit <secret-id-for-GMAIL_APP_PASSWORD> --value <new-password>\n'
printf '    # If GMAIL_USERNAME changed:\n'
printf '    # bws secret edit <secret-id-for-GMAIL_USERNAME> --value <username>\n\n'

log "DRY-RUN" "Step 6 printed (Gmail app password rotation)"

# ── Step 7: Post-rotation verification ───────────────────────────────────────
printf '── Step 7: Verification ────────────────────────────────────────────\n'
printf '  After updating all stores, restart Claude Code and verify:\n'
printf '\n'
printf '  GitHub:\n'
printf '    gh auth status\n'
printf '\n'
printf '  Anthropic (BW SM path):\n'
printf '    Rscript -e '"'"'cat(nchar(Sys.getenv("ANTHROPIC_API_KEY")), "chars\n")'"'"'\n'
printf '\n'
printf '  OpenAI (BW SM path):\n'
printf '    Rscript -e '"'"'cat(nchar(Sys.getenv("OPENAI_API_KEY")), "chars\n")'"'"'\n'
printf '\n'
printf '  FRED (env var path):\n'
printf '    Rscript -e '"'"'cat(nchar(Sys.getenv("FRED_API_KEY")), "chars\n")'"'"'\n'
printf '\n'
printf '  BW SM access token (Keychain path):\n'
printf '    security find-generic-password -a bws -s claude-cron -w | wc -c\n'
printf '    bws secret list 2>&1 | grep -c "key"\n'
printf '\n'
printf '  Credential tier lookup (sanity check):\n'
printf '    bash ~/.claude/scripts/credential_tier_lookup.sh ANTHROPIC_API_KEY  # → ask\n'
printf '    bash ~/.claude/scripts/credential_tier_lookup.sh BWS_ACCESS_TOKEN   # → ask\n'
printf '    bash ~/.claude/scripts/credential_tier_lookup.sh FRED_API_KEY       # → auto\n\n'

log "DRY-RUN" "Step 7 printed (post-rotation verification)"

# ── Summary ──────────────────────────────────────────────────────────────────
printf '═══════════════════════════════════════════════════════════════════\n'
printf '  DRY-RUN COMPLETE. No credentials were modified.\n'
printf '  Providers covered: GitHub · Anthropic · OpenAI · FRED · BW SM · Gmail\n'
printf '  Log: %s\n' "$LOG_FILE"
printf '═══════════════════════════════════════════════════════════════════\n\n'

log "COMPLETE" "dry-run finished — 6 providers printed, no mutations"
