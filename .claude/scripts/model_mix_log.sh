#!/usr/bin/env bash
# model_mix_log.sh — Log weekly model mix for tracking auto-delegation effectiveness
# Run manually or via cron: ~/.claude/scripts/model_mix_log.sh
# Appends one line per week to ~/.claude/logs/model_mix.csv

set -euo pipefail

LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/model_mix.csv"
mkdir -p "$LOG_DIR"

# Create header if file doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  echo "week,opus_out_pct,sonnet_out_pct,haiku_out_pct,opus_cost,sonnet_cost,haiku_cost,total_cost" > "$LOG_FILE"
fi

# Get current week data
json=$(timeout 30 npx ccusage weekly \
  --start-of-week tuesday \
  --timezone Europe/Dublin \
  --since "$(date -v-7d +%Y%m%d 2>/dev/null || date -d '7 days ago' +%Y%m%d)" \
  --json --offline 2>/dev/null) || { echo "Failed to fetch usage"; exit 1; }

echo "$json" | python3 -c "
import sys, json

data = json.load(sys.stdin)
weeks = data.get('weekly', [])
if not weeks:
    sys.exit(0)

w = weeks[-1]  # current/latest week
total_out = sum(m.get('outputTokens', 0) for m in w.get('modelBreakdowns', []))
total_cost = w['totalCost']

opus_out = opus_cost = 0
sonnet_out = sonnet_cost = 0
haiku_out = haiku_cost = 0

for m in w.get('modelBreakdowns', []):
    name = m['modelName']
    out = m.get('outputTokens', 0)
    cost = m.get('cost', 0)
    if 'opus' in name:
        opus_out += out; opus_cost += cost
    elif 'sonnet' in name:
        sonnet_out += out; sonnet_cost += cost
    elif 'haiku' in name:
        haiku_out += out; haiku_cost += cost

opus_pct = (opus_out / total_out * 100) if total_out else 0
sonnet_pct = (sonnet_out / total_out * 100) if total_out else 0
haiku_pct = (haiku_out / total_out * 100) if total_out else 0

print(f\"{w['week']},{opus_pct:.1f},{sonnet_pct:.1f},{haiku_pct:.1f},{opus_cost:.0f},{sonnet_cost:.0f},{haiku_cost:.0f},{total_cost:.0f}\")
" >> "$LOG_FILE"

echo "Logged to $LOG_FILE"
tail -5 "$LOG_FILE"
