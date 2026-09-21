#!/usr/bin/env bash
# tests/test_ci_availability_check.sh
#
# Tests for .claude/scripts/ci_availability_check.sh (JohnGavin/llm#1234).
# Uses a mock `gh` on PATH; never touches the network or the real ledger.
# Exits 0 if all pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CHECK_SCRIPT:-${SCRIPT_DIR}/../.claude/scripts/ci_availability_check.sh}"
TMP="$(mktemp -d /tmp/test_ci_avail_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- ${2:-}"; FAIL=$((FAIL + 1)); }

# ── mock gh ──────────────────────────────────────────────────────────────────
# MOCK_RUNS      file with "conclusion<TAB>status" lines (newest first)
# MOCK_RUN_EXIT  exit code for `run list` (default 0)
# MOCK_401       if 1: `run list` fails 401 while GH_TOKEN is set
# MOCK_API_EXIT  exit code for `api` (default 0); prints 12.5 on success
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  run)
    if [ "${MOCK_401:-0}" = "1" ] && [ -n "${GH_TOKEN:-}" ]; then
      echo "HTTP 401: Bad credentials" >&2; exit 1
    fi
    if [ "${MOCK_RUN_EXIT:-0}" != "0" ]; then
      echo "gh: boom" >&2; exit "$MOCK_RUN_EXIT"
    fi
    cat "$MOCK_RUNS"; exit 0 ;;
  api)
    if [ "${MOCK_API_EXIT:-0}" != "0" ]; then
      echo "gh: This endpoint has been moved. (HTTP 410)" >&2; exit "$MOCK_API_EXIT"
    fi
    echo "12.5"; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/gh"

T=$'\t'
runs() { printf '%b' "$1" > "$TMP/runs.txt"; export MOCK_RUNS="$TMP/runs.txt"; }

# run_check ARGS... -> sets OUT, RC
run_check() {
  OUT="$(PATH="$TMP/bin:$PATH" bash "$CHECK" "$@" 2>&1)"
  RC=$?
}
expect() { # desc expected_rc pattern
  if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -q -- "$3"; then
    pass "$1"
  else
    fail "$1" "rc=$RC (want $2); output: $OUT"
  fi
}

unset MOCK_401 MOCK_RUN_EXIT MOCK_API_EXIT

# 1. newest run succeeded -> AVAILABLE / 0
runs "success${T}completed\nsuccess${T}completed\n"
run_check
expect "newest success -> AVAILABLE exit 0" 0 "RESULT: AVAILABLE"

# 2. two newest startup_failure -> UNAVAILABLE / 1
runs "startup_failure${T}completed\nstartup_failure${T}completed\nsuccess${T}completed\n"
run_check
expect "two startup_failure -> UNAVAILABLE exit 1" 1 "RESULT: UNAVAILABLE"

# 3. single uncorroborated startup_failure -> INDETERMINATE / 3
runs "startup_failure${T}completed\nsuccess${T}completed\n"
run_check
expect "single startup_failure -> INDETERMINATE exit 3" 3 "RESULT: INDETERMINATE"

# 4. gh failing (non-401) -> INDETERMINATE, never UNAVAILABLE and never AVAILABLE
runs "success${T}completed\n"
MOCK_RUN_EXIT=4 run_check
expect "gh failure -> INDETERMINATE exit 3" 3 "RESULT: INDETERMINATE"

# 5. 401 with stale GH_TOKEN, retry without it succeeds -> AVAILABLE + note
runs "success${T}completed\n"
MOCK_401=1 GH_TOKEN=stale run_check
expect "401 then unset-token retry -> AVAILABLE with note" 0 "GH_TOKEN was rejected"

# 6. 401 persists even without the token is impossible in mock; simulate via hard fail
MOCK_RUN_EXIT=1 MOCK_401=1 GH_TOKEN=stale run_check
expect "401 + still failing -> INDETERMINATE (not UNAVAILABLE)" 3 "RESULT: INDETERMINATE"

# 7. gh missing -> INDETERMINATE
if PATH="/usr/bin:/bin" command -v gh >/dev/null 2>&1; then
  fail "test precondition" "gh exists in /usr/bin:/bin"
fi
OUT="$(PATH="/usr/bin:/bin" /bin/bash "$CHECK" 2>&1)"
RC=$?
expect "gh missing -> INDETERMINATE exit 3" 3 "RESULT: INDETERMINATE"

# 8. empty run list -> INDETERMINATE
runs ""
run_check
expect "no runs -> INDETERMINATE exit 3" 3 "RESULT: INDETERMINATE"

# 9. output never says PASS on indeterminate
if printf '%s' "$OUT" | grep -qw PASS; then fail "indeterminate output must not say PASS" "$OUT"; else pass "indeterminate output does not say PASS"; fi

# 10. billing unreadable is reported INDETERMINATE but does not change exit code
runs "success${T}completed\n"
MOCK_API_EXIT=1 run_check
expect "billing unreadable -> reported, exit unchanged" 0 "billing: INDETERMINATE"

# 11. billing readable is reported
run_check
expect "billing readable reported" 0 "billing: readable"

# 12. banner mode words
runs "startup_failure${T}completed\nstartup_failure${T}completed\n"
run_check --banner
expect "banner UNAVAILABLE" 0 "^ci:UNAVAILABLE$"
runs "success${T}completed\n"
run_check --banner
expect "banner ok" 0 "^ci:ok$"
MOCK_RUN_EXIT=4 run_check --banner
expect "banner unknown on failure" 0 "^ci:unknown$"

# 13. usage error
run_check --nonsense
expect "unknown flag -> exit 2" 2 "unknown argument"

# ── ledger ───────────────────────────────────────────────────────────────────
L="$TMP/ledger.tsv"
run_check --ledger "$L" --date 2026-09-21 --record-start "budget exhausted" "llm#1234"
expect "record-start creates ledger" 0 "recorded outage start"
if [ "$(sed -n '1p' "$L")" = "start_date${T}end_date_or_open${T}reason${T}source" ]; then pass "ledger has header"; else fail "ledger header" "$(cat "$L")"; fi
if [ "$(sed -n '2p' "$L")" = "2026-09-21${T}open${T}budget exhausted${T}llm#1234" ]; then pass "ledger row written"; else fail "ledger row" "$(cat "$L")"; fi

run_check --ledger "$L" --date 2026-09-22 --record-start "again" "x"
expect "second open outage refused" 2 "open outage already exists"

run_check --ledger "$L" --date 2026-10-01 --record-end
expect "record-end closes" 0 "closed open outage"
if [ "$(sed -n '2p' "$L")" = "2026-09-21${T}2026-10-01${T}budget exhausted${T}llm#1234" ] && [ "$(wc -l < "$L" | tr -d ' ')" = "2" ]; then
  pass "only end field changed, no rows added/removed"
else
  fail "record-end result" "$(cat "$L")"
fi

run_check --ledger "$L" --record-end
expect "record-end with nothing open refused" 2 "found 0"

run_check --ledger "$L" --date "not-a-date" --record-end
expect "bad date rejected" 2 "YYYY-MM-DD"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
