#!/usr/bin/env bash
# braindump_respond.sh — Send status reply to Signal Notes group
# Usage:
#   braindump_respond.sh <braindump_id> "<message>"
#   braindump_respond.sh --summary   # Send daily summary
#
# Requires: signal-cli daemon running on localhost:7583

set -uo pipefail

DAEMON_URL="http://localhost:7583/api/v1/rpc"
DB="$HOME/.claude/logs/unified.duckdb"

# Notes group ID (from signal-cli listGroups)
NOTES_GROUP=$(cat "$HOME/.claude/config/signal_notes_group_id.txt" 2>/dev/null || echo "")

if [ -z "$NOTES_GROUP" ]; then
  echo "ERROR: Signal Notes group ID not configured"
  echo "Run: signal-cli -a YOUR_NUMBER listGroups"
  echo "Save group ID to ~/.claude/config/signal_notes_group_id.txt"
  exit 1
fi

# Get registered phone number
PHONE=$(cat "$HOME/.claude/config/signal_phone.txt" 2>/dev/null || echo "")
if [ -z "$PHONE" ]; then
  echo "ERROR: Phone number not configured"
  echo "Save to ~/.claude/config/signal_phone.txt"
  exit 1
fi

send_message() {
  local msg="$1"
  curl -s -X POST "$DAEMON_URL" \
    -H "Content-Type: application/json" \
    -d "{
      \"jsonrpc\": \"2.0\",
      \"method\": \"send\",
      \"params\": {
        \"account\": \"$PHONE\",
        \"groupId\": \"$NOTES_GROUP\",
        \"message\": \"$msg\"
      },
      \"id\": 1
    }" 2>/dev/null
}

if [ "${1:-}" = "--summary" ]; then
  # Daily summary
  if [ ! -f "$DB" ]; then
    echo "ERROR: unified.duckdb not found"
    exit 1
  fi

  STATS=$(duckdb "$DB" -noheader -c "
    SELECT
      COUNT(*) || ' braindumps total, ' ||
      COUNT(processed_at) || ' processed, ' ||
      (COUNT(*) - COUNT(processed_at)) || ' pending'
    FROM braindumps;" 2>/dev/null | tail -1 | tr -d '[:space:]' | sed 's/^ *//')

  RECENT=$(duckdb "$DB" -noheader -c "
    SELECT COUNT(*) FROM braindumps
    WHERE captured_at >= current_date - INTERVAL '1 day';" 2>/dev/null | grep -oE '[0-9]+' | tail -1)

  ACTIONS=$(duckdb "$DB" -noheader -c "
    SELECT COUNT(*) || ' actions, ' ||
      SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) || ' completed'
    FROM braindump_actions;" 2>/dev/null | tail -1 | tr -d ' ')

  MSG="Claude braindump status: ${STATS}. Last 24h: ${RECENT:-0} new. Actions: ${ACTIONS}."
  echo "Sending summary: $MSG"
  send_message "$MSG"

elif [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
  # Reply to specific braindump
  BD_ID="$1"
  MSG="$2"
  echo "Sending reply for braindump #$BD_ID: $MSG"
  send_message "BD#$BD_ID: $MSG"

else
  echo "Usage:"
  echo "  braindump_respond.sh --summary"
  echo "  braindump_respond.sh <braindump_id> \"<message>\""
fi
