#!/usr/bin/env bash
# tests/test_etl_freshness_upsert.sh
#
# Unit tests for the ETL freshness registry (JohnGavin/llm#309 Phase 1a):
#   .claude/scripts/etl_freshness_upsert.sh
#
# etl_freshness_upsert.sh records FACTS only (last_row_ts, last_etl_run_ts,
# expected_cadence_hours) — it no longer computes a `status` verdict. The
# authoritative staleness answer is the `staleness_status` view (llm#893),
# recomputed at every read from facts collected by
# .claude/scripts/staleness_collect.sh (one of whose inputs is this table).
# The retired write-time `status` column and its session_init.sh Phase 15c
# banner (etl_freshness_stale_banner.sh) were removed in llm#913; that
# coverage is superseded by Phase 15d (staleness_banner.sh) and
# tests/testthat/test-staleness-collect.R.
#
# Every test runs against a freshly-created scratch DuckDB — never the live
# ~/.claude/logs/unified.duckdb.
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSERT="${SCRIPT_DIR}/../.claude/scripts/etl_freshness_upsert.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass "${desc}"
  else
    fail "${desc} — expected='${expected}' actual='${actual}'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
    pass "${desc}"
  else
    fail "${desc} — '${needle}' not found in output: ${haystack}"
  fi
}

if ! command -v duckdb >/dev/null 2>&1; then
  echo "SKIP: duckdb not in PATH — cannot run fixture-based tests"
  exit 0
fi

# ── Test 0: bash -n syntax check on the touched script ───────────────────────
rc0=0
bash -n "${UPSERT}" 2>/dev/null || rc0=$?
assert_eq "test0: bash -n exits 0 ($(basename "${UPSERT}"))" "0" "${rc0}"

# ── Test 1: usage error — missing required args exits 1 ──────────────────────
rc1=0
bash "${UPSERT}" >/dev/null 2>&1 || rc1=$?
assert_eq "test1: missing args exits 1 (usage error)" "1" "${rc1}"

# ── Test 2: upsert with no --table/--file creates a row; facts recorded, status NULL ─
DB2="${TMPDIR_ROOT}/db2.duckdb"
rc2=0
bash "${UPSERT}" burn_rate "${DB2}" 24 >/dev/null 2>&1 || rc2=$?
assert_eq "test2: exit 0 with no table/file" "0" "${rc2}"

row2=$(duckdb -init /dev/null "${DB2}" -noheader -list -c \
  "SELECT source_name, expected_cadence_hours, status FROM etl_freshness WHERE source_name='burn_rate';" 2>/dev/null)
assert_contains "test2: row created for burn_rate" "burn_rate" "${row2}"

cadence2=$(duckdb -init /dev/null "${DB2}" -noheader -list -c \
  "SELECT expected_cadence_hours FROM etl_freshness WHERE source_name='burn_rate';" 2>/dev/null)
assert_eq "test2: expected_cadence_hours round-trips (24)" "24.0" "${cadence2}"

lastetl2=$(duckdb -init /dev/null "${DB2}" -noheader -list -c \
  "SELECT COUNT(*) FROM etl_freshness WHERE source_name='burn_rate' AND last_etl_run_ts IS NOT NULL;" 2>/dev/null)
assert_eq "test2: last_etl_run_ts populated" "1" "${lastetl2}"

status2=$(duckdb -init /dev/null "${DB2}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='burn_rate';" 2>/dev/null)
assert_eq "test2: status is NULL (no longer written)" "NULL" "${status2}"

# ── Test 3: cadence omitted (event-driven) -> expected_cadence_hours NULL ────
DB3="${TMPDIR_ROOT}/db3.duckdb"
duckdb -init /dev/null "${DB3}" -c "
  CREATE TABLE sessions (started_at TIMESTAMP);
  INSERT INTO sessions VALUES (current_timestamp);
" >/dev/null 2>&1

rc3=0
bash "${UPSERT}" sessions "${DB3}" "" --table sessions --ts-col started_at >/dev/null 2>&1 || rc3=$?
assert_eq "test3: exit 0 with empty cadence" "0" "${rc3}"

cadence3=$(duckdb -init /dev/null "${DB3}" -noheader -list -c \
  "SELECT expected_cadence_hours FROM etl_freshness WHERE source_name='sessions';" 2>/dev/null)
assert_eq "test3: expected_cadence_hours NULL when cadence omitted" "NULL" "${cadence3}"

lastrow3=$(duckdb -init /dev/null "${DB3}" -noheader -list -c \
  "SELECT COUNT(*) FROM etl_freshness WHERE source_name='sessions' AND last_row_ts IS NOT NULL;" 2>/dev/null)
assert_eq "test3: last_row_ts populated from --table/--ts-col" "1" "${lastrow3}"

status3=$(duckdb -init /dev/null "${DB3}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='sessions';" 2>/dev/null)
assert_eq "test3: status is NULL" "NULL" "${status3}"

# ── Test 4: last_row_ts 30 days back + cadence 24h -> facts recorded, status NULL ─
DB4="${TMPDIR_ROOT}/db4.duckdb"
duckdb -init /dev/null "${DB4}" -c "
  CREATE TABLE roborev_daily_metrics (etl_run_at TIMESTAMP);
  INSERT INTO roborev_daily_metrics VALUES (current_timestamp - INTERVAL 30 DAY);
" >/dev/null 2>&1

rc4=0
bash "${UPSERT}" roborev "${DB4}" 24 --table roborev_daily_metrics --ts-col etl_run_at \
  >/dev/null 2>&1 || rc4=$?
assert_eq "test4: exit 0" "0" "${rc4}"

age4=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT COUNT(*) FROM etl_freshness WHERE source_name='roborev' AND last_row_ts < current_timestamp - INTERVAL 29 DAY;" 2>/dev/null)
assert_eq "test4: last_row_ts reflects the 30d-old source row" "1" "${age4}"

cadence4=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT expected_cadence_hours FROM etl_freshness WHERE source_name='roborev';" 2>/dev/null)
assert_eq "test4: expected_cadence_hours round-trips (24)" "24.0" "${cadence4}"

status4=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='roborev';" 2>/dev/null)
assert_eq "test4: status is NULL" "NULL" "${status4}"

# ── Test 5: same source, refreshed to 1 hour old -> idempotent, facts updated ─
duckdb -init /dev/null "${DB4}" -c "
  UPDATE roborev_daily_metrics SET etl_run_at = current_timestamp - INTERVAL 1 HOUR;
" >/dev/null 2>&1

rc5=0
bash "${UPSERT}" roborev "${DB4}" 24 --table roborev_daily_metrics --ts-col etl_run_at \
  >/dev/null 2>&1 || rc5=$?
assert_eq "test5: exit 0" "0" "${rc5}"

age5=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT COUNT(*) FROM etl_freshness WHERE source_name='roborev' AND last_row_ts > current_timestamp - INTERVAL 2 HOUR;" 2>/dev/null)
assert_eq "test5: last_row_ts refreshed to ~1h old" "1" "${age5}"

rowcount5=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT COUNT(*) FROM etl_freshness WHERE source_name='roborev';" 2>/dev/null)
assert_eq "test5: idempotent — still exactly 1 row for roborev" "1" "${rowcount5}"

status5=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='roborev';" 2>/dev/null)
assert_eq "test5: status is NULL" "NULL" "${status5}"

# ── Test 6: --table pointing at a non-existent table -> no error, last_row_ts NULL ─
DB6="${TMPDIR_ROOT}/db6.duckdb"
rc6=0
bash "${UPSERT}" ghost "${DB6}" 24 --table does_not_exist --ts-col ts >/dev/null 2>&1 || rc6=$?
assert_eq "test6: exit 0 even when table missing" "0" "${rc6}"

lastrow6=$(duckdb -init /dev/null "${DB6}" -noheader -list -c \
  "SELECT last_row_ts FROM etl_freshness WHERE source_name='ghost';" 2>/dev/null)
assert_eq "test6: missing table -> last_row_ts stays NULL" "NULL" "${lastrow6}"

status6=$(duckdb -init /dev/null "${DB6}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='ghost';" 2>/dev/null)
assert_eq "test6: status is NULL" "NULL" "${status6}"

# ── Test 7: --file mode uses file mtime for last_row_ts ──────────────────────
DB7="${TMPDIR_ROOT}/db7.duckdb"
STALE_FILE="${TMPDIR_ROOT}/stale_events.jsonl"
echo '{"ts":"old"}' > "${STALE_FILE}"
# Backdate the file's mtime by 30 days (portable: touch -t or -d)
OLD_TS="$(date -v-30d '+%Y%m%d%H%M' 2>/dev/null || date -d '-30 days' '+%Y%m%d%H%M')"
touch -t "${OLD_TS}" "${STALE_FILE}" 2>/dev/null || true

rc7=0
bash "${UPSERT}" llmtelemetry "${DB7}" 24 --file "${STALE_FILE}" >/dev/null 2>&1 || rc7=$?
assert_eq "test7: exit 0 with --file mode" "0" "${rc7}"

age7=$(duckdb -init /dev/null "${DB7}" -noheader -list -c \
  "SELECT COUNT(*) FROM etl_freshness WHERE source_name='llmtelemetry' AND last_row_ts < current_timestamp - INTERVAL 29 DAY;" 2>/dev/null)
assert_eq "test7: last_row_ts derived from 30d-old file mtime" "1" "${age7}"

status7=$(duckdb -init /dev/null "${DB7}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='llmtelemetry';" 2>/dev/null)
assert_eq "test7: status is NULL" "NULL" "${status7}"

# ── Test 8: duckdb missing from PATH -> upsert exits 0 (fail-open) ───────────
DB8="${TMPDIR_ROOT}/db8.duckdb"
rc8=0
PATH="/usr/bin:/bin" bash "${UPSERT}" x "${DB8}" 24 >/dev/null 2>&1 || rc8=$?
assert_eq "test8: exit 0 when duckdb absent from PATH" "0" "${rc8}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
