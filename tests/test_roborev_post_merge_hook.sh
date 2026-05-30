#!/usr/bin/env bash
# tests/test_roborev_post_merge_hook.sh
#
# Unit tests for bin/roborev_install_post_merge_hook.sh
#
# Uses a synthetic temp git-repo fixture.
# Exits 0 if all tests pass, 1 on any failure.
#
# Part of: llm#217 Phase 3 — post-merge hook installer tests

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../bin/roborev_install_post_merge_hook.sh"

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

make_git_repo() {
    local dir
    dir="$(mktemp -d "${TMPDIR_ROOT}/repo_XXXX")"
    git -C "${dir}" init -q
    git -C "${dir}" config user.email "test@test.local"
    git -C "${dir}" config user.name "Test"
    echo > "${dir}/README"
    git -C "${dir}" add README
    git -C "${dir}" commit -qm "init"
    echo "${dir}"
}

# ── Test 1: Fresh repo gets hook installed + chmod +x ────────────────────────
REPO1="$(make_git_repo)"
output1="$("${INSTALLER}" "${REPO1}" 2>&1)"
exit1=$?

assert_eq "test1: exit code 0 on fresh install" "0" "${exit1}"
assert_true "test1: post-merge hook file created" "[[ -f '${REPO1}/.git/hooks/post-merge' ]]"
assert_true "test1: post-merge hook is executable" "[[ -x '${REPO1}/.git/hooks/post-merge' ]]"

# ── Test 2: Re-run on same repo is idempotent ────────────────────────────────
mtime_before="$(stat -f '%m' "${REPO1}/.git/hooks/post-merge" 2>/dev/null || stat -c '%Y' "${REPO1}/.git/hooks/post-merge")"
sleep 1
"${INSTALLER}" "${REPO1}" > /dev/null 2>&1
exit2=$?
mtime_after="$(stat -f '%m' "${REPO1}/.git/hooks/post-merge" 2>/dev/null || stat -c '%Y' "${REPO1}/.git/hooks/post-merge")"

assert_eq "test2: idempotent re-run exits 0" "0" "${exit2}"
assert_true "test2: hook still exists after re-run" "[[ -f '${REPO1}/.git/hooks/post-merge' ]]"
assert_true "test2: hook still executable after re-run" "[[ -x '${REPO1}/.git/hooks/post-merge' ]]"

# ── Test 3: Unrecognised existing post-merge hook is skipped, not overwritten ─
REPO3="$(make_git_repo)"
FOREIGN_HOOK="${REPO3}/.git/hooks/post-merge"
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

assert_eq "test3: skip exits 0 (non-blocking)" "0" "${exit3}"
assert_true "test3: skip message printed" "echo '${output3}' | grep -q 'SKIP:'"
assert_eq "test3: foreign hook not overwritten" "${original_content}" "${current_content}"

# ── Test 4: Hook content has marker comment ──────────────────────────────────
REPO4="$(make_git_repo)"
"${INSTALLER}" "${REPO4}" > /dev/null 2>&1
MARKER="Installed by ~/docs_gh/llm/bin/roborev_install_post_merge_hook.sh"

assert_true "test4: marker comment present in hook" "grep -qF '${MARKER}' '${REPO4}/.git/hooks/post-merge'"

# ── Test 5: Hook content has roborev-availability guard ─────────────────────
assert_true "test5: availability guard present" "grep -q 'command -v roborev' '${REPO4}/.git/hooks/post-merge'"

# ── Test 6: Generated hook parses cleanly under bash -n ─────────────────────
bash_n_output="$(bash -n "${REPO4}/.git/hooks/post-merge" 2>&1)"
bash_n_exit=$?

assert_eq "test6: bash -n exits 0 (hook syntax valid)" "0" "${bash_n_exit}"

# ── Test 7: Non-git directory is rejected with exit 1 ───────────────────────
NOTGIT="$(mktemp -d "${TMPDIR_ROOT}/notgit_XXXX")"
"${INSTALLER}" "${NOTGIT}" > /dev/null 2>&1
exit_notgit=$?
assert_eq "test7: non-git dir exits non-zero" "1" "${exit_notgit}"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
