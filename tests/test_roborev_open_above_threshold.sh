#!/usr/bin/env bash
# tests/test_roborev_open_above_threshold.sh
#
# Tests .claude/scripts/roborev_open_above_threshold.sh against a fixture
# sqlite DB, fixture per-repo .roborev.toml and a fixture HOME (global
# config). Every positive result has a paired falsification: lowering the
# fixture severity flips exit 1 to 0; a missing/unreadable DB gives exit 3,
# never 0. The checker must never print finding text or paths: a marker
# string is planted in each finding body and root path and grep'd for absence.
#
# Bash 3.2 compatible. Needs sqlite3 and /usr/bin/python3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${SCRIPT_DIR}/../.claude/scripts/roborev_open_above_threshold.sh"
SQLITE3="${SQLITE3:-$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAKE_HOME="${TMP}/home"
mkdir -p "${FAKE_HOME}/.roborev"
REPO_ROOT_DIR="${TMP}/SECRETPATHMARKER/proj"
mkdir -p "${REPO_ROOT_DIR}"
BODY_MARKER="SECRETBODYMARKER"

mk_db() {
  "$SQLITE3" "$1" <<EOF
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'done');
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER UNIQUE NOT NULL, output TEXT NOT NULL DEFAULT '', closed INTEGER NOT NULL DEFAULT 0, structured_output TEXT);
INSERT INTO repos (id, root_path, name) VALUES (1, '${REPO_ROOT_DIR}', 'fixrepo');
EOF
}

# add_review <db> <job_id> <closed 0|1> <severity|none>
add_review() {
  local db="$1" job="$2" closed="$3" sev="$4" json
  if [ "$sev" = "none" ]; then
    json='{"schema_version":2,"summary":"clean","verdict":"pass","findings":[]}'
  else
    json="{\"schema_version\":2,\"summary\":\"s\",\"verdict\":\"fail\",\"findings\":[{\"severity\":\"${sev}\",\"location\":\"x.R:1\",\"problem\":\"${BODY_MARKER} problem text\"}]}"
  fi
  "$SQLITE3" "$db" "INSERT INTO review_jobs (id, repo_id) VALUES (${job}, 1); INSERT INTO reviews (job_id, closed, structured_output) VALUES (${job}, ${closed}, '${json}');"
}

set_repo_toml() { printf '[autoclose]\nseverity_threshold = "%s"\n' "$1" > "${REPO_ROOT_DIR}/.roborev.toml"; }
clear_repo_toml() { rm -f "${REPO_ROOT_DIR}/.roborev.toml"; }
set_global() { printf 'autoclose_severity_threshold = "%s"\n' "$1" > "${FAKE_HOME}/.roborev/config.toml"; }
clear_global() { rm -f "${FAKE_HOME}/.roborev/config.toml"; }

# run_checker <db>: sets OUT_FILE and RC; isolated HOME, env override unset.
run_checker() {
  OUT_FILE="${TMP}/out.txt"
  env -u ROBOREV_SEVERITY_AUTOCLOSE_THRESHOLD HOME="${FAKE_HOME}" \
    bash "$CHECKER" --repo fixrepo --db "$1" > "$OUT_FILE" 2> "${TMP}/err.txt"
  RC=$?
}

expect() { # label, expected rc
  if [ "$RC" -eq "$2" ]; then ok "$1 (exit $RC)"; else bad "$1: expected exit $2, got $RC; stdout=$(tr '\n' ' ' < "$OUT_FILE") stderr=$(tr '\n' ' ' < "${TMP}/err.txt")"; fi
}
expect_no_leak() {
  if grep -q "$BODY_MARKER" "$OUT_FILE" "${TMP}/err.txt" || grep -q "SECRETPATHMARKER" "$OUT_FILE" "${TMP}/err.txt"; then
    bad "$1: output leaked finding text or a path"
  else
    ok "$1: no finding text or path printed"
  fi
}

# 1. above threshold (high review, threshold medium) -> exit 1, id listed
DB="${TMP}/t1.db"; mk_db "$DB"; add_review "$DB" 101 0 high
set_repo_toml medium; clear_global
run_checker "$DB"
expect "above threshold" 1
if grep -qx 'job_id=101 max=high' "$OUT_FILE" && grep -qx 'count=1' "$OUT_FILE"; then ok "above threshold lists id and count"; else bad "above threshold output: $(tr '\n' ' ' < "$OUT_FILE")"; fi
expect_no_leak "above threshold"

# 1b. falsification: same fixture with severity lowered to low -> exit 0
DB="${TMP}/t1b.db"; mk_db "$DB"; add_review "$DB" 101 0 low
run_checker "$DB"
expect "falsification: lowered severity flips to none" 0

# 2. at threshold and below -> exit 0
DB="${TMP}/t2.db"; mk_db "$DB"; add_review "$DB" 201 0 medium; add_review "$DB" 202 0 low
run_checker "$DB"
expect "at threshold and below" 0
grep -qx 'count=0' "$OUT_FILE" && ok "count=0 printed" || bad "count=0 missing: $(tr '\n' ' ' < "$OUT_FILE")"

# 3. closed/addressed above-threshold review not counted
DB="${TMP}/t3.db"; mk_db "$DB"; add_review "$DB" 301 1 critical
run_checker "$DB"
expect "closed above-threshold review not counted" 0

# 3b. mixed: closed one ignored, open one counted
DB="${TMP}/t3b.db"; mk_db "$DB"; add_review "$DB" 301 1 critical; add_review "$DB" 302 0 high
run_checker "$DB"
expect "mixed closed+open" 1
if grep -q 'job_id=301' "$OUT_FILE"; then bad "closed review 301 listed"; else ok "closed review 301 not listed"; fi

# 4. threshold=off: every parsed severity counts; unparsed (clean) does not
DB="${TMP}/t4.db"; mk_db "$DB"; add_review "$DB" 401 0 low; add_review "$DB" 402 0 none
set_repo_toml off
run_checker "$DB"
expect "threshold=off counts a low finding" 1
if grep -q 'job_id=402' "$OUT_FILE"; then bad "clean review 402 counted under off"; else ok "clean (no severity) review not counted under off"; fi
grep -qx 'count=1' "$OUT_FILE" && ok "off count=1" || bad "off count: $(tr '\n' ' ' < "$OUT_FILE")"

# 5. missing DB and unreadable DB -> exit 3
run_checker "${TMP}/does-not-exist.db"
expect "missing DB is INDETERMINATE" 3
grep -q '^count=' "$OUT_FILE" && bad "missing DB printed a count" || ok "missing DB prints no count"
printf 'this is not a sqlite database at all\n' > "${TMP}/garbage.db"
run_checker "${TMP}/garbage.db"
expect "unreadable (non-sqlite) DB is INDETERMINATE" 3

# 6. per-repo threshold overrides global
DB="${TMP}/t6.db"; mk_db "$DB"; add_review "$DB" 601 0 high
clear_repo_toml; set_global low
run_checker "$DB"
expect "global=low alone: high is above" 1
set_repo_toml high
run_checker "$DB"
expect "per-repo high overrides global low: high at threshold" 0
set_repo_toml low; set_global critical
run_checker "$DB"
expect "per-repo low overrides global critical: high above" 1

# 7. global applies when no per-repo threshold
clear_repo_toml; set_global critical
run_checker "$DB"
expect "global=critical alone: high below" 0

# 8. unresolved threshold value -> exit 3, not 0
set_repo_toml bogus
run_checker "$DB"
expect "unrecognised threshold is INDETERMINATE" 3

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
