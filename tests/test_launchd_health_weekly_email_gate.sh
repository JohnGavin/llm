#!/usr/bin/env bash
# tests/test_launchd_health_weekly_email_gate.sh
#
# Regression test: bin/launchd_health_weekly_cron.sh's Step 2 (the
# standalone "launchd health" email, sent via send_launchd_health_email.R)
# was sending EVERY DAY instead of weekly.
#
# History: com.claude.launchd-health-weekly.plist used to fire only Sunday
# 09:00. llm#554 (PR #836) converted the WHOLE script to a daily
# StartCalendarInterval (Hour=8, Minute=0, no Weekday key) so Step 1/1b (the
# unified.duckdb writer feeding the "Cron health" digest section) would run
# daily -- but Step 2 (the email) was never re-gated, so it started sending
# every day too. Confirmed live: ~/.claude/logs/launchd_health_weekly.out
# logs "Step 2: sending launchd health email..." on every date from
# 2026-09-15 through 2026-09-29.
#
# The fix adds a weekday gate around Step 2 ONLY (HEALTH_EMAIL_WEEKDAY,
# default 7=Sunday, matching the pre-#836 schedule) while Step 1/1b keep
# running daily, unaffected. HEALTH_EMAIL_FORCE=1 overrides the gate.
# HEALTH_EMAIL_TODAY_OVERRIDE lets this test drive "today" deterministically
# without waiting for a real weekday, and without ever touching the live
# `date` command's notion of today.
#
# This suite drives the REAL script end-to-end with EMAIL_DRY_RUN=1,
# SKIP_CRON_PULL=1, and a fake nix-shell binary + fake NIX file (so no real
# nix evaluation happens and no real email step 1/1b network calls occur),
# and asserts on the "Step 2:" log line rather than on any live send.
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRON_SCRIPT="${REPO_ROOT}/bin/launchd_health_weekly_cron.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_launchd_health_weekly_email_gate_XXXXXX)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- ${2:-}"; FAIL=$((FAIL + 1)); }

# ── bash -n syntax check ───────────────────────────────────────────────────
rc0=0
bash -n "${CRON_SCRIPT}" 2>/dev/null || rc0=$?
if [ "${rc0}" -eq 0 ]; then
  pass "bash -n: launchd_health_weekly_cron.sh"
else
  fail "bash -n: launchd_health_weekly_cron.sh" "rc=${rc0}"
fi

# ── Fixture: a fake repo carrying the REAL shared library scripts (so
# cron_deploy_pull / wait_for_resolvable_host / nix_gcroot_refresh all run
# for real) but a deliberately invalid default.nix, so nix-shell fails fast
# on a local eval error instead of doing a real multi-second package
# evaluation. Step 1's nix-shell call is expected to fail here ("WARNING:
# launchd_health_report.R exited ... continuing" — a path the script already
# tolerates); Step 2's gate decision happens in bash BEFORE its own
# nix-shell call, so it is fully exercised regardless of Step 1's outcome.
LIB_SCRIPTS_DIR="${REPO_ROOT}/.claude/scripts"

# run_cron TODAY_DOW [extra_env...] -- runs the real script against an
# isolated HOME + fake repo, so it never touches the real checkout, real
# git remote, or the real DuckDB ledger.
run_cron() {
  local today_dow="$1"; shift
  local home_dir="${TMPDIR_ROOT}/home_${today_dow}_$$_${RANDOM}"
  mkdir -p "${home_dir}/.claude/logs"

  local fake_repo="${home_dir}/repo"
  mkdir -p "${fake_repo}/.claude/scripts" "${fake_repo}/.claude/launchd"
  git -C "${fake_repo}" init -q
  git -C "${fake_repo}" config user.email "test@example.com"
  git -C "${fake_repo}" config user.name "test"
  git -C "${fake_repo}" commit -q --allow-empty -m "init"

  cp "${LIB_SCRIPTS_DIR}/cron_deploy_pull.sh" "${fake_repo}/.claude/scripts/"
  cp "${LIB_SCRIPTS_DIR}/wait_for_resolvable_host.sh" "${fake_repo}/.claude/scripts/"
  cp "${LIB_SCRIPTS_DIR}/nix_gcroot_refresh.sh" "${fake_repo}/.claude/scripts/" 2>/dev/null || true
  touch "${fake_repo}/.claude/scripts/launchd_health_report.R"
  touch "${fake_repo}/.claude/scripts/send_launchd_health_email.R"
  printf 'this is not a valid nix expression {{{\n' > "${fake_repo}/default.nix"

  HOME="${home_dir}" \
    REPO_ROOT="${fake_repo}" \
    EMAIL_DRY_RUN=1 \
    SKIP_CRON_PULL=1 \
    HEALTH_EMAIL_TODAY_OVERRIDE="${today_dow}" \
    WAIT_FOR_HOST_TIMEOUT=10 \
    WAIT_FOR_HOST_INTERVAL=1 \
    "$@" \
    bash "${CRON_SCRIPT}" >"${home_dir}/stdout.log" 2>&1

  echo "${home_dir}"
}

test_default_sunday_sends() {
  local home_dir
  home_dir="$(run_cron 7)"
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2: sending launchd health email" "${log}" 2>/dev/null; then
    pass "default gate (HEALTH_EMAIL_WEEKDAY=7): Sunday (dow=7) sends"
  else
    fail "default gate (HEALTH_EMAIL_WEEKDAY=7): Sunday (dow=7) sends" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_default_monday_skips() {
  local home_dir
  home_dir="$(run_cron 1)"
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2: skipped" "${log}" 2>/dev/null \
     && ! grep -q "Step 2: sending launchd health email" "${log}" 2>/dev/null; then
    pass "default gate (HEALTH_EMAIL_WEEKDAY=7): Monday (dow=1) skips"
  else
    fail "default gate (HEALTH_EMAIL_WEEKDAY=7): Monday (dow=1) skips" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_custom_weekday_sends_on_match() {
  local home_dir
  home_dir="$(run_cron 3 env HEALTH_EMAIL_WEEKDAY=3)"
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2: sending launchd health email" "${log}" 2>/dev/null; then
    pass "custom HEALTH_EMAIL_WEEKDAY=3: Wednesday (dow=3) sends"
  else
    fail "custom HEALTH_EMAIL_WEEKDAY=3: Wednesday (dow=3) sends" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_custom_weekday_skips_off_match() {
  local home_dir
  home_dir="$(run_cron 4 env HEALTH_EMAIL_WEEKDAY=3)"
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2: skipped" "${log}" 2>/dev/null; then
    pass "custom HEALTH_EMAIL_WEEKDAY=3: Thursday (dow=4) skips"
  else
    fail "custom HEALTH_EMAIL_WEEKDAY=3: Thursday (dow=4) skips" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_force_overrides_gate() {
  local home_dir
  home_dir="$(run_cron 2 env HEALTH_EMAIL_FORCE=1)"
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2: sending launchd health email" "${log}" 2>/dev/null; then
    pass "HEALTH_EMAIL_FORCE=1: sends even on a non-matching weekday (dow=2)"
  else
    fail "HEALTH_EMAIL_FORCE=1: sends even on a non-matching weekday (dow=2)" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_skip_is_not_a_failure() {
  local home_dir
  home_dir="$(run_cron 1)"
  local out="${home_dir}/stdout.log"
  # A skip must not be logged as an ERROR/WARNING, and the script must not
  # exit non-zero purely because Step 2 was skipped by design.
  if grep -qE "^ERROR" "${out}" 2>/dev/null; then
    fail "skip is not reported as a failure" "unexpected ERROR line in: $(cat "${out}" 2>/dev/null)"
  elif grep -qF "WARNING: send_launchd_health_email.R exited" "${out}" 2>/dev/null; then
    fail "skip is not reported as a failure" \
      "skip branch incorrectly ran/warned about send_launchd_health_email.R: $(cat "${out}" 2>/dev/null)"
  else
    pass "skip is not reported as a failure (no ERROR / no send warning)"
  fi
}

echo "=== test_launchd_health_weekly_email_gate.sh ==="
test_default_sunday_sends
test_default_monday_skips
test_custom_weekday_sends_on_match
test_custom_weekday_skips_off_match
test_force_overrides_gate
test_skip_is_not_a_failure

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
