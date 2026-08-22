#!/usr/bin/env bash
# roborev_agent_health.sh — detect sustained codex failures and temporarily
# swap to claude-code in ~/.roborev/config.toml; probe for recovery and swap back.
# (#676: free-tier agent was permanently dead — IneligibleTierError/UNSUPPORTED_CLIENT, exit 55.
# All swap targets changed to claude-code.)
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
# Portability fixes (#181 Theme 2 — roborev id 900):
#   - macOS /usr/bin/timeout does not exist. The _timeout() helper detects
#     timeout/gtimeout via `command -v` and falls back to a portable
#     background-kill pattern (SIGTERM then SIGKILL, exits 124 on timeout).
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
# Stream-json cause-unknown detection (llm#954): also reports (report-only,
# never mutates) any agent with >= STREAM_JSON_THRESHOLD (default 3) failures
# in the last STREAM_JSON_WINDOW_MIN minutes (default 1440 = 24h) whose
# review_jobs.error contains "no valid stream-json" — roborev's own fallback
# message for "agent exited non-zero with empty stdout", fabricated as if it
# were a parse error regardless of the real (discarded) cause. Runs on every
# invocation (both --status and the default mutating flow), agent-agnostic
# by construction (matches the signature, not a specific agent name).
#
# Usage:
#   roborev_agent_health.sh                  # dry-run (default, no mutations)
#   roborev_agent_health.sh --apply          # actually mutate config
#   roborev_agent_health.sh --status         # report state only, no mutation
#   roborev_agent_health.sh --selftest       # fixture-based test of the
#                                             #   stream-json detector (llm#954)
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
SELFTEST=0

case "${1:-}" in
  --apply)      APPLY=1 ;;
  --dry-run|"") APPLY=0 ;;
  --status)     STATUS_ONLY=1 ;;
  --selftest)   SELFTEST=1 ;;
  -h|--help)    sed -n '2,56p' "$0"; exit 0 ;;
  *)            echo "unknown arg: $1" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ── Selftest (llm#954) ────────────────────────────────────────────────────────
# Fixture-based: builds a throwaway sqlite DB + config.toml, then re-invokes
# THIS script (`bash "$0" --status ...`) as a fresh subprocess with env vars
# pointed at the fixtures — never touches the real ~/.roborev/reviews.db.
# Defined (and dispatched, immediately below) before the "required tools"
# gate so --selftest works even on a machine with no roborev installed.
run_selftest() {
  local total=0 pass=0
  local tmp_root fixture_db fixture_config fixture_marker fixture_log out

  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/roborev_agent_health_selftest.XXXXXX")"
  fixture_db="${tmp_root}/reviews.db"
  fixture_config="${tmp_root}/config.toml"
  fixture_marker="${tmp_root}/.agent-throttle-codex"
  fixture_log="${tmp_root}/health.log"

  cat > "$fixture_config" <<'EOF'
default_agent = 'codex'
default_backup_agent = 'claude-code'
EOF

  "$SQLITE" "$fixture_db" <<'SQL'
CREATE TABLE review_jobs (
  id INTEGER PRIMARY KEY,
  agent TEXT NOT NULL,
  status TEXT NOT NULL,
  error TEXT,
  enqueued_at TEXT NOT NULL
);
SQL

  # Check 1: >= threshold (3) 'no valid stream-json' gemini failures in
  # window -> WARN line naming gemini + count, NOT worded as a parse error.
  total=$((total + 1))
  "$SQLITE" "$fixture_db" <<SQL
INSERT INTO review_jobs VALUES (1, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now'));
INSERT INTO review_jobs VALUES (2, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now'));
INSERT INTO review_jobs VALUES (3, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now'));
SQL
  out="$(ROBOREV_DB="$fixture_db" CONFIG_TOML="$fixture_config" MARKER="$fixture_marker" LOG="$fixture_log" \
    SQLITE="$SQLITE" ROBOREV="$ROBOREV" CODEX="$CODEX" \
    bash "$0" --status 2>&1)"
  # Note: the WARN message itself legitimately contains the substring
  # "parse error" (as "NOT a parse error") — assert the correct positive
  # framing rather than a blanket absence of that substring.
  if echo "$out" | grep -q "agent-failed-cause-unknown: gemini has 3" && echo "$out" | grep -q "NOT a parse error"; then
    pass=$((pass + 1))
  else
    echo "FAIL: 3 gemini stream-json failures did not produce the expected cause-unknown WARN with correct framing. Output:"
    echo "$out"
  fi

  # Check 2: below threshold (2 < 3) -> no WARN at all (proves the gate is
  # a real threshold, not "any occurrence").
  total=$((total + 1))
  "$SQLITE" "$fixture_db" "DELETE FROM review_jobs;"
  "$SQLITE" "$fixture_db" <<SQL
INSERT INTO review_jobs VALUES (4, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now'));
INSERT INTO review_jobs VALUES (5, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now'));
SQL
  out="$(ROBOREV_DB="$fixture_db" CONFIG_TOML="$fixture_config" MARKER="$fixture_marker" LOG="$fixture_log" \
    SQLITE="$SQLITE" ROBOREV="$ROBOREV" CODEX="$CODEX" \
    bash "$0" --status 2>&1)"
  if ! echo "$out" | grep -q "agent-failed-cause-unknown"; then
    pass=$((pass + 1))
  else
    echo "FAIL: 2 gemini stream-json failures (below threshold=3) wrongly triggered a WARN. Output:"
    echo "$out"
  fi

  # Check 3: agent-agnostic — same signature from a DIFFERENT agent
  # (claude-code) still triggers, proving the detector is not gemini-only
  # (llm#954's own point: "not gemini-specific").
  total=$((total + 1))
  "$SQLITE" "$fixture_db" "DELETE FROM review_jobs;"
  "$SQLITE" "$fixture_db" <<SQL
INSERT INTO review_jobs VALUES (6, 'claude-code', 'failed', 'agent: claude-code failed: exit status 1 (parse error: no valid stream-json)', datetime('now'));
INSERT INTO review_jobs VALUES (7, 'claude-code', 'failed', 'agent: claude-code failed: exit status 1 (parse error: no valid stream-json)', datetime('now'));
INSERT INTO review_jobs VALUES (8, 'claude-code', 'failed', 'agent: claude-code failed: exit status 1 (parse error: no valid stream-json)', datetime('now'));
SQL
  out="$(ROBOREV_DB="$fixture_db" CONFIG_TOML="$fixture_config" MARKER="$fixture_marker" LOG="$fixture_log" \
    SQLITE="$SQLITE" ROBOREV="$ROBOREV" CODEX="$CODEX" \
    bash "$0" --status 2>&1)"
  if echo "$out" | grep -q "agent-failed-cause-unknown: claude-code has 3"; then
    pass=$((pass + 1))
  else
    echo "FAIL: claude-code stream-json failures did not trigger the (agent-agnostic) WARN. Output:"
    echo "$out"
  fi

  # Check 4: a normal (non-stream-json) failure never triggers this WARN —
  # proves the detector matches the specific signature, not "any failure".
  total=$((total + 1))
  "$SQLITE" "$fixture_db" "DELETE FROM review_jobs;"
  "$SQLITE" "$fixture_db" <<SQL
INSERT INTO review_jobs VALUES (9, 'gemini', 'failed', 'agent: gemini failed: exit status 1', datetime('now'));
INSERT INTO review_jobs VALUES (10, 'gemini', 'failed', 'agent: gemini failed: exit status 1', datetime('now'));
INSERT INTO review_jobs VALUES (11, 'gemini', 'failed', 'agent: gemini failed: exit status 1', datetime('now'));
SQL
  out="$(ROBOREV_DB="$fixture_db" CONFIG_TOML="$fixture_config" MARKER="$fixture_marker" LOG="$fixture_log" \
    SQLITE="$SQLITE" ROBOREV="$ROBOREV" CODEX="$CODEX" \
    bash "$0" --status 2>&1)"
  if ! echo "$out" | grep -q "agent-failed-cause-unknown"; then
    pass=$((pass + 1))
  else
    echo "FAIL: an unrelated failure signature wrongly triggered agent-failed-cause-unknown. Output:"
    echo "$out"
  fi

  # Check 5: rows outside the window (25h ago, window default 1440m=24h)
  # never count -> proves the window bound is enforced, not "all time".
  total=$((total + 1))
  "$SQLITE" "$fixture_db" "DELETE FROM review_jobs;"
  "$SQLITE" "$fixture_db" <<SQL
INSERT INTO review_jobs VALUES (12, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now', '-25 hours'));
INSERT INTO review_jobs VALUES (13, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now', '-25 hours'));
INSERT INTO review_jobs VALUES (14, 'gemini', 'failed', 'agent: gemini failed: exit status 41 (parse error: no valid stream-json)', datetime('now', '-25 hours'));
SQL
  out="$(ROBOREV_DB="$fixture_db" CONFIG_TOML="$fixture_config" MARKER="$fixture_marker" LOG="$fixture_log" \
    SQLITE="$SQLITE" ROBOREV="$ROBOREV" CODEX="$CODEX" \
    bash "$0" --status 2>&1)"
  if ! echo "$out" | grep -q "agent-failed-cause-unknown"; then
    pass=$((pass + 1))
  else
    echo "FAIL: stream-json failures 25h old (outside the 24h default window) wrongly triggered a WARN. Output:"
    echo "$out"
  fi

  rm -rf "$tmp_root" 2>/dev/null || true

  echo "selftest: ${pass}/${total} PASS"
  [ "$pass" -eq "$total" ]
}

if [ "$SELFTEST" -eq 1 ]; then
  run_selftest
  exit $?
fi

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

# ── Stream-json cause-unknown detection (llm#954) ────────────────────────────
# roborev reports "exit status N (parse error: no valid stream-json)" whenever
# an agent exits non-zero with empty stdout, regardless of the real cause.
# Reproduced directly (llm#954): gemini exiting 41 for a missing
# GEMINI_API_KEY produces exactly this text — the real reason ("you must
# specify the GEMINI_API_KEY environment variable") was on stderr, which
# roborev discards. This recorded error stood for a week and pointed
# diagnosis in the wrong direction (llm#936). Since roborev is a third-party
# binary we cannot make it capture/persist stderr; the best we can do is
# detect the SIGNATURE it leaves behind and refuse to repeat its fabricated
# "parse error" framing — report it as what it actually is: an agent exit
# with no usable output, cause unknown from this record alone.
#
# Only status='failed' rows carrying the literal 'no valid stream-json'
# substring qualify — that string is roborev's own, stable across the agents
# observed producing it (llm#954 was gemini; the pattern is agent-agnostic
# by construction, since it fires whenever ANY agent's stdout is empty).
STREAM_JSON_WINDOW_MIN="${STREAM_JSON_WINDOW_MIN:-1440}"   # 24h
STREAM_JSON_THRESHOLD="${STREAM_JSON_THRESHOLD:-3}"

# stream_json_fail_summary — one "agent|count" line per agent whose
# cause-unknown failure count in the window meets/exceeds the threshold.
# Empty output means nothing to report (below threshold or none at all).
stream_json_fail_summary() {
  "$SQLITE" -separator '|' "$ROBOREV_DB" <<SQL 2>/dev/null
SELECT agent, COUNT(*)
FROM review_jobs
WHERE status = 'failed'
  AND error LIKE '%no valid stream-json%'
  AND datetime(replace(replace(enqueued_at, 'T', ' '), 'Z', '')) > datetime('now', '-${STREAM_JSON_WINDOW_MIN} minutes')
GROUP BY agent
HAVING COUNT(*) >= ${STREAM_JSON_THRESHOLD};
SQL
}

# report_stream_json_health — emits one WARN log line + one stdout line per
# agent returned by stream_json_fail_summary(). Shared between --status and
# the default (mutating) flow so both surfaces say the same thing.
report_stream_json_health() {
  local hits agent_name count
  hits="$(stream_json_fail_summary)"
  [ -n "$hits" ] || return 0
  while IFS='|' read -r agent_name count; do
    [ -n "$agent_name" ] || continue
    log "WARN: agent-failed-cause-unknown: agent=${agent_name} count=${count} 'no valid stream-json' in last ${STREAM_JSON_WINDOW_MIN}m (llm#954 — this is roborev's own empty-stdout parse fallback, NOT a genuine parse error; the real cause is on the agent's stderr, which roborev does not persist)"
    echo "roborev_agent_health: WARN: agent-failed-cause-unknown: ${agent_name} has ${count} 'no valid stream-json' failures in last ${STREAM_JSON_WINDOW_MIN}m (empty-stdout exit — NOT a parse error, real cause unrecorded; see llm#954)"
  done <<< "$hits"
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

# llm#954 — runs for both --status and the default (mutating) flow, since
# this is a report-only signal (never mutates config/marker/daemon state)
# and should be visible regardless of which mode the caller used.
report_stream_json_health

if [ "$STATUS_ONLY" -eq 1 ]; then
  log "status: failures=$recent_failures threshold=$FAILURE_THRESHOLD state=$throttle_state"
  exit 0
fi

# ── Active-agent failure guard (#676) ────────────────────────────────────────
# Check job-level health via roborev summary --json. Crashed reviews never
# produce a verdict, so verdicts.failed == 0 is NOT a "clean" signal. We must
# inspect overview.failed and agents[].errors to surface silent failures.
# This guard logs a WARNING so roborev_agent_health.log captures the signal
# even when the codex-specific failure count is below the swap threshold.
_active_summary=$(timeout 5 "$ROBOREV" summary --json 2>/dev/null) || _active_summary=""
if [ -n "$_active_summary" ] && command -v python3 >/dev/null 2>&1; then
  _active_overview_failed=$(echo "$_active_summary" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('overview',{}).get('failed',0))" \
    2>/dev/null || echo 0)
  _active_agent_errors=$(echo "$_active_summary" | python3 -c \
    "import sys,json; d=json.load(sys.stdin)
[print(a['agent']+'='+str(a.get('errors',0))) for a in d.get('agents',[]) if a.get('errors',0)>0]" \
    2>/dev/null || echo "")
  _active_overview_failed="${_active_overview_failed:-0}"
  if [ "${_active_overview_failed:-0}" -gt 0 ] || [ -n "$_active_agent_errors" ]; then
    log "WARN: active agent failing: overview.failed=${_active_overview_failed} agent_errors=${_active_agent_errors:-none}"
    echo "roborev_agent_health: WARN: active agent failing (overview.failed=${_active_overview_failed}, agent_errors=${_active_agent_errors:-none})"
  fi
fi

# ── Throttle: swap codex → claude-code ───────────────────────────────────────
if [ "$recent_failures" -ge "$FAILURE_THRESHOLD" ] && ! marker_exists; then
  ts=$(date -u +%Y%m%d_%H%M%S)
  backup_path="${CONFIG_TOML}.bak-agent-health-${ts}"
  ts_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$APPLY" -eq 0 ]; then
    echo "[dry] would throttle codex: backup config, swap to claude-code, create marker, kickstart daemon"
    echo "  reason: $recent_failures codex failures in last ${FAILURE_WINDOW_MIN} minutes"
    log "dry-run: would throttle codex (failures=$recent_failures threshold=$FAILURE_THRESHOLD)"
    exit 0
  fi

  log "throttle: $recent_failures codex failures in last ${FAILURE_WINDOW_MIN}m — swapping to claude-code"

  # Backup config
  if ! cp "$CONFIG_TOML" "$backup_path"; then
    log "abort: backup to $backup_path failed"
    echo "roborev_agent_health: backup failed — aborting" >&2
    exit 1
  fi
  log "backup: $backup_path"

  # Swap agents in config (in-place sed; BSD/GNU compatible via temp file)
  # (#676: swap target changed to claude-code; free-tier agent was permanently dead)
  tmp_config=$(mktemp)
  sed \
    -e "s|^default_agent = 'codex'|default_agent = 'claude-code'|" \
    -e "s|^default_backup_agent = 'claude-code'|default_backup_agent = 'codex'|" \
    "$CONFIG_TOML" > "$tmp_config"
  mv "$tmp_config" "$CONFIG_TOML"
  log "config: swapped default_agent=claude-code backup_agent=codex"

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

  echo "roborev_agent_health [applied]: codex throttled — swapped to claude-code (backup: $backup_path)"
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
      # (#676: swap target was claude-code, so invert back to codex primary / claude-code backup)
      tmp_config=$(mktemp)
      sed \
        -e "s|^default_agent = 'claude-code'|default_agent = 'codex'|" \
        -e "s|^default_backup_agent = 'codex'|default_backup_agent = 'claude-code'|" \
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
    log "recovery-check: codex still unhealthy (version probe failed) — remaining on claude-code"
    echo "roborev_agent_health: codex still unhealthy — remaining on claude-code"
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
