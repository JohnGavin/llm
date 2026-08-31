#!/usr/bin/env bash
# tests/test_agentsview_quality_baseline.sh
#
# Integration tests for .claude/scripts/agentsview_quality_baseline.sh
#
# Runs the script as a real subprocess (not sourced) against a synthetic
# SQLite fixture (real sessions.db schema subset: sessions.project/cwd) and
# a mocked `agentsview` CLI binary placed first on PATH. No live agentsview
# CLI or real ~/.agentsview/sessions.db is touched.
#
# Complements the script's own internal `--selftest` (unit tests of its
# helper functions run in-process). This file exercises the script
# end-to-end as an external process, matching the convention established by
# tests/test_roborev_project_backlog.sh.
#
# Exits 0 if all tests pass, 1 on any failure.
#
# Part of: JohnGavin/llm#1115

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE_SCRIPT="${SCRIPT_DIR}/../.claude/scripts/agentsview_quality_baseline.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "${expected}" = "${actual}" ]; then
        pass "${desc}"
    else
        fail "${desc} -- expected='${expected}' actual='${actual}'"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "${haystack}" | grep -qF "${needle}"; then
        pass "${desc}"
    else
        fail "${desc} -- '${needle}' not found in output"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "${haystack}" | grep -qF "${needle}"; then
        fail "${desc} -- '${needle}' should NOT appear in output but does"
    else
        pass "${desc}"
    fi
}

# Create a synthetic sessions.db with just the columns
# agentsview_quality_baseline.sh's bucket-resolution query reads
# (project, cwd) -- a minimal subset of the real sessions table schema.
make_sessions_db() {
    local db_path="$1"
    /usr/bin/python3 - "$db_path" <<'PYEOF'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE IF NOT EXISTS sessions (
    id      TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    cwd     TEXT NOT NULL DEFAULT ''
);
""")
con.commit()
con.close()
PYEOF
}

insert_session_row() {
    local db="$1" project="$2" cwd="$3" id="$4"
    /usr/bin/python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('INSERT INTO sessions (id, project, cwd) VALUES (?, ?, ?)', (sys.argv[4], sys.argv[2], sys.argv[3]))
con.commit()
" "${db}" "${project}" "${cwd}" "${id}"
}

# Build a mock `agentsview` executable, first on PATH, that returns fixed
# JSON depending on which flags it receives -- distinguishing the raw-total
# call (--include-automated) from the substantive-session call
# (--min-messages), per bucket name passed via --project.
make_mock_agentsview() {
    local bindir="$1"
    mkdir -p "${bindir}"
    cat > "${bindir}/agentsview" <<'MOCKEOF'
#!/usr/bin/env bash
project=""
has_automated=0
has_minmsg=0
prev=""
for a in "$@"; do
  [ "$prev" = "--project" ] && project="$a"
  [ "$a" = "--include-automated" ] && has_automated=1
  [ "$a" = "--min-messages" ] && has_minmsg=1
  prev="$a"
done

if [ "$has_automated" = "1" ]; then
  case "$project" in
    demo)     echo '{"total": 200, "sessions": []}' ;;
    demo_old) echo '{"total": 50, "sessions": []}' ;;
    *)        echo '{"total": 0, "sessions": []}' ;;
  esac
elif [ "$has_minmsg" = "1" ]; then
  case "$project" in
    demo)
      cat <<'JSON'
{"total": 3, "sessions": [
  {"message_count": 45,  "is_automated": false, "health_score": 95, "health_grade": "A"},
  {"message_count": 60,  "is_automated": false, "health_score": 80, "health_grade": "B"},
  {"message_count": 200, "is_automated": true,  "health_score": 100, "health_grade": "A"}
]}
JSON
      ;;
    demo_old)
      cat <<'JSON'
{"total": 1, "sessions": [
  {"message_count": 100, "is_automated": false, "health_score": 60, "health_grade": "D"}
]}
JSON
      ;;
    *)
      echo '{"total": 0, "sessions": []}'
      ;;
  esac
else
  echo '{}'
fi
MOCKEOF
    chmod +x "${bindir}/agentsview"
}

# ── Test 1: single-bucket resolution, human output, tier=building ─────────
DB1="${TMPDIR_ROOT}/db1.sqlite"
BIN1="${TMPDIR_ROOT}/bin1"
make_sessions_db "${DB1}"
insert_session_row "${DB1}" "demo" "/Users/x/demo" "s1"
make_mock_agentsview "${BIN1}"

out1=$(PATH="${BIN1}:${PATH}" AGENTSVIEW_DB="${DB1}" bash "${BASELINE_SCRIPT}" demo 2>&1)
exit1=$?

assert_eq "test1: exit 0" "0" "${exit1}"
assert_contains "test1: reports 1 bucket resolved" "Buckets resolved: 1" "${out1}"
# 3 sessions in fixture; only 2 pass (message_count>=30 AND is_automated==false)
assert_contains "test1: substantive n=2" "combined: 2" "${out1}"
assert_contains "test1: tier=too-thin (n=2 < 3)" "Trust tier: too-thin" "${out1}"

# ── Test 2: multi-bucket resolution (split-project case, rule caveat 3) ───
DB2="${TMPDIR_ROOT}/db2.sqlite"
BIN2="${TMPDIR_ROOT}/bin2"
make_sessions_db "${DB2}"
insert_session_row "${DB2}" "demo" "/Users/x/demo" "s1"
insert_session_row "${DB2}" "demo_old" "/Users/x/demo-old" "s2"
make_mock_agentsview "${BIN2}"

out2=$(PATH="${BIN2}:${PATH}" AGENTSVIEW_DB="${DB2}" bash "${BASELINE_SCRIPT}" demo 2>&1)
exit2=$?

assert_eq "test2: exit 0" "0" "${exit2}"
assert_contains "test2: reports 2 buckets resolved" "Buckets resolved: 2" "${out2}"
assert_contains "test2: names both buckets" "demo_old" "${out2}"
# demo contributes 2 substantive, demo_old contributes 1 -> aggregate n=3
assert_contains "test2: aggregate substantive n=3" "combined: 3" "${out2}"
assert_contains "test2: tier=building (n=3)" "Trust tier: building" "${out2}"

# ── Test 3: --json output is valid and machine-parseable ──────────────────
DB3="${TMPDIR_ROOT}/db3.sqlite"
BIN3="${TMPDIR_ROOT}/bin3"
make_sessions_db "${DB3}"
insert_session_row "${DB3}" "demo" "/Users/x/demo" "s1"
make_mock_agentsview "${BIN3}"

out3=$(PATH="${BIN3}:${PATH}" AGENTSVIEW_DB="${DB3}" bash "${BASELINE_SCRIPT}" demo --json 2>&1)
exit3=$?
assert_eq "test3: exit 0" "0" "${exit3}"
if command -v jq >/dev/null 2>&1; then
    valid=$(printf '%s' "${out3}" | jq empty >/dev/null 2>&1 && echo 1 || echo 0)
    assert_eq "test3: valid JSON" "1" "${valid}"
    tier_val=$(printf '%s' "${out3}" | jq -r '.tier')
    assert_eq "test3: tier field is too-thin" "too-thin" "${tier_val}"
    n_val=$(printf '%s' "${out3}" | jq -r '.aggregate.n')
    assert_eq "test3: aggregate.n is 2" "2" "${n_val}"
fi

# ── Test 4: INDETERMINATE -- DB unreadable, distinct from too-thin ────────
out4=$(AGENTSVIEW_DB="${TMPDIR_ROOT}/does-not-exist.db" bash "${BASELINE_SCRIPT}" demo 2>&1)
exit4=$?
assert_eq "test4: exit 2 (INDETERMINATE)" "2" "${exit4}"
assert_contains "test4: labelled INDETERMINATE" "INDETERMINATE" "${out4}"
assert_not_contains "test4: never silently renders as too-thin" "too-thin" "${out4}"

# ── Test 5: no bucket matches the given name -> INDETERMINATE, not a zero ─
DB5="${TMPDIR_ROOT}/db5.sqlite"
make_sessions_db "${DB5}"
insert_session_row "${DB5}" "unrelated" "/Users/x/unrelated" "s1"
out5=$(AGENTSVIEW_DB="${DB5}" bash "${BASELINE_SCRIPT}" nosuchproject 2>&1)
exit5=$?
assert_eq "test5: exit 2 (INDETERMINATE)" "2" "${exit5}"
assert_contains "test5: labelled INDETERMINATE" "INDETERMINATE" "${out5}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "${PASS}/$((PASS + FAIL)) PASS"
[ "${FAIL}" -eq 0 ] && exit 0 || exit 1
