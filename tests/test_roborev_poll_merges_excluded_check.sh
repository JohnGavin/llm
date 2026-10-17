#!/usr/bin/env bash
# tests/test_roborev_poll_merges_excluded_check.sh
#
# Regression test for JohnGavin/llm#1333: roborev_poll_merges.sh runs under
# `set -eo pipefail`, and the all-files-excluded check was written as
#     excl_msg=$(roborev_all_files_excluded ...); excl_rc=$?
# The helper returns 1 for the NORMAL "some file is not excluded" case and 3
# for indeterminate. Under `set -e` a non-zero assignment from a command
# substitution aborts the script, so the poller died at the first repo with
# real new commits (never reaching the summary line or later repos).
#
# Each case builds a real git repo + a synthetic roborev DB, runs the real
# poller in --dry-run (fake roborev binary, no network, no live DB/log) and
# asserts the poller REACHES its summary line and took the right branch:
#   1. rc 1 (normal change)        -> "would enqueue", summary present
#   2. rc 0 (all files excluded)   -> "skip: all files excluded", no enqueue
#   3. rc 3 (unparseable config)   -> "indeterminate", still would enqueue
#   4. a second repo AFTER the changed one is still polled (no mid-loop abort)
#
# bash 3.2 compatible. Exit 0 pass, 1 fail, 3 indeterminate (fixture unusable).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_SCRIPT="${SCRIPT_DIR}/../.claude/scripts/roborev_poll_merges.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
    if printf '%s\n' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 -- '$2' not found in: $3"; fi
}
assert_not_contains() {
    if printf '%s\n' "$3" | grep -qF -- "$2"; then fail "$1 -- unexpected '$2' in: $3"; else pass "$1"; fi
}

# The poller treats /tmp and /private/tmp roots as ephemeral and skips them.
case "$(cd -P "${TMPDIR_ROOT}" && pwd -P)" in
    /tmp/*|/private/tmp/*)
        echo "INDETERMINATE: mktemp root is under /tmp (poller skips ephemeral roots); set TMPDIR elsewhere"
        exit 3 ;;
esac

FAKE_ROBOREV="${TMPDIR_ROOT}/fake_roborev"
printf '#!/bin/sh\nexit 0\n' > "${FAKE_ROBOREV}"
chmod +x "${FAKE_ROBOREV}"

# Global roborev config pointed at a nonexistent file so the user's real
# ~/.roborev/config.toml can never influence the result.
NO_GLOBAL="${TMPDIR_ROOT}/no_global_config.toml"

# mkrepo DIR: two commits, prints the first sha. $2 = file changed by commit 2,
# $3 = contents of .roborev.toml (written in commit 1).
mkrepo() {
    local dir="$1" changed="$2" toml="$3"
    mkdir -p "${dir}"
    git -C "${dir}" init -q
    git -C "${dir}" config user.email t@example.invalid
    git -C "${dir}" config user.name t
    git -C "${dir}" config commit.gpgsign false
    git -C "${dir}" config core.hooksPath /dev/null
    printf 'a\n' > "${dir}/a.txt"
    printf '%s\n' "${toml}" > "${dir}/.roborev.toml"
    git -C "${dir}" add -A
    git -C "${dir}" commit -q -m c1
    git -C "${dir}" rev-parse HEAD
    printf 'b\n' >> "${dir}/${changed}"
    git -C "${dir}" add -A
    git -C "${dir}" commit -q -m c2
}

# mkdb DB NAME:DIR:SHA ... -> repos + commits + one done review at SHA
mkdb() {
    local db="$1"; shift
    /usr/bin/python3 - "${db}" "$@" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.executescript("""
CREATE TABLE repos (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, root_path TEXT);
CREATE TABLE commits (id INTEGER PRIMARY KEY AUTOINCREMENT, sha TEXT);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, repo_id INTEGER,
  commit_id INTEGER, status TEXT DEFAULT 'done', git_ref TEXT, enqueued_at TEXT);
""")
for spec in sys.argv[2:]:
    name, root, sha = spec.split(":", 2)
    rid = con.execute("INSERT INTO repos (name, root_path) VALUES (?, ?)", (name, root)).lastrowid
    cid = con.execute("INSERT INTO commits (sha) VALUES (?)", (sha,)).lastrowid
    con.execute("INSERT INTO review_jobs (repo_id, commit_id, status, git_ref, enqueued_at) "
                "VALUES (?, ?, 'done', ?, '2026-01-01')", (rid, cid, sha))
con.commit()
PYEOF
}

# run_poller DB LOG -> combined stdout/stderr; sets POLL_RC
run_poller() {
    ROBOREV_DB="$1" LOG="$2" ROBOREV="${FAKE_ROBOREV}" SKIP_ROBOREV_REQUEUE=1 \
        ROBOREV_GLOBAL_CONFIG="${NO_GLOBAL}" \
        bash "${POLL_SCRIPT}" --dry-run > "$2.out" 2>&1
    echo $? > "$2.rc"
    cat "$2.out"
}

# ── Case 1: normal change, helper returns 1 ──────────────────────────────────
R1="${TMPDIR_ROOT}/repo1"
S1=$(mkrepo "${R1}" a.txt 'exclude_patterns = ["CHANGELOG.md"]')
R1B="${TMPDIR_ROOT}/repo1b"
S1B=$(mkrepo "${R1B}" a.txt 'exclude_patterns = ["CHANGELOG.md"]')
DB1="${TMPDIR_ROOT}/db1.sqlite"
mkdb "${DB1}" "alpha:${R1}:${S1}" "beta:${R1B}:${S1B}"
out1=$(run_poller "${DB1}" "${TMPDIR_ROOT}/log1")
assert_contains "case1: poller exits 0" "rc=0" "rc=$(cat "${TMPDIR_ROOT}/log1.rc")"
assert_contains "case1: first repo reaches would-enqueue" "[dry] alpha" "${out1}"
assert_contains "case1: SECOND repo still polled (no mid-loop abort)" "[dry] beta" "${out1}"
assert_contains "case1: summary line reached" "roborev_poll_merges [dry-run]" "${out1}"

# ── Case 2: every changed file excluded, helper returns 0 ────────────────────
R2="${TMPDIR_ROOT}/repo2"
S2=$(mkrepo "${R2}" CHANGELOG.md 'exclude_patterns = ["CHANGELOG.md"]')
DB2="${TMPDIR_ROOT}/db2.sqlite"
mkdb "${DB2}" "gamma:${R2}:${S2}"
LOG2="${TMPDIR_ROOT}/log2"
out2=$(run_poller "${DB2}" "${LOG2}")
assert_contains "case2: summary line reached" "roborev_poll_merges [dry-run]" "${out2}"
assert_not_contains "case2: all-excluded repo is NOT enqueued" "[dry] gamma" "${out2}"
assert_contains "case2: logged as all-files-excluded skip" "skip: all files excluded: gamma" "$(cat "${LOG2}" 2>/dev/null)"

# ── Case 3: indeterminate (exclude_patterns not an array), helper returns 3 ──
R3="${TMPDIR_ROOT}/repo3"
S3=$(mkrepo "${R3}" a.txt 'exclude_patterns = "CHANGELOG.md"')
DB3="${TMPDIR_ROOT}/db3.sqlite"
mkdb "${DB3}" "delta:${R3}:${S3}"
LOG3="${TMPDIR_ROOT}/log3"
out3=$(run_poller "${DB3}" "${LOG3}")
assert_contains "case3: summary line reached" "roborev_poll_merges [dry-run]" "${out3}"
assert_contains "case3: indeterminate still enqueues" "[dry] delta" "${out3}"
assert_contains "case3: indeterminate is logged" "indeterminate: config-unparseable: delta" "$(cat "${LOG3}" 2>/dev/null)"

echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
