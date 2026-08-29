#!/usr/bin/env bash
# session_index_dedup.sh — ONE-TIME backfill for llm#912.
#
# Root cause: session_stop.sh's session-index block (fixed in the same
# commit as this script) appended a row to session_index.log on EVERY Stop
# hook firing — i.e. after every assistant response, not only at /bye.
# Measured impact (llm#912): ~93% of rows on 2026-08-04 were duplicate
# per-turn appends; 4326 total lines for only 12 distinct (branch, slug)
# pairs across 3 days.
#
# This script de-duplicates an EXISTING session_index.log, keeping the LAST
# row per (day, branch, slug) group — the row nearest the real end of that
# session — per the issue's explicit instruction: "the existing 4326-line
# file should be de-duplicated as a one-time backfill, keeping the last row
# per (branch, slug, day)."
#
# NOT wired into any hook, cron job, or session_init.sh — this is a
# one-time data-migration action on shared state and is meant to be
# triggered deliberately by a human, not run unattended (destructive-ops-guard
# Part 2/3: the file is rewritten in place under --apply, so a recovery
# trail backup is mandatory and confirmation is required).
#
# Usage:
#   bash .claude/scripts/session_index_dedup.sh                 # dry-run (default) — reports counts only
#   bash .claude/scripts/session_index_dedup.sh --apply          # de-duplicates ~/.claude/logs/session_index.log in place
#   bash .claude/scripts/session_index_dedup.sh --apply --file /path/to/session_index.log
#
# Recovery trail: --apply backs up the original file to
# <file>.<timestamp>.bak BEFORE overwriting it. Nothing is deleted.
#
# Issues: JohnGavin/llm#912, JohnGavin/llm#803 (reaper precedent)

set -euo pipefail

# ── Selftest ──────────────────────────────────────────────────────────────────
# Mirrors the CLAUDE_HOOK_SELFTEST convention used by session_slug.sh.
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  _pass=0
  _fail=0
  _tmpdir=$(mktemp -d /tmp/session_index_dedup_test.XXXXXX)
  trap 'rm -rf "$_tmpdir"' EXIT

  _log="$_tmpdir/session_index.log"

  # Case 1: same (day, branch, slug) repeated 3x (simulating per-turn
  # duplicate appends within one session) collapses to 1 row, keeping the
  # LAST occurrence's timestamp.
  printf '2026-08-04T09:00:00Z\tmain\tfix-foo-bar\n' > "$_log"
  printf '2026-08-04T09:05:00Z\tmain\tfix-foo-bar\n' >> "$_log"
  printf '2026-08-04T09:12:00Z\tmain\tfix-foo-bar\n' >> "$_log"
  _out=$(CLAUDE_HOOK_SELFTEST=0 bash "$0" --file "$_log" 2>&1)
  _rowcount=$(CLAUDE_HOOK_SELFTEST=0 bash "$0" --apply --file "$_log" >/dev/null 2>&1; wc -l < "$_log" | tr -d ' ')
  if [ "$_rowcount" = "1" ] && grep -q '^2026-08-04T09:12:00Z' "$_log"; then
    echo "PASS: same-session duplicates collapse to 1 row, keeping the last timestamp"
    _pass=$((_pass + 1))
  else
    echo "FAIL: same-session duplicates collapse to 1 row, keeping the last timestamp"
    echo "      rowcount=$_rowcount content=$(cat "$_log")"
    _fail=$((_fail + 1))
  fi

  # Case 2: distinct (branch, slug) pairs are never merged together.
  printf '2026-08-04T09:00:00Z\tmain\tfix-foo-bar\n' > "$_log"
  printf '2026-08-04T09:05:00Z\tfeat-x\tadd-widget\n' >> "$_log"
  printf '2026-08-04T09:06:00Z\tfeat-x\tadd-widget\n' >> "$_log"
  CLAUDE_HOOK_SELFTEST=0 bash "$0" --apply --file "$_log" >/dev/null 2>&1
  _distinct_rowcount=$(wc -l < "$_log" | tr -d ' ')
  if [ "$_distinct_rowcount" = "2" ]; then
    echo "PASS: distinct (branch, slug) pairs are not over-deduplicated"
    _pass=$((_pass + 1))
  else
    echo "FAIL: distinct (branch, slug) pairs are not over-deduplicated"
    echo "      rowcount=$_distinct_rowcount content=$(cat "$_log")"
    _fail=$((_fail + 1))
  fi

  # Case 3: a backup file is created on --apply.
  _bak_count=$(find "$_tmpdir" -maxdepth 1 -name 'session_index.log.*.bak' | wc -l | tr -d ' ')
  if [ "$_bak_count" -ge 1 ]; then
    echo "PASS: --apply creates a recovery-trail backup file"
    _pass=$((_pass + 1))
  else
    echo "FAIL: --apply creates a recovery-trail backup file"
    _fail=$((_fail + 1))
  fi

  # Case 4: dry-run (no --apply) never modifies the file.
  printf '2026-08-04T09:00:00Z\tmain\tfix-foo-bar\n' > "$_log"
  printf '2026-08-04T09:05:00Z\tmain\tfix-foo-bar\n' >> "$_log"
  _before_hash=$(shasum "$_log" | awk '{print $1}')
  CLAUDE_HOOK_SELFTEST=0 bash "$0" --file "$_log" >/dev/null 2>&1
  _after_hash=$(shasum "$_log" | awk '{print $1}')
  if [ "$_before_hash" = "$_after_hash" ]; then
    echo "PASS: dry-run (no --apply) never modifies the file"
    _pass=$((_pass + 1))
  else
    echo "FAIL: dry-run (no --apply) never modifies the file"
    _fail=$((_fail + 1))
  fi

  echo ""
  echo "$_pass/$((_pass + _fail)) PASS"
  if [ "$_fail" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

# ── Main logic ────────────────────────────────────────────────────────────────

FILE="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude}/logs/session_index.log"
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --file) FILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$FILE" ]; then
  echo "No session_index.log at $FILE — nothing to do."
  exit 0
fi

BEFORE=$(wc -l < "$FILE" | tr -d ' ')

# Group by (day, branch, slug); keep the LAST occurrence's full line
# (file is append-only/chronological, so "last occurrence" == "most
# recent timestamp" for that group). O(n) single pass.
DEDUPED=$(awk -F'\t' '
  NF < 3 { next }  # skip malformed lines defensively
  {
    day = substr($1, 1, 10)
    key = day SUBSEP $2 SUBSEP $3
    if (!(key in seen)) {
      seen[key] = 1
      n++
      keys[n] = key
    }
    line[key] = $0
  }
  END {
    for (i = 1; i <= n; i++) print line[keys[i]]
  }
' "$FILE")

AFTER=$(printf '%s\n' "$DEDUPED" | grep -c . || true)

echo "session_index_dedup: $FILE"
echo "  before: $BEFORE rows"
echo "  after:  $AFTER rows (dropping $((BEFORE - AFTER)) duplicate rows)"

if [ "$APPLY" -eq 0 ]; then
  echo "Dry-run only — no changes written. Re-run with --apply to write $FILE in place."
  exit 0
fi

BACKUP="${FILE}.$(date +%Y%m%d_%H%M%S).bak"
cp -a "$FILE" "$BACKUP"
printf '%s\n' "$DEDUPED" > "$FILE"
echo "Applied. Original preserved at: $BACKUP"
