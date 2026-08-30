#!/usr/bin/env bash
# tests/test_roborev_poll_merges_ephemeral_skip.sh
#
# Unit test for .claude/scripts/roborev_poll_merges.sh's ephemeral-path skip
# logging (JohnGavin/llm#887 Option B).
#
# Before this fix, every ephemeral (/tmp, /private/tmp) repo in the `repos`
# table got its own "SKIP <path> (ephemeral)" log line per poll run -- on an
# unpurged DB with ~1,390 ephemeral rows that was ~1,390 lines/run x 3
# runs/day, dwarfing the one-line `summary [...]: ... skipped=N` line that
# already carried the same count. This test asserts:
#   1. NO per-repo "(ephemeral)" SKIP line appears in the log, regardless of
#      how many ephemeral repos are in the table.
#   2. The aggregate summary line instead carries an `ephemeral=N` field.
#   3. Per-repo log lines for OTHER skip reasons (a real, non-ephemeral repo
#      whose root_path no longer exists on disk) are UNCHANGED -- Option B is
#      scoped to the ephemeral case only; other skip reasons stay actionable.
#
# Uses ROBOREV_DB and LOG env-var overrides (both already supported by the
# script) so this test never touches the live ~/.roborev/reviews.db or the
# live ~/.claude/logs/roborev_poll_merges.log.
#
# Exits 0 if all tests pass, 1 on any failure.
#
# Part of: JohnGavin/llm#887

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_SCRIPT="${SCRIPT_DIR}/../.claude/scripts/roborev_poll_merges.sh"

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

# Create a synthetic DB with the subset of roborev's schema this script reads.
make_roborev_db() {
    local db_path="$1"
    /usr/bin/python3 - "$db_path" <<'PYEOF'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE IF NOT EXISTS repos (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT    NOT NULL,
    root_path TEXT
);
CREATE TABLE IF NOT EXISTS commits (
    id  INTEGER PRIMARY KEY AUTOINCREMENT,
    sha TEXT
);
CREATE TABLE IF NOT EXISTS review_jobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_id     INTEGER REFERENCES repos(id),
    commit_id   INTEGER REFERENCES commits(id),
    status      TEXT DEFAULT 'done',
    git_ref     TEXT,
    enqueued_at TEXT
);
""")
con.commit()
con.close()
PYEOF
}

insert_repo() {
    local db="$1" name="$2" root_path="$3"
    /usr/bin/python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('INSERT INTO repos (name, root_path) VALUES (?, ?)', (sys.argv[2], sys.argv[3]))
con.commit()
" "${db}" "${name}" "${root_path}"
}

run_poller() {
    local db="$1" log="$2"
    ROBOREV_DB="${db}" LOG="${log}" SKIP_ROBOREV_REQUEUE=1 \
        bash "${POLL_SCRIPT}" 2>&1
}

# ── Test 1: N ephemeral repos -> zero per-repo lines, one aggregate field ────
DB1="${TMPDIR_ROOT}/db1.sqlite"
LOG1="${TMPDIR_ROOT}/poll1.log"
make_roborev_db "${DB1}"
for i in 1 2 3 4 5; do
    insert_repo "${DB1}" "kb_fixture_${i}" "/private/tmp/nix-shell-1-0/Rtmp/kb_fixture_${i}"
done

out1=$(run_poller "${DB1}" "${LOG1}")
exit1=$?

assert_eq "test1: exit 0" "0" "${exit1}"

# No `2>/dev/null || true` here: grep -c on a file with zero matches exits 1
# but still prints "0" to stdout, which the caller's `set -uo pipefail` (no
# -e) captures correctly without help. Swallowing the exit status would make
# a genuinely missing log file (empty stdout) indistinguishable from a
# correct zero-count result ("0") -- see checks-must-distinguish-unknown.
ephemeral_lines_1=$(grep -c '(ephemeral)' "${LOG1}")
assert_eq "test1: zero per-repo '(ephemeral)' log lines" "0" "${ephemeral_lines_1}"

assert_contains "test1: stdout summary carries ephemeral=5" "ephemeral=5" "${out1}"
assert_contains "test1: stdout summary carries skipped=5" "skipped=5" "${out1}"

log_line_count_1=$(wc -l < "${LOG1}" | tr -d ' ')
assert_eq "test1: log has exactly 2 lines (summary + requeue-skip note)" "2" "${log_line_count_1}"

# ── Test 2: zero ephemeral repos -> aggregate field reads ephemeral=0 ────────
DB2="${TMPDIR_ROOT}/db2.sqlite"
LOG2="${TMPDIR_ROOT}/poll2.log"
make_roborev_db "${DB2}"

out2=$(run_poller "${DB2}" "${LOG2}")
exit2=$?

assert_eq "test2: exit 0 on empty repos table" "0" "${exit2}"
assert_contains "test2: ephemeral=0 when no ephemeral repos" "ephemeral=0" "${out2}"

# ── Test 3: a non-ephemeral repo whose root_path no longer exists on disk ────
# still gets its own actionable per-repo log line (Option B is scoped to the
# ephemeral case only).
DB3="${TMPDIR_ROOT}/db3.sqlite"
LOG3="${TMPDIR_ROOT}/poll3.log"
make_roborev_db "${DB3}"
DELETED_PATH="${TMPDIR_ROOT}/this_repo_was_deleted_$$"
insert_repo "${DB3}" "deleted_real_repo" "${DELETED_PATH}"
# (never create DELETED_PATH -- the whole point is it does not exist)

out3=$(run_poller "${DB3}" "${LOG3}")
exit3=$?

assert_eq "test3: exit 0" "0" "${exit3}"
assert_contains "test3: per-repo skip line for a deleted real repo is kept" \
    "deleted_real_repo" "$(cat "${LOG3}")"
assert_contains "test3: ephemeral=0 (this repo isn't ephemeral, just deleted)" \
    "ephemeral=0" "${out3}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
exit 0
