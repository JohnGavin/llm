#!/usr/bin/env bash
# roborev_weekly_update.sh — check for a roborev release, install it, restart the
# daemon, and VERIFY the daemon actually came back.
#
# Origin: the 2026-08-03 manual run of `roborev update` to v0.63.0 ended with
#
#     Restarting daemon... warning: daemon did not become ready after restart;
#     restart it manually
#
# and then exited 0. The daemon did in fact recover on its own, but nothing in
# that flow would have told anyone if it hadn't — a silent half-failure of
# exactly the kind `zero-metric-evidence-or-defect` warns about. This script
# therefore splits update from restart (`--no-restart`, which roborev documents
# for externally-managed daemons), does the restart itself, and then polls
# `roborev status` until the daemon reports running. If it never does, the
# script exits NON-ZERO so launchd surfaces it instead of logging a warning
# nobody reads.
#
# Portability: launchd provides only a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin),
# so roborev at /usr/local/bin would not resolve. Prepend the usual install dirs.
# ~/.local/bin MUST precede /usr/local/bin so the Phase-1.6 roborev primary shim
# (#386) intercepts invocations, matching com.claude.roborev-agent-health.
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
#
# Logic:
#   1. `roborev update --check` — if no update is available, log and exit 0.
#   2. Record the running version.
#   3. `roborev update --yes --no-restart` — install without touching the daemon.
#   4. `roborev daemon restart` — restart under our own control.
#   5. Poll `roborev status` for up to READY_TIMEOUT seconds for "running".
#   6. Exit non-zero if the daemon never reports running.
#
# Designed to run weekly on Thursday nights via launchd
#   (com.claude.roborev-weekly-update.plist, Thu 23:30).
#
# Usage:
#   roborev_weekly_update.sh              # dry-run (default, no mutations)
#   roborev_weekly_update.sh --apply      # actually update + restart + verify
#   roborev_weekly_update.sh --selftest   # self-checks, no mutations
#
# Exit codes:
#   0  ok (updated and verified, or already current, or roborev absent)
#   1  unexpected error
#   2  update applied but the daemon did not come back — NEEDS ATTENTION

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

ROBOREV_BIN="${ROBOREV:-$(command -v roborev || true)}"
LOG_FILE="${ROBOREV_UPDATE_LOG:-$HOME/.claude/logs/roborev_weekly_update.log}"
READY_TIMEOUT="${ROBOREV_READY_TIMEOUT:-90}"   # seconds to wait for the daemon
READY_POLL_INTERVAL="${ROBOREV_READY_POLL_INTERVAL:-3}"

MODE="dry-run"
case "${1:-}" in
  --apply)    MODE="apply" ;;
  --selftest) MODE="selftest" ;;
  "")         MODE="dry-run" ;;
  *) echo "Usage: $(basename "$0") [--apply|--selftest]" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  # One line per event: timestamp, mode, then key=value pairs.
  printf '%s mode=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$*" >> "$LOG_FILE"
}

say() { printf '%s\n' "$*"; }

# Extract "0.63.0" from `roborev version` output ("roborev v0.63.0").
# Any leading "v" is stripped so versions compare as plain strings regardless of
# whether they came from `version`, `update --check`, or a tarball filename.
current_version() {
  "$ROBOREV_BIN" version 2>/dev/null | head -1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Decide whether `roborev update --check` is announcing a NEW version.
#
# Phrase-matching alone is brittle: the real up-to-date line is
# "Already running latest version (v0.63.0)", which is not the wording any of
# the obvious patterns ("up to date", "already on the latest") would catch — a
# mismatch here means re-downloading the same release every single week. So the
# authoritative test is a VERSION COMPARISON: if the check output mentions any
# semver that differs from the running one, an update exists. The phrase match
# is kept only as a fast path for the case where no version is printed at all.
#
# Args: $1 = check output, $2 = currently-running version (no leading v)
update_is_available() {
  local out="$1" running="$2" v
  if printf '%s' "$out" | grep -qiE \
      'already[[:space:]]+(running|on|at)?[[:space:]]*(the[[:space:]]+)?latest|up[-[:space:]]to[-[:space:]]date|no[[:space:]]updates?[[:space:]]available'; then
    return 1   # explicitly current
  fi
  for v in $(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u); do
    [ "$v" != "$running" ] && return 0   # a different version is on offer
  done
  return 1   # nothing newer named -> treat as current
}

# True when `roborev status` reports the daemon as running.
daemon_is_running() {
  "$ROBOREV_BIN" status 2>/dev/null | grep -qE '^Daemon:[[:space:]]+running'
}

# ── Selftest ─────────────────────────────────────────────────────────────────
# Verifies the two parsers against fixed strings rather than a live daemon, so
# it is safe to run anywhere and cannot mutate anything.

if [ "$MODE" = "selftest" ]; then
  pass=0; fail=0
  check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
      pass=$((pass + 1)); say "  PASS  $1"
    else
      fail=$((fail + 1)); say "  FAIL  $1 (expected '$2', got '$3')"
    fi
  }

  got=$(printf 'roborev v0.63.0\n' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  check "version parsed from 'roborev v0.63.0'" "0.63.0" "$got"

  got=$(printf 'roborev 1.2.30 (dev)\n' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  check "version parsed without a leading v" "1.2.30" "$got"

  if printf 'Daemon: running (uptime: 50h 37m) [v0.63.0]\n' \
       | grep -qE '^Daemon:[[:space:]]+running'; then r=yes; else r=no; fi
  check "running daemon detected" "yes" "$r"

  if printf 'Daemon: not running\n' \
       | grep -qE '^Daemon:[[:space:]]+running'; then r=yes; else r=no; fi
  check "stopped daemon NOT detected as running" "no" "$r"

  # "restarting" must not satisfy the running check — that was the exact
  # half-state the 2026-08-03 warning left behind.
  if printf 'Daemon: restarting\n' \
       | grep -qE '^Daemon:[[:space:]]+running'; then r=yes; else r=no; fi
  check "restarting daemon NOT counted as running" "no" "$r"

  # update_is_available() must say "no" for every up-to-date phrasing and "yes"
  # only when a genuinely different version is named.
  #
  # The first case is roborev's REAL output, captured from `roborev update
  # --check` on 2026-08-03. It is deliberately first because it is the one that
  # broke the original phrase-only matcher: "Already running latest version"
  # matches neither "up to date" nor "already on the latest". If roborev ever
  # rewords this line, THIS is the assertion that should fail.
  if update_is_available "Checking for updates...
Already running latest version (v0.63.0)" "0.63.0"; then r=yes; else r=no; fi
  check "REAL up-to-date output not read as an update" "no" "$r"

  if update_is_available "roborev is up-to-date (v0.63.0)" "0.63.0"; then r=yes; else r=no; fi
  check "'up-to-date' phrasing not read as an update" "no" "$r"

  if update_is_available "No updates available" "0.63.0"; then r=yes; else r=no; fi
  check "'no updates available' not read as an update" "no" "$r"

  # Version comparison is the authoritative path: an unrecognised phrasing that
  # names only the running version must still resolve to "current".
  if update_is_available "Some future wording (v0.63.0)" "0.63.0"; then r=yes; else r=no; fi
  check "unknown phrasing naming only the running version -> current" "no" "$r"

  if update_is_available "Update available: v0.63.0 -> v0.64.0" "0.63.0"; then r=yes; else r=no; fi
  check "new version offered -> update available" "yes" "$r"

  if update_is_available "Downloading roborev_0.64.0_darwin_arm64.tar.gz" "0.63.0"; then r=yes; else r=no; fi
  check "version read from a tarball filename" "yes" "$r"

  say ""
  say "$pass/$((pass + fail)) PASS"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# ── Preconditions ────────────────────────────────────────────────────────────

if [ -z "$ROBOREV_BIN" ] || [ ! -x "$ROBOREV_BIN" ]; then
  # Fail open: an absent binary is not this job's problem to escalate.
  say "roborev not found on PATH — nothing to do"
  log "result=skipped reason=binary-absent"
  exit 0
fi

BEFORE="$(current_version || true)"

# ── 1. Is there anything to install? ─────────────────────────────────────────

CHECK_OUT="$("$ROBOREV_BIN" update --check 2>&1 || true)"

if ! update_is_available "$CHECK_OUT" "$BEFORE"; then
  say "roborev $BEFORE is current — no update available"
  log "result=current version=$BEFORE"
  exit 0
fi

say "Update available. Current: ${BEFORE:-unknown}"
say "$CHECK_OUT"

if [ "$MODE" = "dry-run" ]; then
  say ""
  say "DRY RUN — would run:"
  say "  $ROBOREV_BIN update --yes --no-restart"
  say "  $ROBOREV_BIN daemon restart"
  say "  poll '$ROBOREV_BIN status' for up to ${READY_TIMEOUT}s"
  log "result=dry-run version=$BEFORE update_available=yes"
  exit 0
fi

# ── 2. Install, daemon untouched ─────────────────────────────────────────────

if ! "$ROBOREV_BIN" update --yes --no-restart; then
  say "ERROR: roborev update failed"
  log "result=update-failed version=$BEFORE"
  exit 1
fi

AFTER="$(current_version || true)"
say "Binary now reports: ${AFTER:-unknown} (was ${BEFORE:-unknown})"

# ── 3. Restart the daemon ourselves, then prove it came back ─────────────────

"$ROBOREV_BIN" daemon restart || true   # verified below, not trusted here

waited=0
while [ "$waited" -lt "$READY_TIMEOUT" ]; do
  if daemon_is_running; then
    say "Daemon is running after ${waited}s. Updated ${BEFORE:-unknown} -> ${AFTER:-unknown}."
    log "result=ok before=$BEFORE after=$AFTER daemon_ready_after=${waited}s"
    exit 0
  fi
  sleep "$READY_POLL_INTERVAL"
  waited=$((waited + READY_POLL_INTERVAL))
done

# The failure the 2026-08-03 run swallowed. Exit 2 so launchd records non-zero
# and the weekly launchd-health audit surfaces it.
say "ERROR: roborev updated to ${AFTER:-unknown} but the daemon did not report"
say "       running within ${READY_TIMEOUT}s. Restart it manually:"
say "         roborev daemon restart"
say "         roborev status"
log "result=daemon-not-ready before=$BEFORE after=$AFTER timeout=${READY_TIMEOUT}s"
exit 2
