#!/usr/bin/env bash
# hook_events_load.sh — batch-loads hook_events_staging.jsonl into
# unified.duckdb's hook_events table (llm#950).
#
# WHY THIS EXISTS AS A SEPARATE, STANDALONE SCRIPT:
#   Hooks emit via hook_event_emit.sh, which appends one JSON line per event
#   to a spool file (no duckdb lock — see that script's header, and
#   log_session.sh's #710 header for the incident this design avoids: a
#   duckdb CLI write held an exclusive lock for ~100ms on every PostToolUse
#   event and starved the ETL's 3x10s retry window). This script is the
#   OTHER half of that split: it drains the spool into hook_events in a
#   batch, at a time contention is low.
#
#   It does NOT register its own launchd job. Per the housekeeping-framework
#   rule (reuse an existing scheduled slot before adding a new one), it is
#   called BY roborev_metrics_etl.sh at that script's existing ~02:00
#   launchd run — see the "Import hook_events" call site there.
#
# Idempotency:
#   hook_events has no natural unique key (auto-increment `id`), so this
#   script adds a UNIQUE index over the row's content
#   (session_id, hook_name, event_type, fired_at, output_preview) and loads
#   via INSERT OR IGNORE. Index creation is fail-open (wrapped, non-fatal) —
#   if it can't be created (e.g. pre-existing duplicate legacy rows), the
#   load still proceeds as a plain insert; idempotency degrades but nothing
#   breaks. On a table created fresh by this script (selftest, or a new
#   unified.duckdb), the index always succeeds.
#
# Safety:
#   - Atomic hand-off: the spool is `mv`'d to a timestamped import file
#     before reading, so hook_event_emit.sh calls that happen WHILE this
#     script runs land in a brand-new spool file at the canonical path and
#     are picked up whole on the NEXT run — never interleaved with the
#     in-flight read, never lost.
#   - Malformed lines: `read_json(..., ignore_errors = true)` skips any line
#     that fails to parse instead of aborting the whole batch.
#   - Always exits 0 (fail-open) outside --selftest: a broken loader must
#     never fail the parent ETL run that calls it.
#
# Usage:
#   hook_events_load.sh [--db PATH] [--spool PATH]
#   hook_events_load.sh --selftest
#
# Tracked in llm#950.

set -uo pipefail

LOGFILE="${HOME}/.claude/logs/hook_events_load.log"
log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" >> "$LOGFILE" 2>/dev/null || true
}

# ─── Schema (idempotent) ─────────────────────────────────────────────────────
_ensure_schema() {
  local db="$1"
  duckdb -init /dev/null "$db" -c "
    CREATE SEQUENCE IF NOT EXISTS hook_seq START 1;
    CREATE TABLE IF NOT EXISTS hook_events (
      id INTEGER PRIMARY KEY DEFAULT nextval('hook_seq'),
      session_id VARCHAR,
      hook_name VARCHAR,
      event_type VARCHAR,
      fired_at TIMESTAMP DEFAULT current_timestamp,
      duration_ms INTEGER,
      output_preview VARCHAR
    );
  " 2>/dev/null || true
  # Dedup index — separate statement so a failure here (e.g. pre-existing
  # duplicate rows in a long-lived production table) never blocks table
  # creation or the load below.
  duckdb -init /dev/null "$db" -c "
    CREATE UNIQUE INDEX IF NOT EXISTS hook_events_dedup_idx
      ON hook_events (session_id, hook_name, event_type, fired_at, output_preview);
  " 2>/dev/null || true
}

# ─── Import a single JSONL file (no rename dance — used directly by selftest
# to prove idempotency by calling it twice on the same file) ─────────────────
_import_file() {
  local db="$1" file="$2"
  [ -f "$file" ] || return 0
  duckdb -init /dev/null "$db" -c "
    INSERT OR IGNORE INTO hook_events (session_id, hook_name, event_type, output_preview, fired_at)
    SELECT
      session_id,
      hook_name,
      event_type,
      output_preview,
      CAST(ts AS TIMESTAMP) AS fired_at
    FROM read_json(
      '${file}',
      format        = 'newline_delimited',
      columns       = {ts: 'VARCHAR', session_id: 'VARCHAR',
                       hook_name: 'VARCHAR', event_type: 'VARCHAR',
                       output_preview: 'VARCHAR'},
      ignore_errors = true
    )
    WHERE session_id IS NOT NULL;
  " 2>/dev/null || { log "import_file: duckdb insert failed (non-fatal) file=${file}"; return 1; }
  return 0
}

# ─── Atomic hand-off drain: spool -> timestamped import file -> DB -> delete ─
_drain_spool() {
  local db="$1" spool="$2"
  if [ ! -f "$spool" ] || [ ! -s "$spool" ]; then
    log "drain_spool: SKIP (no pending events) spool=${spool}"
    return 0
  fi
  local import_file="${spool}.import.$(date +%s).$$"
  mv "$spool" "$import_file" 2>/dev/null || { log "drain_spool: mv failed spool=${spool}"; return 1; }
  log "drain_spool: start file=${import_file}"
  _import_file "$db" "$import_file"
  rm -f "$import_file" 2>/dev/null || true
  log "drain_spool: end file=${import_file}"
  return 0
}

_row_count() {
  local db="$1"
  duckdb -init /dev/null -noheader -list "$db" -c "SELECT count(*) FROM hook_events;" 2>/dev/null || echo 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; TOTAL=0
  _ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf '  PASS  %s\n' "$1"; }
  _fail() { TOTAL=$((TOTAL+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "${2:-}" "${3:-}"; }

  if ! command -v duckdb >/dev/null 2>&1; then
    echo "SKIP: duckdb not on PATH — cannot run hook_events_load.sh selftest"
    echo "selftest: 0/0 PASS"
    exit 0
  fi

  TMPDIR_ST=$(mktemp -d /tmp/hook_events_load_selftest_XXXXXX)
  trap 'rm -rf "$TMPDIR_ST"' EXIT
  DB="$TMPDIR_ST/unified.duckdb"
  _ensure_schema "$DB"

  _line() {
    # Args: session_id hook_name event_type preview -> one JSONL line
    printf '{"ts":"%s","session_id":"%s","hook_name":"%s","event_type":"%s","output_preview":"%s"}\n' \
      "2026-08-14T00:00:00Z" "$1" "$2" "$3" "$4"
  }

  # ── Case 1: malformed line is skipped, valid lines still load ───────────
  MALFORMED_FILE="$TMPDIR_ST/malformed.jsonl"
  {
    _line "s1" "hookA" "PreToolUse:blocked" "one"
    printf '%s\n' 'not valid json at all {{{'
    _line "s1" "hookB" "PreToolUse:blocked" "two"
  } > "$MALFORMED_FILE"
  _import_file "$DB" "$MALFORMED_FILE"
  CNT=$(_row_count "$DB")
  if [ "$CNT" = "2" ]; then
    _ok "malformed spool line is skipped; valid lines still load"
  else
    _fail "malformed spool line is skipped; valid lines still load" "$CNT" "2"
  fi

  # ── Case 2: loader is idempotent — importing the SAME file twice does not
  # duplicate rows (INSERT OR IGNORE against the dedup unique index) ──────
  _import_file "$DB" "$MALFORMED_FILE"
  CNT2=$(_row_count "$DB")
  if [ "$CNT2" = "2" ]; then
    _ok "re-importing the same file does not duplicate rows"
  else
    _fail "re-importing the same file does not duplicate rows" "$CNT2" "2"
  fi

  # ── Case 3: safe across a spool boundary — events written AFTER a drain
  # are neither lost nor merged into the batch that already completed;
  # they are picked up whole on the next drain call. ──────────────────────
  SPOOL="$TMPDIR_ST/hook_events_staging.jsonl"
  _line "s2" "hookC" "PreToolUse:blocked" "three" > "$SPOOL"
  _line "s2" "hookD" "PreToolUse:blocked" "four" >> "$SPOOL"
  _drain_spool "$DB" "$SPOOL"
  CNT3=$(_row_count "$DB")
  # Simulate an event emitted AFTER the drain (hook_event_emit.sh writes to
  # the now-fresh spool path, exactly as it would in production).
  _line "s2" "hookE" "PreToolUse:blocked" "five" > "$SPOOL"
  SPOOL_SURVIVED=0
  [ -f "$SPOOL" ] && [ -s "$SPOOL" ] && SPOOL_SURVIVED=1
  _drain_spool "$DB" "$SPOOL"
  CNT4=$(_row_count "$DB")
  if [ "$CNT3" = "4" ] && [ "$SPOOL_SURVIVED" = "1" ] && [ "$CNT4" = "5" ]; then
    _ok "events written after a drain survive and are picked up on the next drain (no loss, no duplication)"
  else
    _fail "events written after a drain survive and are picked up on the next drain" \
      "cnt3=${CNT3} survived=${SPOOL_SURVIVED} cnt4=${CNT4}" "cnt3=4 survived=1 cnt4=5"
  fi

  # ── Case 4: drain on an absent/empty spool is a silent no-op, never fails ─
  RC=0
  _drain_spool "$DB" "$TMPDIR_ST/does_not_exist.jsonl" || RC=$?
  if [ "$RC" -eq 0 ]; then
    _ok "drain on an absent spool is a no-op (exit 0)"
  else
    _fail "drain on an absent spool is a no-op (exit 0)" "$RC" "0"
  fi

  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL OPERATION
# ═══════════════════════════════════════════════════════════════════════════
DB="${HOME}/.claude/logs/unified.duckdb"
SPOOL="${HOME}/.claude/logs/hook_events_staging.jsonl"

while [ $# -gt 0 ]; do
  case "$1" in
    --db)    DB="$2"; shift 2 ;;
    --spool) SPOOL="$2"; shift 2 ;;
    *) echo "Usage: hook_events_load.sh [--db PATH] [--spool PATH] | --selftest" >&2; exit 0 ;;
  esac
done

if [ ! -f "$DB" ]; then
  log "SKIP: db not found at ${DB}"
  exit 0
fi

_ensure_schema "$DB"
_drain_spool "$DB" "$SPOOL"
exit 0
