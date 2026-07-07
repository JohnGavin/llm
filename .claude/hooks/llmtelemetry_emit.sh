#!/usr/bin/env bash
# llmtelemetry_emit.sh — Push session events to llmtelemetry staging
#
# Usage (wired by settings.json):
#   llmtelemetry_emit.sh start   (SessionStart hook)
#   llmtelemetry_emit.sh stop    (Stop hook)
#
# Opt-in (either suffices):
#   Global:      touch ~/.claude/.llmtelemetry_emit
#   Per-project: touch <project_dir>/.llmtelemetry_emit
#
# Staging output: ~/.claude/logs/llmtelemetry-staging/events-HOST-DATE.jsonl
# Format: {"ts":"...","host":"...","pid":"...","payload":{...}}
#
# Fire-and-forget: always exits 0. Never blocks session start/stop.
#
# Real-session-end gate: the Stop hook fires after EVERY Claude response, not
# only at actual session end. To avoid emitting spurious stop events on every
# response, we gate stop emission behind a per-session sentinel written by /bye.
# Mid-session Stop invocations (non-/bye) skip emit entirely.
#
# Scheduled-session bypass (llmtelemetry#322 Phase 2):
# Headless sessions (launchd/cron, claude -p, /schedule, /loop) never call
# /bye, so they would emit nothing without the bypass. When CLAUDE_TRIGGER is
# "scheduled" at Stop time, the sentinel gate is bypassed and emit runs
# unconditionally. The payload includes "trigger":"scheduled" (vs "interactive"
# for normal sessions). Set by exporting CLAUDE_TRIGGER=scheduled in launcher
# scripts before invoking claude.
#
# Concurrent-session safety (llm#273):
#   - SESSION_ID is stable: prefer $CLAUDE_SESSION_ID → PPID-anchored fallback
#     written at start time. A PPID-keyed anchor file ensures start/stop resolve
#     the same ID even when CLAUDE_SESSION_ID is absent.
#   - Sentinels are per-session: ~/.claude/.bye-requested.<SESSION_ID>
#     A /bye in session B CANNOT consume session A's sentinel.
#   - State files are namespaced by SESSION_ID.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)"
MODE="${1:-stop}"
LOG_DIR="$HOME/.claude/logs"
STAGING_DIR="$LOG_DIR/llmtelemetry-staging"
GLOBAL_FLAG="$HOME/.claude/.llmtelemetry_emit"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd 2>/dev/null || echo "")}"
PROJECT_FLAG="$PROJECT_DIR/.llmtelemetry_emit"

# Opt-in gate (fail-open: if gate check errors, skip emit silently)
if [ ! -f "$GLOBAL_FLAG" ] && [ ! -f "$PROJECT_FLAG" ]; then
  exit 0
fi

# ── Stable session ID resolution (llm#273) ──────────────────────────────────
# Priority: CLAUDE_SESSION_ID env var → PPID-anchored file → .current_session
# → generate + anchor. The PPID anchor persists the generated ID across
# start/stop invocations that share the same parent process (one Claude session).
_PPID_ANCHOR="$LOG_DIR/.llmtelemetry_ppid_session.${PPID:-0}"
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
  if [ -f "$_PPID_ANCHOR" ]; then
    SESSION_ID=$(cat "$_PPID_ANCHOR" 2>/dev/null || echo "")
  fi
fi
if [ -z "$SESSION_ID" ]; then
  # .current_session is written by log_session.sh at SessionStart — last resort
  if [ -f "$LOG_DIR/.current_session" ]; then
    SESSION_ID=$(cat "$LOG_DIR/.current_session" 2>/dev/null || echo "")
  fi
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="emit-$(uuidgen 2>/dev/null || date -u '+%Y%m%dT%H%M%SZ')"
fi
# Write PPID anchor on first use so stop resolves the same ID
if [ ! -f "$_PPID_ANCHOR" ]; then
  printf '%s' "$SESSION_ID" > "$_PPID_ANCHOR" 2>/dev/null || true
fi

# Per-session state files — namespaced by SESSION_ID to avoid concurrent collisions
STATE_START="$LOG_DIR/.llmtelemetry_started_at.${SESSION_ID}"
STATE_SID="$LOG_DIR/.llmtelemetry_session_id.${SESSION_ID}"

# Derive project from project dir
PROJECT=$(basename "${PROJECT_DIR:-$(pwd 2>/dev/null || echo unknown)}")

# ── START mode: record UTC start time and session ID ─────────────────────────
if [ "$MODE" = "start" ]; then
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE_START" 2>/dev/null || true
  printf '%s' "$SESSION_ID" > "$STATE_SID" 2>/dev/null || true
  exit 0
fi

# ── STOP mode: determine trigger (scheduled vs interactive) ──────────────────
# CLAUDE_TRIGGER=scheduled is exported by in-repo launcher scripts and launchd
# entrypoints that invoke claude headlessly (cron jobs, /schedule, /loop).
# Interactive sessions leave CLAUDE_TRIGGER unset → defaults to "interactive".
# Validation: any value other than "scheduled" or "interactive" → "interactive".
_RAW_TRIGGER="${CLAUDE_TRIGGER:-interactive}"
case "$_RAW_TRIGGER" in
  scheduled|interactive) TRIGGER="$_RAW_TRIGGER" ;;
  *) TRIGGER="interactive" ;;
esac

# ── STOP mode: gate on per-session /bye sentinel (llm#273) ───────────────────
# /bye writes ~/.claude/.bye-requested.<SESSION_ID> (per-session) AND the
# legacy ~/.claude/.bye-requested for session_stop.sh pattern detection.
# We check ONLY the per-session sentinel so concurrent sessions cannot steal
# each other's stop events.
_BYE_SENTINEL_PER_SESSION="${HOME}/.claude/.bye-requested.${SESSION_ID}"
_BYE_SENTINEL_GLOBAL="${HOME}/.claude/.bye-requested"

# Scheduled-session bypass (llmtelemetry#322 Phase 2):
# Headless sessions spawned by launchd/cron/claude-p never call /bye, so the
# sentinel gate would permanently suppress their telemetry. When CLAUDE_TRIGGER
# is "scheduled" at Stop time, bypass the /bye sentinel and emit unconditionally.
# A headless claude session fires Stop exactly once at its natural exit, so
# there is no risk of spurious duplicate emission — the bypass is safe.
# Interactive sessions are unaffected: sentinel gate logic unchanged below.
_sentinel_found=0
if [ "$TRIGGER" = "scheduled" ]; then
  # Scheduled bypass: emit without /bye sentinel
  _sentinel_found=1
elif [ -f "$_BYE_SENTINEL_PER_SESSION" ]; then
  _sentinel_found=1
  rm -f "$_BYE_SENTINEL_PER_SESSION" 2>/dev/null || true
elif [ -f "$_BYE_SENTINEL_GLOBAL" ]; then
  # Backward-compat: consume global sentinel only when exactly one session is
  # active (i.e. only one PPID anchor exists). Prevents stealing another
  # session's intended sentinel when two sessions run concurrently.
  _anchor_count=$(find "$LOG_DIR" -maxdepth 1 -name '.llmtelemetry_ppid_session.*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_anchor_count:-2}" -le 1 ]; then
    _sentinel_found=1
    rm -f "$_BYE_SENTINEL_GLOBAL" 2>/dev/null || true
  fi
fi

if [ "$_sentinel_found" -eq 0 ]; then
  # Not a real session end — skip telemetry emit. State files are preserved
  # so the eventual real /bye stop can compute accurate duration.
  exit 0
fi

# ── STOP mode: emit JSONL envelope ───────────────────────────────────────────
mkdir -p "$STAGING_DIR" 2>/dev/null || exit 0

HOST=$(hostname -s 2>/dev/null || echo "unknown")
TS_END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
DATE=$(date +%Y-%m-%d)

# Read start time written by start mode (fall back to empty)
TS_START=""
if [ -f "$STATE_START" ]; then
  TS_START=$(cat "$STATE_START" 2>/dev/null || echo "")
fi
# Restore session ID written at start (may differ from env var for some sessions)
if [ -f "$STATE_SID" ]; then
  SAVED_SID=$(cat "$STATE_SID" 2>/dev/null || echo "")
  [ -n "$SAVED_SID" ] && SESSION_ID="$SAVED_SID"
fi

# Compute duration_min using python3 (portable: works with BSD and GNU date)
DURATION_MIN="null"
if [ -n "$TS_START" ]; then
  DURATION_MIN=$(/usr/bin/python3 - "$TS_START" 2>/dev/null <<'PYEOF'
import sys, datetime
try:
    start = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)
    now   = datetime.datetime.now(datetime.timezone.utc)
    print(f"{(now - start).total_seconds() / 60:.2f}")
except Exception:
    print("null")
PYEOF
  ) || DURATION_MIN="null"
fi

# Minimal JSON escaping for string fields (backslash and double-quote)
jsons() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Build and append the JSONL envelope
# "trigger" is always written explicitly: "scheduled" for automated/headless
# sessions (CLAUDE_TRIGGER=scheduled), "interactive" for human-driven sessions.
JSONL=$(printf \
  '{"ts":"%s","host":"%s","pid":"%s","payload":{"event_type":"session_stop","session_id":"%s","project":"%s","started_at":"%s","ended_at":"%s","duration_min":%s,"agent":"claude-code","source":"claude-code-hook","trigger":"%s","working_dir":"%s"}}' \
  "$TS_END" \
  "$(jsons "$HOST")" \
  "$$" \
  "$(jsons "$SESSION_ID")" \
  "$(jsons "$PROJECT")" \
  "$(jsons "${TS_START:-}")" \
  "$TS_END" \
  "$DURATION_MIN" \
  "$TRIGGER" \
  "$(jsons "$PROJECT_DIR")")

printf '%s\n' "$JSONL" >> "$STAGING_DIR/events-${HOST}-${DATE}.jsonl" 2>/dev/null || true

# ETL freshness registry (llm#309 Phase 1a): event-driven, no SLA -> unknown.
# Freshness proxy is the staging file's mtime (this is a JSONL sink, not a
# queryable DB table — the file we just appended to is the source of truth).
if [ -x "${SCRIPT_DIR}/etl_freshness_upsert.sh" ]; then
  "${SCRIPT_DIR}/etl_freshness_upsert.sh" llmtelemetry "$LOG_DIR/unified.duckdb" "" \
    --file "$STAGING_DIR/events-${HOST}-${DATE}.jsonl" >/dev/null 2>&1 || true
fi

# Clean up per-session state files and PPID anchor (only on real session end)
rm -f "$STATE_START" "$STATE_SID" "$_PPID_ANCHOR" 2>/dev/null || true

exit 0
