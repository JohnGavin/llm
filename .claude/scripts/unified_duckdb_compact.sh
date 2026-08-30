#!/usr/bin/env bash
# unified_duckdb_compact.sh — compact unified.duckdb by full rewrite (EXPORT/IMPORT),
# with per-table row-count parity verification against the exact snapshot exported.
#
# JohnGavin/llm#884 + JohnGavin/llm#850 — unified.duckdb does not reclaim freed
# pages on DELETE/UPDATE, and is written one-row-per-transaction very frequently
# (hook_events etc.), producing near-empty 256 KB blocks. Measured 2026-08-30:
# 3.7 GiB on disk (database_size), 15350 total_blocks / 15285 used_blocks /
# 65 free_blocks — i.e. DuckDB considers almost every block "used" even though
# the live data is tiny (EXPORT DATABASE of the same 35 tables produced 2.2 MB
# of Parquet; IMPORT into a fresh file produced a 27 MB .duckdb, a ~146x
# reduction from the 4.02 GB live file measured at that moment).
#
# CRITICAL — this script NEVER writes to its --source path. It always produces
# a NEW file at --dest. Swapping the compacted file into place (the `mv` dance)
# is printed as an instruction, never executed here — that is a deliberate,
# separate, human-supervised step (see the printed SWAP INSTRUCTIONS block).
#
# Method: EXPORT DATABASE (Parquet, ZSTD) then IMPORT DATABASE, matching the
# existing unified_duckdb_backup.sh convention (llm#228) rather than inventing
# a second export mechanism. Row-count parity is captured INSIDE the same
# transaction as the export (BEGIN ... COPY (counts) TO csv ... EXPORT DATABASE
# ... COMMIT) so the recorded source counts are guaranteed to match the exact
# MVCC snapshot that was exported, not a racing later/earlier read. This
# matters because the live DB is under concurrent write load: a `cp` of the
# raw .duckdb file while a writer holds the file (verified live, 2026-08-30)
# produced a truncated/inconsistent copy that failed to open at all
# ("AddAndRegisterBlock called with a transient block id"). EXPORT DATABASE
# against the live file directly (never `cp`) is the only safe read path here
# — this is also why unified_duckdb_backup.sh never does `cp` either.
#
# Lock contention is real but transient: hooks/launchd jobs periodically hold
# an exclusive lock for a few seconds. Verified live 2026-08-30: opening
# `--readonly` failed once with "Conflicting lock is held ... (PID N)" and
# succeeded on retry ~seconds later against the same file with no other
# change. This script retries the EXPORT step with backoff rather than
# failing on the first transient conflict.
#
# Usage:
#   unified_duckdb_compact.sh --source PATH --dest PATH [--apply] [--dry-run]
#                              [--retries N] [--keep-export] [--help]
#
# Flags:
#   --source PATH    source DuckDB file to compact (default:
#                     ~/.claude/logs/unified.duckdb). READ ONLY — never
#                     modified by this script.
#   --dest PATH      output path for the compacted DB. REQUIRED unless
#                     --dry-run (dry-run does not need a real dest). Must
#                     NOT equal --source — the script refuses if it does.
#   --apply          actually perform the compaction (default: dry-run).
#   --dry-run        (default) show table inventory + sizes; verify the
#                     source is readable; do not write --dest at all.
#   --retries N      max attempts for the EXPORT step on lock conflict
#                     (default: 5, exponential backoff capped at 30s).
#   --keep-export    keep the intermediate Parquet export directory instead
#                     of deleting it after a successful --apply run.
#   --help           show this message.
#
# Exit codes:
#   0  success (dry-run completed, or --apply completed with verified parity)
#   1  usage error / precondition failure (e.g. dest == source, source missing)
#   2  DuckDB operation failed (export/import) after retries exhausted
#   3  row-count parity FAILED or COULD NOT BE VERIFIED for one or more
#      tables — per checks-must-distinguish-unknown, an unverifiable table
#      is treated the same as a mismatch, never silently passed
#
# Self-test (no subprocess recursion):
#   SELFTEST=1 bash unified_duckdb_compact.sh
#
# Tracked in JohnGavin/llm#884, JohnGavin/llm#850.

# Portability: may be invoked by launchd with a bare PATH.
export PATH="/usr/local/bin:/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -uo pipefail
# NOTE: deliberately NOT `set -e` — the retry loop around the DuckDB CLI needs
# to observe non-zero exits without aborting the script; failures are checked
# explicitly at every step instead.

# ── Anti-fork-bomb depth guard ────────────────────────────────────────────────
_DEPTH="${_UNIFIED_DUCKDB_COMPACT_DEPTH:-0}"
if [ "$_DEPTH" -gt 2 ]; then
  echo "ERROR: recursion depth $_DEPTH — aborting" >&2
  exit 2
fi
export _UNIFIED_DUCKDB_COMPACT_DEPTH=$((_DEPTH + 1))

# ── Defaults ──────────────────────────────────────────────────────────────────
SOURCE_DB="${HOME}/.claude/logs/unified.duckdb"
DEST_DB=""
MODE="dry-run"
MAX_RETRIES=5
KEEP_EXPORT=0
LOGFILE="${HOME}/.claude/logs/unified_duckdb_compact.log"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" | tee -a "$LOGFILE" 2>/dev/null || echo "${ts} $*"
}

die() { log "ERROR: $*"; echo "ERROR: $*" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Usage: unified_duckdb_compact.sh --source PATH --dest PATH [--apply] [--dry-run]
                                  [--retries N] [--keep-export] [--help]

See header comment in this file for full flag documentation.

Never swaps the compacted file into place — prints the swap instructions and
stops. Tracked in JohnGavin/llm#884, JohnGavin/llm#850.
EOF
}

find_duckdb() {
  if command -v duckdb >/dev/null 2>&1; then
    command -v duckdb
    return 0
  fi
  for candidate in /nix/store/*/bin/duckdb /opt/homebrew/bin/duckdb /usr/local/bin/duckdb; do
    if [ -x "$candidate" ] 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# duckdb_ro_json <db> <sql> — run one read-only statement, no init-file noise,
# JSON output. Used for metadata queries (table list, sizes) that don't need
# to share a transaction with anything else.
duckdb_ro_json() {
  local db="$1" sql="$2" duckdb_bin
  duckdb_bin=$(find_duckdb) || return 127
  "$duckdb_bin" -readonly -init /dev/null -json "$db" -c "$sql" 2>&1
}

duckdb_ro_csv_noheader() {
  local db="$1" sql="$2" duckdb_bin
  duckdb_bin=$(find_duckdb) || return 127
  "$duckdb_bin" -readonly -init /dev/null -csv -noheader "$db" -c "$sql" 2>&1
}

# is_lock_conflict <output> — true if the DuckDB CLI output text is the
# transient "Conflicting lock is held" error rather than a real failure.
is_lock_conflict() {
  echo "$1" | grep -qi "Conflicting lock is held"
}

# list_tables <db> — newline-separated table names, sorted. Empty + exit
# non-zero on failure (never silently returns "no tables" for an unreadable DB).
list_tables() {
  local db="$1" out ec
  out=$(duckdb_ro_csv_noheader "$db" "SELECT table_name FROM duckdb_tables() ORDER BY table_name;")
  ec=$?
  if [ "$ec" -ne 0 ]; then
    return "$ec"
  fi
  echo "$out"
  return 0
}

# build_union_count_sql <tables-newline-separated> — builds a
# `SELECT 'tbl' AS table_name, count(*) AS n_rows FROM "tbl" UNION ALL ...`
# statement across every table so a single query captures every table's row
# count in one MVCC snapshot.
build_union_count_sql() {
  local tables="$1" sql="" first=1 t
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if [ "$first" -eq 1 ]; then
      sql="SELECT '${t}' AS table_name, count(*) AS n_rows FROM \"${t}\""
      first=0
    else
      sql="${sql} UNION ALL SELECT '${t}', count(*) FROM \"${t}\""
    fi
  done <<EOF
$tables
EOF
  echo "$sql"
}

# export_with_retry <source_db> <export_dir> <counts_csv> <union_sql> <max_retries>
# Runs, in ONE duckdb session and ONE transaction:
#   BEGIN TRANSACTION;
#   COPY (<union_sql>) TO '<counts_csv>' (HEADER, DELIMITER ',');
#   EXPORT DATABASE '<export_dir>' (FORMAT PARQUET, COMPRESSION ZSTD);
#   COMMIT;
# so the recorded counts are guaranteed to match the exported snapshot exactly.
# Retries on transient lock conflicts only; any other error aborts immediately.
export_with_retry() {
  local source_db="$1" export_dir="$2" counts_csv="$3" union_sql="$4" max_retries="$5"
  local duckdb_bin sql_file attempt=1 out ec backoff
  duckdb_bin=$(find_duckdb) || { log "ERROR: duckdb binary not found"; return 127; }

  sql_file=$(mktemp /tmp/unified_duckdb_compact_export_XXXXXX.sql)
  {
    echo "BEGIN TRANSACTION;"
    echo "COPY (${union_sql}) TO '${counts_csv}' (HEADER, DELIMITER ',');"
    echo "EXPORT DATABASE '${export_dir}' (FORMAT PARQUET, COMPRESSION ZSTD);"
    echo "COMMIT;"
  } > "$sql_file"

  while [ "$attempt" -le "$max_retries" ]; do
    rm -rf "$export_dir"
    out=$("$duckdb_bin" -readonly -init /dev/null "$source_db" < "$sql_file" 2>&1)
    ec=$?
    if [ "$ec" -eq 0 ]; then
      rm -f "$sql_file"
      return 0
    fi
    if is_lock_conflict "$out"; then
      backoff=$(( attempt * attempt ))
      [ "$backoff" -gt 30 ] && backoff=30
      log "WARN: transient lock conflict on export attempt ${attempt}/${max_retries} — retrying in ${backoff}s"
      sleep "$backoff"
      attempt=$((attempt + 1))
      continue
    fi
    log "ERROR: export failed (non-lock error): $out"
    rm -f "$sql_file"
    return 2
  done

  log "ERROR: export failed after ${max_retries} attempts (persistent lock conflict)"
  rm -f "$sql_file"
  return 2
}

# import_fresh <export_dir> <dest_db> — imports a Parquet export into a
# brand-new DuckDB file. Refuses if dest_db already exists (caller must
# remove it deliberately first — this script never silently overwrites).
import_fresh() {
  local export_dir="$1" dest_db="$2" duckdb_bin out ec
  duckdb_bin=$(find_duckdb) || { log "ERROR: duckdb binary not found"; return 127; }
  if [ -e "$dest_db" ]; then
    log "ERROR: dest already exists: $dest_db (refusing to overwrite)"
    return 1
  fi
  out=$("$duckdb_bin" -init /dev/null "$dest_db" -c "IMPORT DATABASE '${export_dir}';" 2>&1)
  ec=$?
  if [ "$ec" -ne 0 ]; then
    log "ERROR: import failed: $out"
    rm -f "$dest_db"
    return 2
  fi
  return 0
}

# verify_parity <source_counts_csv> <dest_db> <union_sql> — re-runs the same
# union-count query against dest and diffs against the recorded source counts.
# Returns 0 only if EVERY table's count matches exactly. A table present in
# source but missing (or unqueryable) in dest is a FAILURE, never a skip —
# per checks-must-distinguish-unknown, "could not verify" != "verified OK".
verify_parity() {
  local source_counts_csv="$1" dest_db="$2" union_sql="$3"
  local dest_counts_csv mismatches=0 total=0 line tbl src_n dst_n

  dest_counts_csv=$(mktemp /tmp/unified_duckdb_compact_destcounts_XXXXXX.csv)
  local duckdb_bin
  duckdb_bin=$(find_duckdb) || { log "ERROR: duckdb binary not found"; return 127; }

  if ! "$duckdb_bin" -readonly -init /dev/null "$dest_db" \
        -c "COPY (${union_sql}) TO '${dest_counts_csv}' (HEADER, DELIMITER ',');" \
        > /tmp/unified_duckdb_compact_destcount_err.log 2>&1; then
    log "ERROR: could not query dest for row counts — parity UNVERIFIABLE (treated as failure)"
    cat /tmp/unified_duckdb_compact_destcount_err.log >&2
    rm -f "$dest_counts_csv" /tmp/unified_duckdb_compact_destcount_err.log
    return 3
  fi

  # Join on table_name (skip header line 1 of each CSV).
  while IFS=, read -r tbl src_n; do
    [ "$tbl" = "table_name" ] && continue
    [ -z "$tbl" ] && continue
    total=$((total + 1))
    dst_n=$(awk -F, -v t="$tbl" 'NR>1 && $1==t {print $2}' "$dest_counts_csv")
    if [ -z "$dst_n" ]; then
      log "PARITY FAIL: table '$tbl' present in source (n=$src_n) but MISSING from dest — unverifiable, treated as failure"
      mismatches=$((mismatches + 1))
      continue
    fi
    if [ "$src_n" != "$dst_n" ]; then
      log "PARITY FAIL: table '$tbl' source=$src_n dest=$dst_n"
      mismatches=$((mismatches + 1))
    else
      log "PARITY OK: table '$tbl' n=$src_n"
    fi
  done < "$source_counts_csv"

  rm -f "$dest_counts_csv" /tmp/unified_duckdb_compact_destcount_err.log

  if [ "$mismatches" -gt 0 ]; then
    log "PARITY: ${mismatches}/${total} tables FAILED — aborting, dest is NOT safe to swap in"
    return 3
  fi
  log "PARITY: ${total}/${total} tables verified OK"
  return 0
}

human_size() {
  local path="$1"
  if [ -e "$path" ]; then
    du -sh "$path" 2>/dev/null | cut -f1
  else
    echo "n/a"
  fi
}

# ── Self-test ──────────────────────────────────────────────────────────────────
if [ "${SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  _assert() {
    local label="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
      PASS=$((PASS + 1)); echo "  PASS [$label]"
    else
      FAIL=$((FAIL + 1)); echo "  FAIL [$label]: expected='$expected' got='$result'"
    fi
  }

  echo "unified_duckdb_compact selftest: running..."

  # Case 1: find_duckdb locates a binary (or legitimately doesn't — either is
  # a valid environment fact, but the function must not hang or crash).
  _bin=$(find_duckdb 2>/dev/null || true)
  if [ -n "$_bin" ]; then _assert "find_duckdb_returns_path" "yes" "yes"
  else _assert "find_duckdb_returns_path" "no (duckdb not on PATH in this env)" "yes — SKIP-ACCEPTABLE"; fi

  # Case 2: is_lock_conflict detects the known error string
  if is_lock_conflict "Error: unable to open database: IO Error: Could not set lock on file \"x\": Conflicting lock is held in /bin/duckdb (PID 1) by user x"; then
    _assert "lock_conflict_detected" "yes" "yes"
  else
    _assert "lock_conflict_detected" "no" "yes"
  fi

  # Case 3: is_lock_conflict does NOT fire on an unrelated error
  if is_lock_conflict "Error: Catalog Error: Table with name nonexistent does not exist!"; then
    _assert "lock_conflict_false_positive" "yes (BUG)" "no"
  else
    _assert "lock_conflict_false_positive" "no" "no"
  fi

  # Case 4: build_union_count_sql produces a UNION ALL across all given tables
  _sql=$(build_union_count_sql "$(printf 'a\nb\nc\n')")
  _n_union=$(echo "$_sql" | grep -o "UNION ALL" | wc -l | tr -d ' ')
  _assert "union_sql_has_2_unions_for_3_tables" "$_n_union" "2"
  echo "$_sql" | grep -q '"a"' && echo "$_sql" | grep -q '"c"' \
    && _assert "union_sql_quotes_table_names" "yes" "yes" \
    || _assert "union_sql_quotes_table_names" "no" "yes"

  # Case 5: import_fresh refuses to overwrite an existing dest
  _tmpdest=$(mktemp /tmp/selftest_compact_dest_XXXXXX.duckdb)
  import_fresh "/tmp/nonexistent_export_dir_$$" "$_tmpdest" > /tmp/selftest_import_refuse.log 2>&1
  _ec=$?
  _assert "import_fresh_refuses_existing_dest" "$_ec" "1"
  rm -f "$_tmpdest" /tmp/selftest_import_refuse.log

  # Case 6: verify_parity treats a table missing from dest as FAILURE (exit 3),
  # never as a silent pass. Build a tiny real source+dest pair to test this
  # honestly rather than mocking the CSV shape.
  if [ -n "$_bin" ]; then
    _src_db=$(mktemp /tmp/selftest_compact_src_XXXXXX.duckdb); rm -f "$_src_db"
    _dst_db=$(mktemp /tmp/selftest_compact_dst_XXXXXX.duckdb); rm -f "$_dst_db"
    "$_bin" -init /dev/null "$_src_db" -c "CREATE TABLE t1 AS SELECT 1 AS x; CREATE TABLE t2 AS SELECT 1 AS x;" >/dev/null 2>&1
    "$_bin" -init /dev/null "$_dst_db" -c "CREATE TABLE t1 AS SELECT 1 AS x;" >/dev/null 2>&1
    _union=$(build_union_count_sql "$(printf 't1\nt2\n')")
    _counts_csv=$(mktemp /tmp/selftest_compact_counts_XXXXXX.csv)
    "$_bin" -readonly -init /dev/null "$_src_db" -c "COPY (${_union}) TO '${_counts_csv}' (HEADER, DELIMITER ',');" >/dev/null 2>&1
    verify_parity "$_counts_csv" "$_dst_db" "$_union" > /tmp/selftest_parity_missing.log 2>&1
    _ec=$?
    _assert "verify_parity_fails_on_missing_table" "$_ec" "3"
    # The union query itself fails when it references a table absent from
    # dest (Catalog Error), so the coarser "UNVERIFIABLE" branch fires rather
    # than the per-table "MISSING from dest" branch — both are FAILUREs
    # (exit 3), never a silent pass, which is the property under test.
    grep -q "UNVERIFIABLE" /tmp/selftest_parity_missing.log \
      && _assert "verify_parity_reports_unverifiable_reason" "yes" "yes" \
      || _assert "verify_parity_reports_unverifiable_reason" "no" "yes"
    rm -f "$_src_db" "$_dst_db" "$_counts_csv" /tmp/selftest_parity_missing.log

    # Case 7: verify_parity passes when counts genuinely match
    _src_db2=$(mktemp /tmp/selftest_compact_src2_XXXXXX.duckdb); rm -f "$_src_db2"
    _dst_db2=$(mktemp /tmp/selftest_compact_dst2_XXXXXX.duckdb); rm -f "$_dst_db2"
    "$_bin" -init /dev/null "$_src_db2" -c "CREATE TABLE t1 AS SELECT 1 AS x;" >/dev/null 2>&1
    "$_bin" -init /dev/null "$_dst_db2" -c "CREATE TABLE t1 AS SELECT 1 AS x;" >/dev/null 2>&1
    _union2=$(build_union_count_sql "$(printf 't1\n')")
    _counts_csv2=$(mktemp /tmp/selftest_compact_counts2_XXXXXX.csv)
    "$_bin" -readonly -init /dev/null "$_src_db2" -c "COPY (${_union2}) TO '${_counts_csv2}' (HEADER, DELIMITER ',');" >/dev/null 2>&1
    verify_parity "$_counts_csv2" "$_dst_db2" "$_union2" > /tmp/selftest_parity_ok.log 2>&1
    _ec=$?
    _assert "verify_parity_passes_on_match" "$_ec" "0"
    rm -f "$_src_db2" "$_dst_db2" "$_counts_csv2" /tmp/selftest_parity_ok.log

    # Case 8: verify_parity FAILS (never silently passes) when a count differs
    _src_db3=$(mktemp /tmp/selftest_compact_src3_XXXXXX.duckdb); rm -f "$_src_db3"
    _dst_db3=$(mktemp /tmp/selftest_compact_dst3_XXXXXX.duckdb); rm -f "$_dst_db3"
    "$_bin" -init /dev/null "$_src_db3" -c "CREATE TABLE t1 AS SELECT * FROM range(5);" >/dev/null 2>&1
    "$_bin" -init /dev/null "$_dst_db3" -c "CREATE TABLE t1 AS SELECT * FROM range(3);" >/dev/null 2>&1
    _union3=$(build_union_count_sql "$(printf 't1\n')")
    _counts_csv3=$(mktemp /tmp/selftest_compact_counts3_XXXXXX.csv)
    "$_bin" -readonly -init /dev/null "$_src_db3" -c "COPY (${_union3}) TO '${_counts_csv3}' (HEADER, DELIMITER ',');" >/dev/null 2>&1
    verify_parity "$_counts_csv3" "$_dst_db3" "$_union3" > /tmp/selftest_parity_mismatch.log 2>&1
    _ec=$?
    _assert "verify_parity_fails_on_count_mismatch" "$_ec" "3"
    rm -f "$_src_db3" "$_dst_db3" "$_counts_csv3" /tmp/selftest_parity_mismatch.log
  else
    echo "  SKIP [verify_parity_* cases] — duckdb not on PATH in this env"
  fi

  # Case 9: depth guard exported
  _depth_val="${_UNIFIED_DUCKDB_COMPACT_DEPTH:-0}"
  if [ "$_depth_val" -ge 1 ]; then _assert "depth_guard_increments" "yes" "yes"
  else _assert "depth_guard_increments" "no" "yes"; fi

  echo ""
  TOTAL=$((PASS + FAIL))
  if [ "$FAIL" -eq 0 ]; then
    echo "${PASS}/${TOTAL} PASS"
    exit 0
  else
    echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
    exit 1
  fi
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --source)      SOURCE_DB="$2"; shift 2 ;;
    --dest)        DEST_DB="$2"; shift 2 ;;
    --apply)       MODE="apply"; shift ;;
    --dry-run)     MODE="dry-run"; shift ;;
    --retries)     MAX_RETRIES="$2"; shift 2 ;;
    --keep-export) KEEP_EXPORT=1; shift ;;
    --help|-h)     usage; exit 0 ;;
    *)             die "Unknown argument: $1 (try --help)" ;;
  esac
done

[ -f "$SOURCE_DB" ] || die "source DB not found: $SOURCE_DB"

if [ "$MODE" = "apply" ]; then
  [ -n "$DEST_DB" ] || die "--dest is required with --apply (this script never writes in-place)"
  # Resolve to absolute-ish comparison; refuse if dest resolves to source.
  if [ "$(cd "$(dirname "$SOURCE_DB")" 2>/dev/null && pwd)/$(basename "$SOURCE_DB")" = \
       "$(cd "$(dirname "$DEST_DB")" 2>/dev/null && pwd)/$(basename "$DEST_DB")" ]; then
    die "--dest must not equal --source — this script never writes in-place"
  fi
  [ -e "$DEST_DB" ] && die "--dest already exists: $DEST_DB (remove it first, or pick a new path)"
fi

log "unified_duckdb_compact: mode=$MODE source=$SOURCE_DB dest=${DEST_DB:-<dry-run, none>}"

BEFORE_SIZE=$(human_size "$SOURCE_DB")
log "source size: $BEFORE_SIZE"

TABLES=$(list_tables "$SOURCE_DB")
if [ -z "$TABLES" ]; then
  die "could not list tables in source (unreadable, locked, or empty DB)"
fi
N_TABLES=$(echo "$TABLES" | grep -c .)
log "source has $N_TABLES tables"

if [ "$MODE" = "dry-run" ]; then
  log "DRY-RUN: table inventory:"
  echo "$TABLES" | while IFS= read -r t; do
    [ -z "$t" ] && continue
    log "  - $t"
  done
  log "DRY-RUN: would export+import to produce a compacted copy at the given --dest."
  log "DRY-RUN: no files written. Re-run with --apply --dest PATH to actually compact."
  exit 0
fi

# ── --apply path ────────────────────────────────────────────────────────────
UNION_SQL=$(build_union_count_sql "$TABLES")
EXPORT_DIR=$(mktemp -d /tmp/unified_duckdb_compact_export_XXXXXX)
SOURCE_COUNTS_CSV=$(mktemp /tmp/unified_duckdb_compact_srccounts_XXXXXX.csv)

log "exporting (with row-count snapshot captured in the same transaction)..."
if ! export_with_retry "$SOURCE_DB" "$EXPORT_DIR" "$SOURCE_COUNTS_CSV" "$UNION_SQL" "$MAX_RETRIES"; then
  rm -rf "$EXPORT_DIR" "$SOURCE_COUNTS_CSV"
  die "export failed — see log for details" "$?"
fi
EXPORT_SIZE=$(human_size "$EXPORT_DIR")
log "export complete: $EXPORT_SIZE at $EXPORT_DIR"

log "importing into fresh dest: $DEST_DB"
if ! import_fresh "$EXPORT_DIR" "$DEST_DB"; then
  ec=$?
  [ "$KEEP_EXPORT" -eq 0 ] && rm -rf "$EXPORT_DIR"
  rm -f "$SOURCE_COUNTS_CSV"
  die "import failed — see log for details" "$ec"
fi

log "verifying per-table row-count parity..."
if ! verify_parity "$SOURCE_COUNTS_CSV" "$DEST_DB" "$UNION_SQL"; then
  ec=$?
  log "ABORTING — dest is NOT verified and must NOT be swapped in: $DEST_DB"
  rm -f "$SOURCE_COUNTS_CSV"
  [ "$KEEP_EXPORT" -eq 0 ] && rm -rf "$EXPORT_DIR"
  exit "$ec"
fi

AFTER_SIZE=$(human_size "$DEST_DB")
rm -f "$SOURCE_COUNTS_CSV"
if [ "$KEEP_EXPORT" -eq 0 ]; then
  rm -rf "$EXPORT_DIR"
else
  log "kept export dir (--keep-export): $EXPORT_DIR"
fi

log "unified_duckdb_compact: SUCCESS"
log "  source: $SOURCE_DB ($BEFORE_SIZE)"
log "  dest:   $DEST_DB ($AFTER_SIZE)"
log ""
log "SWAP INSTRUCTIONS (not executed — run these yourself, after quiescing writers):"
TS=$(date -u +%Y%m%d_%H%M%S)
log "  mv \"$SOURCE_DB\" \"${SOURCE_DB}.pre-compact-${TS}\" && mv \"$DEST_DB\" \"$SOURCE_DB\""
log ""
log "Verify after swap: duckdb -readonly -init /dev/null \"$SOURCE_DB\" -c 'PRAGMA database_size;'"

exit 0
