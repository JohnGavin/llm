#!/usr/bin/env bash
# staleness_collect.sh — populate the unified `staleness` fact table (llm#893 step 2)
#
# One out-of-band collector for "when did this last run/produce data, and how
# often should it?" across three asset kinds:
#
#   etl_source   — carried over from the existing etl_freshness table
#   launchd_job  — derived from a deployed plist's schedule + launchctl state
#   collector    — this script's own heartbeat row (asset_id='staleness_collect')
#
# This table stores FACTS only (last_seen_ts, expected_cadence_hours) — never
# a computed status. Status is the `staleness_status` VIEW (see
# staleness_schema.sql), recomputed at every read. That directly fixes
# llm#893 defect 1: a stored status can go stale itself (roborev's row read
# 'fresh' while 38h old against a 24h cadence, because nothing recomputed it
# after the writer that set it died).
#
# expected_cadence_hours is NOT NULL for every row this script writes — no
# 'unknown' escape hatch (defect 2). See _etl_cadence_override() below for
# the per-source reasoning on the 5 etl_freshness sources that currently
# carry a NULL cadence (sessions, skill_usage, command_usage, agent_runs,
# llmtelemetry — one more than the 4 the issue named; llmtelemetry was added
# to etl_freshness after the issue was filed).
#
# Read out-of-band, from a different trigger class than launchd (defect 3):
# see staleness_banner.sh, wired into session_init.sh — a total launchd
# outage (llm#886) is then visible at the next session start, not silent.
#
# Usage:
#   .claude/scripts/staleness_collect.sh [--db PATH]
#   .claude/scripts/staleness_collect.sh --selftest
#
# Env:
#   STALENESS_DB          override target DB (default ~/.claude/logs/unified.duckdb)
#   STALENESS_PLIST_DIR   override plist dir to scan (default ~/Library/LaunchAgents)
#
# Follows housekeeping-framework: writes a housekeeping_runs start row, and
# updates it at the end with status ('ok'|'partial'|'failed') + rows_written.
#
# Fail-partial, not fail-silent: a single source failing to collect (missing
# table, unparseable plist, launchctl unavailable) logs a WARN and is
# skipped — it does not abort collection of the remaining sources. Only a
# missing duckdb binary or missing DB aborts the whole run (recorded as
# 'failed' in housekeeping_runs, non-zero exit).
#
# Tracked in llm#893 (step 2 of the Sequencing plan). Steps 3-5 (repointing
# the email/dashboard, content/unusual-activity checks, retiring
# launchd_runs.duckdb) are out of scope for this script.

set -uo pipefail

# ─── PATH (launchd runs with a minimal PATH) ─────────────────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_DEFAULT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)/default.nix"
DB="${STALENESS_DB:-${HOME}/.claude/logs/unified.duckdb}"
PLIST_DIR="${STALENESS_PLIST_DIR:-${HOME}/Library/LaunchAgents}"
LOG_DIR_DEFAULT="${HOME}/.claude/logs"
SCHEMA_APPLY="${SCRIPT_DIR}/staleness_schema_apply.sh"
SCHEMA_SQL="${SCRIPT_DIR}/staleness_schema.sql"
PLUTIL=/usr/bin/plutil
PYTHON3=/usr/bin/python3

# ─── Argument parsing ─────────────────────────────────────────────────────────
MODE="normal"
while [ $# -gt 0 ]; do
  case "$1" in
    --db)       DB="${2:-}"; shift 2 ;;
    --selftest) MODE="selftest"; shift ;;
    *)
      echo "Usage: $0 [--db PATH] [--selftest]" >&2
      exit 1
      ;;
  esac
done

# ─── duckdb invocation (prefer direct; fall back to nix-shell wrapper) ───────
duck_run() {
  if command -v duckdb >/dev/null 2>&1; then
    duckdb -init /dev/null "$@"
  elif command -v nix-shell >/dev/null 2>&1 && [ -f "${NIX_DEFAULT}" ]; then
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    nix-shell "${NIX_DEFAULT}" --run "duckdb -init /dev/null${q}"
  else
    echo "staleness_collect: duckdb not found" >&2
    return 1
  fi
}

# ─── SQL string escaping ──────────────────────────────────────────────────────
_esc() { printf '%s' "$1" | sed "s/'/''/g"; }

# ─── Counters (global; functions below mutate these directly) ───────────────
ROWS_WRITTEN=0
WARN_COUNT=0
FAIL_COUNT=0

# ─── Cadence overrides for etl_freshness sources with NULL cadence ──────────
# (llm#893 defect 2: NULL degraded to status='unknown', which read as benign
# — 'sessions' sat stale 11 days reporting 'unknown', not 'stale'.)
#
# Values derived from observed inter-row-gap statistics in unified.duckdb on
# 2026-08-03 (WITH s AS (SELECT ts, LAG(ts) OVER (ORDER BY ts) AS prev FROM
# <table>) SELECT MAX(...), QUANTILE_CONT(..., 0.9|0.95) ...):
#   sessions       p95 gap ~1.5h during active use. 72h (3d) tolerates a full
#                  weekend-plus-a-day of inactivity before flagging — the
#                  observed 11-day real staleness incident clears this by 3.5x.
#   skill_usage    event-driven, sparse. Observed max gap 335h (~14d). 336h
#                  sits just above the noisiest real gap seen so far.
#   command_usage  observed p90 gap ~112h, max ~165h. 168h (7d) rounds up.
#   agent_runs     observed p90 gap ~21h. Agents run near-daily in active
#                  development; 48h (2d) catches genuine dead periods without
#                  false-alarming on a single quiet day.
#   llmtelemetry   written by a separate project's pipeline, outside this
#                  repo's read scope — no in-repo history to derive a cadence
#                  from. Documented default: 24h, matching its sibling
#                  cron-fed sources (roborev, burn_rate) in the same table.
#   config_staleness  (added llm#928 defect 2) refreshed only as a side
#                  effect of /bye (session_stop.sh -> export_and_deploy_data.sh
#                  -> skill_usage_etl.R --apply), not on a launchd schedule —
#                  so its real cadence is the observed gap BETWEEN /bye
#                  events, not a fixed clock. Derived 2026-08-17 from
#                  command_usage (WITH b AS (SELECT ts FROM command_usage
#                  WHERE command_name='bye' ORDER BY ts), g AS (SELECT
#                  date_diff('hour', LAG(ts) OVER (ORDER BY ts), ts) AS
#                  gap_hours FROM b) SELECT ...): n=60 bye events
#                  2026-06-07..2026-08-10, median gap 5h, p90 94.2h, p95
#                  118.9h, max 234h. The 234h/165h/127h outlier gaps were
#                  checked against their timestamps and all fall in
#                  late-June/mid-July — genuine multi-day gaps between work
#                  sessions on this repo, predating the current dead-feed
#                  incident, not artifacts of it. 120h (5d) rounds the p95 up
#                  — comfortably inside the range of gaps this repo's owner
#                  has produced before without anything being wrong, while
#                  sitting well below the two rarer >150h gaps.
#                  KNOWN CONSEQUENCE: as of 2026-08-17 this source reads
#                  'stale' under this cadence — last_row_ts is 2026-08-08
#                  (~9d ago, ~216h > 120h). That is correct: llm#829
#                  documents that config_staleness's refresh has no reliable
#                  hook-firing feed (a /bye fired 2026-08-10 without a
#                  matching etl_freshness update), so it IS a dead producer
#                  right now. 120h was chosen from the gap data, not
#                  inflated to suppress this — a larger number would have
#                  hidden a real defect.
_etl_cadence_override() {
  case "$1" in
    sessions)          echo "72" ;;
    skill_usage)       echo "336" ;;
    command_usage)     echo "168" ;;
    agent_runs)        echo "48" ;;
    llmtelemetry)      echo "24" ;;
    config_staleness)  echo "120" ;;
    *)                 echo "" ;;
  esac
}

# ─── collect_etl_sources: carry rows from etl_freshness into staleness ──────
collect_etl_sources() {
  local rows
  rows="$(duck_run "$DB" -noheader -list -c "
    SELECT source_name || '|' ||
           COALESCE(last_row_ts::VARCHAR, '') || '|' ||
           COALESCE(last_etl_run_ts::VARCHAR, '') || '|' ||
           COALESCE(expected_cadence_hours::VARCHAR, '')
    FROM etl_freshness;
  " 2>/dev/null)"
  if [ $? -ne 0 ]; then
    echo "staleness_collect: WARN could not read etl_freshness (missing table?)" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi
  [ -z "$rows" ] && return

  local _name _lrt _let _cad
  while IFS='|' read -r _name _lrt _let _cad; do
    [ -z "$_name" ] && continue

    local _last_seen="$_lrt"
    [ -z "$_last_seen" ] && _last_seen="$_let"

    local _cadence="$_cad"
    if [ -z "$_cadence" ]; then
      _cadence="$(_etl_cadence_override "$_name")"
    fi
    if [ -z "$_cadence" ]; then
      echo "staleness_collect: WARN no cadence for etl_source '${_name}' (not in override table) — skipping" >&2
      WARN_COUNT=$((WARN_COUNT + 1))
      continue
    fi

    local _last_seen_sql="NULL"
    [ -n "$_last_seen" ] && _last_seen_sql="TIMESTAMPTZ '$(_esc "$_last_seen")'"

    if duck_run "$DB" -c "
      INSERT OR REPLACE INTO staleness
        (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours, last_exit_code, observed_at)
      VALUES (
        'etl_source', '$(_esc "$_name")', NULL,
        ${_last_seen_sql}, ${_cadence}, NULL, current_timestamp
      );
    " >/dev/null 2>&1; then
      ROWS_WRITTEN=$((ROWS_WRITTEN + 1))
    else
      echo "staleness_collect: WARN upsert failed for etl_source '${_name}'" >&2
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  done <<< "$rows"
}

# ─── _launchd_cadence_hours: derive cadence from a plist's schedule keys ────
# Adapted from bin/launchd_health_audit.sh's expected_cadence_seconds(). Falls
# back to a documented default of 86400s (24h, "assume daily") when the
# schedule is unparseable or absent — never NULL.
_launchd_cadence_hours() {
  local json="$1"
  local seconds
  seconds="$(printf '%s' "$json" | "$PYTHON3" -c "
import sys, json
d = json.load(sys.stdin)
si = d.get('StartInterval')
if si:
    print(int(si))
    sys.exit()
sci = d.get('StartCalendarInterval')
if sci is None:
    print(86400)  # no declared schedule -> documented default: assume daily
    sys.exit()
if isinstance(sci, list):
    # Multiple entries commonly repeat the same Hour:Minute across different
    # Weekdays (e.g. Mon/Tue/Wed all at 09:00) — sorting by minute-of-day
    # alone then yields adjacent duplicates and a diff of 0, which would make
    # the cadence 0h (=> permanently 'stale'). Only strictly-positive diffs
    # between distinct minute-of-day slots count; an all-duplicate list falls
    # back to the documented daily default, same as a single-entry list.
    entries = sorted(sci, key=lambda x: x.get('Hour', 0) * 60 + x.get('Minute', 0))
    diffs = []
    for i in range(1, len(entries)):
        a = entries[i-1].get('Hour', 0) * 60 + entries[i-1].get('Minute', 0)
        b = entries[i].get('Hour', 0) * 60 + entries[i].get('Minute', 0)
        d = (b - a) * 60
        if d > 0:
            diffs.append(d)
    print(min(diffs) if diffs else 86400)
    sys.exit()
if isinstance(sci, dict):
    wd = sci.get('Weekday')
    print(604800 if wd is not None else 86400)
" 2>/dev/null)"
  case "$seconds" in
    ''|*[!0-9]*) seconds=86400 ;;
  esac
  awk -v s="$seconds" 'BEGIN { printf "%.4f", s / 3600.0 }'
}

# ─── _launchd_log_file: find the log used as a "last fired" proxy ───────────
# Priority: StandardOutPath from the plist, else derived <suffix>.out/.log
# under ~/.claude/logs (same derivation as launchd_health_audit.sh).
_launchd_log_file() {
  local label="$1" out_path="$2"
  if [ -n "$out_path" ] && [ -f "$out_path" ]; then
    echo "$out_path"
    return
  fi
  local suffix
  suffix="$(printf '%s' "$label" | sed 's/^com\.claude\.//' | tr '-' '_')"
  if [ -f "${LOG_DIR_DEFAULT}/${suffix}.out" ]; then
    echo "${LOG_DIR_DEFAULT}/${suffix}.out"
    return
  fi
  if [ -f "${LOG_DIR_DEFAULT}/${suffix}.log" ]; then
    echo "${LOG_DIR_DEFAULT}/${suffix}.log"
    return
  fi
  echo ""
}

# ─── collect_launchd_jobs: one row per deployed com.claude.* plist ──────────
collect_launchd_jobs() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "staleness_collect: SKIP launchd_job collection (not macOS)" >&2
    return
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    echo "staleness_collect: WARN launchctl not found" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi
  if [ ! -x "$PLUTIL" ] || [ ! -x "$PYTHON3" ]; then
    echo "staleness_collect: WARN plutil/python3 not found — cannot parse plists" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi
  if [ ! -d "$PLIST_DIR" ]; then
    echo "staleness_collect: WARN plist dir not found: ${PLIST_DIR}" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi

  # Single `launchctl list` call, tab-delimited "PID\tStatus\tLabel" rows.
  # Deliberately NOT using `launchctl list <label>` per-label — that output is
  # a JSON5-like dump (unquoted keys, '=' not ':'), not valid JSON; python3's
  # json.load() fails on it silently (see launchd_health_audit.sh's lc_pid/
  # lc_exit, which both always fall back to '-' for this exact reason).
  local _lc_list
  _lc_list="$(launchctl list 2>/dev/null | grep 'com\.claude\.' || true)"

  shopt -s nullglob
  local plist
  for plist in "$PLIST_DIR"/com.claude.*.plist; do
    case "$plist" in *.bak*) continue ;; esac

    local json
    json="$("$PLUTIL" -convert json -o - "$plist" 2>/dev/null)"
    if [ $? -ne 0 ] || [ -z "$json" ]; then
      echo "staleness_collect: WARN could not parse plist ${plist}" >&2
      WARN_COUNT=$((WARN_COUNT + 1))
      continue
    fi

    local label
    label="$(printf '%s' "$json" | "$PYTHON3" -c "import sys, json; print(json.load(sys.stdin).get('Label', ''))" 2>/dev/null)"
    [ -z "$label" ] && continue

    local out_path
    out_path="$(printf '%s' "$json" | "$PYTHON3" -c "import sys, json; print(json.load(sys.stdin).get('StandardOutPath', ''))" 2>/dev/null)"

    local cadence_hours
    cadence_hours="$(_launchd_cadence_hours "$json")"

    local log_file
    log_file="$(_launchd_log_file "$label" "$out_path")"

    local last_seen_epoch=0
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
      last_seen_epoch="$(/usr/bin/stat -f '%m' "$log_file" 2>/dev/null || echo 0)"
    fi

    local last_seen_sql="NULL"
    if [ "${last_seen_epoch:-0}" -gt 0 ] 2>/dev/null; then
      local last_seen_iso
      last_seen_iso="$(/bin/date -r "$last_seen_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")"
      [ -n "$last_seen_iso" ] && last_seen_sql="TIMESTAMPTZ '$(_esc "$last_seen_iso")'"
    fi

    local exit_code_sql="NULL"
    local _status
    _status="$(printf '%s\n' "$_lc_list" | awk -F'\t' -v l="$label" '$3 == l { print $2; exit }')"
    case "$_status" in
      ''|*[!0-9-]*) exit_code_sql="NULL" ;;
      *)            exit_code_sql="$_status" ;;
    esac

    if duck_run "$DB" -c "
      INSERT OR REPLACE INTO staleness
        (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours, last_exit_code, observed_at)
      VALUES (
        'launchd_job', '$(_esc "$label")', NULL,
        ${last_seen_sql}, ${cadence_hours}, ${exit_code_sql}, current_timestamp
      );
    " >/dev/null 2>&1; then
      ROWS_WRITTEN=$((ROWS_WRITTEN + 1))
    else
      echo "staleness_collect: WARN upsert failed for launchd_job '${label}'" >&2
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  done
  shopt -u nullglob
}

# ─── Content-fact detectors (llm#893 step 4 / section D) ────────────────────
# Three concrete detectors, each mapped to a real incident that already
# happened, so each is testable against something real rather than a
# hypothetical. See staleness_schema.sql for the column semantics
# (metric_value / metric_value_prior / metric_aux / metric_aux_prior /
# metric_threshold_high) and the 2-deep retention rule (current + one prior
# observation per asset — bounded, no history table).
#
# Section D is scoped to *scheduling and surfacing* content checks with the
# existing cadence machinery, not to building a general content-regression
# framework (that is llm#892's). These two functions are intentionally
# narrow: one named log, one named DB, both already implicated in a real
# incident (llm#886/#887 and llm#884 respectively).

# Monitored asset for detectors 1+2. One row (asset_kind='log_growth') answers
# both questions:
#   1. "did it stop growing?" — the EXISTING time machinery from steps 1-2:
#      last_seen_ts is set to the file's own mtime (proxy for "last time it
#      produced new content"); staleness_status.status (fresh/stale) answers
#      this with zero new columns. This is the llm#886 tell.
#   2. "did it grow abnormally?" — the NEW magnitude machinery: metric_value
#      (current size in bytes) vs metric_value_prior (previous observation)
#      vs metric_threshold_high; staleness_status.content_status answers
#      this. This is the llm#887 incident (74 MB).
LOG_GROWTH_PATH="${HOME}/.claude/logs/roborev_poll_merges.log"
LOG_GROWTH_ASSET_ID="roborev_poll_merges.log"
# 72h, not 24h: the underlying job (com.claude.roborev-poll-merges) runs
# weekdays only at 09:00/13:00/17:00 — a naive 24h cadence would misfire
# 'stale' every Saturday/Sunday when nothing is scheduled to write. 72h
# tolerates a full Fri-17:00-to-Mon-09:00 gap (64h) with margin, matching the
# same weekend-tolerant reasoning already used for the 'sessions' etl
# override above.
LOG_GROWTH_CADENCE_HOURS=72
# Ceiling for a 72h window's worth of growth, in bytes. Derived from the live
# log's own per-run byte-size distribution, measured 2026-08-16 by splitting
# the file on its "summary [applied]" lines (n=25 runs since the file was
# last reset 2026-08-04): min=3,227 B, mean=44,694 B, max=171,919 B per run.
# A 72h window spans at most 3 weekdays x 3 runs/day = 9 runs; even 9
# consecutive worst-case (171,919 B) runs = 1,547,271 B. 2,000,000 B (2 MB)
# rounds that up with ~30% margin — comfortably above any plausible run of
# healthy runs, and ~37x below the actual llm#887 incident size (74 MB), so
# it fires long before a recurrence reaches that scale.
LOG_GROWTH_THRESHOLD_HIGH_BYTES=2000000

collect_log_growth() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "staleness_collect: SKIP log_growth collection (not macOS — uses BSD stat/date)" >&2
    return
  fi
  if [ ! -f "$LOG_GROWTH_PATH" ]; then
    echo "staleness_collect: WARN log_growth target not found: ${LOG_GROWTH_PATH} — skipping" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi

  local size_bytes mtime_epoch mtime_iso
  size_bytes="$(/usr/bin/stat -f '%z' "$LOG_GROWTH_PATH" 2>/dev/null || echo "")"
  mtime_epoch="$(/usr/bin/stat -f '%m' "$LOG_GROWTH_PATH" 2>/dev/null || echo "")"
  if [ -z "$size_bytes" ] || [ -z "$mtime_epoch" ]; then
    echo "staleness_collect: WARN could not stat ${LOG_GROWTH_PATH} — skipping" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi
  mtime_iso="$(/bin/date -r "$mtime_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")"
  if [ -z "$mtime_iso" ]; then
    echo "staleness_collect: WARN could not format mtime for ${LOG_GROWTH_PATH} — skipping" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi

  # 2-deep retention: read the current metric_value before it is overwritten
  # — it becomes metric_value_prior in the upsert below (see
  # staleness_schema.sql for the retention rule this implements).
  local prior_value prior_sql="NULL"
  prior_value="$(duck_run "$DB" -noheader -list -c "
    SELECT metric_value FROM staleness
    WHERE asset_kind = 'log_growth' AND asset_id = '$(_esc "$LOG_GROWTH_ASSET_ID")';
  " 2>/dev/null)"
  [ -n "$prior_value" ] && prior_sql="$prior_value"

  if duck_run "$DB" -c "
    INSERT OR REPLACE INTO staleness
      (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours,
       last_exit_code, observed_at, metric_value, metric_value_prior, metric_threshold_high)
    VALUES (
      'log_growth', '$(_esc "$LOG_GROWTH_ASSET_ID")', NULL,
      TIMESTAMPTZ '$(_esc "$mtime_iso")', ${LOG_GROWTH_CADENCE_HOURS},
      NULL, current_timestamp, ${size_bytes}, ${prior_sql}, ${LOG_GROWTH_THRESHOLD_HIGH_BYTES}
    );
  " >/dev/null 2>&1; then
    ROWS_WRITTEN=$((ROWS_WRITTEN + 1))
  else
    echo "staleness_collect: WARN upsert failed for log_growth '${LOG_GROWTH_ASSET_ID}'" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
}

# Detector 3: "a DB grew without its row count growing" (llm#884: 7.1 GiB for
# 61,635 rows). asset_kind='db_bloat' tracks this DB's own size (bytes,
# metric_value) alongside its total row count (metric_aux); content_status
# flags when bytes-per-row density exceeds metric_threshold_high.
#
# Ceiling derived from a live measurement taken 2026-08-16: this DB is
# currently 1.4 GiB (block_size * used_blocks) holding 79,712 rows across 38
# tables = ~18,858 B/row (post-compaction, healthy). The documented llm#884
# incident measured 7.1 GiB / 61,635 rows = ~123,676 B/row. 3x today's
# healthy density (~56,574 B/row, rounded to 60,000) sits well below the
# incident value — it would fire long before the DB reached crisis scale —
# with margin above today's baseline to tolerate normal day-to-day variation
# without false-alarming.
#
# last_seen_ts is set to current_timestamp (this DB always "exists" the
# moment the collector runs) and expected_cadence_hours=24 (matches the
# collector's own daily schedule) — the interesting signal here is
# content_status (density), not time-staleness of the DB file itself.
DB_BLOAT_ASSET_ID="unified.duckdb"
DB_BLOAT_CADENCE_HOURS=24
DB_BLOAT_THRESHOLD_HIGH_BYTES_PER_ROW=60000

collect_db_bloat() {
  # Single query, explicit '|' concatenation (not relying on the CLI -list
  # separator — same defensive pattern as collect_etl_sources above).
  # duckdb_tables().estimated_size is an ESTIMATE, not an exact COUNT(*) —
  # adequate for a density trend signal, not for exact accounting.
  local facts
  facts="$(duck_run "$DB" -noheader -list -c "
    SELECT block_size::VARCHAR || '|' || used_blocks::VARCHAR || '|' ||
           (SELECT COALESCE(SUM(estimated_size), 0) FROM duckdb_tables())::VARCHAR
    FROM pragma_database_size();
  " 2>/dev/null)"
  if [ -z "$facts" ]; then
    echo "staleness_collect: WARN could not measure db_bloat facts — skipping" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi

  local _block_size _used_blocks _rows
  IFS='|' read -r _block_size _used_blocks _rows <<< "$facts"
  if [ -z "$_block_size" ] || [ -z "$_used_blocks" ]; then
    echo "staleness_collect: WARN incomplete db_bloat facts — skipping" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi
  [ -z "$_rows" ] && _rows=0
  local _size_bytes=$((_block_size * _used_blocks))

  # 2-deep retention: read both current facts before they are overwritten —
  # they become metric_value_prior / metric_aux_prior in the upsert below.
  local prior prior_size prior_rows prior_size_sql="NULL" prior_rows_sql="NULL"
  prior="$(duck_run "$DB" -noheader -list -c "
    SELECT COALESCE(metric_value::VARCHAR, '') || '|' || COALESCE(metric_aux::VARCHAR, '')
    FROM staleness WHERE asset_kind = 'db_bloat' AND asset_id = '$(_esc "$DB_BLOAT_ASSET_ID")';
  " 2>/dev/null)"
  IFS='|' read -r prior_size prior_rows <<< "$prior"
  [ -n "$prior_size" ] && prior_size_sql="$prior_size"
  [ -n "$prior_rows" ] && prior_rows_sql="$prior_rows"

  if duck_run "$DB" -c "
    INSERT OR REPLACE INTO staleness
      (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours,
       last_exit_code, observed_at, metric_value, metric_value_prior,
       metric_aux, metric_aux_prior, metric_threshold_high)
    VALUES (
      'db_bloat', '$(_esc "$DB_BLOAT_ASSET_ID")', NULL,
      current_timestamp, ${DB_BLOAT_CADENCE_HOURS},
      NULL, current_timestamp, ${_size_bytes}, ${prior_size_sql},
      ${_rows}, ${prior_rows_sql}, ${DB_BLOAT_THRESHOLD_HIGH_BYTES_PER_ROW}
    );
  " >/dev/null 2>&1; then
    ROWS_WRITTEN=$((ROWS_WRITTEN + 1))
  else
    echo "staleness_collect: WARN upsert failed for db_bloat '${DB_BLOAT_ASSET_ID}'" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
}

# ─── collect_self_heartbeat: this script's own row ──────────────────────────
# Cadence (24h) matches com.claude.staleness-collect's daily 08:15 schedule
# (.claude/launchd/com.claude.staleness-collect.plist) — keep the two in sync
# if the schedule ever changes.
collect_self_heartbeat() {
  if duck_run "$DB" -c "
    INSERT OR REPLACE INTO staleness
      (asset_kind, asset_id, project, last_seen_ts, expected_cadence_hours, last_exit_code, observed_at)
    VALUES (
      'collector', 'staleness_collect', NULL,
      current_timestamp, 24, 0, current_timestamp
    );
  " >/dev/null 2>&1; then
    ROWS_WRITTEN=$((ROWS_WRITTEN + 1))
  else
    echo "staleness_collect: WARN could not write collector heartbeat" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─── SELFTEST ─────────────────────────────────────────────────────────────────
selftest() {
  local pass=0 fail=0 pid=$$

  _assert() {
    local label="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
      echo "PASS: ${label}"
      pass=$((pass + 1))
    else
      echo "FAIL: ${label} (got='${result}', want='${expected}')"
      fail=$((fail + 1))
    fi
  }

  _assert "override-sessions" "$(_etl_cadence_override sessions)" "72"
  _assert "override-skill_usage" "$(_etl_cadence_override skill_usage)" "336"
  _assert "override-command_usage" "$(_etl_cadence_override command_usage)" "168"
  _assert "override-agent_runs" "$(_etl_cadence_override agent_runs)" "48"
  _assert "override-llmtelemetry" "$(_etl_cadence_override llmtelemetry)" "24"
  _assert "override-config_staleness" "$(_etl_cadence_override config_staleness)" "120"
  _assert "override-unknown-source-empty" "$(_etl_cadence_override some_new_source)" ""

  if ! command -v duckdb >/dev/null 2>&1; then
    if ! (command -v nix-shell >/dev/null 2>&1 && [ -f "${NIX_DEFAULT}" ]); then
      echo "SKIP: duckdb not reachable; skipping fixture-based tests"
      echo "─────────────────────────────"
      echo "Selftest: ${pass} PASS, ${fail} FAIL"
      [ "$fail" -eq 0 ]
      return
    fi
  fi

  # Fixture DB: etl_freshness with a mix of cadenced + NULL-cadence rows.
  local fixture_db="/tmp/staleness_collect_selftest_${pid}.duckdb"
  rm -f "$fixture_db"
  duck_run "$fixture_db" -c "
    CREATE TABLE etl_freshness (
      source_name VARCHAR PRIMARY KEY,
      last_row_ts TIMESTAMP,
      last_etl_run_ts TIMESTAMP,
      expected_cadence_hours DOUBLE,
      status VARCHAR
    );
    INSERT INTO etl_freshness VALUES
      ('roborev', current_timestamp, current_timestamp, 24.0, 'fresh'),
      ('sessions', current_timestamp - INTERVAL 40 DAY, NULL, NULL, 'unknown'),
      ('mystery_source', current_timestamp, current_timestamp, NULL, 'unknown');
  " >/dev/null 2>&1

  DB="$fixture_db"
  ROWS_WRITTEN=0
  WARN_COUNT=0
  FAIL_COUNT=0
  duck_run "$fixture_db" < "$SCHEMA_SQL" >/dev/null 2>&1
  collect_etl_sources

  local r_roborev r_sessions r_mystery
  r_roborev="$(duck_run "$fixture_db" -noheader -list -c "SELECT expected_cadence_hours FROM staleness WHERE asset_id='roborev'" 2>/dev/null)"
  _assert "carried-cadence-roborev" "$r_roborev" "24.0"

  r_sessions="$(duck_run "$fixture_db" -noheader -list -c "SELECT expected_cadence_hours FROM staleness WHERE asset_id='sessions'" 2>/dev/null)"
  _assert "override-applied-sessions" "$r_sessions" "72.0"

  r_mystery="$(duck_run "$fixture_db" -noheader -list -c "SELECT COUNT(*) FROM staleness WHERE asset_id='mystery_source'" 2>/dev/null)"
  _assert "no-override-skipped-mystery_source" "$r_mystery" "0"
  _assert "warn-count-for-skipped-source" "$WARN_COUNT" "1"

  local r_sessions_status
  r_sessions_status="$(duck_run "$fixture_db" -noheader -list -c "SELECT status FROM staleness_status WHERE asset_id='sessions'" 2>/dev/null)"
  _assert "sessions-40d-stale-vs-72h-cadence" "$r_sessions_status" "stale"

  local r_roborev_status
  r_roborev_status="$(duck_run "$fixture_db" -noheader -list -c "SELECT status FROM staleness_status WHERE asset_id='roborev'" 2>/dev/null)"
  _assert "roborev-fresh-vs-24h-cadence" "$r_roborev_status" "fresh"

  rm -f "$fixture_db"

  # ── llm#893 step 4 (section D) — content-fact detectors ──────────────────
  # Separate fixture db from the etl fixture above, so a failure here is
  # unambiguously attributed to the content-fact feature. Each detector is
  # proven in BOTH directions: it fires on a synthetic case shaped like the
  # real incident it names, and stays quiet on a healthy case — proving only
  # the fire direction is worth little (a check that always fires "works" by
  # that standard too).
  local content_db="/tmp/staleness_collect_selftest_content_${pid}.duckdb"
  rm -f "$content_db"
  duck_run "$content_db" < "$SCHEMA_SQL" >/dev/null 2>&1

  # Detector 1: "a log stopped growing" (llm#886 tell) — pure time check,
  # reuses the EXISTING status machinery from steps 1-2 with
  # asset_kind='log_growth' — zero new columns needed for this direction.
  duck_run "$content_db" -c "
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at, metric_threshold_high)
    VALUES
      ('log_growth', 'stalled_case', current_timestamp - INTERVAL 100 HOUR, ${LOG_GROWTH_CADENCE_HOURS}, current_timestamp, ${LOG_GROWTH_THRESHOLD_HIGH_BYTES}),
      ('log_growth', 'healthy_case', current_timestamp - INTERVAL 1 HOUR,   ${LOG_GROWTH_CADENCE_HOURS}, current_timestamp, ${LOG_GROWTH_THRESHOLD_HIGH_BYTES});
  " >/dev/null 2>&1

  local d1_stalled d1_healthy
  d1_stalled="$(duck_run "$content_db" -noheader -list -c "SELECT status FROM staleness_status WHERE asset_id='stalled_case'" 2>/dev/null)"
  _assert "detector1-stopped-growing-fires-past-72h-gap" "$d1_stalled" "stale"
  d1_healthy="$(duck_run "$content_db" -noheader -list -c "SELECT status FROM staleness_status WHERE asset_id='healthy_case'" 2>/dev/null)"
  _assert "detector1-quiet-within-72h-cadence" "$d1_healthy" "fresh"

  # Detector 2: "a log grew abnormally" (llm#887: 74 MB poller log) —
  # magnitude delta vs metric_threshold_high, on the SAME threshold value
  # used in production (LOG_GROWTH_THRESHOLD_HIGH_BYTES = 2 MB).
  duck_run "$content_db" -c "
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at, metric_value, metric_value_prior, metric_threshold_high)
    VALUES
      ('log_growth', 'spike_case',  current_timestamp, ${LOG_GROWTH_CADENCE_HOURS}, current_timestamp, 5000000, 1000000, ${LOG_GROWTH_THRESHOLD_HIGH_BYTES}),
      ('log_growth', 'normal_case', current_timestamp, ${LOG_GROWTH_CADENCE_HOURS}, current_timestamp, 1050000, 1000000, ${LOG_GROWTH_THRESHOLD_HIGH_BYTES});
  " >/dev/null 2>&1

  local d2_spike d2_normal
  d2_spike="$(duck_run "$content_db" -noheader -list -c "SELECT content_status FROM staleness_status WHERE asset_id='spike_case'" 2>/dev/null)"
  _assert "detector2-abnormal-growth-fires-4MB-delta" "$d2_spike" "abnormal_growth"
  d2_normal="$(duck_run "$content_db" -noheader -list -c "SELECT content_status FROM staleness_status WHERE asset_id='normal_case'" 2>/dev/null)"
  _assert "detector2-quiet-50KB-delta" "$d2_normal" "normal"

  # Detector 3: "a DB grew without its row count growing" (llm#884: 7.1 GiB
  # for 61,635 rows = ~123,676 B/row) — density vs metric_threshold_high, on
  # the SAME threshold value used in production
  # (DB_BLOAT_THRESHOLD_HIGH_BYTES_PER_ROW = 60,000 B/row).
  duck_run "$content_db" -c "
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at, metric_value, metric_aux, metric_threshold_high)
    VALUES
      ('db_bloat', 'db_bloated_case', current_timestamp, ${DB_BLOAT_CADENCE_HOURS}, current_timestamp, 700000000, 1000, ${DB_BLOAT_THRESHOLD_HIGH_BYTES_PER_ROW}),
      ('db_bloat', 'db_healthy_case', current_timestamp, ${DB_BLOAT_CADENCE_HOURS}, current_timestamp, 20000000,  1000, ${DB_BLOAT_THRESHOLD_HIGH_BYTES_PER_ROW});
  " >/dev/null 2>&1

  # NB: asset_id is only unique per (asset_kind, asset_id) — the db_bloat
  # rows above use a 'db_'-prefixed asset_id distinct from the log_growth
  # 'healthy_case'/'spike_case' rows above so this SELECT (by asset_id
  # alone) can't accidentally match a row from a different asset_kind.
  local d3_bloated d3_healthy
  d3_bloated="$(duck_run "$content_db" -noheader -list -c "SELECT content_status FROM staleness_status WHERE asset_id='db_bloated_case'" 2>/dev/null)"
  _assert "detector3-bloat-fires-700KB-per-row" "$d3_bloated" "bloat"
  d3_healthy="$(duck_run "$content_db" -noheader -list -c "SELECT content_status FROM staleness_status WHERE asset_id='db_healthy_case'" 2>/dev/null)"
  _assert "detector3-quiet-20KB-per-row" "$d3_healthy" "normal"

  rm -f "$content_db"

  # ── Collector wiring: prove collect_log_growth()'s 2-deep retention runs
  # end-to-end (reads the prior metric_value before overwriting it) against a
  # temp fixture FILE — LOG_GROWTH_PATH/ASSET_ID are swapped for the
  # duration, never touching the real
  # ~/.claude/logs/roborev_poll_merges.log or the live unified.duckdb.
  local retention_db="/tmp/staleness_collect_selftest_retention_${pid}.duckdb"
  local fixture_log="/tmp/staleness_collect_selftest_log_${pid}.log"
  rm -f "$retention_db" "$fixture_log"
  duck_run "$retention_db" < "$SCHEMA_SQL" >/dev/null 2>&1
  printf 'line one\n' > "$fixture_log"   # 9 bytes

  local saved_log_path="$LOG_GROWTH_PATH" saved_log_id="$LOG_GROWTH_ASSET_ID"
  LOG_GROWTH_PATH="$fixture_log"
  LOG_GROWTH_ASSET_ID="selftest_fixture_log"
  DB="$retention_db"

  collect_log_growth
  local r1_value r1_prior
  r1_value="$(duck_run "$retention_db" -noheader -list -c "SELECT metric_value FROM staleness WHERE asset_id='selftest_fixture_log'" 2>/dev/null)"
  _assert "retention-first-run-metric-value-9-bytes" "$r1_value" "9.0"
  r1_prior="$(duck_run "$retention_db" -noheader -list -c "SELECT metric_value_prior FROM staleness WHERE asset_id='selftest_fixture_log'" 2>/dev/null)"
  _assert "retention-first-run-no-prior-yet" "$r1_prior" "NULL"

  printf 'line one\nline two has a lot more bytes than the first line did\n' > "$fixture_log"
  collect_log_growth
  local r2_prior
  r2_prior="$(duck_run "$retention_db" -noheader -list -c "SELECT metric_value_prior FROM staleness WHERE asset_id='selftest_fixture_log'" 2>/dev/null)"
  _assert "retention-second-run-prior-equals-first-runs-value" "$r2_prior" "9.0"

  LOG_GROWTH_PATH="$saved_log_path"
  LOG_GROWTH_ASSET_ID="$saved_log_id"
  rm -f "$retention_db" "$fixture_log"

  # collect_db_bloat() wiring: same retention proof, against the (also temp)
  # retention_db itself as the measured target — never the live unified.duckdb.
  local bloat_db="/tmp/staleness_collect_selftest_bloat_${pid}.duckdb"
  rm -f "$bloat_db"
  duck_run "$bloat_db" < "$SCHEMA_SQL" >/dev/null 2>&1
  DB="$bloat_db"
  collect_db_bloat
  local b1_prior
  b1_prior="$(duck_run "$bloat_db" -noheader -list -c "SELECT metric_value_prior FROM staleness WHERE asset_id='${DB_BLOAT_ASSET_ID}'" 2>/dev/null)"
  _assert "db_bloat-first-run-no-prior-yet" "$b1_prior" "NULL"
  collect_db_bloat
  local b2_prior b1_value
  b1_value="$(duck_run "$bloat_db" -noheader -list -c "SELECT metric_value FROM staleness WHERE asset_id='${DB_BLOAT_ASSET_ID}'" 2>/dev/null)"
  # After a second run, metric_value_prior must equal whatever metric_value
  # was after the first run (bloat_db is tiny and near-static between the two
  # calls, so this also incidentally proves the measurement itself is a real,
  # non-zero number rather than a stubbed/NULL fact).
  b2_prior="$(duck_run "$bloat_db" -noheader -list -c "SELECT metric_value_prior FROM staleness WHERE asset_id='${DB_BLOAT_ASSET_ID}'" 2>/dev/null)"
  if [ -n "$b1_value" ] && [ "$b1_value" != "NULL" ] && [ "$b1_value" != "0.0" ]; then
    echo "PASS: db_bloat-measures-nonzero-size (metric_value=${b1_value})"
    pass=$((pass + 1))
  else
    echo "FAIL: db_bloat-measures-nonzero-size (got metric_value='${b1_value}')"
    fail=$((fail + 1))
  fi
  _assert "db_bloat-second-run-prior-populated" "$([ "$b2_prior" != "NULL" ] && [ -n "$b2_prior" ] && echo yes || echo no)" "yes"
  rm -f "$bloat_db"

  echo "─────────────────────────────"
  echo "Selftest: ${pass} PASS, ${fail} FAIL"
  [ "$fail" -eq 0 ]
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "selftest" ]; then
  selftest
  exit $?
fi

if ! command -v duckdb >/dev/null 2>&1 && ! (command -v nix-shell >/dev/null 2>&1 && [ -f "${NIX_DEFAULT}" ]); then
  echo "staleness_collect: ERROR duckdb not available" >&2
  exit 1
fi
if [ ! -f "$DB" ]; then
  echo "staleness_collect: ERROR DB not found at ${DB}" >&2
  exit 1
fi

# Ensure schema exists (idempotent).
if [ -x "$SCHEMA_APPLY" ]; then
  bash "$SCHEMA_APPLY" --db "$DB" >/dev/null 2>&1 || {
    echo "staleness_collect: WARN schema apply failed" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
  }
else
  duck_run "$DB" < "$SCHEMA_SQL" >/dev/null 2>&1 || true
fi

# housekeeping_runs start row (see housekeeping-framework rule).
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
SCRIPT_ABS="${SCRIPT_DIR}/staleness_collect.sh"
duck_run "$DB" -c "
  INSERT OR IGNORE INTO housekeeping_runs
    (id, task, source_script, started_at, status, rows_written)
  VALUES ('${RUN_ID}', 'staleness_collect', '$(_esc "$SCRIPT_ABS")', current_timestamp, 'ok', 0);
" >/dev/null 2>&1 || true

collect_etl_sources
collect_launchd_jobs
collect_log_growth
collect_db_bloat
collect_self_heartbeat

STATUS="ok"
[ "$WARN_COUNT" -gt 0 ] && STATUS="partial"
[ "$FAIL_COUNT" -gt 0 ] && STATUS="failed"

duck_run "$DB" -c "
  UPDATE housekeeping_runs
  SET ended_at = current_timestamp,
      rows_written = ${ROWS_WRITTEN},
      status = '$(_esc "$STATUS")'
  WHERE id = '${RUN_ID}';
" >/dev/null 2>&1 || true

echo "staleness_collect: rows_written=${ROWS_WRITTEN} warnings=${WARN_COUNT} failures=${FAIL_COUNT} status=${STATUS}"

[ "$FAIL_COUNT" -eq 0 ]
