#!/usr/bin/env bash
# braindump_act.sh — Record braindump processing outcomes
# Called by Claude after interpreting a braindump instruction.
#
# Usage:
#   braindump_act.sh process <id> "<summary>"
#   braindump_act.sh action <braindump_id> <type> <project> [issue_url] [issue_number]
#   braindump_act.sh complete <action_id> "<resolution_notes>"
#   braindump_act.sh status
#   braindump_act.sh pending

set -uo pipefail

DB="$HOME/.claude/logs/unified.duckdb"
[ -f "$DB" ] || { echo "ERROR: $DB not found" >&2; exit 1; }

CMD="${1:-status}"
shift || true

case "$CMD" in
  process)
    # Mark a braindump as processed with a summary
    ID="${1:?Usage: braindump_act.sh process <id> '<summary>'}"
    SUMMARY="${2:?Usage: braindump_act.sh process <id> '<summary>'}"
    ESCAPED=$(echo "$SUMMARY" | sed "s/'/''/g")
    duckdb "$DB" -c "
      UPDATE braindumps
      SET processed_prompt = '$ESCAPED',
          processed_at = current_timestamp
      WHERE id = $ID;
    " 2>/dev/null
    echo "Braindump $ID marked as processed"
    ;;

  action)
    # Record an action taken for a braindump
    BD_ID="${1:?Usage: braindump_act.sh action <braindump_id> <type> <project> [issue_url] [issue_number]}"
    TYPE="${2:?action type required (issue/review/test/investigate/informational)}"
    PROJECT="${3:?project name required}"
    ISSUE_URL="${4:-}"
    ISSUE_NUM="${5:-}"
    duckdb "$DB" -c "
      INSERT INTO braindump_actions (braindump_id, action_type, project, issue_url, issue_number, status, issue_created_at)
      VALUES ($BD_ID, '$TYPE', '$PROJECT', $([ -n "$ISSUE_URL" ] && echo "'$ISSUE_URL'" || echo "NULL"),
              $([ -n "$ISSUE_NUM" ] && echo "$ISSUE_NUM" || echo "NULL"),
              $([ -n "$ISSUE_URL" ] && echo "'created'" || echo "'pending'"),
              $([ -n "$ISSUE_URL" ] && echo "current_timestamp" || echo "NULL"));
    " 2>/dev/null
    echo "Action recorded: $TYPE for braindump $BD_ID in $PROJECT"
    ;;

  complete)
    # Mark an action as completed
    ACTION_ID="${1:?Usage: braindump_act.sh complete <action_id> '<resolution_notes>'}"
    NOTES="${2:-completed}"
    ESCAPED=$(echo "$NOTES" | sed "s/'/''/g")
    duckdb "$DB" -c "
      UPDATE braindump_actions
      SET status = 'completed',
          issue_closed_at = current_timestamp,
          resolution_notes = '$ESCAPED'
      WHERE id = $ACTION_ID;
    " 2>/dev/null
    echo "Action $ACTION_ID completed"
    ;;

  status)
    # Show current state: unprocessed braindumps + open actions
    echo "=== Unprocessed braindumps ==="
    duckdb "$DB" -c "
      SELECT id, source, captured_at::DATE as date,
             CASE WHEN LENGTH(raw_text) > 80 THEN SUBSTR(raw_text, 1, 80) || '...' ELSE raw_text END as preview
      FROM braindumps WHERE processed_prompt IS NULL
      ORDER BY captured_at;
    " 2>/dev/null | grep -v "^$"
    echo ""
    echo "=== Open actions ==="
    duckdb "$DB" -c "
      SELECT a.id, a.braindump_id as bd, a.action_type, a.project, a.status,
             a.created_at::DATE as created,
             CASE WHEN a.issue_url IS NOT NULL THEN a.issue_url ELSE '(no issue)' END as issue
      FROM braindump_actions a
      WHERE a.status NOT IN ('completed', 'skipped')
      ORDER BY a.created_at;
    " 2>/dev/null | grep -v "^$"
    echo ""
    echo "=== Summary ==="
    duckdb "$DB" -c "
      SELECT
        (SELECT COUNT(*) FROM braindumps WHERE processed_prompt IS NULL) as unprocessed,
        (SELECT COUNT(*) FROM braindump_actions WHERE status='pending') as pending_actions,
        (SELECT COUNT(*) FROM braindump_actions WHERE status='created' AND issue_closed_at IS NULL) as open_issues,
        (SELECT COUNT(*) FROM braindump_actions WHERE status='completed') as completed;
    " 2>/dev/null | grep -v "^$"
    ;;

  pending)
    # Just list unprocessed braindump IDs and text (for Claude to read)
    duckdb "$DB" -c "
      SELECT id, source, captured_at::VARCHAR as captured, raw_text
      FROM braindumps WHERE processed_prompt IS NULL
      ORDER BY captured_at;
    " 2>/dev/null | grep -v "^$"
    ;;

  *)
    echo "Usage: braindump_act.sh {process|action|complete|status|pending}" >&2
    exit 1
    ;;
esac
