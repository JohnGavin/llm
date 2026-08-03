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
_etl_cadence_override() {
  case "$1" in
    sessions)      echo "72" ;;
    skill_usage)   echo "336" ;;
    command_usage) echo "168" ;;
    agent_runs)    echo "48" ;;
    llmtelemetry)  echo "24" ;;
    *)             echo "" ;;
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
