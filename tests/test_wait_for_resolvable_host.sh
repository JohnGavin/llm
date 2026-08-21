#!/usr/bin/env bash
# tests/test_wait_for_resolvable_host.sh
#
# Unit tests for the shared DNS-readiness gate (llm#947, llm#970):
#   .claude/scripts/wait_for_resolvable_host.sh
#
# Scheduled jobs fire before this machine's network is reliably up; a job
# that enters a nix shell or sends SMTP mail before DNS resolves dies with
# "Could not resolve host". wait_for_resolvable_host.sh gives DNS a bounded
# window to come up and returns a distinct code (2) when it doesn't, so
# callers can defer instead of recording a failure.
#
# Test 3 (the bound) deliberately uses a short timeout/interval (2s/1s), NOT
# the 120s production default, and asserts wall-clock elapsed stays under a
# small ceiling — this is the test that would fail if the timeout logic
# were broken (see "mutation test" note in the PR description this file was
# written for: breaking `-ge` to `-le` in the helper makes this test hang
# past its own outer `timeout` guard and FAIL).
#
# Test 2 uses doesnotexist.invalid — the .invalid TLD is reserved by RFC
# 2606 and is guaranteed to never resolve, so this test does not depend on
# any real host being down or up.
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../.claude/scripts/wait_for_resolvable_host.sh"

PASS=0
FAIL=0

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

assert_le() {
  local desc="$1" actual="$2" ceiling="$3"
  if [ "${actual}" -le "${ceiling}" ]; then
    pass "${desc} (${actual}s <= ${ceiling}s)"
  else
    fail "${desc} — actual=${actual}s exceeds ceiling=${ceiling}s"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    pass "${desc}"
  else
    fail "${desc} — '${needle}' not found in output: ${haystack}"
  fi
}

# ── Test 0: bash -n syntax check on the helper ────────────────────────────
rc0=0
bash -n "${HELPER}" 2>/dev/null || rc0=$?
assert_eq "test0: bash -n exits 0 (wait_for_resolvable_host.sh)" "0" "${rc0}"

# ── Test 1: resolvable host returns success promptly (rc=0), does not
#    sleep the full timeout window ───────────────────────────────────────
t1_start=$(date +%s)
out1=$(timeout 15 bash "${HELPER}" --hosts github.com --timeout 10 --interval 1 2>&1)
rc1=$?
t1_elapsed=$(( $(date +%s) - t1_start ))
assert_eq "test1: resolvable host exits 0" "0" "${rc1}"
assert_contains "test1: logs 'resolved'" "resolved" "${out1}"
assert_le "test1: does not sleep the full 10s timeout" "${t1_elapsed}" "5"

# ── Test 2: unresolvable host (.invalid TLD, RFC 2606) returns the
#    deferred code (2) within the bound, does not hang ──────────────────
t2_start=$(date +%s)
out2=$(timeout 15 bash "${HELPER}" --hosts doesnotexist.invalid --timeout 3 --interval 1 2>&1)
rc2=$?
t2_elapsed=$(( $(date +%s) - t2_start ))
assert_eq "test2: unresolvable host returns deferred code 2" "2" "${rc2}"
assert_contains "test2: logs 'deferring'" "deferring" "${out2}"
assert_le "test2: does not hang past its own timeout" "${t2_elapsed}" "6"

# ── Test 3: the bound is honoured — short timeout (2s), assert elapsed
#    stays under a small ceiling (not the 120s production default) ──────
t3_start=$(date +%s)
timeout 10 bash "${HELPER}" --hosts doesnotexist.invalid --timeout 2 --interval 1 >/dev/null 2>&1
rc3=$?
t3_elapsed=$(( $(date +%s) - t3_start ))
assert_eq "test3: deferred code 2 with a 2s bound" "2" "${rc3}"
assert_le "test3: elapsed stays close to the 2s bound, not the 10s outer guard" "${t3_elapsed}" "4"

# ── Test 4: hosts list with a mix of unresolvable-then-resolvable still
#    succeeds (does not stop at the first miss) ──────────────────────────
out4=$(timeout 15 bash "${HELPER}" --hosts doesnotexist.invalid,github.com --timeout 10 --interval 1 2>&1)
rc4=$?
assert_eq "test4: second host in list still resolves" "0" "${rc4}"
assert_contains "test4: logs the host that actually resolved" "resolved github.com" "${out4}"

# ── Test 5: default host list (no --hosts) does not error ────────────────
rc5=0
timeout 15 bash "${HELPER}" --timeout 10 --interval 1 >/dev/null 2>&1 || rc5=$?
assert_eq "test5: default host list resolves (network assumed up in CI)" "0" "${rc5}"

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
