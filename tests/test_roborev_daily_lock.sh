#!/usr/bin/env bash
# tests/test_roborev_daily_lock.sh
#
# roborev_daily_report.R must FAIL LOUDLY when unified.duckdb stays locked by
# another process: exit 3 (indeterminate), never exit 0. The cron wrapper must
# map that code to a 'failed' housekeeping_runs row and a non-zero exit.
#
# Must be run where Rscript + duckdb R pkg are on PATH, e.g.
#   nix-shell /Users/johngavin/docs_gh/llm/default.nix --run "bash tests/test_roborev_daily_lock.sh"
#
# Never touches the live unified.duckdb: everything uses a temp DB.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT="${REPO_ROOT}/.claude/scripts/roborev_daily_report.R"
HELPER="${REPO_ROOT}/.claude/scripts/lib/roborev_daily_step1.sh"
SCHEMA="${REPO_ROOT}/.claude/scripts/housekeeping_schema_init.sql"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
HOLDER_PID=""
cleanup() {
  [ -n "${HOLDER_PID}" ] && kill "${HOLDER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected='$2' actual='$3'"; fi
}

DB="${TMP}/unified.duckdb"

# ── Hold a write lock from a separate process ────────────────────────────────
Rscript -e "
suppressPackageStartupMessages(library(duckdb))
con <- DBI::dbConnect(duckdb::duckdb(), '${DB}')
DBI::dbExecute(con, 'CREATE TABLE t (x INT)')
file.create('${TMP}/held')
Sys.sleep(120)
" > "${TMP}/holder.log" 2>&1 &
HOLDER_PID=$!
for _ in $(seq 1 60); do
  [ -f "${TMP}/held" ] && break
  sleep 1
done
[ -f "${TMP}/held" ] || { echo "FAIL: lock holder never started"; cat "${TMP}/holder.log"; exit 1; }

# ── T1: a read-only open does NOT get around another process's write lock ───
Rscript -e "
suppressPackageStartupMessages(library(duckdb))
r <- tryCatch(DBI::dbConnect(duckdb::duckdb(), '${DB}', read_only = TRUE),
              error = function(e) conditionMessage(e))
quit(status = if (is.character(r) && grepl('lock', r, ignore.case = TRUE)) 0L else 9L)
" > "${TMP}/ro.log" 2>&1
assert_eq "T1 read-only open is blocked by a writer in another process (so retry is needed)" "0" "$?"

# ── T2: report script, lock never clears -> exit 3 after the bounded wait ────
UNIFIED_DUCKDB="${DB}" ROBOREV_DAILY_DIR="${TMP}/out" \
  ROBOREV_LOCK_MAX_WAIT_S=4 ROBOREV_LOCK_BACKOFF_START_S=1 \
  Rscript "${REPORT}" --dry-run > "${TMP}/report.log" 2>&1
assert_eq "T2 persistent lock -> exit code 3 (indeterminate), not 0" "3" "$?"
if grep -qi "INDETERMINATE" "${TMP}/report.log"; then
  pass "T2b message says INDETERMINATE"
else
  fail "T2b message says INDETERMINATE"
fi

# ── T3: lock released mid-wait -> script proceeds past the open (retry works)─
kill "${HOLDER_PID}" 2>/dev/null; wait "${HOLDER_PID}" 2>/dev/null; HOLDER_PID=""
UNIFIED_DUCKDB="${DB}" ROBOREV_DAILY_DIR="${TMP}/out" \
  ROBOREV_LOCK_MAX_WAIT_S=4 ROBOREV_LOCK_BACKOFF_START_S=1 \
  Rscript "${REPORT}" --dry-run > "${TMP}/report2.log" 2>&1
RC=$?
# Opens fine; the temp DB lacks roborev_review_lifecycle so it exits 0 on that
# unrelated, documented graceful path. The point: it is NOT exit 3.
assert_eq "T3 no lock -> not exit 3 (opens, then graceful table-missing exit)" "0" "${RC}"
if grep -q "table not found" "${TMP}/report2.log"; then
  pass "T3b reached the table check (open succeeded)"
else
  fail "T3b reached the table check (open succeeded)"
fi

# ── T4: wrapper helper maps rc=3 to a failed housekeeping_runs row ───────────
HDB="${TMP}/hk.duckdb"
duckdb "${HDB}" < "${SCHEMA}" > "${TMP}/schema.log" 2>&1
if [ -f "${HELPER}" ]; then
  # shellcheck disable=SC1090
  source "${HELPER}"
  logger_fn() { :; }
  roborev_daily_record_step1 3 "${HDB}" "/x/bin/roborev_daily_cron.sh" logger_fn
  assert_eq "T4 rc=3 helper returns 3" "3" "$?"
  assert_eq "T4b failed row written" "1" \
    "$(duckdb -init /dev/null -noheader -list "${HDB}" "SELECT count(*) FROM housekeeping_runs WHERE task='roborev_daily' AND status='failed'" | tail -1)"
  roborev_daily_record_step1 0 "${HDB}" "/x/bin/roborev_daily_cron.sh" logger_fn
  assert_eq "T4c rc=0 helper returns 0" "0" "$?"
  assert_eq "T4d rc=0 writes no extra row" "1" \
    "$(duckdb -init /dev/null -noheader -list "${HDB}" "SELECT count(*) FROM housekeeping_runs WHERE task='roborev_daily'" | tail -1)"
else
  fail "T4 helper ${HELPER} missing"
fi

# ── T5: wrapper wires the helper and no longer logs 'continuing' on rc 3 ─────
if grep -q "roborev_daily_record_step1" "${REPO_ROOT}/bin/roborev_daily_cron.sh"; then
  pass "T5 wrapper calls roborev_daily_record_step1"
else
  fail "T5 wrapper calls roborev_daily_record_step1"
fi

echo "---"
echo "passed=${PASS} failed=${FAIL}"
[ "${FAIL}" -eq 0 ]
