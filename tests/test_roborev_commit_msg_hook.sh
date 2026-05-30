#!/usr/bin/env bash
# tests/test_roborev_commit_msg_hook.sh
#
# Unit tests for bin/roborev_install_commit_msg_hook.sh and the installed
# commit-msg hook logic.
#
# Uses synthetic temp git-repo + synthetic reviews.db fixtures.
# Exits 0 if all tests pass, 1 on any failure.
#
# Part of: JohnGavin/llm#352 — commit-msg citation validator tests

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../bin/roborev_install_commit_msg_hook.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d)"

# Cleanup on exit
cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { echo "PASS: $1"; (( PASS += 1 )); }
fail() { echo "FAIL: $1"; (( FAIL += 1 )); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        pass "${desc}"
    else
        fail "${desc} — expected='${expected}' actual='${actual}'"
    fi
}

assert_true() {
    local desc="$1"
    if eval "$2"; then
        pass "${desc}"
    else
        fail "${desc}"
    fi
}

assert_false() {
    local desc="$1"
    if ! eval "$2"; then
        pass "${desc}"
    else
        fail "${desc}"
    fi
}

# Make a minimal git repo with one commit (repo name = "testrepo")
make_git_repo() {
    local name="${1:-testrepo}"
    local dir
    dir="$(mktemp -d "${TMPDIR_ROOT}/${name}_XXXX")"
    git -C "${dir}" init -q
    git -C "${dir}" config user.email "test@test.local"
    git -C "${dir}" config user.name "Test"
    printf "readme\n" > "${dir}/README"
    git -C "${dir}" add README
    git -C "${dir}" commit -qm "init"
    echo "${dir}"
}

# Create a synthetic reviews.db with controllable fixture rows.
# Usage: make_reviews_db <db-path> <repo-name>
# Inserts:
#   repo id=1, name=<repo-name>
#   commits: id=1 sha=abc123
#   review_jobs: id=1 repo_id=1 commit_id=1
#   reviews:
#     id=1 job_id=1 closed=0  (open, same repo)
#     id=2 job_id=1 closed=1  (already closed, same repo)
#     id=3 review_jobs id=2 repo_id=2 (different repo "otherrepo")
make_reviews_db() {
    local db="$1"
    local repo_name="${2:-testrepo}"

    /usr/bin/python3 - "${db}" "${repo_name}" <<'PY'
import sys, sqlite3

db_path   = sys.argv[1]
repo_name = sys.argv[2]

con = sqlite3.connect(db_path)
con.executescript("""
    CREATE TABLE repos (
        id INTEGER PRIMARY KEY,
        root_path TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE commits (
        id INTEGER PRIMARY KEY,
        repo_id INTEGER NOT NULL REFERENCES repos(id),
        sha TEXT NOT NULL,
        author TEXT NOT NULL,
        subject TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE(repo_id, sha)
    );
    CREATE TABLE review_jobs (
        id INTEGER PRIMARY KEY,
        repo_id INTEGER NOT NULL REFERENCES repos(id),
        commit_id INTEGER REFERENCES commits(id),
        git_ref TEXT NOT NULL DEFAULT '',
        agent TEXT NOT NULL DEFAULT 'codex',
        status TEXT NOT NULL DEFAULT 'done',
        enqueued_at TEXT NOT NULL DEFAULT (datetime('now')),
        job_type TEXT NOT NULL DEFAULT 'review',
        review_type TEXT NOT NULL DEFAULT '',
        agentic INTEGER NOT NULL DEFAULT 0,
        prompt_prebuilt INTEGER NOT NULL DEFAULT 0,
        min_severity TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE reviews (
        id INTEGER PRIMARY KEY,
        job_id INTEGER UNIQUE NOT NULL REFERENCES review_jobs(id),
        agent TEXT NOT NULL DEFAULT 'codex',
        prompt TEXT NOT NULL DEFAULT '',
        output TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        closed INTEGER NOT NULL DEFAULT 0
    );
""")

# Repo 1: current project
con.execute("INSERT INTO repos (id, root_path, name) VALUES (1, '/tmp/testrepo', ?)", (repo_name,))
# Repo 2: different project
con.execute("INSERT INTO repos (id, root_path, name) VALUES (2, '/tmp/otherrepo', 'otherrepo')")

# Commits
con.execute("INSERT INTO commits (id, repo_id, sha, author, subject, timestamp) VALUES (1, 1, 'abc123', 'test', 'test commit', datetime('now'))")
con.execute("INSERT INTO commits (id, repo_id, sha, author, subject, timestamp) VALUES (2, 2, 'def456', 'test', 'other commit', datetime('now'))")

# Review jobs
con.execute("INSERT INTO review_jobs (id, repo_id, commit_id, git_ref) VALUES (1, 1, 1, 'abc123')")
con.execute("INSERT INTO review_jobs (id, repo_id, commit_id, git_ref) VALUES (2, 2, 2, 'def456')")
con.execute("INSERT INTO review_jobs (id, repo_id, commit_id, git_ref) VALUES (3, 1, 1, 'abc123')")

# Reviews:
#   id=1: open (closed=0), same repo
#   id=2: already closed (closed=1), same repo
#   id=3: open, cross-repo (repo 2 = otherrepo)
con.execute("INSERT INTO reviews (id, job_id, closed) VALUES (1, 1, 0)")
con.execute("INSERT INTO reviews (id, job_id, closed) VALUES (2, 3, 1)")
con.execute("INSERT INTO reviews (id, job_id, closed) VALUES (3, 2, 0)")

con.commit()
con.close()
print("DB created")
PY
}

# Run the installed commit-msg hook against a given message string.
# Usage: run_hook <hook-path> <message> [<db-path>] [<skip_env>]
# Sets globals: HOOK_EXIT (integer), HOOK_OUTPUT_FILE (temp file path).
# Use hook_output_contains "pattern" to test output (avoids quoting issues
# with em-dashes and special chars when passing output through eval).
HOOK_OUTPUT_FILE=""
hook_output_contains() {
    local pattern="$1"
    grep -qiE "${pattern}" "${HOOK_OUTPUT_FILE}" 2>/dev/null
}

run_hook() {
    local hook="$1"
    local message="$2"
    local db="${3:-}"
    local skip="${4:-0}"

    local msg_file out_file
    msg_file="$(mktemp "${TMPDIR_ROOT}/msg_XXXX")"
    out_file="$(mktemp "${TMPDIR_ROOT}/out_XXXX")"
    HOOK_OUTPUT_FILE="${out_file}"
    printf '%s\n' "${message}" > "${msg_file}"

    if [ -n "${db}" ]; then
        ROBOREV_DB="${db}" ROBOREV_COMMIT_HOOK_SKIP="${skip}" \
            bash "${hook}" "${msg_file}" > "${out_file}" 2>&1
        HOOK_EXIT=$?
    else
        ROBOREV_COMMIT_HOOK_SKIP="${skip}" \
            bash "${hook}" "${msg_file}" > "${out_file}" 2>&1
        HOOK_EXIT=$?
    fi
    rm -f "${msg_file}"
}

# ── Installer tests ───────────────────────────────────────────────────────────

# Test 1: Fresh repo gets hook installed + chmod +x
REPO1="$(make_git_repo)"
output1="$("${INSTALLER}" "${REPO1}" 2>&1)"
exit1=$?

assert_eq "test01: exit code 0 on fresh install" "0" "${exit1}"
assert_true "test01: commit-msg hook file created" "[[ -f '${REPO1}/.git/hooks/commit-msg' ]]"
assert_true "test01: commit-msg hook is executable" "[[ -x '${REPO1}/.git/hooks/commit-msg' ]]"

# Test 2: Re-run on same repo is idempotent
"${INSTALLER}" "${REPO1}" > /dev/null 2>&1
exit2=$?
assert_eq "test02: idempotent re-run exits 0" "0" "${exit2}"
assert_true "test02: hook still exists after re-run" "[[ -f '${REPO1}/.git/hooks/commit-msg' ]]"
assert_true "test02: hook still executable after re-run" "[[ -x '${REPO1}/.git/hooks/commit-msg' ]]"

# Test 3: Unrecognised existing commit-msg hook is skipped, not overwritten
REPO3="$(make_git_repo)"
FOREIGN_HOOK="${REPO3}/.git/hooks/commit-msg"
cat > "${FOREIGN_HOOK}" <<'EOF'
#!/usr/bin/env bash
# Custom hook not written by our installer
echo "custom hook"
EOF
chmod +x "${FOREIGN_HOOK}"
original_content="$(cat "${FOREIGN_HOOK}")"

output3="$("${INSTALLER}" "${REPO3}" 2>&1)"
exit3=$?
current_content="$(cat "${FOREIGN_HOOK}")"

assert_eq "test03: skip exits 0 (non-blocking)" "0" "${exit3}"
assert_true "test03: skip message printed" "echo '${output3}' | grep -q 'SKIP:'"
assert_eq "test03: foreign hook not overwritten" "${original_content}" "${current_content}"

# Test 4: Hook content has marker comment
REPO4="$(make_git_repo)"
"${INSTALLER}" "${REPO4}" > /dev/null 2>&1
MARKER="Installed by ~/docs_gh/llm/bin/roborev_install_commit_msg_hook.sh"

assert_true "test04: marker comment present in hook" "grep -qF '${MARKER}' '${REPO4}/.git/hooks/commit-msg'"

# Test 5: Generated hook parses cleanly under bash -n
bash_n_output="$(bash -n "${REPO4}/.git/hooks/commit-msg" 2>&1)"
bash_n_exit=$?
assert_eq "test05: bash -n exits 0 (hook syntax valid)" "0" "${bash_n_exit}"

# Test 6: Non-git directory is rejected with exit 1
NOTGIT="$(mktemp -d "${TMPDIR_ROOT}/notgit_XXXX")"
"${INSTALLER}" "${NOTGIT}" > /dev/null 2>&1
exit_notgit=$?
assert_eq "test06: non-git dir exits non-zero" "1" "${exit_notgit}"

# ── Hook behaviour tests ──────────────────────────────────────────────────────

# Set up a shared test repo + DB for hook tests
REPO_H="$(make_git_repo "testrepo")"
"${INSTALLER}" "${REPO_H}" > /dev/null 2>&1
HOOK_FILE="${REPO_H}/.git/hooks/commit-msg"
DB_FILE="${TMPDIR_ROOT}/test_reviews.db"
make_reviews_db "${DB_FILE}" "testrepo"

# Test 7: Commit with no roborev citation → exit 0
run_hook "${HOOK_FILE}" "fix: update readme" "${DB_FILE}"
assert_eq "test07: no citation → exit 0" "0" "${HOOK_EXIT}"

# Test 8: Commit with 'closes roborev #1' (open, same repo) → exit 0
run_hook "${HOOK_FILE}" "fix: something (closes roborev #1)" "${DB_FILE}"
assert_eq "test08: valid open citation → exit 0" "0" "${HOOK_EXIT}"

# Test 9: Commit with 'closes roborev #99' (ID does not exist) → exit 1 + error msg
run_hook "${HOOK_FILE}" "fix: something (closes roborev #99)" "${DB_FILE}"
assert_eq "test09: missing ID → exit 1" "1" "${HOOK_EXIT}"
assert_true "test09: error message mentions missing ID" "hook_output_contains 'not found|ERROR'"

# Test 10: Commit with 'closes roborev #2' (already closed=1) → exit 0 + WARN
run_hook "${HOOK_FILE}" "fix: something (closes roborev #2)" "${DB_FILE}"
assert_eq "test10: already-closed citation → exit 0" "0" "${HOOK_EXIT}"
assert_true "test10: WARN printed for already-closed" "hook_output_contains 'WARN|already closed|no-op'"

# Test 11: ROBOREV_COMMIT_HOOK_SKIP=1 bypasses entirely even with missing ID
run_hook "${HOOK_FILE}" "fix: something (closes roborev #99)" "${DB_FILE}" "1"
assert_eq "test11: ROBOREV_COMMIT_HOOK_SKIP=1 → exit 0" "0" "${HOOK_EXIT}"

# Test 12: 'acks roborev #1' citation also recognised (open, valid) → exit 0
run_hook "${HOOK_FILE}" "fix: something (acks roborev #1)" "${DB_FILE}"
assert_eq "test12: 'acks roborev #N' citation recognised → exit 0" "0" "${HOOK_EXIT}"

# Test 13: Multiple citations, one missing → exit 1
run_hook "${HOOK_FILE}" "fix: something (closes roborev #1, closes roborev #99)" "${DB_FILE}"
assert_eq "test13: mixed valid+missing → exit 1" "1" "${HOOK_EXIT}"

# Test 14: Cross-repo citation (ID=3 belongs to 'otherrepo') → exit 0 + WARN
run_hook "${HOOK_FILE}" "fix: something (closes roborev #3)" "${DB_FILE}"
assert_eq "test14: cross-repo citation → exit 0 (warn only)" "0" "${HOOK_EXIT}"
assert_true "test14: WARN printed for cross-repo" "hook_output_contains 'WARN|cross|otherrepo|belong'"

# Test 15: DB absent → fail-open (exit 0) with WARN
run_hook "${HOOK_FILE}" "fix: something (closes roborev #1)" "/nonexistent/reviews.db"
assert_eq "test15: DB absent → fail-open exit 0" "0" "${HOOK_EXIT}"
assert_true "test15: WARN printed for absent DB" "hook_output_contains 'WARN|not found|skip'"

# Test 16: Installer bash -n passes
bash_n_inst="$(bash -n "${INSTALLER}" 2>&1)"
bash_n_inst_exit=$?
assert_eq "test16: installer bash -n exits 0" "0" "${bash_n_inst_exit}"

# Test 17: All-repos installer bash -n passes
ALL_INSTALLER="${SCRIPT_DIR}/../bin/roborev_install_commit_msg_hook_all.sh"
bash_n_all="$(bash -n "${ALL_INSTALLER}" 2>&1)"
bash_n_all_exit=$?
assert_eq "test17: all-repos installer bash -n exits 0" "0" "${bash_n_all_exit}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
