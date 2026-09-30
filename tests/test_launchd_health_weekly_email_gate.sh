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
# roborev #1292 review (10654) added two more cases: (1) an exact-weekday
# equality gate alone drops the whole week's email if the exact day is
# missed entirely (laptop asleep) -- HEALTH_EMAIL_STATE_FILE now tracks the
# epoch of the last successful send and a >=7-day-elapsed catch-up also
# sends, regardless of today's weekday; (2) an unvalidated
# HEALTH_EMAIL_WEEKDAY (not 1-7) used to skip forever indistinguishably from
# a correct skip -- it is now validated and falls back to the default with a
# logged ERROR.
#
# This suite drives the REAL script end-to-end with EMAIL_DRY_RUN=1,
# SKIP_CRON_PULL=1, and a fixture repo carrying the REAL
# cron_deploy_pull.sh/wait_for_resolvable_host.sh/nix_gcroot_refresh.sh
# library scripts plus a deliberately invalid default.nix, so the real
# /nix/var/nix/profiles/default/bin/nix-shell fails fast on a local eval
# error (no real nix package evaluation, no real network calls). Because
# nix-shell always fails against that invalid default.nix, Step 2's send
# attempt in this fixture never reaches STEP2_EXIT=0, so the catch-up tests
# below seed HEALTH_EMAIL_STATE_FILE's default location directly to control
# the "days since last send" input, rather than relying on a real send to
# populate it. Assertions are on the "Step 2:" log line, not on any live
# send.
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

# make_home TAG -- creates an isolated HOME + fake repo (so a run never
# touches the real checkout, real git remote, or the real DuckDB ledger) and
# prints its path. Split out from run_cron so a caller can seed
# HEALTH_EMAIL_STATE_FILE's default location ($HOME/.claude/logs/...)
# BEFORE the script runs, for the catch-up tests below.
make_home() {
  local tag="$1"
  local home_dir="${TMPDIR_ROOT}/home_${tag}_$$_${RANDOM}"
  mkdir -p "${home_dir}/.claude/logs"

  local fake_repo="${home_dir}/repo"
  mkdir -p "${fake_repo}/.claude/scripts" "${fake_repo}/.claude/launchd"
  git -C "${fake_repo}" init -q
  git -C "${fake_repo}" config user.email "test@example.com"
  git -C "${fake_repo}" config user.name "test"
  git -C "${fake_repo}" commit -q --allow-empty -m "init"

  cp "${LIB_SCRIPTS_DIR}/cron_deploy_pull.sh" "${fake_repo}/.claude/scripts/"
  cp "${LIB_SCRIPTS_DIR}/wait_for_resolvable_host.sh" "${fake_repo}/.claude/scripts/"
  mkdir -p "${fake_repo}/.claude/scripts/lib"
  cp "${LIB_SCRIPTS_DIR}/lib/load_email_creds.sh" "${fake_repo}/.claude/scripts/lib/"
  cp "${LIB_SCRIPTS_DIR}/nix_gcroot_refresh.sh" "${fake_repo}/.claude/scripts/" 2>/dev/null || true
  touch "${fake_repo}/.claude/scripts/launchd_health_report.R"
  touch "${fake_repo}/.claude/scripts/send_launchd_health_email.R"
  printf 'this is not a valid nix expression {{{\n' > "${fake_repo}/default.nix"

  echo "${home_dir}"
}

# run_cron_home HOME_DIR TODAY_DOW [extra_env...] -- runs the real script
# against an already-created home_dir (see make_home).
run_cron_home() {
  local home_dir="$1" today_dow="$2"; shift 2
  local fake_repo="${home_dir}/repo"

  HOME="${home_dir}" \
    REPO_ROOT="${fake_repo}" \
    EMAIL_DRY_RUN=1 \
    SKIP_CRON_PULL=1 \
    HEALTH_EMAIL_TODAY_OVERRIDE="${today_dow}" \
    WAIT_FOR_HOST_TIMEOUT=10 \
    WAIT_FOR_HOST_INTERVAL=1 \
    "$@" \
    bash "${CRON_SCRIPT}" >"${home_dir}/stdout.log" 2>&1
}

# run_cron TODAY_DOW [extra_env...] -- make_home + run_cron_home in one call,
# for tests that don't need to seed anything before the run. Prints home_dir.
run_cron() {
  local today_dow="$1"; shift
  local home_dir
  home_dir="$(make_home "${today_dow}")"
  run_cron_home "${home_dir}" "${today_dow}" "$@"
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
  # exit non-zero purely because Step 2 was skipped by design. Assert the
  # actual internal flag Step 3 reads (_email_failed) directly, rather than
  # only the absence of certain log lines -- roborev #1292 review (10654)
  # noted the prior version of this test could not isolate the skip branch
  # because Step 1 always fails in this fixture regardless.
  if grep -qE "^ERROR" "${out}" 2>/dev/null; then
    fail "skip is not reported as a failure" "unexpected ERROR line in: $(cat "${out}" 2>/dev/null)"
  elif grep -qF "WARNING: send_launchd_health_email.R exited" "${out}" 2>/dev/null; then
    fail "skip is not reported as a failure" \
      "skip branch incorrectly ran/warned about send_launchd_health_email.R: $(cat "${out}" 2>/dev/null)"
  elif ! grep -qF "Step 2: _email_failed=0" "${out}" 2>/dev/null; then
    fail "skip is not reported as a failure" \
      "expected 'Step 2: _email_failed=0' in: $(cat "${out}" 2>/dev/null)"
  else
    pass "skip is not reported as a failure (no ERROR / no send warning)"
  fi
}

# ── roborev #1292 review (10654): missed-weekday catch-up + weekday validation ──

test_catchup_sends_after_missed_week() {
  local home_dir
  home_dir="$(make_home catchup_missed)"
  local state_file="${home_dir}/.claude/logs/.launchd_health_email_last_sent"
  # Simulate: last successful send was 8 days ago (e.g. the laptop was
  # asleep all of the configured weekday and launchd coalesced the run to a
  # non-matching day). Today (Monday, dow=1) does NOT match the default
  # HEALTH_EMAIL_WEEKDAY=7 -- the exact-equality gate alone would skip.
  echo "$(( $(date -u +%s) - (8 * 86400) ))" > "${state_file}"
  run_cron_home "${home_dir}" 1
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2: sending launchd health email... (catch-up:" "${log}" 2>/dev/null; then
    pass "catch-up: last send 8 days ago + non-matching weekday still sends"
  else
    fail "catch-up: last send 8 days ago + non-matching weekday still sends" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_no_catchup_when_sent_yesterday() {
  local home_dir
  home_dir="$(make_home catchup_recent)"
  local state_file="${home_dir}/.claude/logs/.launchd_health_email_last_sent"
  # Last successful send was 1 day ago -- well under the 7-day catch-up
  # threshold. Today (Monday, dow=1) does not match the default weekday, so
  # this must skip exactly like the no-stamp case.
  echo "$(( $(date -u +%s) - 86400 ))" > "${state_file}"
  run_cron_home "${home_dir}" 1
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2: skipped" "${log}" 2>/dev/null \
     && ! grep -q "Step 2: sending launchd health email" "${log}" 2>/dev/null; then
    pass "no catch-up: last send 1 day ago + non-matching weekday skips"
  else
    fail "no catch-up: last send 1 day ago + non-matching weekday skips" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_invalid_weekday_falls_back_to_default() {
  local home_dir
  home_dir="$(make_home invalid_weekday)"
  # HEALTH_EMAIL_WEEKDAY='nonsense' would never match `date +%u` (1-7), so
  # without validation Step 2 would skip every single run forever,
  # indistinguishable from a correct skip. Assert it is caught and falls
  # back to the default (7=Sunday), which the dow=7 run below then matches.
  run_cron_home "${home_dir}" 7 env HEALTH_EMAIL_WEEKDAY=nonsense
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -qF "ERROR: HEALTH_EMAIL_WEEKDAY='nonsense' is not 1-7" "${log}" 2>/dev/null \
     && grep -q "Step 2: sending launchd health email" "${log}" 2>/dev/null; then
    pass "invalid HEALTH_EMAIL_WEEKDAY logs an ERROR and falls back to default 7 (Sunday sends)"
  else
    fail "invalid HEALTH_EMAIL_WEEKDAY logs an ERROR and falls back to default 7 (Sunday sends)" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_invalid_weekday_does_not_send_on_nonmatching_day() {
  local home_dir
  home_dir="$(make_home invalid_weekday_skip)"
  # Same invalid HEALTH_EMAIL_WEEKDAY, but today (Monday, dow=1) does not
  # match the fallback default (7) -- confirms the fallback is a real
  # weekday value participating in the gate, not an accidental "always send".
  run_cron_home "${home_dir}" 1 env HEALTH_EMAIL_WEEKDAY=0
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -qF "ERROR: HEALTH_EMAIL_WEEKDAY='0' is not 1-7" "${log}" 2>/dev/null \
     && grep -q "Step 2: skipped" "${log}" 2>/dev/null \
     && ! grep -q "Step 2: sending launchd health email" "${log}" 2>/dev/null; then
    pass "invalid HEALTH_EMAIL_WEEKDAY='0' falls back to default 7, still skips on non-matching day"
  else
    fail "invalid HEALTH_EMAIL_WEEKDAY='0' falls back to default 7, still skips on non-matching day" \
      "log: $(cat "${log}" 2>/dev/null)"
  fi
}

# make_fake_nix_shell HOME_DIR -- an executable stand-in for nix-shell that
# exits 0 without running anything, so Step 2 counts as a SUCCESSFUL send and
# the last-sent stamp path is reachable (the real nix-shell always fails
# against this fixture's invalid default.nix). Nothing is sent.
make_fake_nix_shell() {
  local f="$1/fake-nix-shell"
  printf '#!/bin/bash\nexit 0\n' > "${f}"
  chmod +x "${f}"
  echo "${f}"
}

test_dry_run_success_writes_no_stamp() {
  local home_dir fake
  home_dir="$(make_home dryrun_stamp)"
  fake="$(make_fake_nix_shell "${home_dir}")"
  local state_file="${home_dir}/.claude/logs/.launchd_health_email_last_sent"
  run_cron_home "${home_dir}" 7 env NIX_SHELL_BIN="${fake}" EMAIL_DRY_RUN=1
  local log="${home_dir}/.claude/logs/launchd_health_weekly.log"
  if grep -q "Step 2 done" "${log}" 2>/dev/null \
     && [ ! -f "${state_file}" ] \
     && grep -q "dry run -- last-sent stamp NOT written" "${log}" 2>/dev/null; then
    pass "successful DRY-RUN send writes no last-sent stamp (roborev #10663)"
  else
    fail "successful DRY-RUN send writes no last-sent stamp (roborev #10663)" \
      "stamp exists: $([ -f "${state_file}" ] && echo yes || echo no); log: $(cat "${log}" 2>/dev/null)"
  fi
}

test_real_success_writes_stamp() {
  local home_dir fake
  home_dir="$(make_home real_stamp)"
  fake="$(make_fake_nix_shell "${home_dir}")"
  local state_file="${home_dir}/.claude/logs/.launchd_health_email_last_sent"
  run_cron_home "${home_dir}" 7 env NIX_SHELL_BIN="${fake}" EMAIL_DRY_RUN=0
  if [ -f "${state_file}" ] && grep -qE '^[0-9]+$' "${state_file}"; then
    pass "successful non-dry-run send writes a numeric last-sent stamp"
  else
    fail "successful non-dry-run send writes a numeric last-sent stamp" \
      "log: $(cat "${home_dir}/.claude/logs/launchd_health_weekly.log" 2>/dev/null)"
  fi
}

echo "=== test_launchd_health_weekly_email_gate.sh ==="
test_default_sunday_sends
test_default_monday_skips
test_custom_weekday_sends_on_match
test_custom_weekday_skips_off_match
test_force_overrides_gate
test_skip_is_not_a_failure
test_catchup_sends_after_missed_week
test_no_catchup_when_sent_yesterday
test_invalid_weekday_falls_back_to_default
test_invalid_weekday_does_not_send_on_nonmatching_day
test_dry_run_success_writes_no_stamp
test_real_success_writes_stamp

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
