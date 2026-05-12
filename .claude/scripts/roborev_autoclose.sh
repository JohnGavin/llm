#!/usr/bin/env bash
# roborev_autoclose.sh — close open roborev findings older than N days
#
# Status: DRAFT (#138). Not yet wired into any hook or launchd plist.
#         Threshold and cadence pending user decision — see the issue.
#
# Usage:
#   roborev_autoclose.sh                  # default: dry-run, threshold=30d
#   roborev_autoclose.sh --apply          # actually close
#   THRESHOLD_DAYS=14 roborev_autoclose.sh --apply
#
# Exit codes:
#   0  ok (including "nothing to do" and "roborev binary missing")
#   1  unexpected error
#
# Why "open" findings accumulate: a roborev review job runs after each
# commit and stays in the `open` set (closed=false) until either (a) the
# user dismisses the finding or (b) something auto-closes it. There is
# currently no (b) — hence the queue grows. See #138 for analysis showing
# 47% of the 129 open jobs in the llm repo are >30 days old.

set -euo pipefail

ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-30}"
APPLY=0
LOGFILE="$HOME/.claude/logs/roborev_autoclose.log"

case "${1:-}" in
  --apply) APPLY=1 ;;
  --dry-run|"") APPLY=0 ;;
  -h|--help)
    sed -n '2,18p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 1
    ;;
esac

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

# Quietly succeed if roborev isn't installed (laptop vs CI portability)
if [ ! -x "$ROBOREV" ]; then
  log "skip: roborev binary not found at $ROBOREV"
  exit 0
fi

# Cutoff in epoch seconds
CUTOFF=$(date -u -v "-${THRESHOLD_DAYS}d" +%s 2>/dev/null \
       || date -u -d "${THRESHOLD_DAYS} days ago" +%s)

# Fetch open jobs, filter by enqueued_at < cutoff, emit ids
mapfile -t STALE_IDS < <(
  "$ROBOREV" list --json --open --limit 1000 2>/dev/null \
    | python3 -c "
import json, sys
from datetime import datetime, timezone
cutoff = int(sys.argv[1])
data = json.load(sys.stdin)
jobs = data if isinstance(data, list) else data.get('jobs', [])
for j in jobs:
    ts = j.get('enqueued_at')
    if not ts: continue
    try:
        ds = datetime.fromisoformat(ts.replace('Z','+00:00')).timestamp()
    except Exception:
        continue
    if ds < cutoff:
        print(j['id'])
" "$CUTOFF"
)

N=${#STALE_IDS[@]}
if [ "$N" -eq 0 ]; then
  log "ok: 0 jobs older than ${THRESHOLD_DAYS}d"
  echo "roborev: 0 stale jobs (>${THRESHOLD_DAYS}d)"
  exit 0
fi

if [ "$APPLY" -eq 0 ]; then
  echo "roborev: $N stale jobs (>${THRESHOLD_DAYS}d) — dry-run; pass --apply to close"
  log "dry-run: $N stale jobs identified"
  exit 0
fi

# Apply: close each. Tolerate per-id failures; report at the end.
CLOSED=0
FAILED=0
for id in "${STALE_IDS[@]}"; do
  if "$ROBOREV" close "$id" >/dev/null 2>&1; then
    CLOSED=$((CLOSED + 1))
  else
    FAILED=$((FAILED + 1))
    log "fail: roborev close $id"
  fi
done

log "applied: closed=$CLOSED failed=$FAILED threshold=${THRESHOLD_DAYS}d"
echo "roborev: closed $CLOSED / $N stale jobs (>${THRESHOLD_DAYS}d, $FAILED failed)"

# Integration options (pick one when #138 is resolved):
#
# Option A — session-stop hook (runs after every Claude response):
#   Append to .claude/hooks/session_stop.sh:
#     # ── roborev stale-finding sweep ─────────────────────────────
#     STAMP="$HOME/.claude/.roborev_autoclose.stamp"
#     if [ ! -f "$STAMP" ] || [ "$(find "$STAMP" -mtime +1 2>/dev/null)" ]; then
#       "$HOME/docs_gh/llm/.claude/scripts/roborev_autoclose.sh" --apply
#       touch "$STAMP"
#     fi
#
# Option B — weekly launchd plist (~/Library/LaunchAgents/llm.roborev.autoclose.plist):
#   <?xml version="1.0" encoding="UTF-8"?>
#   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
#     "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
#   <plist version="1.0"><dict>
#     <key>Label</key><string>llm.roborev.autoclose</string>
#     <key>ProgramArguments</key>
#     <array>
#       <string>/Users/johngavin/docs_gh/llm/.claude/scripts/roborev_autoclose.sh</string>
#       <string>--apply</string>
#     </array>
#     <key>StartCalendarInterval</key>
#     <dict><key>Weekday</key><integer>1</integer>
#           <key>Hour</key><integer>9</integer></dict>
#     <key>StandardOutPath</key><string>/tmp/roborev_autoclose.out</string>
#     <key>StandardErrorPath</key><string>/tmp/roborev_autoclose.err</string>
#   </dict></plist>
#
# Option C — manual command only (no auto-run, just available as a script).
