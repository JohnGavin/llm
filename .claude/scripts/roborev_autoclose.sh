#!/usr/bin/env bash
# roborev_autoclose.sh — close stale roborev findings.
#
# Portability: this script is invoked by launchd, which provides only a bare
# PATH (/usr/bin:/bin:/usr/sbin:/sbin). Prepend coreutils paths so that
# python3, sqlite3, and other tools are visible on both Homebrew and Nix Macs.
# Portability fixes (#181 Theme 2 — roborev ids 844):
#   - mapfile replaced with portable while-read loop (Bash 3.2 compat;
#     macOS ships Bash 3.2 which lacks the mapfile builtin).
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
#
# Two phases:
#   Phase 1 — `roborev close <id>` for jobs that have a review attached
#             (status='done', the agent ran and emitted findings).
#   Phase 2 — direct DB UPDATE status='canceled' for jobs that don't
#             (status='failed', the agent errored before producing a
#             review; daemon API rejects `close` with 404 "review not
#             found for job"). Backs up reviews.db, then UPDATE scoped
#             to ROBOREV_REPO (default 'llm') and age > THRESHOLD_DAYS.
#             Daemon stays running — SQLite WAL + busy_timeout handles
#             write contention with the live daemon (it's supervised by
#             com.roborev.auto-refine launchd, so killing it just makes
#             it respawn).
#
# Status: wired into weekly launchd via
#   ~/Library/LaunchAgents/com.claude.roborev-autoclose.plist
# Tracked in #138.
#
# Usage:
#   roborev_autoclose.sh                  # dry-run, threshold=30d
#   roborev_autoclose.sh --apply          # actually mutate
#   THRESHOLD_DAYS=14 roborev_autoclose.sh --apply
#   ROBOREV_REPO=mycare roborev_autoclose.sh --apply
#
# Exit codes:
#   0  ok (including "nothing to do" and "roborev binary missing")
#   1  unexpected error (daemon stop failed, backup failed, SQL failed)
#
# Why "open" findings accumulate: a roborev review job runs after each
# commit and stays in the `open` set until something dismisses it.
# Phase 1 + Phase 2 together handle both populations (review-with and
# review-without). See #138 for analysis showing ~47% of open jobs
# were >30d old.

set -euo pipefail

if [ -z "${ROBOREV:-}" ]; then
    ROBOREV="$(command -v roborev 2>/dev/null || echo /usr/local/bin/roborev)"
fi
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

# Fetch open jobs, filter by enqueued_at < cutoff, emit ids.
# Portable while-read loop instead of mapfile (Bash 3.2 compat — macOS ships Bash 3.2).
STALE_IDS=()
while IFS= read -r _line; do
  STALE_IDS+=("$_line")
done < <(
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

# ── Phase 2: cancel stale failed jobs (no review attached) ────────────
# Done jobs with reviews use the API (above). Failed jobs never produced
# a review, so the daemon API rejects `close` with 404. Resolve by
# direct DB UPDATE — stop daemon, backup DB, transition status='failed'
# → 'canceled', restart daemon. Scoped to the current repo only.
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
ROBOREV_REPO="${ROBOREV_REPO:-llm}"
SQLITE="${SQLITE:-/usr/bin/sqlite3}"
if [ ! -f "$ROBOREV_DB" ] || [ ! -x "$SQLITE" ]; then
  log "phase2 skipped: missing $ROBOREV_DB or $SQLITE"
  exit 0
fi

# Count what we'd cancel before doing anything
PHASE2_N=$("$SQLITE" "$ROBOREV_DB" <<SQL 2>/dev/null
SELECT COUNT(*)
FROM review_jobs rj JOIN repos r ON r.id = rj.repo_id
WHERE r.name = '$ROBOREV_REPO'
  AND rj.status = 'failed'
  AND (julianday('now') - julianday(rj.enqueued_at)) > $THRESHOLD_DAYS;
SQL
)
PHASE2_N=${PHASE2_N:-0}

if [ "$PHASE2_N" -eq 0 ]; then
  log "phase2: 0 stale failed jobs in repo=$ROBOREV_REPO"
  exit 0
fi

echo "roborev phase2: $PHASE2_N stale failed jobs (repo=$ROBOREV_REPO, no review attached) — cancelling via DB"

# Backup BEFORE mutating using Python's sqlite3.backup() — this is WAL-safe because
# it uses the SQLite Online Backup API which snapshots committed state including any
# un-checkpointed WAL pages. A plain `cp reviews.db` would miss those pages.
# We use /usr/bin/python3 to avoid depending on sqlite3 CLI being on PATH inside nix.
BACKUP="$ROBOREV_DB.bak-$(date +%Y%m%d_%H%M%S)"
if ! /usr/bin/python3 -c "
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
src.close()
dst.close()
" "$ROBOREV_DB" "$BACKUP"; then
  log "phase2 abort: WAL-safe backup to $BACKUP failed"
  echo "roborev phase2: backup failed"
  exit 1
fi

# We don't stop the daemon — it's supervised by com.roborev.auto-refine
# launchd which respawns it. SQLite's BEGIN IMMEDIATE + busy_timeout
# handles write contention with the running daemon.
"$SQLITE" "$ROBOREV_DB" <<SQL >/dev/null 2>&1
PRAGMA busy_timeout = 10000;
BEGIN IMMEDIATE;
UPDATE review_jobs
SET status = 'canceled',
    error = COALESCE(error, '') || ' [autoclose: cancelled at threshold ${THRESHOLD_DAYS}d, no review attached]'
WHERE repo_id = (SELECT id FROM repos WHERE name = '$ROBOREV_REPO')
  AND status = 'failed'
  AND (julianday('now') - julianday(enqueued_at)) > $THRESHOLD_DAYS;
COMMIT;
SQL
SQL_RC=$?

if [ "$SQL_RC" -ne 0 ]; then
  log "phase2 abort: SQL UPDATE failed rc=$SQL_RC (backup at $BACKUP)"
  echo "roborev phase2: SQL UPDATE failed (rc=$SQL_RC) — backup at $BACKUP"
  exit 1
fi

log "phase2: cancelled $PHASE2_N failed jobs (repo=$ROBOREV_REPO, backup=$BACKUP)"
echo "roborev phase2: cancelled $PHASE2_N stale failed jobs (backup at $BACKUP)"

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
