#!/usr/bin/env bash
# tests/test_roborev_autoclose.sh
#
# Regression tests for the stale-job discovery step in
# .claude/scripts/roborev_autoclose.sh (JohnGavin/llm#1100).
#
# The bug: the discovery step piped `roborev list --json --open --limit
# 1000` into a python3 JSON parser inside a process substitution
# ( < <(...) ). `set -euo pipefail` does NOT propagate a failure through a
# process substitution (a well-known bash gotcha), so when `roborev list`
# produced empty/invalid output, the python3 parse step crashed silently,
# STALE_IDS ended up empty, and the script printed "roborev: 0 stale jobs"
# and exited 0 -- a genuine discovery-step crash collapsed into the same
# output as a real, verified-empty result. This is exactly the failure mode
# `checks-must-distinguish-unknown` names: an error path and a
# negative-result path must never share an exit.
#
# This suite drives the discovery step via a fake `roborev` binary (the
# script already supports overriding the binary path via the ROBOREV env
# var, intended for exactly this kind of test) and asserts the THREE
# possible outcomes stay distinguishable:
#   1. ok-empty       -- roborev returns valid, well-formed, empty JSON
#                        -> exit 0, "roborev: 0 stale jobs"
#   2. indeterminate  -- roborev list fails, OR returns unparseable output
#                        -> non-zero exit, output must NEVER read "0 stale
#                           jobs", and the log must carry a distinct
#                           INDETERMINATE line
#
# (ok-with-jobs, the third state, needs a live/faked `close` path and is out
# of scope for this discovery-focused suite.)
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOCLOSE="${SCRIPT_DIR}/../.claude/scripts/roborev_autoclose.sh"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_roborev_autoclose_XXXXXX)"

cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

pass() { echo "PASS: $1"; (( PASS += 1 )); }
fail() { echo "FAIL: $1 -- ${2:-}"; (( FAIL += 1 )); }

# Fake `roborev` binary. Responds to the exact subcommand the discovery
# step invokes ("list") using content taken from env vars set by the
# caller (FAKE_ROBOREV_STDOUT / FAKE_ROBOREV_STDERR / FAKE_ROBOREV_EXIT) so
# the same script body works for every fixture without re-writing files.
# Any other subcommand ("close", ...) is a harmless no-op success --
# discovery-focused tests never reach Phase 1/2.
make_fake_roborev() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
  printf '%s' "${FAKE_ROBOREV_STDOUT:-}"
  printf '%s' "${FAKE_ROBOREV_STDERR:-}" >&2
  exit "${FAKE_ROBOREV_EXIT:-0}"
fi
exit 0
EOF
  chmod +x "$path"
}

# Runs the real roborev_autoclose.sh --dry-run against an isolated HOME
# (so LOGFILE / Phase-0 retention never touch the real ~/.claude or
# ~/.roborev) with the given fake roborev fixture wired in via ROBOREV.
run_autoclose() {
  local home_dir="$1" fake_roborev="$2" \
        stdout_content="$3" stderr_content="$4" exit_code="$5"
  mkdir -p "$home_dir/.claude/logs"
  HOME="$home_dir" ROBOREV="$fake_roborev" \
    FAKE_ROBOREV_STDOUT="$stdout_content" \
    FAKE_ROBOREV_STDERR="$stderr_content" \
    FAKE_ROBOREV_EXIT="$exit_code" \
    "$AUTOCLOSE" --dry-run
}

# ── Test 1 (control): valid, well-formed EMPTY JSON -> exit 0, "0 stale jobs"
test_ok_empty() {
  local home_dir="${TMPDIR_ROOT}/home1" fake="${TMPDIR_ROOT}/roborev1"
  mkdir -p "$home_dir"
  make_fake_roborev "$fake"

  local out rc=0
  out="$(run_autoclose "$home_dir" "$fake" '{"jobs": []}' '' 0 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ] && echo "$out" | grep -qF "roborev: 0 stale jobs"; then
    pass "ok-empty: valid empty JSON -> exit 0, '0 stale jobs'"
  else
    fail "ok-empty: valid empty JSON -> exit 0, '0 stale jobs'" "rc=$rc out=$out"
  fi
}

# ── Test 2 (FALSIFICATION TARGET): roborev "succeeds" (exit 0) but stdout is
# empty -- the exact llm#1100 reproduction. Must NOT read "0 stale jobs" and
# must exit non-zero.
test_indeterminate_empty_stdout() {
  local home_dir="${TMPDIR_ROOT}/home2" fake="${TMPDIR_ROOT}/roborev2"
  mkdir -p "$home_dir"
  make_fake_roborev "$fake"

  local out rc=0
  out="$(run_autoclose "$home_dir" "$fake" '' '' 0 2>&1)" || rc=$?

  if [ "$rc" -ne 0 ] && ! echo "$out" | grep -qF "0 stale jobs"; then
    pass "indeterminate: empty stdout -> non-zero exit, never '0 stale jobs'"
  else
    fail "indeterminate: empty stdout -> non-zero exit, never '0 stale jobs'" "rc=$rc out=$out"
  fi
}

# ── Test 3: garbage (non-JSON) stdout is also indeterminate, not empty
test_indeterminate_garbage_stdout() {
  local home_dir="${TMPDIR_ROOT}/home3" fake="${TMPDIR_ROOT}/roborev3"
  mkdir -p "$home_dir"
  make_fake_roborev "$fake"

  local out rc=0
  out="$(run_autoclose "$home_dir" "$fake" 'not json at all' '' 0 2>&1)" || rc=$?

  if [ "$rc" -ne 0 ] && ! echo "$out" | grep -qF "0 stale jobs"; then
    pass "indeterminate: garbage stdout -> non-zero exit, never '0 stale jobs'"
  else
    fail "indeterminate: garbage stdout -> non-zero exit, never '0 stale jobs'" "rc=$rc out=$out"
  fi
}

# ── Test 4: JSON that parses but has the wrong shape (a bare number) --
# the exact AttributeError trigger described in the issue when 'jobs' key
# access is attempted on a non-dict.
test_indeterminate_wrong_shape() {
  local home_dir="${TMPDIR_ROOT}/home4" fake="${TMPDIR_ROOT}/roborev4"
  mkdir -p "$home_dir"
  make_fake_roborev "$fake"

  local out rc=0
  out="$(run_autoclose "$home_dir" "$fake" '42' '' 0 2>&1)" || rc=$?

  if [ "$rc" -ne 0 ] && ! echo "$out" | grep -qF "0 stale jobs"; then
    pass "indeterminate: wrong-shape JSON -> non-zero exit, never '0 stale jobs'"
  else
    fail "indeterminate: wrong-shape JSON -> non-zero exit, never '0 stale jobs'" "rc=$rc out=$out"
  fi
}

# ── Test 5: roborev list itself fails (nonzero exit + stderr) is also
# indeterminate -- stderr must no longer be silently discarded either.
test_indeterminate_roborev_list_fails() {
  local home_dir="${TMPDIR_ROOT}/home5" fake="${TMPDIR_ROOT}/roborev5"
  mkdir -p "$home_dir"
  make_fake_roborev "$fake"

  local out rc=0
  out="$(run_autoclose "$home_dir" "$fake" '' 'daemon unreachable' 1 2>&1)" || rc=$?

  if [ "$rc" -ne 0 ] && ! echo "$out" | grep -qF "0 stale jobs"; then
    pass "indeterminate: roborev list exit!=0 -> non-zero exit, never '0 stale jobs'"
  else
    fail "indeterminate: roborev list exit!=0 -> non-zero exit, never '0 stale jobs'" "rc=$rc out=$out"
  fi
}

# ── Test 6: the log file records a DISTINCT line for the indeterminate case
# -- never conflatable with the "ok: 0 jobs older than" line a genuine
# empty result writes.
test_log_line_distinct() {
  local home_dir="${TMPDIR_ROOT}/home6" fake="${TMPDIR_ROOT}/roborev6"
  mkdir -p "$home_dir"
  make_fake_roborev "$fake"

  run_autoclose "$home_dir" "$fake" '' '' 0 >/dev/null 2>&1 || true

  local logfile="$home_dir/.claude/logs/roborev_autoclose.log"
  if [ -f "$logfile" ] \
     && grep -q "INDETERMINATE" "$logfile" \
     && ! grep -q "ok: 0 jobs older than" "$logfile"; then
    pass "log: indeterminate case writes a distinct INDETERMINATE line"
  else
    fail "log: indeterminate case writes a distinct INDETERMINATE line" \
      "logfile content: $(cat "$logfile" 2>/dev/null)"
  fi
}

echo "=== test_roborev_autoclose.sh ==="
test_ok_empty
test_indeterminate_empty_stdout
test_indeterminate_garbage_stdout
test_indeterminate_wrong_shape
test_indeterminate_roborev_list_fails
test_log_line_distinct

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
