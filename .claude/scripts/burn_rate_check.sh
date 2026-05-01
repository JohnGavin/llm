#!/usr/bin/env bash
# burn_rate_check.sh — Weekly usage burn-rate alert
# Checks if current-week run rate projects to breach the weekly cap.
# Uses ccusage JSON output. Week starts Tuesday, Europe/Dublin timezone.
#
# Usage:
#   burn_rate_check.sh [compact]   # compact = one-line for hooks
#
# Env vars:
#   CLAUDE_WEEKLY_CAP_USD  — weekly budget cap (default: 150)
#   CLAUDE_WEEK_START_DAY  — week start day (default: tuesday)
#   CLAUDE_TIMEZONE        — timezone (default: Europe/Dublin)

set -euo pipefail

MODE="${1:-full}"
CAP="${CLAUDE_WEEKLY_CAP_USD:-150}"
WEEK_START="${CLAUDE_WEEK_START_DAY:-tuesday}"
TZ_NAME="${CLAUDE_TIMEZONE:-Europe/Dublin}"

# Cache: reuse if < 5 minutes old (ccusage is slow due to pricing fetch)
CACHE_FILE="/tmp/ccusage_weekly_cache.json"
CACHE_MAX_AGE=300

use_cache=false
if [ -f "$CACHE_FILE" ]; then
  # GNU stat (Nix) uses -c %Y, macOS stat uses -f %m
  file_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_age=$(( $(date +%s) - file_mtime ))
  [ "$cache_age" -lt "$CACHE_MAX_AGE" ] && use_cache=true
fi

if [ "$use_cache" = true ]; then
  weekly_json=$(cat "$CACHE_FILE")
else
  weekly_json=$(timeout 30 npx ccusage weekly \
    --start-of-week "$WEEK_START" \
    --timezone "$TZ_NAME" \
    --since "$(date -v-7d +%Y%m%d 2>/dev/null || date -d '7 days ago' +%Y%m%d)" \
    --json --offline 2>/dev/null) || {
    [ "$MODE" = "compact" ] && echo "burn:err" || echo "Burn rate: could not fetch usage"
    exit 0
  }
  echo "$weekly_json" > "$CACHE_FILE"
fi

# Parse: get the last (current) week's cost
result=$(echo "$weekly_json" | python3 -c "
import sys, json
from datetime import datetime, timedelta

data = json.load(sys.stdin)
weeks = data.get('weekly', [])
if not weeks:
    print('no_data')
    sys.exit(0)

# Current week = last entry
current = weeks[-1]
spent = current['totalCost']
week_start_str = current['week']  # e.g. '2026-04-14'

# Calculate days elapsed and remaining
week_start = datetime.strptime(week_start_str, '%Y-%m-%d').date()
today = datetime.now().date()
days_elapsed = (today - week_start).days + 1  # inclusive of today
days_remaining = max(0, 7 - days_elapsed)

# Run rate
if days_elapsed > 0:
    daily_rate = spent / days_elapsed
    projected = spent + (daily_rate * days_remaining)
else:
    daily_rate = 0
    projected = spent

cap = float(${CAP})
pct_used = (spent / cap * 100) if cap > 0 else 0
pct_projected = (projected / cap * 100) if cap > 0 else 0

# Determine severity
if pct_projected > 95 or pct_used > 90:
    severity = 'CRITICAL'
elif pct_projected > 80:
    severity = 'WARN'
elif pct_projected > 60:
    severity = 'INFO'
else:
    severity = 'OK'

print(f'{severity}|{spent:.0f}|{projected:.0f}|{cap:.0f}|{days_elapsed}|{days_remaining}|{daily_rate:.0f}|{pct_used:.0f}|{pct_projected:.0f}')
" 2>/dev/null) || { echo "burn:parse_err"; exit 0; }

[ "$result" = "no_data" ] && { [ "$MODE" = "compact" ] && echo "burn:no_data" || echo "Burn rate: no data for current week"; exit 0; }

IFS='|' read -r severity spent projected cap days_elapsed days_remaining daily_rate pct_used pct_projected <<< "$result"

if [ "$MODE" = "compact" ]; then
  # One-line output for hooks/statusline
  case "$severity" in
    CRITICAL) echo "BURN CRITICAL: \$${spent}/\$${cap} (${pct_used}%), proj \$${projected} (${pct_projected}%), ${days_remaining}d left — THROTTLE TO HAIKU" ;;
    WARN)     echo "BURN WARN: \$${spent}/\$${cap} (${pct_used}%), proj \$${projected} (${pct_projected}%), ${days_remaining}d left — prefer sonnet/haiku" ;;
    INFO)     echo "burn:\$${spent}/\$${cap}(${days_remaining}d)" ;;
    OK)       echo "burn:\$${spent}/\$${cap}(${days_remaining}d)" ;;
  esac
else
  # Full output for session start
  echo "Weekly burn rate (${WEEK_START} reset, ${TZ_NAME}):"
  echo "  Spent:     \$${spent} / \$${cap} (${pct_used}%)"
  echo "  Rate:      \$${daily_rate}/day over ${days_elapsed} days"
  echo "  Projected: \$${projected} by week end (${pct_projected}% of cap)"
  echo "  Remaining: ${days_remaining} days"
  case "$severity" in
    CRITICAL)
      echo "  STATUS:    CRITICAL — lockout imminent"
      echo "  ACTION:    Switch to haiku-only. Defer non-urgent work."
      ;;
    WARN)
      echo "  STATUS:    WARNING — on track to breach"
      echo "  ACTION:    Prefer sonnet/haiku. Avoid long opus sessions."
      ;;
    INFO)
      echo "  STATUS:    Elevated — monitor closely"
      ;;
    OK)
      echo "  STATUS:    OK"
      ;;
  esac
fi

exit 0
