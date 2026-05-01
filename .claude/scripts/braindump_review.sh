#!/usr/bin/env bash
# braindump_review.sh — Weekly review of braindump lifecycle
# Checks: unprocessed braindumps, stale linked issues, orphaned actions
# Run: weekly via cron or manually
# Output: summary to stdout, optionally to unified.duckdb review log

set -uo pipefail

DB="$HOME/.claude/logs/unified.duckdb"

if [ ! -f "$DB" ]; then
  echo "ERROR: unified.duckdb not found at $DB"
  exit 1
fi

echo "=== Braindump Weekly Review ($(date +%Y-%m-%d)) ==="
echo ""

# 1. Unprocessed braindumps
echo "--- Unprocessed Braindumps ---"
duckdb "$DB" -c "
SELECT id, source, substr(raw_text, 1, 60) as preview,
  captured_at::varchar as captured
FROM braindumps
WHERE processed_at IS NULL
ORDER BY captured_at;" 2>/dev/null | tail -n +3

UNPROCESSED=$(duckdb "$DB" -c "SELECT COUNT(*) FROM braindumps WHERE processed_at IS NULL;" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
echo "Total unprocessed: ${UNPROCESSED:-0}"
echo ""

# 2. Stale actions: linked issues open > 14 days
echo "--- Stale Actions (issues open > 14 days) ---"
duckdb "$DB" -c "
SELECT a.id, a.braindump_id, a.project, a.issue_number,
  a.created_at::date as created, a.status,
  datediff('day', a.created_at, current_timestamp) as age_days
FROM braindump_actions a
WHERE a.status != 'completed'
  AND a.issue_number IS NOT NULL
  AND datediff('day', a.created_at, current_timestamp) > 14
ORDER BY age_days DESC;" 2>/dev/null | tail -n +3

STALE=$(duckdb "$DB" -c "
SELECT COUNT(*) FROM braindump_actions
WHERE status != 'completed'
  AND issue_number IS NOT NULL
  AND datediff('day', created_at, current_timestamp) > 14;" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
echo "Total stale: ${STALE:-0}"
echo ""

# 3. Orphaned actions: no linked issue
echo "--- Orphaned Actions (no issue linked) ---"
duckdb "$DB" -c "
SELECT a.id, a.braindump_id, a.action_type, a.project, a.status,
  a.created_at::date as created
FROM braindump_actions a
WHERE a.issue_number IS NULL
  AND a.action_type != 'informational'
  AND a.status != 'completed'
ORDER BY a.created_at;" 2>/dev/null | tail -n +3
echo ""

# 4. Summary stats
echo "--- Lifecycle Summary ---"
duckdb "$DB" -c "
SELECT
  (SELECT COUNT(*) FROM braindumps) as total_braindumps,
  (SELECT COUNT(*) FROM braindumps WHERE processed_at IS NOT NULL) as processed,
  (SELECT COUNT(*) FROM braindump_actions) as total_actions,
  (SELECT COUNT(*) FROM braindump_actions WHERE status = 'completed') as completed_actions,
  (SELECT COUNT(DISTINCT source) FROM braindumps) as sources;" 2>/dev/null | tail -n +3

# 5. Source breakdown
echo ""
echo "--- By Source ---"
duckdb "$DB" -c "
SELECT source, COUNT(*) as count,
  COUNT(processed_at) as processed,
  MIN(captured_at)::date as earliest,
  MAX(captured_at)::date as latest
FROM braindumps
GROUP BY source
ORDER BY count DESC;" 2>/dev/null | tail -n +3

echo ""
echo "=== Review complete ==="
