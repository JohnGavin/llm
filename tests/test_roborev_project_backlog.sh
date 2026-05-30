#!/usr/bin/env bash
# tests/test_roborev_project_backlog.sh
#
# Unit tests for .claude/scripts/roborev_project_backlog.sh
#
# Uses a synthetic SQLite fixture and a synthetic temp repo dir.
# Exits 0 if all tests pass, 1 on any failure.
#
# Part of: JohnGavin/llm#163 Components 1+2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG_SCRIPT="${SCRIPT_DIR}/../.claude/scripts/roborev_project_backlog.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────
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

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "${haystack}" | grep -qF "${needle}"; then
        fail "${desc} — '${needle}' should NOT appear in output but does"
    else
        pass "${desc}"
    fi
}

# Create a synthetic SQLite DB with the roborev schema (minimal subset)
make_roborev_db() {
    local db_path="$1"
    /usr/bin/python3 - "$db_path" <<'PYEOF'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE IF NOT EXISTS repos (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    name     TEXT    NOT NULL,
    root_path TEXT
);
CREATE TABLE IF NOT EXISTS review_jobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_id     INTEGER REFERENCES repos(id),
    status      TEXT DEFAULT 'done',
    finished_at TEXT,
    enqueued_at TEXT
);
CREATE TABLE IF NOT EXISTS reviews (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id  INTEGER REFERENCES review_jobs(id),
    output  TEXT,
    closed  INTEGER DEFAULT 0
);
""")
con.commit()
con.close()
PYEOF
}

# Insert a finding into the synthetic DB
insert_finding() {
    local db="$1"
    local repo_name="$2"
    local output_text="$3"
    local age_days="${4:-5}"     # days old
    local closed="${5:-0}"

    /usr/bin/python3 - "$db" "$repo_name" "$output_text" "$age_days" "$closed" <<'PYEOF'
import sqlite3, sys
from datetime import datetime, timedelta, timezone
db_path, repo_name, output_text, age_days_str, closed_str = sys.argv[1:6]
age_days = int(age_days_str)
closed = int(closed_str)

con = sqlite3.connect(db_path)
finished_at = (datetime.now(timezone.utc) - timedelta(days=age_days)).isoformat()

# Upsert repo
row = con.execute("SELECT id FROM repos WHERE name = ?", (repo_name,)).fetchone()
if row:
    repo_id = row[0]
else:
    cur = con.execute("INSERT INTO repos (name, root_path) VALUES (?, '')", (repo_name,))
    repo_id = cur.lastrowid

# Insert job
cur = con.execute(
    "INSERT INTO review_jobs (repo_id, status, finished_at, enqueued_at) VALUES (?, 'done', ?, ?)",
    (repo_id, finished_at, finished_at)
)
job_id = cur.lastrowid

# Insert review
con.execute(
    "INSERT INTO reviews (job_id, output, closed) VALUES (?, ?, ?)",
    (job_id, output_text, closed)
)
con.commit()
con.close()
PYEOF
}

# Make a minimal git repo
make_git_repo() {
    local dir="$1"
    git -C "${dir}" init -q
    git -C "${dir}" config user.email "test@test.local"
    git -C "${dir}" config user.name "Test"
    touch "${dir}/README"
    git -C "${dir}" add README
    git -C "${dir}" commit -qm "init"
}

# ── Test 1: Empty backlog → "0 open" placeholder, no error ───────────────────
DB1="${TMPDIR_ROOT}/db1.sqlite"
REPO1="${TMPDIR_ROOT}/repo1"
mkdir -p "${REPO1}"
make_roborev_db "${DB1}"
make_git_repo "${REPO1}"
# Insert a repo record with no findings
/usr/bin/python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute(\"INSERT INTO repos (name, root_path) VALUES ('testrepo1', '')\")
con.commit()
" "${DB1}"

out1=$(ROBOREV_DB="${DB1}" bash "${BACKLOG_SCRIPT}" testrepo1 \
    --repo-root "${REPO1}" --dry-run 2>&1)
exit1=$?

assert_eq "test1: exit 0 on empty backlog" "0" "${exit1}"
assert_contains "test1: reports 0 open" "0 open" "${out1}"

# ── Test 2: 5 findings of mixed severity → priority ordering ─────────────────
DB2="${TMPDIR_ROOT}/db2.sqlite"
REPO2="${TMPDIR_ROOT}/repo2"
mkdir -p "${REPO2}"
make_roborev_db "${DB2}"
make_git_repo "${REPO2}"

# Critical/security (highest expected priority)
insert_finding "${DB2}" "testpriority" \
    "**Severity**: Critical\nThis finding involves a sql injection vulnerability token leak." 10 0
# High/error-handling
insert_finding "${DB2}" "testpriority" \
    "**Severity**: High\nError handling issue: missing tryCatch around stop() call." 5 0
# Medium/other
insert_finding "${DB2}" "testpriority" \
    "**Severity**: Medium\nSome general finding." 3 0
# Low/docs
insert_finding "${DB2}" "testpriority" \
    "**Severity**: Low\nMissing @param documentation in README." 2 0
# Medium/test
insert_finding "${DB2}" "testpriority" \
    "**Severity**: Medium\nMissing testthat expect_ coverage." 7 0

out2=$(ROBOREV_DB="${DB2}" bash "${BACKLOG_SCRIPT}" testpriority \
    --repo-root "${REPO2}" --dry-run 2>&1)
exit2=$?

assert_eq "test2: exit 0 with mixed findings" "0" "${exit2}"
assert_contains "test2: table header present" "| id |" "${out2}"
assert_contains "test2: critical finding in output" "critical" "${out2}"
# Check that critical appears before low in the output (priority ordering)
critical_line=$(echo "${out2}" | grep "critical" | head -1)
low_line=$(echo "${out2}" | grep " low " | head -1)
critical_pos=$(echo "${out2}" | grep -n "critical" | head -1 | cut -d: -f1)
low_pos=$(echo "${out2}" | grep -n " low " | head -1 | cut -d: -f1)
if [ -n "${critical_pos}" ] && [ -n "${low_pos}" ] && [ "${critical_pos}" -lt "${low_pos}" ]; then
    pass "test2: critical finding ranked before low finding"
else
    fail "test2: critical finding should appear before low in priority order (critical_pos=${critical_pos:-?} low_pos=${low_pos:-?})"
fi

# ── Test 3: Category regex — security vs docs ─────────────────────────────────
DB3="${TMPDIR_ROOT}/db3.sqlite"
REPO3="${TMPDIR_ROOT}/repo3"
mkdir -p "${REPO3}"
make_roborev_db "${DB3}"

# Security finding: body contains "token"
insert_finding "${DB3}" "testcat" \
    "**Severity**: High\nAn API token is exposed in the commit history via credential leak." 5 0
# Docs finding: body contains "README"
insert_finding "${DB3}" "testcat" \
    "**Severity**: Low\nREADME vignette is missing @param documentation comment." 5 0

out3=$(ROBOREV_DB="${DB3}" bash "${BACKLOG_SCRIPT}" testcat \
    --dry-run 2>&1)
exit3=$?

assert_eq "test3: exit 0" "0" "${exit3}"
assert_contains "test3: security category detected" "security" "${out3}"
assert_contains "test3: docs category detected" "docs" "${out3}"
# Security should rank higher than docs (risk factor 3.0 vs 0.5)
sec_pos=$(echo "${out3}" | grep -n "security" | head -1 | cut -d: -f1)
doc_pos=$(echo "${out3}" | grep -n "docs" | head -1 | cut -d: -f1)
if [ -n "${sec_pos}" ] && [ -n "${doc_pos}" ] && [ "${sec_pos}" -lt "${doc_pos}" ]; then
    pass "test3: security finding ranked before docs finding"
else
    fail "test3: security should rank higher than docs (sec_pos=${sec_pos:-?} doc_pos=${doc_pos:-?})"
fi

# ── Test 4: Age factor — same priority base, older one wins ──────────────────
DB4="${TMPDIR_ROOT}/db4.sqlite"
REPO4="${TMPDIR_ROOT}/repo4"
mkdir -p "${REPO4}"
make_roborev_db "${DB4}"

# Two Medium/other findings, same severity and category, different age
# Use unique keywords so we can identify which line belongs to which finding
insert_finding "${DB4}" "testage" \
    "**Severity**: Medium\nSome general other finding NEWER_AGE_MARKER." 2 0
insert_finding "${DB4}" "testage" \
    "**Severity**: Medium\nSome general other finding OLDER_AGE_MARKER." 30 0

out4=$(ROBOREV_DB="${DB4}" bash "${BACKLOG_SCRIPT}" testage \
    --dry-run 2>&1)
exit4=$?

assert_eq "test4: exit 0" "0" "${exit4}"
assert_contains "test4: output has table header" "| id |" "${out4}"

# Extract the two data rows by unique markers in the summary column
# The table has format: | id | sev | cat | age_days | touches | priority | summary |
# We find the line number of each marker in the output
newer_lineno=$(echo "${out4}" | grep -n "NEWER_AGE" | head -1 | cut -d: -f1)
older_lineno=$(echo "${out4}" | grep -n "OLDER_AGE" | head -1 | cut -d: -f1)

if [ -n "${newer_lineno}" ] && [ -n "${older_lineno}" ]; then
    if [ "${older_lineno}" -lt "${newer_lineno}" ]; then
        pass "test4: older finding (age=30) ranked before newer (age=2) — correct priority order"
    else
        # Extract priority scores from each line for a clearer failure message
        newer_pri=$(echo "${out4}" | sed -n "${newer_lineno}p" | awk -F'|' '{gsub(/ /,"",$7); print $7}')
        older_pri=$(echo "${out4}" | sed -n "${older_lineno}p" | awk -F'|' '{gsub(/ /,"",$7); print $7}')
        fail "test4: older finding should rank before newer (older_lineno=${older_lineno} newer_lineno=${newer_lineno}; older_pri=${older_pri:-?} newer_pri=${newer_pri:-?})"
    fi
else
    fail "test4: could not locate OLDER/NEWER markers in output — output was: ${out4}"
fi

# ── Test 5: Markdown output has required sections ────────────────────────────
DB5="${TMPDIR_ROOT}/db5.sqlite"
REPO5="${TMPDIR_ROOT}/repo5"
mkdir -p "${REPO5}"
make_git_repo "${REPO5}"
make_roborev_db "${DB5}"
insert_finding "${DB5}" "testmd" \
    "**Severity**: High\nA high severity finding for markdown structure test." 5 0

OUT5="${TMPDIR_ROOT}/backlog5.md"
exit5rc=0
ROBOREV_DB="${DB5}" bash "${BACKLOG_SCRIPT}" testmd \
    --repo-root "${REPO5}" --out "${OUT5}" 2>&1 || exit5rc=$?

assert_eq "test5: exit 0 writing file" "0" "${exit5rc}"
assert_eq "test5: backlog file written" "1" "$([ -f "${OUT5}" ] && echo 1 || echo 0)"

if [ -f "${OUT5}" ]; then
    content5=$(cat "${OUT5}")
    assert_contains "test5: has heading" "# roborev backlog" "${content5}"
    assert_contains "test5: has Generated timestamp" "_Generated:" "${content5}"
    assert_contains "test5: has table header" "| id |" "${content5}"
    assert_contains "test5: has priority column" "priority" "${content5}"
    assert_contains "test5: has source footer" "_Source:" "${content5}"
fi

# ── Test 6: bash -n syntax check ─────────────────────────────────────────────
bash_n_out=$(bash -n "${BACKLOG_SCRIPT}" 2>&1)
bash_n_rc=$?
assert_eq "test6: bash -n exits 0 (script syntax valid)" "0" "${bash_n_rc}"

# ── Test 7: --gitignore appended when not present ────────────────────────────
REPO7="${TMPDIR_ROOT}/repo7"
mkdir -p "${REPO7}"
DB7="${TMPDIR_ROOT}/db7.sqlite"
make_roborev_db "${DB7}"
insert_finding "${DB7}" "testgi" \
    "**Severity**: Medium\nA finding for gitignore test." 3 0
OUT7="${REPO7}/.roborev/backlog.md"

# Run in apply mode (not dry-run) so _ensure_gitignore is called
ROBOREV_DB="${DB7}" bash "${BACKLOG_SCRIPT}" testgi \
    --repo-root "${REPO7}" 2>&1
exit7=$?
assert_eq "test7: exit 0" "0" "${exit7}"
assert_eq "test7: .gitignore created" "1" "$([ -f "${REPO7}/.gitignore" ] && echo 1 || echo 0)"
assert_contains "test7: .roborev/ in .gitignore" ".roborev/" "$(cat "${REPO7}/.gitignore" 2>/dev/null || echo '')"

# Run again — must be idempotent (no duplicate lines)
ROBOREV_DB="${DB7}" bash "${BACKLOG_SCRIPT}" testgi \
    --repo-root "${REPO7}" 2>&1
count7=$(grep -c '\.roborev/' "${REPO7}/.gitignore" 2>/dev/null || echo 0)
assert_eq "test7: .gitignore idempotent (single .roborev/ entry)" "1" "${count7}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
exit 0
