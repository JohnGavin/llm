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
