#!/usr/bin/env bash
# roborev_retention.sh — prune ~/.roborev DB backups and stale job logs.
#
# ~/.roborev grows unbounded (llm#929): measured at 6.1GB, up from 5.3GB
# when the issue was filed. Two independent, unretained accumulations:
#
#   1. DB backups — a full copy of reviews.db (~750MB each) is left behind
#      by TWO different creators, using TWO different naming conventions:
#        reviews.db.bak-<YYYYmmdd_HHMMSS>   roborev_autoclose.sh Phase 2
#                                            (weekly, only when it finds
#                                            stale failed jobs to cancel)
#        reviews.db.<YYYYmmdd_HHMMSS>.bak   cleanup_ephemeral_repos.sh
#                                            --apply (manual, ad hoc)
#      Neither creator prunes old copies. A policy matching only one
#      pattern would leave the other accumulating unnoticed.
#
#   2. Job logs — the roborev daemon writes one file per review job under
#      logs/jobs/<job-id>.log (readable via `roborev log <job-id>`), never
#      rotated. Measured: 11024 files, 1.0GB, dating back to March; 991MB
#      (99%) of that is already >30 days old. This is raw agent stdout/
#      stderr for troubleshooting a specific job — NOT the audit trail;
#      finding resolution history lives in reviews.db itself, so pruning
#      old job logs does not lose anything roborev needs to operate.
#      logs/daemon.std{out,err}.log are NOT touched here — they are small
#      (<250KB combined) and actively appended by the running daemon.
#
# Both policies default to dry-run. Pass --apply to actually delete.
#
# Usage:
#   roborev_retention.sh                       # dry-run (default)
#   roborev_retention.sh --apply               # delete
#   ROBOREV_BACKUP_KEEP=3 roborev_retention.sh --apply
#   ROBOREV_LOG_RETENTION_DAYS=14 roborev_retention.sh --apply
#   SELFTEST=1 roborev_retention.sh            # fixture-based unit tests
#                                               # (always a temp dir, never
#                                               # touches the real ~/.roborev)
#
# Hard guards (human-in-the-loop-decision-points: a retention bug that eats
# the live DB is unrecoverable, so these are not just "should follow from
# KEEP >= 1" — they are enforced explicitly, independent of KEEP/DAYS):
#   - refuses to run (exit 1) if $ROBOREV_DB is missing
#   - refuses to run (exit 1) if $ROBOREV_DB is zero-length
#   - the live DB path is excluded from the backup-candidate glob explicitly
#   - the single most recent backup always survives, even if
#     ROBOREV_BACKUP_KEEP is misconfigured to 0 or a non-numeric value
#     (both clamp to 1)
#
# Wiring: called from roborev_autoclose.sh (Phase 0, before Phase 1/2) so it
# rides the existing weekly com.claude.roborev-autoclose launchd schedule —
# no new launchd job. It runs unconditionally on every invocation of that
# script, independent of whether Phase 1/2 find anything to do (both have
# early exit-0 paths that would otherwise skip anything appended after them).
#
# Reporting: logs to ~/.claude/logs/roborev_retention.log on every run. On
# --apply only (never on --dry-run — see below), writes a housekeeping_runs
# heartbeat row + one roborev_retention_events row per file removed to
# unified.duckdb when `duckdb` is available (silently skipped otherwise).
# --apply-only is deliberate: this script's own --dry-run verification runs
# against the REAL ~/.roborev during development/audit, and dry-run must
# never write outside ~/.roborev/*.log and this script's own log file —
# see housekeeping-framework rule component 3 for the general pattern this
# follows, adapted to keep the read-only mode side-effect-free.
#
# Tracked in JohnGavin/llm#929.

set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROBOREV_HOME="${ROBOREV_HOME:-$HOME/.roborev}"
ROBOREV_DB="${ROBOREV_DB:-$ROBOREV_HOME/reviews.db}"
ROBOREV_BACKUP_KEEP="${ROBOREV_BACKUP_KEEP:-2}"
ROBOREV_LOG_RETENTION_DAYS="${ROBOREV_LOG_RETENTION_DAYS:-30}"
LOGFILE="${ROBOREV_RETENTION_LOGFILE:-$HOME/.claude/logs/roborev_retention.log}"
UNIFIED_DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOGFILE" 2>/dev/null || true; }

# Clamp KEEP to a minimum of 1 — never let misconfiguration delete every backup.
case "$ROBOREV_BACKUP_KEEP" in
  '' | *[!0-9]*) ROBOREV_BACKUP_KEEP=2 ;;
esac
if [ "$ROBOREV_BACKUP_KEEP" -lt 1 ]; then
  ROBOREV_BACKUP_KEEP=1
fi

# ─── portable stat helpers (macOS BSD stat first, GNU stat fallback) ────────
_mtime_epoch() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }
_size_bytes() { stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null; }

human_size() {
  # No numfmt dependency (not present on stock macOS).
  awk -v b="$1" 'BEGIN {
    split("B KB MB GB TB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.1f%s", b, u[i]
  }'
}

# ─── core retention logic (parameterised so --selftest can use fixtures) ───

# find_backup_candidates <roborev_home> <live_db_path>
#   Prints "<mtime_epoch>\t<path>" for every file matching EITHER backup
#   naming convention, explicitly excluding the live DB path.
find_backup_candidates() {
  local home="$1" live="$2" f mt
  for f in "$home"/reviews.db.bak-* "$home"/reviews.db.*.bak; do
    [ -e "$f" ] || continue
    [ "$f" = "$live" ] && continue
    mt=$(_mtime_epoch "$f") || continue
    printf '%s\t%s\n' "$mt" "$f"
  done
}

# plan_backup_removals <roborev_home> <live_db_path> <keep_n>
#   One path per line for every backup beyond the KEEP most recent
#   (sorted by mtime descending — the newest KEEP always survive).
plan_backup_removals() {
  local home="$1" live="$2" keep="$3"
  find_backup_candidates "$home" "$live" \
    | sort -t $'\t' -k1,1nr \
    | awk -F'\t' -v keep="$keep" 'NR > keep { print $2 }'
}

# plan_log_removals <jobs_dir> <retention_days>
#   One path per line for every logs/jobs/*.log older than N days.
plan_log_removals() {
  local dir="$1" days="$2"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -name '*.log' -mtime "+${days}" 2>/dev/null
}

# ── arg parsing ─────────────────────────────────────────────────────────
APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  --dry-run | "") APPLY=0 ;;
  -h | --help)
    sed -n '2,45p' "$0"
    exit 0
    ;;
  *)
    if [ "${SELFTEST:-0}" != "1" ]; then
      echo "unknown arg: $1" >&2
      exit 1
    fi
    ;;
esac

main() {
  if [ ! -f "$ROBOREV_DB" ]; then
    echo "roborev_retention: refusing to run — live DB not found at $ROBOREV_DB" >&2
    log "abort: live DB missing at $ROBOREV_DB"
    exit 1
  fi

  local live_size
  live_size=$(_size_bytes "$ROBOREV_DB" || echo 0)
  if [ -z "$live_size" ] || [ "$live_size" -eq 0 ]; then
    echo "roborev_retention: refusing to run — live DB is zero-length at $ROBOREV_DB" >&2
    log "abort: live DB zero-length at $ROBOREV_DB"
    exit 1
  fi

  local backup_removals log_removals
  backup_removals=$(plan_backup_removals "$ROBOREV_HOME" "$ROBOREV_DB" "$ROBOREV_BACKUP_KEEP")
  log_removals=$(plan_log_removals "$ROBOREV_HOME/logs/jobs" "$ROBOREV_LOG_RETENTION_DAYS")

  local total_bytes=0 n_backups=0 n_logs=0 f sz age_days now mode_word
  now=$(date +%s)
  mode_word="to remove"
  [ "$APPLY" -eq 1 ] && mode_word="REMOVED"

  echo "roborev_retention: live DB = $ROBOREV_DB ($(human_size "$live_size"))"
  echo "roborev_retention: backup policy — keep ${ROBOREV_BACKUP_KEEP} most recent (both naming conventions), never the live DB"
  echo "roborev_retention: log policy — logs/jobs/*.log older than ${ROBOREV_LOG_RETENTION_DAYS}d"
  echo ""

  if [ -n "$backup_removals" ]; then
    echo "DB backups ($mode_word):"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sz=$(_size_bytes "$f" || echo 0)
      sz=${sz:-0}
      age_days=$(((now - $(_mtime_epoch "$f")) / 86400))
      printf '  %-70s %8s  %3dd old\n' "$f" "$(human_size "$sz")" "$age_days"
      total_bytes=$((total_bytes + sz))
      n_backups=$((n_backups + 1))
      if [ "$APPLY" -eq 1 ]; then
        rm -f -- "$f"
        log "removed backup: $f ($(human_size "$sz"), ${age_days}d)"
      fi
    done <<<"$backup_removals"
  else
    echo "DB backups: nothing to remove (<= ${ROBOREV_BACKUP_KEEP} present)"
  fi
  echo ""

  if [ -n "$log_removals" ]; then
    local n_log_files
    n_log_files=$(echo "$log_removals" | wc -l | tr -d ' ')
    local log_bytes=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sz=$(_size_bytes "$f" || echo 0)
      sz=${sz:-0}
      total_bytes=$((total_bytes + sz))
      log_bytes=$((log_bytes + sz))
      n_logs=$((n_logs + 1))
      if [ "$APPLY" -eq 1 ]; then
        rm -f -- "$f"
      fi
    done <<<"$log_removals"
    echo "Job logs ($mode_word): $n_log_files files, $(human_size "$log_bytes") (older than ${ROBOREV_LOG_RETENTION_DAYS}d; per-file listing suppressed)"
    if [ "$APPLY" -eq 1 ]; then
      log "removed $n_logs job logs older than ${ROBOREV_LOG_RETENTION_DAYS}d ($(human_size "$log_bytes"))"
    fi
  else
    echo "Job logs: nothing older than ${ROBOREV_LOG_RETENTION_DAYS}d"
  fi
  echo ""
  echo "roborev_retention: $([ "$APPLY" -eq 1 ] && echo 'reclaimed' || echo 'would reclaim') $(human_size "$total_bytes") ($n_backups backups + $n_logs job logs)"

  if [ "$APPLY" -eq 1 ]; then
    log "apply: reclaimed $(human_size "$total_bytes") ($n_backups backups + $n_logs job logs)"
    # Heartbeat + per-run event count — apply-only (see header comment).
    if command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ]; then
      local run_id started
      run_id=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || echo "run-$$-$now")
      started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      duckdb "$UNIFIED_DB" "
        INSERT OR IGNORE INTO housekeeping_runs
          (id, task, source_script, started_at, ended_at, status, rows_written)
        VALUES ('${run_id}', 'roborev_retention', '$0', TIMESTAMPTZ '${started}',
                TIMESTAMPTZ '${started}', 'ok', $((n_backups + n_logs)));
        INSERT OR IGNORE INTO roborev_retention_events
          (id, fired_at, source, run_id, item_type, action, count, bytes)
        VALUES ('${run_id}-backups', TIMESTAMPTZ '${started}', 'roborev_retention.sh',
                '${run_id}', 'backup', 'removed', $n_backups, $total_bytes);
        INSERT OR IGNORE INTO roborev_retention_events
          (id, fired_at, source, run_id, item_type, action, count, bytes)
        VALUES ('${run_id}-joblogs', TIMESTAMPTZ '${started}', 'roborev_retention.sh',
                '${run_id}', 'joblog', 'removed', $n_logs, $log_bytes);
      " 2>/dev/null || true
    fi
  else
    log "dry-run: would reclaim $(human_size "$total_bytes") ($n_backups backups + $n_logs job logs)"
  fi
}

# ── SELFTEST ─────────────────────────────────────────────────────────────
if [ "${SELFTEST:-0}" = "1" ]; then
  _pass=0
  _fail=0
  _check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
      echo "PASS: $desc"
      _pass=$((_pass + 1))
    else
      echo "FAIL: $desc (expected '$expected' got '$actual')"
      _fail=$((_fail + 1))
    fi
  }

  TMPDIR_RETENTION=$(mktemp -d "${TMPDIR:-/tmp}/roborev_retention_selftest.XXXXXX")
  trap 'rm -rf "$TMPDIR_RETENTION"' EXIT

  # Isolate every global the script reads — never the real ~/.roborev.
  ROBOREV_HOME="$TMPDIR_RETENTION"
  ROBOREV_DB="$TMPDIR_RETENTION/reviews.db"
  LOGFILE="$TMPDIR_RETENTION/retention.log"
  UNIFIED_DB="$TMPDIR_RETENTION/does-not-exist.duckdb"
  ROBOREV_BACKUP_KEEP=2
  ROBOREV_LOG_RETENTION_DAYS=30

  # Fixture: live DB + 4 backups (both naming conventions) at distinct mtimes.
  echo "live-db-content" >"$ROBOREV_DB"
  echo "b1" >"$ROBOREV_HOME/reviews.db.bak-20260601_090000"     # oldest
  echo "b2" >"$ROBOREV_HOME/reviews.db.20260608_090000.bak"     # 2nd oldest
  echo "b3" >"$ROBOREV_HOME/reviews.db.bak-20260615_090000"     # 2nd newest
  echo "b4" >"$ROBOREV_HOME/reviews.db.20260622_090000.bak"     # newest
  touch -t 202606010900 "$ROBOREV_HOME/reviews.db.bak-20260601_090000"
  touch -t 202606080900 "$ROBOREV_HOME/reviews.db.20260608_090000.bak"
  touch -t 202606150900 "$ROBOREV_HOME/reviews.db.bak-20260615_090000"
  touch -t 202606220900 "$ROBOREV_HOME/reviews.db.20260622_090000.bak"

  # Test 1+2: plan_backup_removals keeps N most recent, matching BOTH
  # naming conventions in a single combined ranking (result order is by
  # mtime descending, i.e. the pruning candidates nearest the KEEP cutoff
  # first).
  _plan=$(plan_backup_removals "$ROBOREV_HOME" "$ROBOREV_DB" 2)
  _check "plan removes exactly the 2 oldest backups" \
    "$(printf '%s\n%s' "$ROBOREV_HOME/reviews.db.20260608_090000.bak" "$ROBOREV_HOME/reviews.db.bak-20260601_090000")" \
    "$_plan"

  # Test: never plans to remove the live DB. Check each candidate LINE for
  # exact equality with $ROBOREV_DB (substring containment would false-positive
  # here, since every backup path is prefixed by the live DB's own basename).
  _candidates=$(find_backup_candidates "$ROBOREV_HOME" "$ROBOREV_DB")
  _live_in_candidates="absent"
  while IFS=$'\t' read -r _mt _path; do
    [ "$_path" = "$ROBOREV_DB" ] && _live_in_candidates="present"
  done <<<"$_candidates"
  _check "live DB excluded from backup candidates" "absent" "$_live_in_candidates"

  # Test: apply actually deletes the planned files and nothing else.
  APPLY=1
  main >/dev/null 2>&1
  _remaining_oldest=$([ -e "$ROBOREV_HOME/reviews.db.bak-20260601_090000" ] && echo present || echo absent)
  _check "apply removed the oldest backup" "absent" "$_remaining_oldest"
  _remaining_2nd=$([ -e "$ROBOREV_HOME/reviews.db.20260608_090000.bak" ] && echo present || echo absent)
  _check "apply removed the 2nd-oldest backup" "absent" "$_remaining_2nd"

  # Test: newest backup always survives.
  _newest_survives=$([ -e "$ROBOREV_HOME/reviews.db.20260622_090000.bak" ] && echo present || echo absent)
  _check "apply kept the newest backup" "present" "$_newest_survives"
  _2nd_newest_survives=$([ -e "$ROBOREV_HOME/reviews.db.bak-20260615_090000" ] && echo present || echo absent)
  _check "apply kept the 2nd-newest backup (KEEP=2)" "present" "$_2nd_newest_survives"

  # Test: live DB survives apply.
  _live_survives=$([ -e "$ROBOREV_DB" ] && echo present || echo absent)
  _check "apply never touched the live DB" "present" "$_live_survives"

  # Test: even KEEP=0 (misconfigured) clamps to 1 and keeps the newest.
  rm -rf "$ROBOREV_HOME"/reviews.db.*.bak "$ROBOREV_HOME"/reviews.db.bak-*
  echo "b1" >"$ROBOREV_HOME/reviews.db.bak-20260601_090000"
  echo "b2" >"$ROBOREV_HOME/reviews.db.20260622_090000.bak"
  touch -t 202606010900 "$ROBOREV_HOME/reviews.db.bak-20260601_090000"
  touch -t 202606220900 "$ROBOREV_HOME/reviews.db.20260622_090000.bak"
  ROBOREV_BACKUP_KEEP=0
  case "$ROBOREV_BACKUP_KEEP" in '' | *[!0-9]*) ROBOREV_BACKUP_KEEP=2 ;; esac
  [ "$ROBOREV_BACKUP_KEEP" -lt 1 ] && ROBOREV_BACKUP_KEEP=1
  APPLY=1
  main >/dev/null 2>&1
  _newest_survives_keep0=$([ -e "$ROBOREV_HOME/reviews.db.20260622_090000.bak" ] && echo present || echo absent)
  _check "KEEP clamped to 1 still keeps the newest backup" "present" "$_newest_survives_keep0"

  # Test: refuses to run when live DB is missing.
  ROBOREV_DB="$TMPDIR_RETENTION/does-not-exist-reviews.db"
  APPLY=0
  _rc=0
  (main >/dev/null 2>&1) || _rc=$?
  _check "refuses when live DB missing" "1" "$_rc"

  # Test: refuses to run when live DB is zero-length.
  ROBOREV_DB="$TMPDIR_RETENTION/reviews.db"
  : >"$ROBOREV_DB"
  _rc=0
  (main >/dev/null 2>&1) || _rc=$?
  _check "refuses when live DB is zero-length" "1" "$_rc"

  # Test: job-log age-based pruning.
  ROBOREV_DB="$TMPDIR_RETENTION/reviews.db"
  echo "live-db-content" >"$ROBOREV_DB"
  mkdir -p "$ROBOREV_HOME/logs/jobs"
  echo "old" >"$ROBOREV_HOME/logs/jobs/1.log"
  echo "new" >"$ROBOREV_HOME/logs/jobs/2.log"
  touch -t 202501010900 "$ROBOREV_HOME/logs/jobs/1.log"    # far in the past
  # 2.log keeps its just-created (fresh) mtime
  APPLY=1
  main >/dev/null 2>&1
  _old_log_removed=$([ -e "$ROBOREV_HOME/logs/jobs/1.log" ] && echo present || echo absent)
  _check "old job log removed" "absent" "$_old_log_removed"
  _new_log_kept=$([ -e "$ROBOREV_HOME/logs/jobs/2.log" ] && echo present || echo absent)
  _check "recent job log kept" "present" "$_new_log_kept"

  echo ""
  echo "SELFTEST: ${_pass}/$((_pass + _fail)) PASS"
  [ "$_fail" -eq 0 ]
  exit $?
fi

main "$@"
