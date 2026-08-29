#!/usr/bin/env bash
# tests/test_launchd_health_audit.sh — Integration tests for bin/launchd_health_audit.sh
#
# Uses synthetic fixture plists and a mock launchctl output file to avoid
# touching the live ~/Library/LaunchAgents directory.
#
# Usage:
#   bash tests/test_launchd_health_audit.sh
#
# Returns exit code 0 on all pass, non-zero on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/launchd_health_audit.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/launchd_audit"
TMP="$(mktemp -d /tmp/launchd_audit_test_XXXXXX)"
MOCK_LIST="$TMP/mock_launchctl_list.txt"
LOG_DIR="$TMP/logs"

mkdir -p "$LOG_DIR"

PASS=0
FAIL=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS: $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc"
    echo "        expected string: $expected"
    echo "        actual output:   ${actual:0:200}"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_count() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $desc (count=$actual)"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc (expected=$expected, got=$actual)"
    FAIL=$(( FAIL + 1 ))
  fi
}

# ── Set up mock log files ──────────────────────────────────────────────────────
# loaded-ok: recent timestamp, no errors
echo "2026-05-29 09:00:01 done exit 0" > "$LOG_DIR/loaded_ok.out"
# Update mtime to 1 hour ago (recent enough to not be stale for a daily job)
touch -m -t "$(date -v-1H '+%Y%m%d%H%M.%S')" "$LOG_DIR/loaded_ok.out" 2>/dev/null || true

# loaded-failing: recent timestamp, non-zero exit
echo "2026-05-29 02:30:01 ERROR: script failed exit 127" > "$LOG_DIR/loaded_failing.out"
touch -m -t "$(date -v-1H '+%Y%m%d%H%M.%S')" "$LOG_DIR/loaded_failing.out" 2>/dev/null || true

# stale-job: very old timestamp (3 days ago)
echo "2026-05-26 09:30:01 done exit 0" > "$LOG_DIR/stale_job.out"
touch -m -t "$(date -v-72H '+%Y%m%d%H%M.%S')" "$LOG_DIR/stale_job.out" 2>/dev/null || true

# not-loaded: no log file (never fired)

# weekday-repeated (llm#898 regression): thrice-daily x 5-weekday schedule,
# last fired 3h ago. 3h sits strictly between the pre-fix threshold (cadence
# wrongly computed as 0s -> clamped floor of 2h -> STALE) and the correct
# post-fix threshold (cadence 4h=14400s -> 1.5x = 6h -> NOT stale). This
# fixture only passes under the fixed expected_cadence_seconds().
#
# Written at the fixture plist's literal StandardOutPath (Priority 1 in
# find_log_file()), not under $LOG_DIR (Priority 2/3) -- unrelated to the
# cadence bug this fixture targets. The Priority 2/3 fallback derivation
# (formerly a GNU-only `\|` sed alternation, fixed under llm#995) is
# exercised separately by the com.claude.fallback-log fixture below.
mkdir -p /tmp/launchd_audit_test
echo "2026-05-29 13:00:01 done exit 0" > /tmp/launchd_audit_test/weekday_repeated.out
touch -m -t "$(date -v-3H '+%Y%m%d%H%M.%S')" /tmp/launchd_audit_test/weekday_repeated.out 2>/dev/null || true

# fallback-log (llm#995 regression): this fixture plist has NO StandardOutPath
# key, so find_log_file() MUST fall through to the Priority-2/3 suffix
# derivation (`sed -E 's/^com\.(claude|roborev)\.//; s/-/_/g'`) to locate its
# log file. Every OTHER fixture in this suite sets StandardOutPath explicitly
# (Priority 1), so before this fixture existed the buggy GNU-only `\|`
# alternation sed (a silent no-op on BSD sed) was never actually exercised by
# any test — the fallback path was untested and its bug went undetected.
# Written under $LOG_DIR (Priority 2/3), matching the label
# "com.claude.fallback-log" stripped to "fallback-log" then "fallback_log".
echo "2026-05-29 09:00:01 done exit 0" > "$LOG_DIR/fallback_log.out"
touch -m -t "$(date -v-1H '+%Y%m%d%H%M.%S')" "$LOG_DIR/fallback_log.out" 2>/dev/null || true

# ── Set up mock launchctl list file ───────────────────────────────────────────
# The mock returns JSON-like output for labels that ARE loaded.
# For labels not in this file, launchctl_info() returns empty → not loaded.
#
# Format: each line is a complete JSON object that launchctl list <label> would print.
# Note: the script parses launchctl output with python3 json.load; provide valid JSON.
cat > "$MOCK_LIST" <<'EOF'
{"PID": 1234, "LastExitStatus": 0, "Label": "com.claude.loaded-ok"}
{"PID": 0, "LastExitStatus": 256, "Label": "com.claude.loaded-failing"}
{"PID": 5678, "LastExitStatus": 0, "Label": "com.claude.stale-job"}
{"PID": 9012, "LastExitStatus": 0, "Label": "com.claude.weekday-repeated"}
{"PID": 3456, "LastExitStatus": 0, "Label": "com.claude.fallback-log"}
EOF
# not-loaded intentionally absent → returns empty

# ── Override launchctl_info to use mock file ───────────────────────────────────
# We do this by exporting LAUNCHD_AUDIT_MOCK_LIST.
# The script's launchctl_info() function checks this env var.
# But we need per-label lookup, so we create a per-label file approach:
#
# The mock file contains all labels; the function greps for the label.
# That works because the script's launchctl_info greps for the label.
export LAUNCHD_AUDIT_MOCK_LIST="$MOCK_LIST"

# Mock plist StandardOutPath → log files in $TMP/logs/
# We achieve this by pointing the plists' StandardOutPath to our log files.
# But the fixture plists already point to /tmp/launchd_audit_test/*.out.
# We override LOG_DIR so the fallback heuristic picks up our mock logs.
export LOG_DIR

# Set "now" to a fixed epoch so staleness is deterministic.
# Use a time 4 days after the stale-job log file was last modified.
# stale_job.out mtime ~ 3 days ago, so now = epoch + 3.5 days should flag it stale.
export LAUNCHD_AUDIT_NOW_EPOCH="$(date -v+0H '+%s')"  # current time is fine

echo "=== launchd_health_audit.sh Tests ==="
echo ""

# ── bash -n syntax check ───────────────────────────────────────────────────────
echo "-- Test: bash -n syntax check"
if bash -n "$SCRIPT" 2>/dev/null; then
  echo "  PASS: bash -n"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL: bash -n"
  FAIL=$(( FAIL + 1 ))
fi

# ── Run against fixture dir ────────────────────────────────────────────────────
echo ""
echo "-- Test: full markdown output against fixture plists"
output="$(LAUNCHD_AUDIT_PLIST_DIR="$FIXTURE_DIR" LAUNCHD_AUDIT_MOCK_LIST="$MOCK_LIST" \
  LOG_DIR="$LOG_DIR" LAUNCHD_AUDIT_NOW_EPOCH="$LAUNCHD_AUDIT_NOW_EPOCH" \
  bash "$SCRIPT" 2>/dev/null)"

# Section 3 (NOT loaded) must contain not-loaded label
assert "Section 3 contains com.claude.not-loaded" \
  "com.claude.not-loaded" "$output"

# Section 2 (failing) must contain the failing label
assert "Section 2 contains com.claude.loaded-failing" \
  "com.claude.loaded-failing" "$output"

# Section 1 or 4 must contain loaded-ok (it's OK so not in problems)
assert "Output contains com.claude.loaded-ok" \
  "com.claude.loaded-ok" "$output"

# Section 4 (stale) must contain stale-job
assert "Section 4 contains com.claude.stale-job" \
  "com.claude.stale-job" "$output"

# llm#898 regression: a weekday-repeated thrice-daily schedule (matches
# com.claude.roborev-poll-merges) must derive a 4h cadence, not 0s. At 3h
# since last fire it must NOT be flagged STALE (pre-fix: cadence=0 ->
# 2h floor -> would wrongly show STALE(3h)).
weekday_row="$(printf '%s\n' "$output" | grep 'weekday-repeated' || true)"
if [[ -n "$weekday_row" && "$weekday_row" != *"STALE"* ]]; then
  echo "  PASS: com.claude.weekday-repeated is not flagged STALE (llm#898)"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL: com.claude.weekday-repeated should not be STALE (llm#898)"
  echo "        row: $weekday_row"
  FAIL=$(( FAIL + 1 ))
fi

# llm#995 regression: com.claude.fallback-log has no StandardOutPath, so its
# log file can only be found via the Priority 2/3 suffix-derivation sed. Its
# log is fresh (1h old, daily cadence), so under the fixed sed it must show as
# a normal loaded/fresh row -- NOT "never / unknown" (which is what the
# pre-fix GNU-only `\|` sed produced on BSD sed, because it never stripped
# the com.claude. prefix and therefore looked for the wrong filename).
fallback_row="$(printf '%s\n' "$output" | grep 'fallback-log' || true)"
if [[ -n "$fallback_row" && "$fallback_row" != *"never / unknown"* ]]; then
  echo "  PASS: com.claude.fallback-log log resolved via fallback sed derivation (llm#995)"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL: com.claude.fallback-log should resolve its log via the suffix fallback (llm#995)"
  echo "        row: $fallback_row"
  FAIL=$(( FAIL + 1 ))
fi

# Headers present
assert "Section 3 header present" "## 3. NOT loaded" "$output"
assert "Section 2 header present" "## 2. Loaded — Recent failures" "$output"
assert "Section 4 header present" "## 4. Stale" "$output"
assert "Summary section present" "## 5. Summary" "$output"

# ── Test --quiet flag hides section 1 ────────────────────────────────────────
echo ""
echo "-- Test: --quiet hides section 1"
quiet_output="$(LAUNCHD_AUDIT_PLIST_DIR="$FIXTURE_DIR" LAUNCHD_AUDIT_MOCK_LIST="$MOCK_LIST" \
  LOG_DIR="$LOG_DIR" LAUNCHD_AUDIT_NOW_EPOCH="$LAUNCHD_AUDIT_NOW_EPOCH" \
  bash "$SCRIPT" --quiet 2>/dev/null)"

if [[ "$quiet_output" != *"## 1. Loaded — OK"* ]]; then
  echo "  PASS: --quiet hides section 1"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL: --quiet should hide section 1 but it appeared"
  FAIL=$(( FAIL + 1 ))
fi

# ── Test --json flag ───────────────────────────────────────────────────────────
echo ""
echo "-- Test: --json emits valid JSON"
json_output="$(LAUNCHD_AUDIT_PLIST_DIR="$FIXTURE_DIR" LAUNCHD_AUDIT_MOCK_LIST="$MOCK_LIST" \
  LOG_DIR="$LOG_DIR" LAUNCHD_AUDIT_NOW_EPOCH="$LAUNCHD_AUDIT_NOW_EPOCH" \
  bash "$SCRIPT" --json 2>/dev/null)"

if /usr/bin/python3 -c "import sys, json; json.loads(sys.stdin.read())" <<< "$json_output" 2>/dev/null; then
  echo "  PASS: --json output is valid JSON"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL: --json output is not valid JSON"
  FAIL=$(( FAIL + 1 ))
fi

# ── Test --out flag ────────────────────────────────────────────────────────────
echo ""
echo "-- Test: --out writes to file"
out_file="$TMP/out_test.md"
LAUNCHD_AUDIT_PLIST_DIR="$FIXTURE_DIR" LAUNCHD_AUDIT_MOCK_LIST="$MOCK_LIST" \
  LOG_DIR="$LOG_DIR" LAUNCHD_AUDIT_NOW_EPOCH="$LAUNCHD_AUDIT_NOW_EPOCH" \
  bash "$SCRIPT" --out "$out_file" > /dev/null 2>&1
if [[ -f "$out_file" && -s "$out_file" ]]; then
  echo "  PASS: --out created non-empty file"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL: --out did not create file"
  FAIL=$(( FAIL + 1 ))
fi

# ── Cleanup ────────────────────────────────────────────────────────────────────
rm -rf "$TMP"
rm -f /tmp/launchd_audit_test/weekday_repeated.out
rmdir /tmp/launchd_audit_test 2>/dev/null || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

[[ "$FAIL" -eq 0 ]]
