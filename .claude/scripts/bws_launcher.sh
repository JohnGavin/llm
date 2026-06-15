#!/usr/bin/env bash
# bws_launcher.sh — Inject Bitwarden Secrets Manager secrets, then exec a script.
#
# Retrieves BWS_ACCESS_TOKEN from macOS Keychain (service=claude-cron, account=bws)
# and calls `bws run -- "$@"` so secrets are injected as env vars into the child.
#
# If bws is not installed or the Keychain entry is missing, falls back to sourcing
# the legacy flat env file passed via BW_FALLBACK_ENV (so existing cron jobs
# continue to work during the migration).
#
# Usage (from launchd plist or directly):
#   bws_launcher.sh /path/to/script.sh [args...]
#
# Required Keychain entry (one-time setup by user):
#   security add-generic-password -a "bws" -s "claude-cron" -w "<BWS_ACCESS_TOKEN>"
#
# Environment overrides:
#   BWS_ACCESS_TOKEN     — skip Keychain, use this token directly
#   BW_FALLBACK_ENV      — path to flat env file used when bws is unavailable
#   BW_DRYRUN=1          — print what would be run without executing
#
# Origin: llm#615 — Bitwarden SM pilot (overnight email cron as first target)

set -euo pipefail

LOG_FILE="${HOME}/.claude/logs/bws_launcher.log"
BWS_BIN="${HOME}/.cargo/bin/bws"   # built via: env -i ... cargo install bws (llm#615)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [bws_launcher] $*" | tee -a "${LOG_FILE}"; }

if [[ $# -eq 0 ]]; then
    echo "Usage: bws_launcher.sh <script> [args...]" >&2
    exit 1
fi

TARGET="$1"; shift

# ── Resolve BWS access token ──────────────────────────────────────────────────
if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
    BWS_ACCESS_TOKEN="$(security find-generic-password -a "bws" -s "claude-cron" -w 2>/dev/null || true)"
fi

BW_AVAILABLE=0
if [[ -n "${BWS_ACCESS_TOKEN}" ]] && [[ -x "${BWS_BIN}" ]]; then
    BW_AVAILABLE=1
fi

# ── Execute ───────────────────────────────────────────────────────────────────
if [[ "${BW_AVAILABLE}" -eq 1 ]]; then
    log "bws run → ${TARGET}"
    if [[ "${BW_DRYRUN:-0}" == "1" ]]; then
        echo "[DRYRUN] BWS_ACCESS_TOKEN=<redacted> ${BWS_BIN} run -- ${TARGET} $*"
        exit 0
    fi
    export BWS_ACCESS_TOKEN
    exec "${BWS_BIN}" run -- "${TARGET}" "$@"
else
    # Fallback: source flat env file if provided, then exec the target directly
    FALLBACK="${BW_FALLBACK_ENV:-}"
    if [[ -n "${FALLBACK}" ]] && [[ -f "${FALLBACK}" ]]; then
        log "WARN: bws unavailable — sourcing flat file ${FALLBACK}"
        set -a
        # shellcheck disable=SC1090
        source "${FALLBACK}"
        set +a
    else
        log "WARN: bws unavailable and no BW_FALLBACK_ENV — running ${TARGET} with current env"
    fi
    if [[ "${BW_DRYRUN:-0}" == "1" ]]; then
        echo "[DRYRUN] exec ${TARGET} $*"
        exit 0
    fi
    exec "${TARGET}" "$@"
fi
