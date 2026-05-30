#!/usr/bin/env bash
# tests/test_roborev_daily_backlog_aggregator.sh
#
# Unit tests for .claude/scripts/roborev_daily_backlog_aggregator.sh
#
# Uses a synthetic SQLite fixture and a mock per-project script.
# Exits 0 if all tests pass, 1 on any failure.
#
# Part of: JohnGavin/llm#355 (Component 6)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGG_SCRIPT="${SCRIPT_DIR}/../.claude/scripts/roborev_daily_backlog_aggregator.sh"

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
        fail "${desc} — '${needle}' should NOT appear but does"
    else
        pass "${desc}"
    fi
}

# ── Synthetic DB builder ──────────────────────────────────────────────────────
make_roborev_db() {
    local db_path="$1"
    shift
    # Remaining args: repo names to insert
    /usr/bin/python3 - "$db_path" "$@" <<'PYEOF'
import sqlite3, sys
db_path = sys.argv[1]
repo_names = sys.argv[2:]
con = sqlite3.connect(db_path)
con.executescript("""
CREATE TABLE IF NOT EXISTS repos (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT NOT NULL,
    root_path TEXT
);
CREATE TABLE IF NOT EXISTS review_jobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_id     INTEGER,
    status      TEXT DEFAULT 'done',
    finished_at TEXT,
    enqueued_at TEXT
);
CREATE TABLE IF NOT EXISTS reviews (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id INTEGER,
    output TEXT,
    closed INTEGER DEFAULT 0
);
""")
for name in repo_names:
    con.execute("INSERT INTO repos (name, root_path) VALUES (?, '')", (name,))
con.commit()
con.close()
PYEOF
}

# ── Mock per-project script builder ──────────────────────────────────────────
# Creates a bash script at $path that emits fake OPEN_COUNT / TOP_FINDING lines.
make_mock_per_project_script() {
    local path="$1"
    local open_count="${2:-3}"
    local top_id="${3:-99}"
    local top_sev="${4:-high}"

    cat > "$path" <<MOCK
#!/usr/bin/env bash
# Mock roborev_project_backlog.sh for testing
# Emits structured metadata lines that aggregator parses
echo "ROOT_PATH:/tmp/mock_root"
echo "REPO:\$1"
echo ""
echo "OPEN_COUNT:${open_count}"
echo "| id | sev | category | age_days | touches | priority | summary |"
echo "|----|-----|----------|----------|---------|----------|---------|"
echo "| ${top_id} | ${top_sev} | error-handling | 5 | 2 | 12.5 | Mock finding |"
echo "TOP_FINDING_ID:${top_id}"
echo "TOP_FINDING_SEV:${top_sev}"
echo "TOP_FINDING_CAT:error-handling"
MOCK
    chmod +x "$path"
}

# ── Test 0: bash -n syntax check ─────────────────────────────────────────────
bash_n_rc=0
bash -n "${AGG_SCRIPT}" 2>/dev/null || bash_n_rc=$?
assert_eq "test0: bash -n exits 0 (aggregator syntax valid)" "0" "${bash_n_rc}"

# Also check plist file exists
PLIST="${SCRIPT_DIR}/../.claude/launchd/com.claude.roborev-daily-backlog.plist"
assert_eq "test0: plist file exists" "1" "$([ -f "${PLIST}" ] && echo 1 || echo 0)"

# ── Test 1: Missing DB → exit 0 (fail-open) ──────────────────────────────────
out1=""
rc1=0
out1=$(ROBOREV_DB="/tmp/no_such_db_agg_$$" \
    bash "${AGG_SCRIPT}" 2>&1) || rc1=$?
assert_eq "test1: exit 0 on missing DB" "0" "${rc1}"
assert_contains "test1: reports skipped" "skipped" "${out1}"

# ── Test 2: DB with real projects and mock per-project script ─────────────────
DB2="${TMPDIR_ROOT}/db2.sqlite"
DOCS2="${TMPDIR_ROOT}/docs2"
OUT2="${TMPDIR_ROOT}/out2"
MOCK2="${TMPDIR_ROOT}/mock_per_project.sh"

# Create project directories that aggregator will find
mkdir -p "${DOCS2}/llm"
mkdir -p "${DOCS2}/mycare"
mkdir -p "${DOCS2}/historical"

# Create DB with those project names + some fixture names to be filtered
make_roborev_db "${DB2}" \
    "llm" "mycare" "historical" \
    "fixture_abc" "kb_wiki" "file9afe2d343242" "repo_XXXX" "main"

# Create mock per-project script
make_mock_per_project_script "${MOCK2}" 5 42 "high"

# Point aggregator at our mock script via env; override docs root and out dir
out2=""
rc2=0
out2=$(ROBOREV_DB="${DB2}" \
    ROBOREV_AGG_OUT_DIR="${OUT2}" \
    bash "${AGG_SCRIPT}" \
        --docs-root "${DOCS2}" \
        2>&1) || rc2=$?

# The aggregator uses PER_PROJECT_SCRIPT from SCRIPT_DIR, which points to the
# real script.  We need to call it with our mock override instead.
# Override by placing the mock in SCRIPT_DIR-relative path via symlink trick.
# Actually, let's use SCRIPT_DIR override via a wrapper approach: create
# a temp dir that contains both scripts, run AGG from there.

# Create a temp scripts dir with our mock as the per-project script
SCRIPTS_DIR2="${TMPDIR_ROOT}/scripts2"
mkdir -p "${SCRIPTS_DIR2}"
cp "${AGG_SCRIPT}" "${SCRIPTS_DIR2}/roborev_daily_backlog_aggregator.sh"
cp "${MOCK2}" "${SCRIPTS_DIR2}/roborev_project_backlog.sh"
chmod +x "${SCRIPTS_DIR2}/roborev_daily_backlog_aggregator.sh"
chmod +x "${SCRIPTS_DIR2}/roborev_project_backlog.sh"

out2=""
rc2=0
out2=$(ROBOREV_DB="${DB2}" \
    ROBOREV_AGG_OUT_DIR="${OUT2}" \
    bash "${SCRIPTS_DIR2}/roborev_daily_backlog_aggregator.sh" \
        --docs-root "${DOCS2}" \
        2>&1) || rc2=$?

assert_eq "test2: exit 0 with real projects" "0" "${rc2}"
assert_contains "test2: reports processed count" "processed=" "${out2}"
# Should have processed llm, mycare, historical (3 projects)
assert_contains "test2: processed=3" "processed=3" "${out2}"

# Check global summary was written
TODAY="$(date -u '+%Y-%m-%d')"
SUMMARY2="${OUT2}/${TODAY}.md"
assert_eq "test2: summary file written" "1" "$([ -f "${SUMMARY2}" ] && echo 1 || echo 0)"

if [ -f "${SUMMARY2}" ]; then
    content2="$(cat "${SUMMARY2}")"
    assert_contains "test2: summary has heading" "global backlog summary" "${content2}"
    assert_contains "test2: summary has llm row" "llm" "${content2}"
    assert_contains "test2: summary has mycare row" "mycare" "${content2}"
    assert_contains "test2: summary has historical row" "historical" "${content2}"
    assert_contains "test2: summary has per-project table" "| project |" "${content2}"
    assert_contains "test2: summary has open count" "Total open findings" "${content2}"
    # Total open = 3 projects × 5 each = 15
    assert_contains "test2: summary total open=15" "15" "${content2}"
fi

# ── Test 3: Fixture names are filtered out ────────────────────────────────────
# summary should NOT contain the fixture/internal project names
if [ -f "${SUMMARY2}" ]; then
    content3="$(cat "${SUMMARY2}")"
    assert_not_contains "test3: fixture_ excluded from summary" "fixture_abc" "${content3}"
    assert_not_contains "test3: kb_ excluded from summary" "kb_wiki" "${content3}"
    assert_not_contains "test3: hex file excluded" "file9afe2d343242" "${content3}"
    assert_not_contains "test3: main excluded" "| main |" "${content3}"
fi

# ── Test 4: Missing project root → skipped (not fatal) ────────────────────────
DB4="${TMPDIR_ROOT}/db4.sqlite"
DOCS4="${TMPDIR_ROOT}/docs4"
OUT4="${TMPDIR_ROOT}/out4"
SCRIPTS_DIR4="${TMPDIR_ROOT}/scripts4"
mkdir -p "${DOCS4}/llm"   # only llm exists; mycare does not

make_roborev_db "${DB4}" "llm" "mycare"

mkdir -p "${SCRIPTS_DIR4}"
cp "${AGG_SCRIPT}" "${SCRIPTS_DIR4}/roborev_daily_backlog_aggregator.sh"
cp "${MOCK2}" "${SCRIPTS_DIR4}/roborev_project_backlog.sh"
chmod +x "${SCRIPTS_DIR4}/roborev_daily_backlog_aggregator.sh"
chmod +x "${SCRIPTS_DIR4}/roborev_project_backlog.sh"

out4=""
rc4=0
out4=$(ROBOREV_DB="${DB4}" \
    ROBOREV_AGG_OUT_DIR="${OUT4}" \
    bash "${SCRIPTS_DIR4}/roborev_daily_backlog_aggregator.sh" \
        --docs-root "${DOCS4}" \
        2>&1) || rc4=$?

assert_eq "test4: exit 0 when a project root is missing" "0" "${rc4}"
assert_contains "test4: processed=1" "processed=1" "${out4}"
# skipped=1 for mycare whose root does not exist
assert_contains "test4: skipped=1" "skipped=1" "${out4}"

# ── Test 5: --dry-run passes through to per-project script ───────────────────
# Create a mock that records whether --dry-run was passed
MOCK5="${TMPDIR_ROOT}/mock_dryrun.sh"
DRYRUN_FLAG_FILE="${TMPDIR_ROOT}/dryrun_flag"
cat > "${MOCK5}" <<MOCK5EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "--dry-run" ]; then
    touch "${DRYRUN_FLAG_FILE}"
  fi
done
echo "OPEN_COUNT:2"
echo "TOP_FINDING_ID:1"
echo "TOP_FINDING_SEV:high"
echo "TOP_FINDING_CAT:other"
MOCK5EOF
chmod +x "${MOCK5}"

DB5="${TMPDIR_ROOT}/db5.sqlite"
DOCS5="${TMPDIR_ROOT}/docs5"
OUT5="${TMPDIR_ROOT}/out5"
SCRIPTS_DIR5="${TMPDIR_ROOT}/scripts5"
mkdir -p "${DOCS5}/llm"
make_roborev_db "${DB5}" "llm"
mkdir -p "${SCRIPTS_DIR5}"
cp "${AGG_SCRIPT}" "${SCRIPTS_DIR5}/roborev_daily_backlog_aggregator.sh"
cp "${MOCK5}" "${SCRIPTS_DIR5}/roborev_project_backlog.sh"
chmod +x "${SCRIPTS_DIR5}/roborev_daily_backlog_aggregator.sh"

out5=""
rc5=0
out5=$(ROBOREV_DB="${DB5}" \
    ROBOREV_AGG_OUT_DIR="${OUT5}" \
    bash "${SCRIPTS_DIR5}/roborev_daily_backlog_aggregator.sh" \
        --docs-root "${DOCS5}" \
        --dry-run \
        2>&1) || rc5=$?

assert_eq "test5: exit 0 with --dry-run" "0" "${rc5}"
assert_eq "test5: --dry-run passed to per-project script" "1" "$([ -f "${DRYRUN_FLAG_FILE}" ] && echo 1 || echo 0)"

# ── Test 6: Self-test via ROBOREV_AGG_SELFTEST ────────────────────────────────
selftest_out=""
selftest_rc=0
selftest_out=$(ROBOREV_AGG_SELFTEST=1 bash "${AGG_SCRIPT}" 2>&1) || selftest_rc=$?
assert_eq "test6: ROBOREV_AGG_SELFTEST exits 0" "0" "${selftest_rc}"
assert_contains "test6: selftest reports PASS" "PASS" "${selftest_out}"

# ── Test 7: Idempotent — same date overwrites summary ─────────────────────────
DB7="${TMPDIR_ROOT}/db7.sqlite"
DOCS7="${TMPDIR_ROOT}/docs7"
OUT7="${TMPDIR_ROOT}/out7"
SCRIPTS_DIR7="${TMPDIR_ROOT}/scripts7"
mkdir -p "${DOCS7}/llm"
make_roborev_db "${DB7}" "llm"

# First mock: open_count=3
MOCK7A="${TMPDIR_ROOT}/mock7a.sh"
make_mock_per_project_script "${MOCK7A}" 3 10 "high"

mkdir -p "${SCRIPTS_DIR7}"
cp "${AGG_SCRIPT}" "${SCRIPTS_DIR7}/roborev_daily_backlog_aggregator.sh"
cp "${MOCK7A}" "${SCRIPTS_DIR7}/roborev_project_backlog.sh"
chmod +x "${SCRIPTS_DIR7}/roborev_daily_backlog_aggregator.sh"

ROBOREV_DB="${DB7}" ROBOREV_AGG_OUT_DIR="${OUT7}" \
    bash "${SCRIPTS_DIR7}/roborev_daily_backlog_aggregator.sh" \
        --docs-root "${DOCS7}" >/dev/null 2>&1

TODAY7="$(date -u '+%Y-%m-%d')"
SUMMARY7="${OUT7}/${TODAY7}.md"
first_count=$(grep 'Total open findings:' "${SUMMARY7}" | grep -o '[0-9]*' | head -1)

# Second run: open_count=7
MOCK7B="${TMPDIR_ROOT}/mock7b.sh"
make_mock_per_project_script "${MOCK7B}" 7 20 "medium"
cp "${MOCK7B}" "${SCRIPTS_DIR7}/roborev_project_backlog.sh"

ROBOREV_DB="${DB7}" ROBOREV_AGG_OUT_DIR="${OUT7}" \
    bash "${SCRIPTS_DIR7}/roborev_daily_backlog_aggregator.sh" \
        --docs-root "${DOCS7}" >/dev/null 2>&1

second_count=$(grep 'Total open findings:' "${SUMMARY7}" | grep -o '[0-9]*' | head -1)

assert_eq "test7: first run count=3" "3" "${first_count}"
assert_eq "test7: second run count=7 (overwritten)" "7" "${second_count}"

# ── Test 8: plutil -lint on plist ────────────────────────────────────────────
if command -v plutil >/dev/null 2>&1; then
    plutil_rc=0
    plutil -lint "${PLIST}" >/dev/null 2>&1 || plutil_rc=$?
    assert_eq "test8: plutil -lint exits 0" "0" "${plutil_rc}"
else
    # plutil not available — skip gracefully
    pass "test8: plutil not available (skipped)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
exit 0
