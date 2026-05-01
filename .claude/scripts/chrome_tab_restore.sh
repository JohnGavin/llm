#!/usr/bin/env bash
# chrome_tab_restore.sh — Restore Chrome tabs from a backup snapshot
# Usage:
#   chrome_tab_restore.sh                    # restore latest backup
#   chrome_tab_restore.sh 2026-04-28         # restore specific date
#   chrome_tab_restore.sh path/to/file.json  # restore specific file
#   chrome_tab_restore.sh --list             # list available backups

set -uo pipefail

BACKUP_DIR="$HOME/.chrome-tab-backups"

# --- List mode ---
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
  echo "Available backups:"
  for f in "$BACKUP_DIR"/*.json; do
    [ -f "$f" ] || continue
    TABS=$(/usr/bin/python3 -c "import json; d=json.load(open('$f')); print(f'{d[\"total_tabs\"]} tabs, {d[\"window_count\"]} windows')" 2>/dev/null)
    echo "  $(basename "$f" .json)  $TABS"
  done
  exit 0
fi

# --- Find backup file ---
if [ -n "${1:-}" ]; then
  if [ -f "$1" ]; then
    BACKUP="$1"
  else
    # Match by date prefix
    BACKUP=$(ls "$BACKUP_DIR"/${1}*.json 2>/dev/null | tail -1)
    if [ -z "$BACKUP" ]; then
      echo "ERROR: No backup found matching '$1'" >&2
      echo "  Run: $(basename "$0") --list" >&2
      exit 1
    fi
  fi
else
  BACKUP=$(ls "$BACKUP_DIR"/*.json 2>/dev/null | sort | tail -1)
  if [ -z "$BACKUP" ]; then
    echo "ERROR: No backups found in $BACKUP_DIR" >&2
    exit 1
  fi
fi

# --- Restore ---
/usr/bin/python3 -c "
import json, subprocess, time, sys

d = json.load(open('$BACKUP'))
print(f'Restoring {d[\"total_tabs\"]} tabs in {d[\"window_count\"]} windows')
print(f'From: $BACKUP')
print(f'Snapshot: {d[\"timestamp\"]}')
print()

for i, w in enumerate(d['windows']):
    urls = [t['url'] for t in w['tabs'] if t['url'].startswith('http')]
    if not urls:
        print(f'  Window {i}: skipped ({w[\"tab_count\"]} non-http tabs)')
        continue
    # --new-window + all URLs = one window with all tabs
    subprocess.run(['open', '-na', 'Google Chrome', '--args', '--new-window'] + urls)
    print(f'  Window {i}: {len(urls)} tabs opened')
    if i < d['window_count'] - 1:
        time.sleep(2)

print()
print('Done.')
"
