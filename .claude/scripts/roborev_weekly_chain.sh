#!/usr/bin/env bash
# roborev_weekly_chain.sh — weekly wrapper: handoff first, then autoclose.
#
# Invoked by com.claude.roborev-autoclose.plist on Mondays at 09:15.
#
# Order matters:
#   1. roborev_handoff.sh --apply
#      Creates GH issues for stale fail jobs (Phase 1a),
#      appends to weekly digest for pass-comments jobs (Phase 1b),
#      silently closes pass-clean jobs (Phase 1c).
#   2. roborev_autoclose.sh --apply
#      Closes anything remaining that is truly stale-stale
#      (jobs not handled by handoff, typically >30d old).
#
# Fails loud on first error: if handoff fails, autoclose is NOT run.
# This prevents autoclose from stomping jobs that handoff should have
# converted to GH issues but couldn't due to a transient error.
#
# Depth guard prevents accidental recursive invocation from a misconfigured
# launchd or manual loop (_RBC_DEPTH shared with roborev_autoclose.sh
# naming convention; this script uses _RWC_DEPTH).
#
# Logs to: ~/.claude/logs/roborev_weekly_chain.log
# Each constituent script logs to its own log file as well.
#
# Usage:
#   roborev_weekly_chain.sh          # run both scripts --apply
#   DRY_RUN=1 roborev_weekly_chain.sh  # pass --dry-run to both (for testing)
#
# Exit codes:
#   0  both scripts succeeded (or nothing to do)
#   1  handoff failed (autoclose was NOT run)
#   2  handoff succeeded, autoclose failed
#   3  depth guard triggered (recursive invocation detected)

set -uo pipefail

# ── Depth guard ───────────────────────────────────────────────────────────────
_DEPTH="${_RWC_DEPTH:-0}"
if [ "$_DEPTH" -gt 2 ]; then
  echo "roborev_weekly_chain: depth guard triggered ($_DEPTH > 2), exiting" >&2
  exit 3
fi
export _RWC_DEPTH=$((_DEPTH + 1))

# Mark session as scheduled/automated for llmtelemetry_emit.sh (#322 Phase 2).
# Propagates to any claude process spawned in this process tree so the Stop
# hook emits "trigger":"scheduled" without requiring a /bye sentinel.
export CLAUDE_TRIGGER="${CLAUDE_TRIGGER:-scheduled}"

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$(realpath "$0")")}"
HANDOFF_SCRIPT="${HANDOFF_SCRIPT:-$SCRIPTS_DIR/roborev_handoff.sh}"
AUTOCLOSE_SCRIPT="${AUTOCLOSE_SCRIPT:-$SCRIPTS_DIR/roborev_autoclose.sh}"
LOG="${LOG:-$HOME/.claude/logs/roborev_weekly_chain.log}"
DRY_RUN="${DRY_RUN:-0}"

[ "$DRY_RUN" = "1" ] && APPLY_FLAG="--dry-run" || APPLY_FLAG="--apply"

mkdir -p "$(dirname "$LOG")"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) $*" >> "$LOG"; }
log_and_echo() { echo "$*"; log "$*"; }

log_and_echo "START weekly chain (apply_flag=$APPLY_FLAG)"

# ── Step 1: handoff ───────────────────────────────────────────────────────────
log_and_echo "--- handoff start ---"
if ! bash "$HANDOFF_SCRIPT" "$APPLY_FLAG" 2>&1 | tee -a "$LOG"; then
  log_and_echo "HANDOFF FAILED — autoclose NOT run"
  exit 1
fi
log_and_echo "--- handoff done ---"

# ── Step 2: autoclose ─────────────────────────────────────────────────────────
log_and_echo "--- autoclose start ---"
if ! bash "$AUTOCLOSE_SCRIPT" "$APPLY_FLAG" 2>&1 | tee -a "$LOG"; then
  log_and_echo "AUTOCLOSE FAILED"
  exit 2
fi
log_and_echo "--- autoclose done ---"

log_and_echo "DONE weekly chain"
