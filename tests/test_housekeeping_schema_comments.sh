#!/usr/bin/env bash
# tests/test_housekeeping_schema_comments.sh
#
# Guard for the COMMENT ON metadata in .claude/scripts/housekeeping_schema_init.sql.
# A number or status in unified.duckdb is only readable if its meaning, unit and
# provenance travel with it, so EVERY table and EVERY column the schema file
# creates must carry a non-empty comment.
#
# Checks (all on throwaway temp DBs, never the live ~/.claude/logs/unified.duckdb):
#   1. Fresh DB: the schema file applies cleanly (no errors).
#   2. Sanity: the checker sees tables and columns at all (a vacuous 0-of-0
#      would otherwise read as a pass).
#   3. No table and no column has a NULL or empty comment.
#   4. NEGATIVE CONTROL: the same schema with one COMMENT line deleted MUST be
#      reported as failing by the very same checker (proves the check can go red).
#   5. Idempotent: re-applying the file to the already-commented DB succeeds,
#      leaves the comment count unchanged and preserves existing rows.
#   6. Additive: applying the file to a pre-existing DB created WITHOUT comments
#      (the live-DB situation) adds the comments and preserves existing rows.
#
# Exit codes: 0 all pass, 1 a check failed, 3 INDETERMINATE (duckdb missing, so
# the comments cannot be inspected -- reported, never a silent pass).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA="${REPO_ROOT}/.claude/scripts/housekeeping_schema_init.sql"

DUCKDB_BIN="$(command -v duckdb || true)"
if [ -z "${DUCKDB_BIN}" ]; then
  echo "INDETERMINATE: duckdb not on PATH -- cannot inspect table/column comments"
  exit 3
fi
if [ ! -f "${SCHEMA}" ]; then
  echo "FAIL: schema file not found: ${SCHEMA}"
  exit 1
fi

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_hk_schema_comments_XXXXXX)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- ${2:-}"; FAIL=$((FAIL + 1)); }

# q DB SQL -> single scalar result on stdout
q() {
  "${DUCKDB_BIN}" -init /dev/null -noheader -list "$1" "$2" 2>&1
}

# Counts of user tables / columns in the main schema, and how many lack a comment.
TABLES_SQL="FROM duckdb_tables() WHERE schema_name = 'main' AND NOT internal"
COLS_SQL="FROM duckdb_columns() c JOIN duckdb_tables() t
            ON t.schema_name = c.schema_name AND t.table_name = c.table_name
          WHERE t.schema_name = 'main' AND NOT t.internal"

n_tables()        { q "$1" "SELECT count(*) ${TABLES_SQL};"; }
n_columns()       { q "$1" "SELECT count(*) ${COLS_SQL};"; }
n_tables_bad()    { q "$1" "SELECT count(*) ${TABLES_SQL} AND (comment IS NULL OR trim(comment) = '');"; }
n_columns_bad()   { q "$1" "SELECT count(*) ${COLS_SQL} AND (c.comment IS NULL OR trim(c.comment) = '');"; }
n_comments()      { q "$1" "SELECT (SELECT count(*) ${TABLES_SQL} AND comment IS NOT NULL) + (SELECT count(*) ${COLS_SQL} AND c.comment IS NOT NULL);"; }
list_bad() {
  q "$1" "SELECT 'table ' || table_name ${TABLES_SQL} AND (comment IS NULL OR trim(comment) = '')
          UNION ALL
          SELECT 'column ' || c.table_name || '.' || c.column_name ${COLS_SQL} AND (c.comment IS NULL OR trim(c.comment) = '');"
}

# check_all_commented DB -> 0 when every table and column is commented, else 1
check_all_commented() {
  local db="$1" tb cb
  tb="$(n_tables_bad "${db}")"
  cb="$(n_columns_bad "${db}")"
  [ "${tb}" = "0" ] && [ "${cb}" = "0" ]
}

# --- 1. Fresh apply -----------------------------------------------------------
DB1="${TMPDIR_ROOT}/fresh.duckdb"
apply_out="$("${DUCKDB_BIN}" -init /dev/null "${DB1}" < "${SCHEMA}" 2>&1)"
apply_rc=$?
if [ "${apply_rc}" = "0" ] && ! printf '%s' "${apply_out}" | grep -qiE "error"; then
  pass "schema file applies cleanly to a fresh DB"
else
  fail "schema applies to a fresh DB" "rc=${apply_rc} out=${apply_out}"
fi

# --- 2. Sanity: the checker is not vacuous ------------------------------------
nt="$(n_tables "${DB1}")"
nc="$(n_columns "${DB1}")"
if [ "${nt}" -ge 14 ] 2>/dev/null && [ "${nc}" -ge 100 ] 2>/dev/null; then
  pass "checker sees ${nt} tables and ${nc} columns (not vacuous)"
else
  fail "checker sees the schema" "tables='${nt}' columns='${nc}' (expected >=14 / >=100)"
fi

# --- 3. Every table and column has a comment ----------------------------------
if check_all_commented "${DB1}"; then
  pass "every table and column has a non-empty comment"
else
  fail "every table and column has a comment" "uncommented: $(list_bad "${DB1}" | tr '\n' ' ')"
fi

# --- 4. Negative control: dropping one COMMENT must turn the check red --------
MUT_SQL="${TMPDIR_ROOT}/mutated.sql"
# Delete exactly one column comment (housekeeping_runs.status).
grep -v '^COMMENT ON COLUMN housekeeping_runs\.status IS ' "${SCHEMA}" > "${MUT_SQL}"
removed=$(( $(wc -l < "${SCHEMA}") - $(wc -l < "${MUT_SQL}") ))
DB2="${TMPDIR_ROOT}/mutated.duckdb"
"${DUCKDB_BIN}" -init /dev/null "${DB2}" < "${MUT_SQL}" > /dev/null 2>&1
if [ "${removed}" = "1" ] && ! check_all_commented "${DB2}" \
   && [ "$(list_bad "${DB2}")" = "column housekeeping_runs.status" ]; then
  pass "negative control: removing one COMMENT is detected (only housekeeping_runs.status flagged)"
else
  fail "negative control" "lines_removed=${removed} flagged='$(list_bad "${DB2}" | tr '\n' ' ')'"
fi

# Second negative control for the table level.
MUT2_SQL="${TMPDIR_ROOT}/mutated_table.sql"
grep -v '^COMMENT ON TABLE eval_runs IS ' "${SCHEMA}" > "${MUT2_SQL}"
DB3="${TMPDIR_ROOT}/mutated_table.duckdb"
"${DUCKDB_BIN}" -init /dev/null "${DB3}" < "${MUT2_SQL}" > /dev/null 2>&1
if ! check_all_commented "${DB3}" && [ "$(list_bad "${DB3}")" = "table eval_runs" ]; then
  pass "negative control: removing one TABLE comment is detected (only eval_runs flagged)"
else
  fail "negative control (table)" "flagged='$(list_bad "${DB3}" | tr '\n' ' ')'"
fi

# --- 5. Idempotent re-apply on the commented DB -------------------------------
before="$(n_comments "${DB1}")"
q "${DB1}" "INSERT INTO housekeeping_runs (id, task, source_script, started_at, status)
            VALUES ('t1', 'test', '/x', TIMESTAMPTZ '2026-01-01 00:00:00+00', 'ok');" > /dev/null
reapply_out="$("${DUCKDB_BIN}" -init /dev/null "${DB1}" < "${SCHEMA}" 2>&1)"
reapply_rc=$?
after="$(n_comments "${DB1}")"
rows="$(q "${DB1}" "SELECT count(*) FROM housekeeping_runs WHERE id = 't1';")"
if [ "${reapply_rc}" = "0" ] && ! printf '%s' "${reapply_out}" | grep -qiE "error" \
   && [ "${before}" = "${after}" ] && [ "${rows}" = "1" ] && check_all_commented "${DB1}"; then
  pass "re-applying the schema twice is idempotent (comments ${before} -> ${after}, row preserved)"
else
  fail "idempotent re-apply" "rc=${reapply_rc} before=${before} after=${after} rows=${rows} out=${reapply_out}"
fi

# --- 6. Additive on a pre-existing DB that has no comments --------------------
OLD_SQL="${TMPDIR_ROOT}/no_comments.sql"
grep -v '^COMMENT ON ' "${SCHEMA}" > "${OLD_SQL}"
DB4="${TMPDIR_ROOT}/legacy.duckdb"
"${DUCKDB_BIN}" -init /dev/null "${DB4}" < "${OLD_SQL}" > /dev/null 2>&1
q "${DB4}" "INSERT INTO housekeeping_runs (id, task, source_script, started_at, status)
            VALUES ('legacy1', 'test', '/x', TIMESTAMPTZ '2026-01-01 00:00:00+00', 'ok');
            INSERT INTO eval_runs (run_id, run_at, harness, fixture, attempt, agent, model, config_hash, result)
            VALUES ('r', TIMESTAMPTZ '2026-01-01 00:00:00+00', 'roborev', 'f', 1, 'a', 'm', 'h', 'PASS');" > /dev/null
legacy_bad_before=0
check_all_commented "${DB4}" || legacy_bad_before=1
legacy_out="$("${DUCKDB_BIN}" -init /dev/null "${DB4}" < "${SCHEMA}" 2>&1)"
legacy_rc=$?
r1="$(q "${DB4}" "SELECT count(*) FROM housekeeping_runs WHERE id = 'legacy1';")"
r2="$(q "${DB4}" "SELECT count(*) FROM eval_runs WHERE run_id = 'r';")"
if [ "${legacy_bad_before}" = "1" ] && [ "${legacy_rc}" = "0" ] \
   && ! printf '%s' "${legacy_out}" | grep -qiE "error" \
   && check_all_commented "${DB4}" && [ "${r1}" = "1" ] && [ "${r2}" = "1" ]; then
  pass "applying the schema to a pre-existing uncommented DB adds comments and keeps rows"
else
  fail "additive apply to legacy DB" "uncommented_before=${legacy_bad_before} rc=${legacy_rc} rows=${r1}/${r2} out=${legacy_out}"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
