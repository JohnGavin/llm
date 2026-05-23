#!/usr/bin/env bash
# roborev_agent_health.sh — detect sustained codex failures and temporarily
# swap to gemini in ~/.roborev/config.toml; probe for recovery and swap back.
#
# Closes roborev #900 (#181 Theme 5) — timestamp format mismatch fixed.
# The WHERE clause normalises ISO-8601 (YYYY-MM-DDTHH:MM:SS...Z) to SQLite's
# internal format (YYYY-MM-DD HH:MM:SS) via replace() before passing to
# datetime(), ensuring the "last 60 min" failure count is not inflated.
# Fix landed in commit a93b670.
#
# Portability: this script is invoked by launchd, which provides only a bare
# PATH (/usr/bin:/bin:/usr/sbin:/sbin). Prepend coreutils paths so that
# `timeout` (from GNU coreutils) is visible under both Homebrew and Nix.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
#
# Logic:
#   1. Count codex-agent failures in the last 60 minutes (review_jobs table).
#   2. Threshold ≥3 → "throttled" state.
#   3. If throttled AND no marker: backup config, swap agents, create marker,
#      kickstart roborev daemon.
#   4. If marker exists AND last-60-min codex failures = 0: probe codex with
#      `codex --version`; if healthy, revert swap, remove marker, kickstart.
#
# Marker file: ~/.roborev/.agent-throttle-codex
#   Contains: throttled_at, reason, config_backup path.
#
# Designed to run every 30 minutes via launchd
#   (com.claude.roborev-agent-health.plist, StartInterval=1800).
#
# Tracked in JohnGavin/llm#150 (Phase 2).
#
# Usage:
#   roborev_agent_health.sh                  # dry-run (default, no mutations)
#   roborev_agent_health.sh --apply          # actually mutate config
#   roborev_agent_health.sh --status         # report state only, no mutation
#
# Exit codes:
#   0  ok (including "nothing to do" and "binary/db missing")
#   1  unexpected error

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
if [ -z "${ROBOREV:-}" ]; then
    ROBOREV="$(command -v roborev 2>/dev/null || echo /usr/local/bin/roborev)"
fi
if [ -z "${CODEX:-}" ]; then
    CODEX="$(command -v codex 2>/dev/null || echo /usr/local/bin/codex)"
fi
SQLITE="${SQLITE:-/usr/bin/sqlite3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
CONFIG_TOML="${CONFIG_TOML:-$HOME/.roborev/config.toml}"
MARKER="${MARKER:-$HOME/.roborev/.agent-throttle-codex}"
LOG="$HOME/.claude/logs/roborev_agent_health.log"
LAUNCHD_LABEL="com.roborev.auto-refine"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
FAILURE_WINDOW_MIN="${FAILURE_WINDOW_MIN:-60}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"

APPLY=0
STATUS_ONLY=0

case "${1:-}" in
  --apply)      APPLY=1 ;;
  --dry-run|"") APPLY=0 ;;
  --status)     STATUS_ONLY=1 ;;
  -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
  *)            echo "unknown arg: $1" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Quietly succeed if required tools/db missing (laptop vs CI portability)
for thing in "$SQLITE" "$ROBOREV_DB" "$CONFIG_TOML"; do
  if [ ! -e "$thing" ]; then
    log "skip: $thing not found"
    echo "roborev_agent_health: skipped ($thing missing)"
    exit 0
  fi
done

# ── State queries ─────────────────────────────────────────────────────────────

# Count codex failures in last FAILURE_WINDOW_MIN minutes
codex_fail_count() {
  "$SQLITE" "$ROBOREV_DB" <<SQL 2>/dev/null
SELECT COUNT(*)
FROM review_jobs
WHERE agent = 'codex'
  AND status = 'failed'
  AND datetime(replace(replace(enqueued_at, 'T', ' '), 'Z', '')) > datetime('now', '-${FAILURE_WINDOW_MIN} minutes');
SQL
}

marker_exists() { [ -f "$MARKER" ]; }

# Portable timeout helper — macOS /usr/bin/timeout does not exist; use GNU
# coreutils `timeout` (Homebrew: /opt/homebrew/bin/timeout, or on PATH after
# the PATH export above). Falls back to a pure-shell background-kill pattern.
_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # Shell-only fallback: run in background; watchdog sends SIGTERM then
    # SIGKILL after a 2-second grace period and exits 124 (GNU coreutils
    # convention) so the caller can detect that the timeout actually fired.
    "$@" &
    local pid=$!
    (
      sleep "$secs"
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
      exit 124
    ) &
    local watchdog=$!
    if wait "$pid" 2>/dev/null; then
      local rc=$?
      # Child completed before timeout — reap the watchdog.
      kill "$watchdog" 2>/dev/null
      wait "$watchdog" 2>/dev/null
      return "$rc"
    else
      # Child was killed — check whether the watchdog already exited (fired).
      if ! kill -0 "$watchdog" 2>/dev/null; then
        wait "$watchdog" 2>/dev/null
        return 124
      fi
      kill "$watchdog" 2>/dev/null
      wait "$watchdog" 2>/dev/null
      return 1
    fi
  fi
}

# Probe codex health: version check with 10s timeout
codex_healthy() {
  if [ ! -x "$CODEX" ]; then
    return 1
  fi
  _timeout 10 "$CODEX" --version >/dev/null 2>&1
}

# ── Status report ─────────────────────────────────────────────────────────────
recent_failures=$(codex_fail_count)
recent_failures="${recent_failures:-0}"

if marker_exists; then
  throttle_state="throttled (marker exists)"
  marker_contents=$(cat "$MARKER" 2>/dev/null || echo "(unreadable)")
else
  throttle_state="normal"
  marker_contents=""
fi

echo "roborev_agent_health status:"
echo "  codex failures (last ${FAILURE_WINDOW_MIN}m): $recent_failures"
echo "  threshold: $FAILURE_THRESHOLD"
echo "  state: $throttle_state"
if [ -n "$marker_contents" ]; then
  echo "  marker:"
  echo "$marker_contents" | sed 's/^/    /'
fi

if [ "$STATUS_ONLY" -eq 1 ]; then
  log "status: failures=$recent_failures threshold=$FAILURE_THRESHOLD state=$throttle_state"
  exit 0
fi

# ── Throttle: swap codex → gemini ────────────────────────────────────────────
if [ "$recent_failures" -ge "$FAILURE_THRESHOLD" ] && ! marker_exists; then
  ts=$(date -u +%Y%m%d_%H%M%S)
  backup_path="${CONFIG_TOML}.bak-agent-health-${ts}"
  ts_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$APPLY" -eq 0 ]; then
    echo "[dry] would throttle codex: backup config, swap to gemini, create marker, kickstart daemon"
    echo "  reason: $recent_failures codex failures in last ${FAILURE_WINDOW_MIN} minutes"
    log "dry-run: would throttle codex (failures=$recent_failures threshold=$FAILURE_THRESHOLD)"
    exit 0
  fi

  log "throttle: $recent_failures codex failures in last ${FAILURE_WINDOW_MIN}m — swapping to gemini"

  # Backup config
  if ! cp "$CONFIG_TOML" "$backup_path"; then
    log "abort: backup to $backup_path failed"
    echo "roborev_agent_health: backup failed — aborting" >&2
    exit 1
  fi
  log "backup: $backup_path"

  # Swap agents in config (in-place sed; BSD/GNU compatible via temp file)
  tmp_config=$(mktemp)
  sed \
    -e "s|^default_agent = 'codex'|default_agent = 'gemini'|" \
    -e "s|^default_backup_agent = 'gemini'|default_backup_agent = 'codex'|" \
    "$CONFIG_TOML" > "$tmp_config"
  mv "$tmp_config" "$CONFIG_TOML"
  log "config: swapped default_agent=gemini backup_agent=codex"

  # Write marker
  cat > "$MARKER" <<EOF
throttled_at: ${ts_iso}
reason: ${recent_failures} codex failures in last ${FAILURE_WINDOW_MIN} minutes
config_backup: ${backup_path}
EOF
  log "marker: created $MARKER"

  # Kickstart daemon so it picks up the new config
  uid=$(id -u)
  if [ -f "$LAUNCHD_PLIST" ]; then
    /bin/launchctl bootout "gui/${uid}/${LAUNCHD_LABEL}" 2>/dev/null || true
    /bin/launchctl bootstrap "gui/${uid}" "$LAUNCHD_PLIST" 2>/dev/null \
      && log "daemon: kickstarted $LAUNCHD_LABEL" \
      || log "warn: daemon kickstart failed (config swap still applied)"
  else
    log "warn: $LAUNCHD_PLIST not found — daemon not kickstarted"
  fi

  echo "roborev_agent_health [applied]: codex throttled — swapped to gemini (backup: $backup_path)"
  exit 0
fi

# ── Recovery: probe codex and swap back ───────────────────────────────────────
if marker_exists && [ "$recent_failures" -eq 0 ]; then
  if codex_healthy; then
    if [ "$APPLY" -eq 0 ]; then
      echo "[dry] would recover: codex healthy, revert config swap, remove marker, kickstart daemon"
      log "dry-run: would recover codex (healthy, 0 failures in last ${FAILURE_WINDOW_MIN}m)"
      exit 0
    fi

    log "recovery: codex healthy — reverting swap"

    # Restore original config (primary recovery path: re-swap in place)
    backup_path=$(grep 'config_backup:' "$MARKER" 2>/dev/null | awk '{print $2}')
    if [ -f "$backup_path" ]; then
      cp "$backup_path" "$CONFIG_TOML"
      log "recovery: restored config from $backup_path"
    else
      # Backup gone — re-swap manually
      tmp_config=$(mktemp)
      sed \
        -e "s|^default_agent = 'gemini'|default_agent = 'codex'|" \
        -e "s|^default_backup_agent = 'codex'|default_backup_agent = 'gemini'|" \
        "$CONFIG_TOML" > "$tmp_config"
      mv "$tmp_config" "$CONFIG_TOML"
      log "recovery: backup not found — re-swapped config in place"
    fi

    rm -f "$MARKER"
    log "recovery: removed marker $MARKER"

    # Kickstart daemon with restored config
    uid=$(id -u)
    if [ -f "$LAUNCHD_PLIST" ]; then
      /bin/launchctl bootout "gui/${uid}/${LAUNCHD_LABEL}" 2>/dev/null || true
      /bin/launchctl bootstrap "gui/${uid}" "$LAUNCHD_PLIST" 2>/dev/null \
        && log "daemon: kickstarted $LAUNCHD_LABEL (codex primary restored)" \
        || log "warn: daemon kickstart failed after recovery"
    fi

    echo "roborev_agent_health [applied]: codex recovered — restored as primary agent"
  else
    log "recovery-check: codex still unhealthy (version probe failed) — remaining on gemini"
    echo "roborev_agent_health: codex still unhealthy — remaining on gemini"
  fi
  exit 0
fi

# ── Nothing to do ─────────────────────────────────────────────────────────────
if marker_exists; then
  log "ok: throttled and failures still present (failures=$recent_failures) — no change"
  echo "roborev_agent_health: still throttled (codex failures=$recent_failures in last ${FAILURE_WINDOW_MIN}m)"
else
  log "ok: normal state, no action needed (failures=$recent_failures)"
  echo "roborev_agent_health: ok (codex failures=$recent_failures in last ${FAILURE_WINDOW_MIN}m, below threshold $FAILURE_THRESHOLD)"
fi
