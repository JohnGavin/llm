#!/usr/bin/env bash
# tests/test_bye_sentinel_ownership.sh
#
# Regression test for JohnGavin/llm#913: two Stop-chain hooks
# (.claude/hooks/llmtelemetry_emit.sh and .claude/hooks/session_stop.sh)
# used to share ONE one-shot /bye sentinel (`.bye-requested(.<sid>)`).
# llmtelemetry_emit.sh is registered ahead of session_stop.sh in the Stop
# chain (settings.json), so it always consumed the shared token first,
# leaving `_bye_detected=0` in session_stop.sh on every real /bye. That
# silently disabled four gated blocks there (DB session-stop write,
# telemetry export, pattern detection, mem_pr) from 2026-07-24 onward.
#
# Fix: each consuming hook now owns a dedicated sentinel basename —
# llmtelemetry_emit.sh keeps `.bye-requested`; session_stop.sh uses its own
# `.bye-session-stop`; the session-end-refine block already had its own
# `.bye-session-end-refine`.
#
# This test:
#   Test 0 — bash -n syntax check on the touched hook/script files.
#   Test 1 — drives the REAL hooks (not a reimplementation) against a
#            simulated /bye sentinel write, in the real Stop-chain order
#            (llmtelemetry_emit.sh stop, then session_stop.sh), entirely
#            inside a temp HOME. Asserts session_stop.sh's own sentinel was
#            consumed (i.e. its detection resolved TRUE) even though
#            llmtelemetry_emit.sh ran first and consumed ITS sentinel.
#   Test 2 — durable guard: no sentinel basename under .claude/hooks/ is
#            consumed (`rm -f`) by more than one hook file. This is the
#            check that would catch a future regression if anyone adds a
#            second consumer of an existing sentinel.
#
# Never touches the real ~/.claude/ — everything runs under a temp HOME.
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOKS_DIR="${REPO_ROOT}/.claude/hooks"
LLMTELEMETRY_EMIT="${HOOKS_DIR}/llmtelemetry_emit.sh"
SESSION_STOP="${HOOKS_DIR}/session_stop.sh"
SENTINEL_SWEEP="${REPO_ROOT}/.claude/scripts/sentinel_log_sweep.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

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

# ── Test 0: bash -n syntax check on all touched scripts ──────────────────────
for f in "${LLMTELEMETRY_EMIT}" "${SESSION_STOP}" "${SENTINEL_SWEEP}"; do
  rc=0
  bash -n "${f}" 2>/dev/null || rc=$?
  assert_eq "test0: bash -n exits 0 ($(basename "${f}"))" "0" "${rc}"
done

# ── Test 1: Stop-chain order leaves session_stop.sh's own detection TRUE ─────
# Everything is sandboxed under a temp HOME so real ~/.claude/ is never
# touched. Both hooks resolve their sentinel roots from $HOME
# (llmtelemetry_emit.sh hardcodes "$HOME/.claude"; session_stop.sh defaults
# CLAUDE_RUNTIME_ROOT to "$HOME/.claude" when unset) — pointing HOME at a
# temp dir aligns both hooks on the same sandboxed root without needing to
# know each hook's exact variable name.
FAKE_HOME="${TMPDIR_ROOT}/home"
FAKE_PROJECT="${TMPDIR_ROOT}/project"
mkdir -p "${FAKE_HOME}/.claude/logs" "${FAKE_PROJECT}/.claude"

SID="test-sid-$$"

# Opt-in flag so llmtelemetry_emit.sh actually processes `stop` mode instead
# of exiting immediately (it is opt-in by design — see its header comment).
touch "${FAKE_HOME}/.claude/.llmtelemetry_emit"

# Simulate the /bye sentinel writes (mirrors .claude/commands/session-end.md
# "First: Write the /bye sentinels" block) — one file per consuming hook.
touch "${FAKE_HOME}/.claude/.bye-requested.${SID}"       # owned by llmtelemetry_emit.sh
touch "${FAKE_HOME}/.claude/.bye-session-stop.${SID}"     # owned by session_stop.sh (llm#913)

# Run the REAL hooks in the REAL Stop-chain order (settings.json: 581 before
# 607 — llmtelemetry_emit.sh stop, then session_stop.sh).
HOME="${FAKE_HOME}" CLAUDE_SESSION_ID="${SID}" CLAUDE_PROJECT_DIR="${FAKE_PROJECT}" \
  bash "${LLMTELEMETRY_EMIT}" stop >/dev/null 2>&1

HOME="${FAKE_HOME}" CLAUDE_SESSION_ID="${SID}" CLAUDE_PROJECT_DIR="${FAKE_PROJECT}" \
  bash "${SESSION_STOP}" >/dev/null 2>&1 || true   # session_stop.sh may exit non-zero on
                                                    # optional sub-steps in a bare sandbox;
                                                    # irrelevant to what we assert below.

# Assertion: llmtelemetry_emit.sh consumed ITS OWN sentinel.
requested_exists=0
[ -f "${FAKE_HOME}/.claude/.bye-requested.${SID}" ] && requested_exists=1
assert_eq "test1: llmtelemetry_emit.sh consumed .bye-requested.<sid>" "0" "${requested_exists}"

# Core assertion: session_stop.sh's detection resolved TRUE and consumed ITS
# OWN sentinel, DESPITE llmtelemetry_emit.sh having already run first and
# consumed the (different) .bye-requested sentinel. Pre-llm#913, session_stop.sh
# looked for the SAME .bye-requested sentinel — which llmtelemetry_emit.sh had
# already deleted — so this file would remain untouched and this assertion
# would FAIL (proving the regression + the fix).
session_stop_sentinel_exists=0
[ -f "${FAKE_HOME}/.claude/.bye-session-stop.${SID}" ] && session_stop_sentinel_exists=1
assert_eq "test1: session_stop.sh consumed its own .bye-session-stop.<sid> (detection TRUE)" \
  "0" "${session_stop_sentinel_exists}"

# ── Test 2: durable guard — no sentinel basename shared by two hook files ────
# For each sentinel family, find hook files that (a) assign a variable whose
# value contains the basename literal, AND (b) `rm -f` that same variable
# somewhere in the file. A basename consumed by more than one hook file means
# two hooks are racing for one one-shot token — exactly the llm#913 bug.
check_basename_ownership() {
  local basename="$1"
  local consumers=""
  local f varnames v owns_it

  for f in "${HOOKS_DIR}"/*.sh; do
    [ -f "${f}" ] || continue
    owns_it=0
    varnames=$(grep -E '^[[:space:]]*_[A-Za-z0-9_]*=.*'"${basename}" "${f}" 2>/dev/null \
      | sed -E 's/^[[:space:]]*(_[A-Za-z0-9_]*)=.*/\1/' | sort -u)
    for v in ${varnames}; do
      [ -z "${v}" ] && continue
      if grep -E "rm[[:space:]]+-f[[:space:]]+.*\\\$\{?${v}\}?" "${f}" >/dev/null 2>&1; then
        owns_it=1
      fi
    done
    if [ "${owns_it}" -eq 1 ]; then
      consumers="${consumers} $(basename "${f}")"
    fi
  done

  # shellcheck disable=SC2086
  echo ${consumers} | tr ' ' '\n' | grep -c . || true
}

for basename in '.bye-requested' '.bye-session-stop' '.bye-session-end-refine'; do
  n_consumers=$(check_basename_ownership "${basename}")
  [ -z "${n_consumers}" ] && n_consumers=0
  if [ "${n_consumers}" -le 1 ]; then
    pass "test2: '${basename}' consumed (rm -f) by at most one hook file (found ${n_consumers})"
  else
    fail "test2: '${basename}' consumed (rm -f) by ${n_consumers} hook files — should be at most 1"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
