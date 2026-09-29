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
#
# ROBOREV_REPO_PATH is set to a dummy fixed path so the script's repo-path
# resolution (normally a `sqlite3 $ROBOREV_DB` lookup against the `repos`
# table -- llm#1274 follow-up) is bypassed; none of these fixtures set up a
# real reviews.db. ROBOREV_AUTOCLOSE_RETRY_BACKOFF is set to "0 0" so the
# discovery retry loop (up to 3 attempts on failure) never sleeps in tests.
run_autoclose() {
  local home_dir="$1" fake_roborev="$2" \
        stdout_content="$3" stderr_content="$4" exit_code="$5"
  mkdir -p "$home_dir/.claude/logs"
  HOME="$home_dir" ROBOREV="$fake_roborev" \
    ROBOREV_REPO_PATH="${ROBOREV_REPO_PATH:-$home_dir/fake-repo}" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="${ROBOREV_AUTOCLOSE_RETRY_BACKOFF:-0 0}" \
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

# ── Tests 7-9 (llm#1274 follow-up, 2026-09-28 incident): retry-on-transient-
# failure + explicit --all-branches/--repo scoping.
#
# 2026-09-28 13:05: ~/.claude/logs/roborev_autoclose.log recorded
# "INDETERMINATE: stale-job discovery failed (roborev_list_rc=1
# parse_rc=1): Error: failed to parse response: jsontext: read error:
# unexpected EOF" -- a truncated daemon response. The identical command
# succeeded moments later. A single-shot failure should no longer be fatal;
# the discovery pipeline now retries up to 3 attempts before giving up.
#
# Separately: `roborev list --help` documents that list defaults to "jobs
# for current repo and branch" -- Phase 1 previously passed neither
# --all-branches nor --repo, so its scope silently depended on the caller's
# cwd/branch while Phase 2 explicitly scoped to $ROBOREV_REPO via SQL. Both
# phases must now scope identically.

# make_fake_roborev_retry -- logs every invocation's full argv (one line
# per call) to $ARGV_LOG, and fails its first $FAIL_COUNT "list"
# invocations (exit $FAKE_ROBOREV_FAIL_EXIT, stderr $FAKE_ROBOREV_STDERR)
# before succeeding with $FAKE_ROBOREV_STDOUT. Call count is tracked via
# $COUNT_FILE so repeated invocations (the retry loop) see it increment.
make_fake_roborev_retry() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
  printf '%s\n' "$*" >> "${ARGV_LOG}"
  count=0
  [ -f "${COUNT_FILE}" ] && count="$(cat "${COUNT_FILE}")"
  count=$((count + 1))
  printf '%s' "$count" > "${COUNT_FILE}"
  if [ "$count" -le "${FAIL_COUNT:-0}" ]; then
    printf '%s' "${FAKE_ROBOREV_STDERR:-fail}" >&2
    exit "${FAKE_ROBOREV_FAIL_EXIT:-1}"
  fi
  printf '%s' "${FAKE_ROBOREV_STDOUT:-}"
  exit 0
fi
exit 0
EOF
  chmod +x "$path"
}

# ── Test 7: fails once, succeeds on retry -> exit 0, one retry logged ─────
test_retry_then_success() {
  local home_dir="${TMPDIR_ROOT}/home7" fake="${TMPDIR_ROOT}/roborev7"
  mkdir -p "$home_dir/.claude/logs"
  make_fake_roborev_retry "$fake"
  local argv_log="${TMPDIR_ROOT}/argv7.log" count_file="${TMPDIR_ROOT}/count7"
  rm -f "$argv_log" "$count_file"

  local out rc=0
  out="$(HOME="$home_dir" ROBOREV="$fake" ROBOREV_REPO_PATH="$home_dir/fake-repo" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" \
    ARGV_LOG="$argv_log" COUNT_FILE="$count_file" FAIL_COUNT=1 \
    FAKE_ROBOREV_STDOUT='{"jobs": []}' \
    "$AUTOCLOSE" --dry-run 2>&1)" || rc=$?

  local logfile="$home_dir/.claude/logs/roborev_autoclose.log"
  if [ "$rc" -eq 0 ] && echo "$out" | grep -qF "roborev: 0 stale jobs" \
     && grep -q "retry 1/3" "$logfile" 2>/dev/null; then
    pass "retry: fails once then succeeds -> exit 0, one retry logged"
  else
    fail "retry: fails once then succeeds -> exit 0, one retry logged" \
      "rc=$rc out=$out logfile=$(cat "$logfile" 2>/dev/null)"
  fi
}

# ── Test 8: fails every attempt -> exit 3 (INDETERMINATE) after 3 tries,
# never "0 stale jobs" -- a retry that exhausts is still indeterminate.
test_retry_exhausted_is_indeterminate() {
  local home_dir="${TMPDIR_ROOT}/home8" fake="${TMPDIR_ROOT}/roborev8"
  mkdir -p "$home_dir/.claude/logs"
  make_fake_roborev_retry "$fake"
  local argv_log="${TMPDIR_ROOT}/argv8.log" count_file="${TMPDIR_ROOT}/count8"
  rm -f "$argv_log" "$count_file"

  local out rc=0
  out="$(HOME="$home_dir" ROBOREV="$fake" ROBOREV_REPO_PATH="$home_dir/fake-repo" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" \
    ARGV_LOG="$argv_log" COUNT_FILE="$count_file" FAIL_COUNT=99 \
    FAKE_ROBOREV_STDERR="daemon unreachable" FAKE_ROBOREV_FAIL_EXIT=1 \
    "$AUTOCLOSE" --dry-run 2>&1)" || rc=$?

  local calls
  calls="$(cat "$count_file" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 3 ] && ! echo "$out" | grep -qF "0 stale jobs" && [ "$calls" -eq 3 ]; then
    pass "retry: always fails -> exit 3 after exactly 3 attempts"
  else
    fail "retry: always fails -> exit 3 after exactly 3 attempts" \
      "rc=$rc calls=$calls out=$out"
  fi
}

# ── Test 9: Phase 1's `roborev list` call passes --all-branches and
# --repo <ROBOREV_REPO_PATH>, so its scope matches Phase 2's and no longer
# depends on the caller's cwd/branch.
test_discovery_passes_scope_flags() {
  local home_dir="${TMPDIR_ROOT}/home9" fake="${TMPDIR_ROOT}/roborev9"
  mkdir -p "$home_dir/.claude/logs"
  make_fake_roborev_retry "$fake"
  local argv_log="${TMPDIR_ROOT}/argv9.log" count_file="${TMPDIR_ROOT}/count9"
  rm -f "$argv_log" "$count_file"

  HOME="$home_dir" ROBOREV="$fake" ROBOREV_REPO_PATH="/fake/repo/path" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" \
    ARGV_LOG="$argv_log" COUNT_FILE="$count_file" FAIL_COUNT=0 \
    FAKE_ROBOREV_STDOUT='{"jobs": []}' \
    "$AUTOCLOSE" --dry-run >/dev/null 2>&1 || true

  local argv_recorded
  argv_recorded="$(cat "$argv_log" 2>/dev/null || true)"
  if echo "$argv_recorded" | grep -q -- "--all-branches" \
     && echo "$argv_recorded" | grep -qF -- "--repo /fake/repo/path"; then
    pass "scope: Phase 1 passes --all-branches and --repo <ROBOREV_REPO_PATH>"
  else
    fail "scope: Phase 1 passes --all-branches and --repo <ROBOREV_REPO_PATH>" "argv=$argv_recorded"
  fi
}

echo "=== test_roborev_autoclose.sh ==="
test_ok_empty
test_indeterminate_empty_stdout
test_indeterminate_garbage_stdout
test_indeterminate_wrong_shape
test_indeterminate_roborev_list_fails
test_log_line_distinct
test_retry_then_success
test_retry_exhausted_is_indeterminate
test_discovery_passes_scope_flags

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
