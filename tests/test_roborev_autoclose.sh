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

# ── Tests 10-12 (roborev #1292 review, 10655 Medium+Low): the repo-path
# resolution block itself (the sqlite `repos` lookup that resolves
# ROBOREV_REPO -> ROBOREV_REPO_PATH) was previously untested -- every test
# above sets ROBOREV_REPO_PATH directly, bypassing the lookup entirely. That
# lookup ran with `2>/dev/null || true`, so a sqlite FAILURE (locked DB,
# schema error, corrupt file) looked identical to "no matching repos row".
# These tests exercise the lookup for real against a tiny fixture sqlite DB
# and assert all three outcomes (row found / no row / sqlite failure) are
# distinguishable, per checks-must-distinguish-unknown.

SQLITE_BIN="$(command -v sqlite3 || echo /usr/bin/sqlite3)"

# ── Test 10: a matching repos row resolves and is passed to Phase 1's
# `roborev list --repo <root_path> --all-branches` call.
test_repo_path_lookup_success() {
  local home_dir="${TMPDIR_ROOT}/home10" fake="${TMPDIR_ROOT}/roborev10"
  mkdir -p "$home_dir/.claude/logs"
  make_fake_roborev_retry "$fake"
  local argv_log="${TMPDIR_ROOT}/argv10.log" count_file="${TMPDIR_ROOT}/count10"
  rm -f "$argv_log" "$count_file"

  local db="${TMPDIR_ROOT}/reviews10.db"
  rm -f "$db"
  "$SQLITE_BIN" "$db" \
    "CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT); INSERT INTO repos (name, root_path) VALUES ('llm', '/fake/repo/from-db');"

  HOME="$home_dir" ROBOREV="$fake" ROBOREV_DB="$db" ROBOREV_REPO="llm" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" \
    ARGV_LOG="$argv_log" COUNT_FILE="$count_file" FAIL_COUNT=0 \
    FAKE_ROBOREV_STDOUT='{"jobs": []}' \
    "$AUTOCLOSE" --dry-run >/dev/null 2>&1 || true

  local argv_recorded
  argv_recorded="$(cat "$argv_log" 2>/dev/null || true)"
  if echo "$argv_recorded" | grep -q -- "--all-branches" \
     && echo "$argv_recorded" | grep -qF -- "--repo /fake/repo/from-db"; then
    pass "repo-path lookup: matching repos row -> --repo <root_path> --all-branches"
  else
    fail "repo-path lookup: matching repos row -> --repo <root_path> --all-branches" "argv=$argv_recorded"
  fi
}

# ── Test 11: sqlite runs cleanly but no repos row matches ROBOREV_REPO ->
# exit 3, INDETERMINATE, with a reason distinct from a sqlite FAILURE.
test_repo_path_lookup_no_matching_row() {
  local home_dir="${TMPDIR_ROOT}/home11" fake="${TMPDIR_ROOT}/roborev11"
  mkdir -p "$home_dir/.claude/logs"
  make_fake_roborev "$fake"

  local db="${TMPDIR_ROOT}/reviews11.db"
  rm -f "$db"
  "$SQLITE_BIN" "$db" \
    "CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT); INSERT INTO repos (name, root_path) VALUES ('other-repo', '/some/path');"

  local out rc=0
  out="$(HOME="$home_dir" ROBOREV="$fake" ROBOREV_DB="$db" ROBOREV_REPO="llm" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" \
    "$AUTOCLOSE" --dry-run 2>&1)" || rc=$?

  local logfile="$home_dir/.claude/logs/roborev_autoclose.log"
  if [ "$rc" -eq 3 ] && grep -qF "no repos row matches ROBOREV_REPO=llm" "$logfile" 2>/dev/null; then
    pass "repo-path lookup: no matching row -> exit 3, distinct 'no repos row' reason"
  else
    fail "repo-path lookup: no matching row -> exit 3, distinct 'no repos row' reason" \
      "rc=$rc out=$out logfile=$(cat "$logfile" 2>/dev/null)"
  fi
}

# ── Test 12: sqlite3 itself fails against a corrupt/non-database file ->
# exit 3, INDETERMINATE, with a "sqlite3 lookup ... failed" reason distinct
# from Test 11's "no matching row". This is the exact llm#1292-review gap:
# both cases used to share the same log line via `2>/dev/null || true`.
test_repo_path_lookup_sqlite_failure() {
  local home_dir="${TMPDIR_ROOT}/home12" fake="${TMPDIR_ROOT}/roborev12"
  mkdir -p "$home_dir/.claude/logs"
  make_fake_roborev "$fake"

  local db="${TMPDIR_ROOT}/corrupt12.db"
  printf 'not a real sqlite database\n' > "$db"

  local out rc=0
  out="$(HOME="$home_dir" ROBOREV="$fake" ROBOREV_DB="$db" ROBOREV_REPO="llm" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" \
    "$AUTOCLOSE" --dry-run 2>&1)" || rc=$?

  local logfile="$home_dir/.claude/logs/roborev_autoclose.log"
  if [ "$rc" -eq 3 ] \
     && grep -qF "sqlite3 lookup for ROBOREV_REPO=llm failed" "$logfile" 2>/dev/null \
     && ! grep -qF "no repos row matches" "$logfile" 2>/dev/null; then
    pass "repo-path lookup: sqlite3 failure (corrupt DB) -> exit 3, distinct 'sqlite3 lookup failed' reason"
  else
    fail "repo-path lookup: sqlite3 failure (corrupt DB) -> exit 3, distinct 'sqlite3 lookup failed' reason" \
      "rc=$rc out=$out logfile=$(cat "$logfile" 2>/dev/null)"
  fi
}

# ── Tests 13-14 (llm#929, owner-approved 2026-09-30): Phase 0 retention
# inherits --apply. The autoclose script resolves roborev_retention.sh as
# $(dirname "$0")/roborev_retention.sh, so a COPY of autoclose placed beside a
# stub retention script lets us record the flag it is called with, without
# ever touching a real ~/.roborev.
run_phase0_flag() {
  local n="$1" mode="$2"
  local d="${TMPDIR_ROOT}/phase0_$n"
  mkdir -p "$d/bin" "$d/home/.claude/logs"
  cp "$AUTOCLOSE" "$d/bin/roborev_autoclose.sh"
  cat > "$d/bin/roborev_retention.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/retention_argv"
exit 0
EOS
  chmod +x "$d/bin/roborev_retention.sh" "$d/bin/roborev_autoclose.sh"
  make_fake_roborev "$d/roborev"
  # --apply takes a verified DB backup first (Step 0a), so it needs a real DB.
  "$SQLITE_BIN" "$d/reviews.db" "CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT);"
  HOME="$d/home" ROBOREV="$d/roborev" ROBOREV_DB="$d/reviews.db" ROBOREV_REPO_PATH="$d/fake-repo" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" FAKE_ROBOREV_STDOUT='{"jobs": []}' \
    "$d/bin/roborev_autoclose.sh" "$mode" >/dev/null 2>&1 || true
  # Stub never ran -> distinct sentinel, not empty output (checks-must-
  # distinguish-unknown): empty would conflate "not called" with "no result".
  if [ ! -f "$d/retention_argv" ]; then
    echo "STUB-NOT-CALLED"
    return 2
  fi
  cat "$d/retention_argv"
}

test_phase0_apply_inherited() {
  local got
  got="$(run_phase0_flag 13 --apply)"
  if [ "$got" = "--apply" ]; then
    pass "phase0: parent --apply -> retention called with --apply"
  else
    fail "phase0: parent --apply -> retention called with --apply" "argv=[$got]"
  fi
}

test_phase0_dry_run_inherited() {
  local got
  got="$(run_phase0_flag 14 --dry-run)"
  if [ "$got" = "--dry-run" ]; then
    pass "phase0: parent dry-run -> retention called with --dry-run"
  else
    fail "phase0: parent dry-run -> retention called with --dry-run" "argv=[$got]"
  fi
}

# ── Tests 15-17 (follow-up to #1308; 2026-09-28 incident): the weekly DB
# backup is independent of stale-job discovery. Previously it lived in Phase 2
# and was skipped whenever discovery failed (exit 3). Fixture: a COPY of the
# script beside a stub retention script that records how many backups exist
# at the moment it runs (proves backup-before-retention ordering), a real
# fixture sqlite DB, and a fake roborev that records every `close`.
setup_backup_fixture() {
  local n="$1"
  BF="${TMPDIR_ROOT}/backup_$n"
  mkdir -p "$BF/bin" "$BF/home/.claude/logs"
  cp "$AUTOCLOSE" "$BF/bin/roborev_autoclose.sh"
  cat > "$BF/bin/roborev_retention.sh" <<EOS
#!/usr/bin/env bash
ls "$BF"/reviews.db.bak-* 2>/dev/null | wc -l | tr -d ' ' >> "$BF/retention_backups_seen"
exit 0
EOS
  chmod +x "$BF/bin/roborev_retention.sh" "$BF/bin/roborev_autoclose.sh"
  cat > "$BF/roborev" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "list" ]; then
  printf '%s' "\${FAKE_ROBOREV_STDOUT:-}"
  printf '%s' "\${FAKE_ROBOREV_STDERR:-}" >&2
  exit "\${FAKE_ROBOREV_EXIT:-0}"
fi
if [ "\$1" = "close" ]; then
  printf '%s\n' "\$2" >> "$BF/close_calls"
fi
exit 0
EOS
  chmod +x "$BF/roborev"
  "$SQLITE_BIN" "$BF/reviews.db" \
    "CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT); INSERT INTO repos (name, root_path) VALUES ('llm', '/fake/repo');"
}

run_backup_fixture() {
  HOME="$BF/home" ROBOREV="$BF/roborev" ROBOREV_DB="$BF/reviews.db" ROBOREV_REPO="llm" \
    ROBOREV_AUTOCLOSE_RETRY_BACKOFF="0 0" \
    "$BF/bin/roborev_autoclose.sh" "$1" 2>&1
}

# Test 15 (FALSIFICATION TARGET): discovery fails in --apply -> exit 3 AND the
# backup still exists, taken before retention ran.
test_backup_survives_discovery_failure() {
  setup_backup_fixture 15
  local out rc=0
  out="$(FAKE_ROBOREV_STDERR='jsontext: read error: unexpected EOF' FAKE_ROBOREV_EXIT=1 \
    run_backup_fixture --apply)" || rc=$?
  local nbak seen
  nbak="$(ls "$BF"/reviews.db.bak-* 2>/dev/null | wc -l | tr -d ' ')"
  seen="$(cat "$BF/retention_backups_seen" 2>/dev/null || echo none)"
  if [ "$rc" -eq 3 ] && [ "$nbak" -eq 1 ] && [ "$seen" = "1" ] \
     && [ -s "$(ls "$BF"/reviews.db.bak-* | head -1)" ] \
     && grep -q "INDETERMINATE" "$BF/home/.claude/logs/roborev_autoclose.log"; then
    pass "backup: discovery fails in --apply -> exit 3, backup exists, taken before retention"
  else
    fail "backup: discovery fails in --apply -> exit 3, backup exists, taken before retention" \
      "rc=$rc nbak=$nbak retention_saw=$seen out=$out"
  fi
}

# Test 16: backup step fails (corrupt DB) -> no close, no retention, distinct
# log line, non-zero exit -- even though discovery would have found a stale job.
test_backup_failure_blocks_closures() {
  setup_backup_fixture 16
  printf 'not a real sqlite database\n' > "$BF/reviews.db"
  local out rc=0
  out="$(FAKE_ROBOREV_STDOUT='{"jobs": [{"id": 7, "enqueued_at": "2000-01-01T00:00:00Z"}]}' \
    run_backup_fixture --apply)" || rc=$?
  local log="$BF/home/.claude/logs/roborev_autoclose.log"
  if [ "$rc" -ne 0 ] && [ ! -f "$BF/close_calls" ] && [ ! -f "$BF/retention_backups_seen" ] \
     && grep -qF "BACKUP FAILED" "$log" \
     && ! ls "$BF"/reviews.db.bak-* >/dev/null 2>&1; then
    pass "backup: failure -> no close, no retention, distinct 'BACKUP FAILED' log, non-zero exit"
  else
    fail "backup: failure -> no close, no retention, distinct 'BACKUP FAILED' log, non-zero exit" \
      "rc=$rc closes=$(cat "$BF/close_calls" 2>/dev/null) out=$out log=$(cat "$log" 2>/dev/null)"
  fi
}

# Test 17: dry-run makes no backup (current dry-run semantics preserved).
test_dry_run_makes_no_backup() {
  setup_backup_fixture 17
  local out rc=0
  out="$(FAKE_ROBOREV_STDOUT='{"jobs": []}' run_backup_fixture --dry-run)" || rc=$?
  if [ "$rc" -eq 0 ] && ! ls "$BF"/reviews.db.bak-* >/dev/null 2>&1; then
    pass "backup: dry-run -> no backup file"
  else
    fail "backup: dry-run -> no backup file" "rc=$rc out=$out"
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
test_repo_path_lookup_success
test_repo_path_lookup_no_matching_row
test_repo_path_lookup_sqlite_failure
test_phase0_apply_inherited
test_phase0_dry_run_inherited
test_backup_survives_discovery_failure
test_backup_failure_blocks_closures
test_dry_run_makes_no_backup

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
