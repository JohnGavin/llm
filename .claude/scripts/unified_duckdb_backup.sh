#!/usr/bin/env bash
# unified_duckdb_backup.sh — WAL-safe daily backup of unified.duckdb to Dropbox.
#
# Default backup target is Dropbox (`~/Dropbox/Backups/unified_duckdb/`) because
# Dropbox sync is active on this Mac while iCloud Drive is not (verified via
# absence of synced content in `~/Library/Mobile Documents/com~apple~CloudDocs/`).
# Override via `BACKUP_ROOT=...` env var or `--dest DIR` flag.
#
# Strategy: DuckDB EXPORT DATABASE (Parquet) — reads a consistent MVCC snapshot
# while the DB may be live; produces a portable directory of Parquet files +
# schema.sql that can be restored with IMPORT DATABASE.
#
# Flags:
#   --dry-run   (default) show what would be backed up; no writes
#   --apply     write backup to Dropbox (or whatever BACKUP_ROOT resolves to)
#   --db PATH   override source DB path (default: ~/.claude/logs/unified.duckdb)
#   --dest DIR  override backup root directory
#   --prune     delete daily exports older than 30 days and monthly exports older than 365 days
#   --help      usage
#
# Self-test (no subprocess recursion — per PR #253 pattern):
#   SELFTEST=1 bash unified_duckdb_backup.sh
#   → calls internal functions directly; exits 0 on pass, 1 on any failure.
#   Must complete in <10s.
#
# Backup layout:
#   <BACKUP_ROOT>/
#     YYYY-MM-DD/           ← daily export directory
#       schema.sql
#       *.parquet           ← one file per table
#
# Retention:
#   Daily exports  → kept 30 days
#   Monthly anchor → last daily of each month, kept 365 days
#
# Tracked in llm#228.
#
# Portability: may be invoked by launchd with a bare PATH.
export PATH="/usr/local/bin:/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

# ── Anti-fork-bomb depth guard ────────────────────────────────────────────────
# Must appear before any code that could invoke this script recursively.
_DEPTH="${_UNIFIED_DUCKDB_BACKUP_DEPTH:-0}"
if [ "$_DEPTH" -gt 2 ]; then
  echo "ERROR: recursion depth $_DEPTH — aborting" >&2
  exit 2
fi
export _UNIFIED_DUCKDB_BACKUP_DEPTH=$((_DEPTH + 1))

# ── Paths / defaults ──────────────────────────────────────────────────────────
UNIFIED_DB="${UNIFIED_DB:-${HOME}/.claude/logs/unified.duckdb}"
# Dropbox sync root — `~/Dropbox` symlinks to `~/Library/CloudStorage/Dropbox`
# on macOS when the Dropbox client is installed. Override with BACKUP_ROOT.
DROPBOX_ROOT="${HOME}/Dropbox"
BACKUP_ROOT="${BACKUP_ROOT:-${DROPBOX_ROOT}/Backups/unified_duckdb}"
LOGFILE="${HOME}/.claude/logs/unified_duckdb_backup.log"
DAILY_RETAIN_DAYS=30
MONTHLY_RETAIN_DAYS=365

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "${ts} $*" | tee -a "$LOGFILE" 2>/dev/null || true
}

die() { log "ERROR: $*"; echo "ERROR: $*" >&2; exit 1; }

# ── Helper: find duckdb binary ────────────────────────────────────────────────
find_duckdb() {
  # Prefer nix-store duckdb (pinned version), fall back to PATH
  if command -v duckdb >/dev/null 2>&1; then
    command -v duckdb
    return 0
  fi
  # Try common Homebrew/Nix paths
  for candidate in \
    /nix/store/*/bin/duckdb \
    /opt/homebrew/bin/duckdb \
    /usr/local/bin/duckdb; do
    if [ -x "$candidate" ] 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# ── Helper: today's date ──────────────────────────────────────────────────────
today_date() {
  date -u '+%Y-%m-%d'
}

# ── Helper: month anchor (last day of previous calendar month) ────────────────
# We anchor monthly backups to the 1st of the current month so we keep
# exactly one backup per calendar month. A daily backup taken on the 1st
# that still exists after pruning becomes the monthly anchor automatically.
is_monthly_anchor() {
  local dir_date="$1"
  # Extract day portion
  local day
  day=$(echo "$dir_date" | cut -d'-' -f3)
  # Keep the 1st of every month as the monthly anchor
  [ "$day" = "01" ]
}

# ── Core function: perform_backup ────────────────────────────────────────────
# Args: <db_path> <backup_root> <date_str> <apply: 0|1>
# Returns: 0 on success, 1 on failure
perform_backup() {
  local db_path="$1"
  local backup_root="$2"
  local date_str="$3"
  local apply="$4"

  local dest_dir="${backup_root}/${date_str}"

  if [ ! -f "$db_path" ]; then
    log "WARN: source DB not found: $db_path (skipping)"
    return 0
  fi

  local duckdb_bin
  if ! duckdb_bin=$(find_duckdb); then
    die "duckdb binary not found — install duckdb or ensure it is in PATH"
  fi

  # Verify DB is readable
  if ! "$duckdb_bin" "$db_path" -c ".tables" >/dev/null 2>&1; then
    die "cannot open DB for reading: $db_path"
  fi

  if [ "$apply" = "0" ]; then
    log "DRY-RUN: would export $db_path → $dest_dir"
    # Show table counts as a sanity check
    log "DRY-RUN: table inventory:"
    "$duckdb_bin" "$db_path" -c \
      "SELECT table_name, estimated_size FROM duckdb_tables() ORDER BY table_name" \
      2>/dev/null | while IFS= read -r line; do log "  $line"; done || true
    return 0
  fi

  # --apply path: create destination and export
  log "APPLY: exporting $db_path → $dest_dir"

  # Sync-root parent (Dropbox / iCloud / NAS) may need to exist
  mkdir -p "$backup_root"

  if [ -d "$dest_dir" ]; then
    log "WARN: destination already exists ($dest_dir) — skipping (use --prune to clean old exports)"
    return 0
  fi

  mkdir -p "$dest_dir"

  # EXPORT DATABASE: WAL-safe consistent Parquet snapshot
  # The single-quoted path must be escaped for the SQL string literal.
  local export_sql
  export_sql="EXPORT DATABASE '${dest_dir}' (FORMAT PARQUET, COMPRESSION ZSTD);"

  if "$duckdb_bin" "$db_path" -c "$export_sql"; then
    log "OK: export complete → $dest_dir"
    # Log sizes
    local export_size
    export_size=$(du -sh "$dest_dir" 2>/dev/null | cut -f1 || echo "unknown")
    log "OK: export size = $export_size"
  else
    log "ERROR: export failed"
    rm -rf "$dest_dir"
    return 1
  fi

  return 0
}

# ── Core function: prune_old_backups ──────────────────────────────────────────
# Args: <backup_root> <apply: 0|1>
prune_old_backups() {
  local backup_root="$1"
  local apply="$2"

  if [ ! -d "$backup_root" ]; then
    log "PRUNE: backup root does not exist ($backup_root) — nothing to prune"
    return 0
  fi

  local today_epoch
  today_epoch=$(date -u '+%s' 2>/dev/null || date '+%s')

  # Iterate over YYYY-MM-DD subdirectories
  for dir in "${backup_root}"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
    [ -d "$dir" ] || continue
    local dir_date
    dir_date=$(basename "$dir")

    # Compute age in days
    local dir_epoch
    # macOS date -j -f: convert date string to epoch
    if dir_epoch=$(date -j -f '%Y-%m-%d' "$dir_date" '+%s' 2>/dev/null); then
      local age_days=$(( (today_epoch - dir_epoch) / 86400 ))
    else
      # GNU date fallback
      dir_epoch=$(date -d "$dir_date" '+%s' 2>/dev/null || echo "0")
      local age_days=$(( (today_epoch - dir_epoch) / 86400 ))
    fi

    # Monthly anchors (1st of each month) are retained for MONTHLY_RETAIN_DAYS
    if is_monthly_anchor "$dir_date"; then
      if [ "$age_days" -gt "$MONTHLY_RETAIN_DAYS" ]; then
        if [ "$apply" = "0" ]; then
          log "PRUNE DRY-RUN: would delete monthly anchor $dir (${age_days}d old)"
        else
          log "PRUNE: deleting monthly anchor $dir (${age_days}d old)"
          rm -rf "$dir"
        fi
      else
        log "PRUNE: keeping monthly anchor $dir (${age_days}d old, retain=${MONTHLY_RETAIN_DAYS}d)"
      fi
    else
      # Daily exports retained for DAILY_RETAIN_DAYS
      if [ "$age_days" -gt "$DAILY_RETAIN_DAYS" ]; then
        if [ "$apply" = "0" ]; then
          log "PRUNE DRY-RUN: would delete daily $dir (${age_days}d old)"
        else
          log "PRUNE: deleting daily $dir (${age_days}d old)"
          rm -rf "$dir"
        fi
      else
        log "PRUNE: keeping daily $dir (${age_days}d old, retain=${DAILY_RETAIN_DAYS}d)"
      fi
    fi
  done
}

# ── Self-test (no subprocess recursion — per PR #253 pattern) ─────────────────
if [ "${SELFTEST:-0}" = "1" ]; then
  PASS=0
  FAIL=0

  _assert() {
    local label="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
      PASS=$((PASS + 1))
      echo "  PASS [$label]"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL [$label]: expected='$expected' got='$result'"
    fi
  }

  echo "unified_duckdb_backup selftest: running..."

  # Case 1: find_duckdb locates a binary
  _db_bin=$(find_duckdb 2>/dev/null || true)
  if [ -n "$_db_bin" ] && [ -x "$_db_bin" ]; then
    _assert "find_duckdb_works" "yes" "yes"
  else
    _assert "find_duckdb_works" "no" "yes"
  fi

  # Case 2: today_date returns YYYY-MM-DD format
  _today=$(today_date)
  if echo "$_today" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    _assert "today_date_format" "yes" "yes"
  else
    _assert "today_date_format" "no (got: $_today)" "yes"
  fi

  # Case 3: is_monthly_anchor correctly identifies 1st-of-month
  if is_monthly_anchor "2026-05-01"; then
    _assert "monthly_anchor_1st" "yes" "yes"
  else
    _assert "monthly_anchor_1st" "no" "yes"
  fi

  # Case 4: is_monthly_anchor returns false for non-1st
  if is_monthly_anchor "2026-05-15"; then
    _assert "monthly_anchor_not_15th" "no" "yes"
  else
    _assert "monthly_anchor_not_15th" "yes" "yes"
  fi

  # Case 5: perform_backup --dry-run on absent DB exits 0 and logs WARN
  _tmplog=$(mktemp /tmp/selftest_duckdb_backup_XXXXX)
  LOGFILE="$_tmplog" perform_backup \
    "/tmp/no_such_unified_db_$$.duckdb" \
    "/tmp/no_such_backup_root_$$" \
    "2026-01-01" \
    "0"
  _ec=$?
  _assert "dryrun_absent_db_exits_0" "$_ec" "0"
  if grep -q "WARN" "$_tmplog" 2>/dev/null; then
    _assert "dryrun_absent_db_logs_warn" "yes" "yes"
  else
    _assert "dryrun_absent_db_logs_warn" "no" "yes"
  fi
  rm -f "$_tmplog"

  # Case 6: perform_backup --dry-run on real DB exits 0
  if [ -f "$UNIFIED_DB" ]; then
    _tmplog2=$(mktemp /tmp/selftest_duckdb_backup_XXXXX)
    LOGFILE="$_tmplog2" perform_backup \
      "$UNIFIED_DB" \
      "/tmp/no_such_backup_root_$$" \
      "$(today_date)" \
      "0"
    _ec=$?
    _assert "dryrun_real_db_exits_0" "$_ec" "0"
    if grep -q "DRY-RUN" "$_tmplog2" 2>/dev/null; then
      _assert "dryrun_real_db_logs_dryrun" "yes" "yes"
    else
      _assert "dryrun_real_db_logs_dryrun" "no" "yes"
    fi
    rm -f "$_tmplog2"
  else
    echo "  SKIP [dryrun_real_db_exits_0] — unified.duckdb not present"
    echo "  SKIP [dryrun_real_db_logs_dryrun] — unified.duckdb not present"
  fi

  # Case 7: prune_old_backups on absent root exits 0
  _tmplog3=$(mktemp /tmp/selftest_duckdb_backup_XXXXX)
  LOGFILE="$_tmplog3" prune_old_backups \
    "/tmp/no_such_backup_root_$$" \
    "0"
  _ec=$?
  _assert "prune_absent_root_exits_0" "$_ec" "0"
  rm -f "$_tmplog3"

  # Case 8: depth guard exported
  _depth_val="${_UNIFIED_DUCKDB_BACKUP_DEPTH:-0}"
  if [ "$_depth_val" -ge 1 ]; then
    _assert "depth_guard_increments" "yes" "yes"
  else
    _assert "depth_guard_increments" "no" "yes"
  fi

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
MODE="dry-run"
DO_PRUNE=0

usage() {
  cat <<'EOF'
Usage: unified_duckdb_backup.sh [--dry-run] [--apply] [--prune]
                                 [--db PATH] [--dest DIR] [--help]

Flags:
  --dry-run   (default) show what would be backed up; no writes
  --apply     write backup to Dropbox (or whatever BACKUP_ROOT resolves to)
  --prune     remove daily exports > 30 days, monthly > 365 days
  --db PATH   override source DB (default: ~/.claude/logs/unified.duckdb)
  --dest DIR  override backup root directory
  --help      show this message

Self-test:
  SELFTEST=1 bash unified_duckdb_backup.sh

Tracked in llm#228.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  MODE="dry-run"; shift ;;
    --apply)    MODE="apply";   shift ;;
    --prune)    DO_PRUNE=1;     shift ;;
    --db)       UNIFIED_DB="$2"; shift 2 ;;
    --dest)     BACKUP_ROOT="$2"; shift 2 ;;
    --help|-h)  usage; exit 0 ;;
    *)          die "Unknown argument: $1 (try --help)" ;;
  esac
done

APPLY=0
[ "$MODE" = "apply" ] && APPLY=1

# ── Main ──────────────────────────────────────────────────────────────────────
TODAY=$(today_date)
log "unified_duckdb_backup: mode=$MODE date=$TODAY db=$UNIFIED_DB dest=$BACKUP_ROOT"

perform_backup "$UNIFIED_DB" "$BACKUP_ROOT" "$TODAY" "$APPLY"

if [ "$DO_PRUNE" = "1" ]; then
  prune_old_backups "$BACKUP_ROOT" "$APPLY"
fi

log "unified_duckdb_backup: done"
