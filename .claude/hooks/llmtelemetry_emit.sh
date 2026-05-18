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

set -uo pipefail

MODE="${1:-stop}"
LOG_DIR="$HOME/.claude/logs"
STAGING_DIR="$LOG_DIR/llmtelemetry-staging"
STATE_START="$LOG_DIR/.llmtelemetry_started_at"
STATE_SID="$LOG_DIR/.llmtelemetry_session_id"
GLOBAL_FLAG="$HOME/.claude/.llmtelemetry_emit"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd 2>/dev/null || echo "")}"
PROJECT_FLAG="$PROJECT_DIR/.llmtelemetry_emit"

# Opt-in gate (fail-open: if gate check errors, skip emit silently)
if [ ! -f "$GLOBAL_FLAG" ] && [ ! -f "$PROJECT_FLAG" ]; then
  exit 0
fi

# Derive session ID: env var → state file → generate
SESSION_ID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -f "$LOG_DIR/.current_session" ]; then
  SESSION_ID=$(cat "$LOG_DIR/.current_session" 2>/dev/null || echo "")
fi
[ -n "$SESSION_ID" ] || SESSION_ID="hook-$(date -u '+%Y%m%dT%H%M%SZ')"

# Derive project from project dir
PROJECT=$(basename "${PROJECT_DIR:-$(pwd 2>/dev/null || echo unknown)}")

# ── START mode: record UTC start time and session ID ─────────────────────────
if [ "$MODE" = "start" ]; then
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE_START" 2>/dev/null || true
  printf '%s' "$SESSION_ID" > "$STATE_SID" 2>/dev/null || true
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
JSONL=$(printf \
  '{"ts":"%s","host":"%s","pid":"%s","payload":{"event_type":"session_stop","session_id":"%s","project":"%s","started_at":"%s","ended_at":"%s","duration_min":%s,"agent":"claude-code","source":"claude-code-hook","working_dir":"%s"}}' \
  "$TS_END" \
  "$(jsons "$HOST")" \
  "$$" \
  "$(jsons "$SESSION_ID")" \
  "$(jsons "$PROJECT")" \
  "$(jsons "${TS_START:-}")" \
  "$TS_END" \
  "$DURATION_MIN" \
  "$(jsons "$PROJECT_DIR")")

printf '%s\n' "$JSONL" >> "$STAGING_DIR/events-${HOST}-${DATE}.jsonl" 2>/dev/null || true

# Clean up state files
rm -f "$STATE_START" "$STATE_SID" 2>/dev/null || true

exit 0
