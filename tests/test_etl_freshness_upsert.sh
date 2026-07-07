#!/usr/bin/env bash
# tests/test_etl_freshness_upsert.sh
#
# Unit tests for the ETL freshness registry (JohnGavin/llm#309 Phase 1a):
#   .claude/scripts/etl_freshness_upsert.sh
#   .claude/scripts/etl_freshness_stale_banner.sh
#   .claude/hooks/session_init.sh Phase 15c wiring
#
# Every test runs against a freshly-created scratch DuckDB — never the live
# ~/.claude/logs/unified.duckdb.
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSERT="${SCRIPT_DIR}/../.claude/scripts/etl_freshness_upsert.sh"
BANNER="${SCRIPT_DIR}/../.claude/scripts/etl_freshness_stale_banner.sh"
SESSION_INIT="${SCRIPT_DIR}/../.claude/hooks/session_init.sh"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
    fail "${desc} — '${needle}' should NOT appear but does"
  else
    pass "${desc}"
  fi
}

if ! command -v duckdb >/dev/null 2>&1; then
  echo "SKIP: duckdb not in PATH — cannot run fixture-based tests"
  exit 0
fi

# ── Test 0: bash -n syntax check on all touched scripts ──────────────────────
for f in "${UPSERT}" "${BANNER}" "${SESSION_INIT}"; do
  rc=0
  bash -n "${f}" 2>/dev/null || rc=$?
  assert_eq "test0: bash -n exits 0 ($(basename "${f}"))" "0" "${rc}"
done

# ── Test 1: usage error — missing required args exits 1 ──────────────────────
rc1=0
bash "${UPSERT}" >/dev/null 2>&1 || rc1=$?
assert_eq "test1: missing args exits 1 (usage error)" "1" "${rc1}"

# ── Test 2: upsert with no --table/--file creates a row, status=unknown ──────
DB2="${TMPDIR_ROOT}/db2.duckdb"
rc2=0
bash "${UPSERT}" burn_rate "${DB2}" 24 >/dev/null 2>&1 || rc2=$?
assert_eq "test2: exit 0 with no table/file" "0" "${rc2}"

row2=$(duckdb -init /dev/null "${DB2}" -noheader -list -c \
  "SELECT source_name, status FROM etl_freshness WHERE source_name='burn_rate';" 2>/dev/null)
assert_contains "test2: row created for burn_rate" "burn_rate" "${row2}"
assert_contains "test2: status=unknown (no last_row_ts source)" "unknown" "${row2}"

# ── Test 3: cadence omitted (event-driven) -> status=unknown even with data ──
DB3="${TMPDIR_ROOT}/db3.duckdb"
duckdb -init /dev/null "${DB3}" -c "
  CREATE TABLE sessions (started_at TIMESTAMP);
  INSERT INTO sessions VALUES (current_timestamp);
" >/dev/null 2>&1

rc3=0
bash "${UPSERT}" sessions "${DB3}" "" --table sessions --ts-col started_at >/dev/null 2>&1 || rc3=$?
assert_eq "test3: exit 0 with empty cadence" "0" "${rc3}"

status3=$(duckdb -init /dev/null "${DB3}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='sessions';" 2>/dev/null)
assert_eq "test3: status=unknown when cadence omitted" "unknown" "${status3}"

# ── Test 4: last_row_ts 30 days back + cadence 24h -> status=stale ───────────
DB4="${TMPDIR_ROOT}/db4.duckdb"
duckdb -init /dev/null "${DB4}" -c "
  CREATE TABLE roborev_daily_metrics (etl_run_at TIMESTAMP);
  INSERT INTO roborev_daily_metrics VALUES (current_timestamp - INTERVAL 30 DAY);
" >/dev/null 2>&1

rc4=0
bash "${UPSERT}" roborev "${DB4}" 24 --table roborev_daily_metrics --ts-col etl_run_at \
  >/dev/null 2>&1 || rc4=$?
assert_eq "test4: exit 0" "0" "${rc4}"

status4=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='roborev';" 2>/dev/null)
assert_eq "test4: 30d-old row + 24h cadence -> stale" "stale" "${status4}"

# ── Test 5: same source, refreshed to 1 hour old -> status=fresh (idempotent) ─
duckdb -init /dev/null "${DB4}" -c "
  UPDATE roborev_daily_metrics SET etl_run_at = current_timestamp - INTERVAL 1 HOUR;
" >/dev/null 2>&1

rc5=0
bash "${UPSERT}" roborev "${DB4}" 24 --table roborev_daily_metrics --ts-col etl_run_at \
  >/dev/null 2>&1 || rc5=$?
assert_eq "test5: exit 0" "0" "${rc5}"

status5=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='roborev';" 2>/dev/null)
assert_eq "test5: 1h-old row + 24h cadence -> fresh" "fresh" "${status5}"

rowcount5=$(duckdb -init /dev/null "${DB4}" -noheader -list -c \
  "SELECT COUNT(*) FROM etl_freshness WHERE source_name='roborev';" 2>/dev/null)
assert_eq "test5: idempotent — still exactly 1 row for roborev" "1" "${rowcount5}"

# ── Test 6: --table pointing at a non-existent table -> status=unknown, no error ─
DB6="${TMPDIR_ROOT}/db6.duckdb"
rc6=0
bash "${UPSERT}" ghost "${DB6}" 24 --table does_not_exist --ts-col ts >/dev/null 2>&1 || rc6=$?
assert_eq "test6: exit 0 even when table missing" "0" "${rc6}"

status6=$(duckdb -init /dev/null "${DB6}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='ghost';" 2>/dev/null)
assert_eq "test6: missing table -> unknown (last_row_ts NULL)" "unknown" "${status6}"

# ── Test 7: --file mode uses file mtime; stale file -> status=stale ──────────
DB7="${TMPDIR_ROOT}/db7.duckdb"
STALE_FILE="${TMPDIR_ROOT}/stale_events.jsonl"
echo '{"ts":"old"}' > "${STALE_FILE}"
# Backdate the file's mtime by 30 days (portable: touch -t or -d)
OLD_TS="$(date -v-30d '+%Y%m%d%H%M' 2>/dev/null || date -d '-30 days' '+%Y%m%d%H%M')"
touch -t "${OLD_TS}" "${STALE_FILE}" 2>/dev/null || true

rc7=0
bash "${UPSERT}" llmtelemetry "${DB7}" 24 --file "${STALE_FILE}" >/dev/null 2>&1 || rc7=$?
assert_eq "test7: exit 0 with --file mode" "0" "${rc7}"

status7=$(duckdb -init /dev/null "${DB7}" -noheader -list -c \
  "SELECT status FROM etl_freshness WHERE source_name='llmtelemetry';" 2>/dev/null)
assert_eq "test7: 30d-old file + 24h cadence -> stale" "stale" "${status7}"

# ── Test 8: duckdb missing from PATH -> upsert exits 0 (fail-open) ───────────
DB8="${TMPDIR_ROOT}/db8.duckdb"
rc8=0
PATH="/usr/bin:/bin" bash "${UPSERT}" x "${DB8}" 24 >/dev/null 2>&1 || rc8=$?
assert_eq "test8: exit 0 when duckdb absent from PATH" "0" "${rc8}"

# ── Test 9: banner is silent when nothing is stale ───────────────────────────
DB9="${TMPDIR_ROOT}/db9.duckdb"
bash "${UPSERT}" fresh_source "${DB9}" 24 --file "${STALE_FILE}" >/dev/null 2>&1
# Overwrite it fresh directly for a clean fresh row
duckdb -init /dev/null "${DB9}" -c "
  UPDATE etl_freshness SET last_row_ts = current_timestamp, status = 'fresh'
  WHERE source_name = 'fresh_source';
" >/dev/null 2>&1

out9=$(ETL_FRESHNESS_DB="${DB9}" bash "${BANNER}" 2>&1)
rc9=$?
assert_eq "test9: banner exits 0" "0" "${rc9}"
assert_eq "test9: banner prints nothing when all fresh" "" "${out9}"

# ── Test 10: banner prints one STALE line per stale source ───────────────────
duckdb -init /dev/null "${DB9}" -c "
  INSERT OR REPLACE INTO etl_freshness
    (source_name, last_row_ts, last_etl_run_ts, expected_cadence_hours, status)
  VALUES ('burn_rate', current_timestamp - INTERVAL 3 DAY, current_timestamp, 24, 'stale');
" >/dev/null 2>&1

out10=$(ETL_FRESHNESS_DB="${DB9}" bash "${BANNER}" 2>&1)
rc10=$?
assert_eq "test10: banner exits 0 with a stale row present" "0" "${rc10}"
assert_contains "test10: banner reports STALE: burn_rate" "STALE: burn_rate" "${out10}"
assert_not_contains "test10: banner does not report fresh_source" "STALE: fresh_source" "${out10}"

# ── Test 11: banner never exits non-zero on a query miss ─────────────────────
# 11a: DB file missing entirely
rc11a=0
ETL_FRESHNESS_DB="/tmp/no_such_etl_freshness_db_$$" bash "${BANNER}" >/dev/null 2>&1 || rc11a=$?
assert_eq "test11a: banner exit 0 on missing DB" "0" "${rc11a}"

# 11b: DB exists but etl_freshness table does not (query miss)
DB11B="${TMPDIR_ROOT}/db11b.duckdb"
duckdb -init /dev/null "${DB11B}" -c "CREATE TABLE unrelated (x INTEGER);" >/dev/null 2>&1
rc11b=0
ETL_FRESHNESS_DB="${DB11B}" bash "${BANNER}" >/dev/null 2>&1 || rc11b=$?
assert_eq "test11b: banner exit 0 when etl_freshness table missing" "0" "${rc11b}"

# 11c: duckdb missing from PATH entirely
rc11c=0
PATH="/usr/bin:/bin" ETL_FRESHNESS_DB="${DB9}" bash "${BANNER}" >/dev/null 2>&1 || rc11c=$?
assert_eq "test11c: banner exit 0 when duckdb absent from PATH" "0" "${rc11c}"

# ── Test 12: session_init.sh wires Phase 15c to the banner script ────────────
assert_eq "test12: etl_freshness_stale_banner.sh is executable" "1" \
  "$([ -x "${BANNER}" ] && echo 1 || echo 0)"

phase15c_present=$(grep -c "etl_freshness_stale_banner.sh" "${SESSION_INIT}" || true)
if [ "${phase15c_present:-0}" -ge 1 ]; then
  pass "test12: session_init.sh references etl_freshness_stale_banner.sh"
else
  fail "test12: session_init.sh does not reference etl_freshness_stale_banner.sh"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
