#!/usr/bin/env bash
# tests/test_roborev_classify.sh
#
# Unit tests for .claude/scripts/lib/roborev_classify.py (llm#1035).
#
# This module is a parallel Python port of send_roborev_email.R's
# classify_unparseable_finding() / parse_max_severity_ordinal(), used by
# roborev_project_backlog.sh (and any future consumer of reviews.db output
# text) so a "review never ran" row is classified the SAME way everywhere.
#
# The fixtures here are copied verbatim from
# tests/testthat/test-roborev-daily-email.R's llm#972/llm#1035 test blocks
# -- this is the parity proof that the Python and R implementations agree,
# since they cannot share one implementation directly (see the module
# docstring for why).
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY_MODULE="${SCRIPT_DIR}/../.claude/scripts/lib/roborev_classify.py"
PYTHON="${PYTHON:-/usr/bin/python3}"

PASS=0
FAIL=0

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
        fail "${desc} — '${needle}' not found in output"
    fi
}

# ── Test 1: module file exists ────────────────────────────────────────────
if [ -f "${CLASSIFY_MODULE}" ]; then
    pass "test1: roborev_classify.py exists"
else
    fail "test1: roborev_classify.py NOT found at ${CLASSIFY_MODULE}"
fi

# ── Test 2: module's own --selftest passes ────────────────────────────────
selftest_out=$("${PYTHON}" "${CLASSIFY_MODULE}" --selftest 2>&1)
selftest_rc=$?
assert_eq "test2: --selftest exits 0" "0" "${selftest_rc}"
if echo "${selftest_out}" | grep -qE '^[0-9]+/[0-9]+ PASS$'; then
    total=$(echo "${selftest_out}" | grep -oE '[0-9]+/[0-9]+ PASS' | sed 's#/.*##')
    denom=$(echo "${selftest_out}" | grep -oE '[0-9]+/[0-9]+ PASS' | sed -E 's#^[0-9]+/([0-9]+).*#\1#')
    assert_eq "test2: all selftest cases pass (n/n)" "${denom}" "${total}"
else
    fail "test2: could not find 'N/N PASS' summary line in selftest output"
fi

# ── Test 3: parity fixtures against tests/testthat/test-roborev-daily-email.R ──
# Each fixture: <expected classification> <fixture text as a python -c snippet>
classify_one() {
    local text="$1"
    "${PYTHON}" -c "
import sys
sys.path.insert(0, '$(dirname "${CLASSIFY_MODULE}")')
from roborev_classify import classify_review
print(classify_review(sys.argv[1]))
" "${text}"
}

assert_eq "test3: 'No review output generated' -> not_reviewed" \
    "not_reviewed" \
    "$(classify_one "No review output generated")"

assert_eq "test3: 'SEVERITY_THRESHOLD_MET' -> passed" \
    "passed" \
    "$(classify_one "SEVERITY_THRESHOLD_MET")"

# 2026-09-10: these two phrases were added to send_roborev_email.R's
# PASSED_PATTERNS (llm#972/#1035 follow-ups) without a matching update to
# roborev_classify.py -- undetected because neither had a parity fixture
# here. Caught live via roborev review #10051 (R classified "passed",
# Python classified "unclassified" for the identical text).
assert_eq "test3: 'No issues were found' -> passed (2026-09-10 parity fix, id 10051)" \
    "passed" \
    "$(classify_one "Summary: The code review of the provided diff is complete. No issues were found in the changes.")"

assert_eq "test3: 'No review found for empty diff' -> passed (2026-09-10 parity fix)" \
    "passed" \
    "$(classify_one "No review found for empty diff.")"

assert_eq "test3: unrecognised prose -> unclassified" \
    "unclassified" \
    "$(classify_one "This matches none of the known shapes at all whatsoever.")"

assert_eq "test3: bold severity marker -> parsed" \
    "parsed" \
    "$(classify_one "**Severity**: High" )"

assert_eq "test3: 'unable to read the diff' (live phrasing) -> not_reviewed" \
    "not_reviewed" \
    "$(classify_one "I am unable to read the diff file because it is ignored by configured ignore patterns.")"

assert_eq "test3: 'unable to perform the code review' (live phrasing) -> not_reviewed" \
    "not_reviewed" \
    "$(classify_one "I am unable to perform the code review because the diff file is not readable.")"

assert_eq "test3: 'diff file could not be read' (live phrasing) -> not_reviewed" \
    "not_reviewed" \
    "$(classify_one "Cannot review code changes as the diff file could not be read.")"

# ── Test 3b: structured_output reader (llm#1265) ───────────────────────────
# roborev v0.68.2 migrated every row's review text out of `output` (empty on
# all live rows) into `structured_output` (JSON, schema_version 0/1/2). See
# roborev_classify.py's module docstring for the full shape catalogue.
classify_row() {
    local output="$1" structured_output="$2"
    "${PYTHON}" -c "
import sys
sys.path.insert(0, '$(dirname "${CLASSIFY_MODULE}")')
from roborev_classify import classify_review_row
output = sys.argv[1] if sys.argv[1] != '__NONE__' else None
structured = sys.argv[2] if sys.argv[2] != '__NONE__' else None
print(classify_review_row(output, structured))
" "${output:-__NONE__}" "${structured_output:-__NONE__}"
}

severity_ordinal_row() {
    local output="$1" structured_output="$2"
    "${PYTHON}" -c "
import sys
sys.path.insert(0, '$(dirname "${CLASSIFY_MODULE}")')
from roborev_classify import review_severity_ordinal
output = sys.argv[1] if sys.argv[1] != '__NONE__' else None
structured = sys.argv[2] if sys.argv[2] != '__NONE__' else None
ord_ = review_severity_ordinal(output, structured)
print('' if ord_ is None else ord_)
" "${output:-__NONE__}" "${structured_output:-__NONE__}"
}

V2_WITH_FINDINGS='{"schema_version":2,"summary":"x","verdict":"fail","findings":[{"severity":"medium","problem":"p1","location":"a.R:1","fix":"f1"},{"severity":"high","problem":"p2","location":"b.R:2","fix":"f2"}]}'
V2_PASS_NO_FINDINGS='{"schema_version":2,"summary":"clean diff","verdict":"pass","findings":[]}'
V1_EMPTY_NO_VERDICT='{"schema_version":1,"summary":"trivial gitignore change","findings":[]}'
LEGACY_TEXT_ONLY='- **Severity**: Low
  **Problem**: minor thing'
MALFORMED_JSON='{not valid json'

assert_eq "test3b: v2 JSON with medium+high findings -> parsed" \
    "parsed" \
    "$(classify_row "" "${V2_WITH_FINDINGS}")"

assert_eq "test3b: v2 JSON with findings -> severity ordinal 3 (high, the max)" \
    "3" \
    "$(severity_ordinal_row "" "${V2_WITH_FINDINGS}")"

assert_eq "test3b: v2 verdict=pass, no findings -> passed" \
    "passed" \
    "$(classify_row "" "${V2_PASS_NO_FINDINGS}")"

assert_eq "test3b: v1 empty findings, no verdict key -> passed" \
    "passed" \
    "$(classify_row "" "${V1_EMPTY_NO_VERDICT}")"

assert_eq "test3b: legacy text only (no structured_output) -> parsed" \
    "parsed" \
    "$(classify_row "${LEGACY_TEXT_ONLY}" "")"

assert_eq "test3b: malformed JSON falls back to legacy \`output\` text -> parsed" \
    "parsed" \
    "$(classify_row "${LEGACY_TEXT_ONLY}" "${MALFORMED_JSON}")"

assert_eq "test3b: BOTH output and structured_output empty -> indeterminate (never clean)" \
    "indeterminate" \
    "$(classify_row "" "")"

assert_eq "test3b: BOTH columns absent (None) -> indeterminate" \
    "indeterminate" \
    "$(classify_row "" "")"

assert_eq "test3b: malformed JSON AND empty output -> indeterminate" \
    "indeterminate" \
    "$(classify_row "" "${MALFORMED_JSON}")"

# ── Test 3b falsification: prove the fixtures can go red ───────────────────
# Break _parse_structured_json (temp copy) to confirm the v2/passed/legacy
# cases above are actually exercising the structured_output code path, not
# silently passing for an unrelated reason.
FALSIFY_TMP="$(mktemp -d)"
FALSIFY_MODULE="${FALSIFY_TMP}/roborev_classify.py"
sed 's/^def _parse_structured_json(structured_output):$/def _parse_structured_json(structured_output):\n    return None  # FALSIFICATION INJECTED/' \
    "${CLASSIFY_MODULE}" > "${FALSIFY_MODULE}"
falsify_out=$("${PYTHON}" "${FALSIFY_MODULE}" --selftest 2>&1)
falsify_fail_n=$(echo "${falsify_out}" | grep -c '^  FAIL')
rm -rf "${FALSIFY_TMP}"
if [ "${falsify_fail_n}" -ge 5 ]; then
    pass "test3b-falsify: breaking the structured_output reader turns >=5 selftest cases red (got ${falsify_fail_n})"
else
    fail "test3b-falsify: breaking the structured_output reader only broke ${falsify_fail_n} cases — fixtures may not exercise the real code path"
fi

# ── Test 4: bash -n syntax check on the consumer script ───────────────────
BACKLOG_SCRIPT="${SCRIPT_DIR}/../.claude/scripts/roborev_project_backlog.sh"
bash_n_out=$(bash -n "${BACKLOG_SCRIPT}" 2>&1)
bash_n_rc=$?
assert_eq "test4: roborev_project_backlog.sh syntax valid" "0" "${bash_n_rc}"

# ── Test 5: module importable stand-alone (no side effects on import) ─────
import_rc=0
"${PYTHON}" -c "
import sys
sys.path.insert(0, '$(dirname "${CLASSIFY_MODULE}")')
import roborev_classify
assert callable(roborev_classify.classify_review)
assert callable(roborev_classify.parse_max_severity_ordinal)
" 2>&1 || import_rc=$?
assert_eq "test5: module imports cleanly with no side effects" "0" "${import_rc}"

# ── Test 6: session_init.sh Phase 13d wiring — extracted + run against a ──────
# synthetic DB fixture. Extracts the literal heredoc block between the
# 'RBBEOF' markers (the actual code the background job runs) rather than
# re-typing it, so this test fails if the extraction drifts from the real
# script instead of silently testing a stale copy.
SESSION_INIT="${SCRIPT_DIR}/../.claude/hooks/session_init.sh"
if [ -f "${SESSION_INIT}" ]; then
    TMPDIR6="$(mktemp -d)"
    trap 'rm -rf "${TMPDIR6}"' RETURN 2>/dev/null || true

    RBB_SCRIPT="${TMPDIR6}/rbb_block.sh"
    awk '/^nohup bash -s .* <<.RBBEOF./{flag=1; next} /^RBBEOF$/{flag=0} flag' \
        "${SESSION_INIT}" > "${RBB_SCRIPT}"

    if [ -s "${RBB_SCRIPT}" ]; then
        pass "test6: extracted Phase 13d block from session_init.sh"

        DB6="${TMPDIR6}/db6.sqlite"
        "${PYTHON}" - "${DB6}" <<'PYEOF'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE repos (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, root_path TEXT);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, repo_id INTEGER, status TEXT DEFAULT 'done', finished_at TEXT);
CREATE TABLE reviews (id INTEGER PRIMARY KEY AUTOINCREMENT, job_id INTEGER, output TEXT, closed INTEGER DEFAULT 0);
""")
cur = con.execute("INSERT INTO repos (name, root_path) VALUES ('test6repo', '')")
repo_id = cur.lastrowid
# One genuine open finding, one not_reviewed, one passed (should be excluded)
for output in [
    "**Severity**: High\nA real finding.",
    "No review output generated",
    "SEVERITY_THRESHOLD_MET",
]:
    cur = con.execute(
        "INSERT INTO review_jobs (repo_id, status, finished_at) VALUES (?, 'done', datetime('now'))",
        (repo_id,))
    job_id = cur.lastrowid
    con.execute("INSERT INTO reviews (job_id, output, closed) VALUES (?, ?, 0)", (job_id, output))
con.commit()
con.close()
PYEOF

        LIB_DIR="$(cd "${SCRIPT_DIR}/../.claude/scripts/lib" && pwd)"
        CACHE6="${TMPDIR6}/cache.txt"
        chmod +x "${RBB_SCRIPT}"
        bash "${RBB_SCRIPT}" "${DB6}" "test6repo" "${CACHE6}" "${LIB_DIR}"
        rc6=$?
        assert_eq "test6: extracted block exits 0" "0" "${rc6}"

        cache6_content=$(cat "${CACHE6}" 2>/dev/null || echo "")
        assert_contains "test6: open=2 (passed row excluded)" "open=2" "${cache6_content}"
    else
        fail "test6: extraction produced empty block (regex drifted from session_init.sh — update the awk pattern)"
    fi
else
    fail "test6: session_init.sh not found at ${SESSION_INIT}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
exit 0
