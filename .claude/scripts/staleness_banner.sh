#!/usr/bin/env bash
# staleness_banner.sh — session-start banner for the consolidated staleness table.
#
# Reads the `staleness_status` view (llm#893 steps 1-2; populated by
# .claude/scripts/staleness_collect.sh) and implements the out-of-band check
# that fixes defect 3: every prior checker was itself a launchd job, so a
# total launchd outage (llm#886) silenced the monitor along with everything
# it watched. This script is wired into session_init.sh — a different
# trigger class from launchd — so a dead collector becomes visible the next
# time a session starts, not after days of silence.
#
# llm#893 step 4 (section D) added a SECOND, independent verdict to the same
# view: `content_status` (magnitude, not recency — "did this asset's size
# grow unusually?" vs status's "is this asset recent?"). Steps 3 (this
# email/banner surfacing work) and 4 (the detectors) landed concurrently, so
# neither originally rendered content_status — the detectors recorded
# faithfully but were invisible. Priority 3 below closes that gap.
#
# Rule, in priority order:
#   1. If the collector's own heartbeat row is missing or stale, print ONLY
#      that — when the collector is dead, no other row in the table is
#      trustworthy, so nothing else (including content findings) is worth
#      printing.
#   2. Otherwise, if any other asset is stale on the TIME axis (status),
#      print a capped one-line summary naming up to STALENESS_BANNER_MAX
#      assets.
#   3. Otherwise, surface CONTENT-axis findings (content_status) for the two
#      asset_kinds that carry one (log_growth, db_bloat):
#        a. any FIRED finding (content_status IN ('abnormal_growth','bloat'))
#           — a capped one-line summary naming the asset(s), same style as
#           priority 2.
#        b. any PENDING finding (content_status IS NULL — the delta-based
#           detector has no prior observation to diff against yet) — a
#           distinct one-line count. This is NOT folded into "no output" the
#           way a genuinely healthy ('normal') asset is: an absent verdict
#           must never read the same as a clean one, or a check that has
#           never run looks identical to a check that passed. That
#           conflation is the exact failure this priority exists to close
#           (see the content_status doc block in staleness_schema.sql).
#      A 'normal' content_status prints nothing — that is the genuinely
#      quiet case, same as a 'fresh' time status in priority 2.
#   4. Otherwise, silent.
#
# Usage:
#   staleness_banner.sh
#   STALENESS_DB=/path/to/scratch.duckdb staleness_banner.sh   # ad-hoc testing
#   staleness_banner.sh --selftest                              # fixture-based
#                                                                # proof; never
#                                                                # touches the
#                                                                # live DB
#
# Fail-open: a missing duckdb binary, a missing DB, a missing `staleness`
# table/view, or any query error in the mandatory priority-1/2 checks all
# print nothing and exit 0 (never aborts the caller under `set -euo
# pipefail` — hook-pipefail-no-stderr lesson, llm#695). The priority-3
# content queries are additionally isolated with `|| true` so a failure
# there degrades to "no content line printed" without discarding a
# priority-2 line that already rendered successfully.
#
# Tracked in llm#893 step 2 (time axis) and step 4 (content axis, this
# file's priority-3 addition).

set -uo pipefail

MAX_NAMED="${STALENESS_BANNER_MAX:-6}"

# ─── render: emit the banner for one DB path. Read-only; never writes.
# Isolated into a function so --selftest can call it against disposable
# fixture DBs without ever touching $HOME/.claude/logs/unified.duckdb.
render() {
  local db="$1"

  command -v duckdb >/dev/null 2>&1 || return 0
  [ -f "$db" ] || return 0

  # ─── Collector heartbeat check (priority 1) ────────────────────────────────
  # NULL-safe: if the `staleness` table/view doesn't exist yet, or the
  # collector has never written a row, this query returns nothing — treated
  # the same as "collector stale" (fail-safe, not silent-benign).
  local _collector_row
  _collector_row=$(duckdb -init /dev/null "$db" -noheader -list -c "
    SELECT status || '|' ||
           COALESCE(CAST(FLOOR(EXTRACT(EPOCH FROM (current_timestamp - last_seen_ts)) / 3600.0) AS BIGINT)::VARCHAR, '')
    FROM staleness_status
    WHERE asset_kind = 'collector' AND asset_id = 'staleness_collect';
  " 2>/dev/null) || return 0

  if [ -z "$_collector_row" ]; then
    echo "staleness: COLLECTOR STALE (never observed) — all staleness data untrustworthy"
    return 0
  fi

  local _collector_status="${_collector_row%%|*}"
  local _collector_hours="${_collector_row#*|}"

  if [ "$_collector_status" = "stale" ]; then
    if [ -n "$_collector_hours" ]; then
      echo "staleness: COLLECTOR STALE (last ran ${_collector_hours}h ago) — all staleness data untrustworthy"
    else
      echo "staleness: COLLECTOR STALE — all staleness data untrustworthy"
    fi
    return 0
  fi

  # ─── Other stale assets, TIME axis (priority 2) ────────────────────────────
  local _stale_rows
  _stale_rows=$(duckdb -init /dev/null "$db" -noheader -list -c "
    SELECT asset_kind || ':' || asset_id
    FROM staleness_status
    WHERE status = 'stale' AND asset_kind != 'collector'
    ORDER BY asset_kind, asset_id;
  " 2>/dev/null) || return 0

  if [ -n "$_stale_rows" ]; then
    local _total _named _extra
    _total=$(printf '%s\n' "$_stale_rows" | grep -c . || true)
    _named=$(printf '%s\n' "$_stale_rows" | head -n "$MAX_NAMED" | paste -sd, -)
    _extra=$(( _total - MAX_NAMED ))
    if [ "$_extra" -gt 0 ]; then
      echo "staleness: ${_total} stale (${_named}, +${_extra} more)"
    else
      echo "staleness: ${_total} stale (${_named})"
    fi
  fi

  # ─── Content-axis findings (priority 3, llm#893 step 4) ────────────────────
  # content_status is only ever non-NULL-by-design for log_growth/db_bloat —
  # every other asset_kind is permanently NULL there (never content-checked;
  # correctly rendered as nothing, not as "pending"). Restricting both
  # queries to these two kinds keeps a permanently-NULL etl_source/
  # launchd_job/collector row from being misread as "not yet assessed".
  #
  # Isolated from the mandatory priority-1/2 checks above with `|| true`: a
  # failure here must not discard a priority-2 line that already printed.
  local _flagged_rows
  _flagged_rows=$(duckdb -init /dev/null "$db" -noheader -list -c "
    SELECT asset_kind || ':' || asset_id || '=' || content_status
    FROM staleness_status
    WHERE asset_kind IN ('log_growth', 'db_bloat')
      AND content_status IN ('abnormal_growth', 'bloat')
    ORDER BY asset_kind, asset_id;
  " 2>/dev/null) || true

  if [ -n "${_flagged_rows:-}" ]; then
    local _ftotal _fnamed _fextra
    _ftotal=$(printf '%s\n' "$_flagged_rows" | grep -c . || true)
    _fnamed=$(printf '%s\n' "$_flagged_rows" | head -n "$MAX_NAMED" | paste -sd, -)
    _fextra=$(( _ftotal - MAX_NAMED ))
    if [ "$_fextra" -gt 0 ]; then
      echo "staleness-content: ${_ftotal} flagged (${_fnamed}, +${_fextra} more)"
    else
      echo "staleness-content: ${_ftotal} flagged (${_fnamed})"
    fi
  fi

  # PENDING is reported as a count only (no per-asset naming) — it names a
  # gap in coverage, not a specific problem asset, so there is nothing
  # actionable to point at yet. It must still be VISIBLE and distinct from
  # silence: a check that has never produced a verdict must not read the
  # same as a check that passed.
  local _pending_count
  _pending_count=$(duckdb -init /dev/null "$db" -noheader -list -c "
    SELECT COUNT(*)
    FROM staleness_status
    WHERE asset_kind IN ('log_growth', 'db_bloat')
      AND content_status IS NULL;
  " 2>/dev/null) || true
  case "${_pending_count:-}" in
    ''|*[!0-9]*) _pending_count=0 ;;
  esac

  if [ "$_pending_count" -gt 0 ]; then
    echo "staleness-content: ${_pending_count} not yet assessed (no prior observation to compare against)"
  fi

  return 0
}

# ─── SELFTEST ─────────────────────────────────────────────────────────────────
# Fixture-based proof, entirely against disposable /tmp DuckDB files. Never
# reads or writes STALENESS_DB / $HOME/.claude/logs/unified.duckdb.
selftest() {
  local pass=0 fail=0 pid=$$

  _assert_eq() {
    local label="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
      echo "PASS: ${label}"
      pass=$((pass + 1))
    else
      echo "FAIL: ${label} (got='${result}', want='${expected}')"
      fail=$((fail + 1))
    fi
  }

  _assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
      echo "PASS: ${label}"
      pass=$((pass + 1))
    else
      echo "FAIL: ${label} (expected to find '${needle}' in output)"
      echo "  --- actual output ---"
      printf '%s\n' "$haystack" | sed 's/^/  | /'
      fail=$((fail + 1))
    fi
  }

  _assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
      echo "FAIL: ${label} (did NOT expect to find '${needle}' in output)"
      echo "  --- actual output ---"
      printf '%s\n' "$haystack" | sed 's/^/  | /'
      fail=$((fail + 1))
    else
      echo "PASS: ${label}"
      pass=$((pass + 1))
    fi
  }

  if ! command -v duckdb >/dev/null 2>&1; then
    echo "SKIP: duckdb not on PATH; skipping fixture-based tests"
    echo "─────────────────────────────"
    echo "Selftest: ${pass} PASS, ${fail} FAIL"
    [ "$fail" -eq 0 ]
    return
  fi

  local script_dir schema_sql
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  schema_sql="${script_dir}/staleness_schema.sql"

  if [ ! -f "$schema_sql" ]; then
    echo "SKIP: ${schema_sql} not found; skipping fixture-based tests"
    echo "─────────────────────────────"
    echo "Selftest: ${pass} PASS, ${fail} FAIL"
    [ "$fail" -eq 0 ]
    return
  fi

  # ── Fixture 1: collector STALE suppresses everything below it, including
  # both a time-stale asset AND a fired content finding. ─────────────────────
  local db1="/tmp/staleness_banner_selftest_collector_stale_${pid}.duckdb"
  rm -f "$db1"
  duckdb -init /dev/null "$db1" < "$schema_sql" >/dev/null 2>&1
  duckdb -init /dev/null "$db1" -c "
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at)
    VALUES ('collector', 'staleness_collect', current_timestamp - INTERVAL 30 HOUR, 24, current_timestamp - INTERVAL 30 HOUR);
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at)
    VALUES ('etl_source', 'roborev', current_timestamp - INTERVAL 100 HOUR, 24, current_timestamp - INTERVAL 30 HOUR);
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at,
                            metric_value, metric_value_prior, metric_threshold_high)
    VALUES ('log_growth', 'roborev_poll_merges.log', current_timestamp, 72, current_timestamp - INTERVAL 30 HOUR,
            5000000, 1000000, 2000000);
  " >/dev/null 2>&1

  local out1
  out1="$(render "$db1")"
  _assert_contains "fixture1-collector-stale-message-present" "$out1" "COLLECTOR STALE"
  _assert_not_contains "fixture1-suppresses-etl-stale-summary" "$out1" "roborev"
  _assert_not_contains "fixture1-suppresses-content-flagged-line" "$out1" "staleness-content:"
  _assert_eq "fixture1-exactly-one-line" "$(printf '%s\n' "$out1" | grep -c .)" "1"
  rm -f "$db1"

  # ── Fixture 2: collector FRESH, three content states must render
  # distinguishably — fired, ok (silent), and NULL/pending (visible, distinct
  # from both silence and a fired finding). ──────────────────────────────────
  local db2="/tmp/staleness_banner_selftest_content_states_${pid}.duckdb"
  rm -f "$db2"
  duckdb -init /dev/null "$db2" < "$schema_sql" >/dev/null 2>&1
  duckdb -init /dev/null "$db2" -c "
    -- collector: fresh
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at)
    VALUES ('collector', 'staleness_collect', current_timestamp, 24, current_timestamp);

    -- content_status = 'abnormal_growth' (FIRED): delta 4,000,000 > threshold 2,000,000
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at,
                            metric_value, metric_value_prior, metric_threshold_high)
    VALUES ('log_growth', 'flagged_log', current_timestamp, 72, current_timestamp,
            5000000, 1000000, 2000000);

    -- content_status = 'normal' (OK): delta 50,000 <= threshold 2,000,000
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at,
                            metric_value, metric_value_prior, metric_threshold_high)
    VALUES ('log_growth', 'normal_log', current_timestamp, 72, current_timestamp,
            1050000, 1000000, 2000000);

    -- content_status = NULL (PENDING): no metric_value_prior yet (first-ever observation)
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at,
                            metric_value, metric_threshold_high)
    VALUES ('db_bloat', 'pending_db', current_timestamp, 24, current_timestamp,
            20000000, 60000);
  " >/dev/null 2>&1

  local out2
  out2="$(render "$db2")"
  _assert_not_contains "fixture2-collector-fresh-no-stale-message" "$out2" "COLLECTOR STALE"
  _assert_contains    "fixture2-fired-finding-visible" "$out2" "staleness-content: 1 flagged (log_growth:flagged_log=abnormal_growth)"
  _assert_contains    "fixture2-pending-finding-visible-and-distinct" "$out2" "staleness-content: 1 not yet assessed (no prior observation to compare against)"
  _assert_not_contains "fixture2-normal-asset-not-named-in-flagged-line" "$out2" "normal_log"
  _assert_not_contains "fixture2-normal-asset-not-named-anywhere" "$out2" "=normal"
  rm -f "$db2"

  # ── Fixture 3: silent when everything is fresh/normal and nothing is
  # content-checked. ──────────────────────────────────────────────────────────
  local db3="/tmp/staleness_banner_selftest_all_fresh_${pid}.duckdb"
  rm -f "$db3"
  duckdb -init /dev/null "$db3" < "$schema_sql" >/dev/null 2>&1
  duckdb -init /dev/null "$db3" -c "
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at)
    VALUES ('collector', 'staleness_collect', current_timestamp, 24, current_timestamp);
    INSERT INTO staleness (asset_kind, asset_id, last_seen_ts, expected_cadence_hours, observed_at)
    VALUES ('etl_source', 'roborev', current_timestamp, 24, current_timestamp);
  " >/dev/null 2>&1

  local out3
  out3="$(render "$db3")"
  _assert_eq "fixture3-silent-when-all-fresh" "$out3" ""
  rm -f "$db3"

  # ── Fixture 4: missing DB fails open (no output, render() returns 0). ─────
  local missing_db="/tmp/staleness_banner_selftest_missing_${pid}.duckdb"
  rm -f "$missing_db"
  local out4 rc4
  out4="$(render "$missing_db")"; rc4=$?
  _assert_eq "fixture4-missing-db-silent" "$out4" ""
  _assert_eq "fixture4-missing-db-exit-zero" "$rc4" "0"

  echo "─────────────────────────────"
  echo "Selftest: ${pass} PASS, ${fail} FAIL"
  [ "$fail" -eq 0 ]
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

DB="${STALENESS_DB:-${HOME}/.claude/logs/unified.duckdb}"
render "$DB"
exit 0
