#!/usr/bin/env bash
# check_146_panel_data_watcher.sh
#
# Polled by ~/Library/LaunchAgents/com.johngavin.check-146-panel-data.plist
# every 30 minutes. Runs the llmtelemetry #146 panel-readiness check
# (inst/scripts/check_146_panel_data.sh) and:
#   - on NOT_READY: appends a line to the log
#   - on READY:     posts a macOS notification, writes a marker, unloads itself
#
# Launchd has a bare PATH and won't resolve `nix-shell` without help. We export
# a PATH led by /nix/var/nix/profiles/default/bin (the canonical nix profile
# symlink that survives nix-store garbage collection), mirroring the fix from
# JohnGavin/llm#235 → PR #289.
#
# Idempotent: if the READY marker exists, the script no-ops fast (defensive —
# the plist should already be unloaded but we belt-and-braces it).

set -uo pipefail

# ── Launchd PATH fix (llm#235/#289 pattern) ───────────────────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ── Config ─────────────────────────────────────────────────────────────────────
PROJECT="/Users/johngavin/docs_gh/llmtelemetry"
SCRIPT="$PROJECT/inst/scripts/check_146_panel_data.sh"
# The duckdb CLI lives in the GLOBAL dev shell, not the project shell.
# llmtelemetry/default.nix lists `duckdb` as an R package only — no CLI binary.
# Mirrors the launchd fix from JohnGavin/llm#235 → PR #289.
NIX_DEV_SHELL="/Users/johngavin/docs_gh/llm/default.nix"
LABEL="com.johngavin.check-146-panel-data"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/check_146_panel_data.log"
STATE_DIR="$HOME/.claude/state"
MARKER="$STATE_DIR/146_panel_readiness_notified"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*" >> "$LOG"; }

# ── Fast path: already flipped ────────────────────────────────────────────────
if [ -f "$MARKER" ]; then
  log "marker present; no further polling needed (plist should be unloaded)"
  exit 0
fi

# ── Run the check ─────────────────────────────────────────────────────────────
if ! command -v nix-shell >/dev/null 2>&1; then
  log "FATAL: nix-shell not on PATH after fix ($PATH)"
  exit 2
fi
if [ ! -f "$SCRIPT" ]; then
  log "FATAL: check script not found at $SCRIPT"
  exit 2
fi

# No `timeout` wrapper: macOS doesn't ship one and the nix profile lacks it.
# The check script itself is bounded — duckdb queries are sub-second; the
# slow leg is nix-shell entry (≤20 s cold, ~3 s warm). If anything genuinely
# hangs, launchd will sigkill us after the StartInterval boundary.
OUT=$(nix-shell "$NIX_DEV_SHELL" --run "bash '$SCRIPT' --quiet" 2>&1 \
      | tail -n1)
RC=$?

log "iter rc=$RC out=\"$OUT\""

# ── Branch on result ──────────────────────────────────────────────────────────
case "$OUT" in
  READY*)
    log "FLIP detected: $OUT"
    osascript -e "display notification \"$OUT\" with title \"llmtelemetry #146 panels READY\" subtitle \"Q1/Q11/Q20 cost ROI panels can ship\" sound name \"Glass\"" \
      >> "$LOG" 2>&1 || log "WARN: osascript notification failed"
    touch "$MARKER"
    log "Unloading plist $PLIST"
    launchctl unload "$PLIST" >> "$LOG" 2>&1 || log "WARN: launchctl unload failed"
    exit 0
    ;;
  NOT_READY*)
    # No state change; the periodic log line is enough.
    exit 0
    ;;
  *)
    log "WARN: unexpected output: \"$OUT\""
    exit 0
    ;;
esac
