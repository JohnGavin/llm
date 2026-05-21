#!/usr/bin/env bash
# roborev_summary_wrap.sh
# Wrapper around `roborev summary` that appends severity-autoclose stats.
# Reads ~/.claude/.roborev_autoclose_counters.json (schema version 1, written by
# roborev_severity_autoclose.sh — F1 PR). Degrades gracefully when absent.
#
# Usage:
#   .claude/scripts/roborev_summary_wrap.sh [args passed to roborev summary]
#
# Self-test:
#   ROBOREV_SUMMARY_WRAP_SELFTEST=1 bash .claude/scripts/roborev_summary_wrap.sh
#
# See: llm#224 Phase 4 (F2 — visibility surfaces)

set -euo pipefail

COUNTER_FILE="${HOME}/.claude/.roborev_autoclose_counters.json"
ROBOREV_BIN="${ROBOREV_BIN:-/usr/local/bin/roborev}"

# ── Helper: read counter stats via Python ────────────────────────────────────
# Returns multi-line output:
#   threshold:<value or unknown>
#   closed_today:<int>
#   closed_week:<int>
#   parse_fail:<int>
_read_counters() {
  local counter_file="$1"
  local repo_name="$2"

  if [ ! -f "$counter_file" ]; then
    printf 'threshold:unknown\nclosed_today:0\nclosed_week:0\nparse_fail:0\nabsent:1\n'
    return
  fi

  # Use env vars + quoted heredoc to avoid shell expansion of Python variable names
  ROBOREV_COUNTER_FILE="$counter_file" ROBOREV_REPO_NAME="$repo_name" python3 << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone, timedelta

counter_file = os.environ.get("ROBOREV_COUNTER_FILE", "")
repo_name = os.environ.get("ROBOREV_REPO_NAME", "unknown")

try:
    with open(counter_file, "r") as f:
        data = json.load(f)
except Exception:
    print("threshold:unknown")
    print("closed_today:0")
    print("closed_week:0")
    print("parse_fail:0")
    print("read_error:1")
    sys.exit(0)

by_date = data.get("by_date", {})

today_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d")
# Last 7 days including today
week_dates = set()
for i in range(7):
    d = (datetime.now(timezone.utc) - timedelta(days=i)).strftime("%Y-%m-%d")
    week_dates.add(d)

# Effective threshold: most recent date that has this repo
threshold = "unknown"
most_recent_date = None
for date_key in sorted(by_date.keys(), reverse=True):
    entry = by_date[date_key]
    t_obs = entry.get("threshold_observed", {})
    if repo_name in t_obs:
        threshold = t_obs[repo_name]
        most_recent_date = date_key
        break
    elif most_recent_date is None:
        # Fall back to any threshold_observed key
        if t_obs:
            threshold = next(iter(t_obs.values()))
        most_recent_date = date_key

# closed_today: sum for this repo on today's date
closed_today = 0
today_entry = by_date.get(today_utc, {})
today_by_repo = today_entry.get("by_repo", {})
if repo_name in today_by_repo:
    closed_today = int(today_by_repo[repo_name].get("closed", 0))
else:
    # Fall back to total if repo not broken out
    closed_today = int(today_entry.get("closed_count", 0))

# parse_fail_today
parse_fail = int(today_entry.get("parse_fail_count", 0))

# closed_week: sum across last 7 days for this repo
closed_week = 0
for d in week_dates:
    entry = by_date.get(d, {})
    by_repo = entry.get("by_repo", {})
    if repo_name in by_repo:
        closed_week += int(by_repo[repo_name].get("closed", 0))
    else:
        closed_week += int(entry.get("closed_count", 0))

# Use format() to avoid any shell f-string brace confusion (heredoc is single-quoted)
print("threshold:{}".format(threshold))
print("closed_today:{}".format(closed_today))
print("closed_week:{}".format(closed_week))
print("parse_fail:{}".format(parse_fail))
PYEOF
}

# ── Print the autoclose stats section ────────────────────────────────────────
_print_autoclose_section() {
  local counter_file="$1"
  local repo_name="$2"

  local stats
  stats=$(_read_counters "$counter_file" "$repo_name")

  local absent
  absent=$(printf '%s' "$stats" | grep '^absent:' | cut -d: -f2 || echo "0")

  if [ "${absent:-0}" = "1" ]; then
    echo ""
    echo "Auto-closed by severity threshold"
    echo "  (counter file absent — feature not yet active)"
    echo "  See: $counter_file"
    return
  fi

  local threshold closed_today closed_week parse_fail
  threshold=$(printf '%s' "$stats" | grep '^threshold:' | cut -d: -f2 || echo "unknown")
  closed_today=$(printf '%s' "$stats" | grep '^closed_today:' | cut -d: -f2 || echo "0")
  closed_week=$(printf '%s' "$stats" | grep '^closed_week:' | cut -d: -f2 || echo "0")
  parse_fail=$(printf '%s' "$stats" | grep '^parse_fail:' | cut -d: -f2 || echo "0")

  echo ""
  echo "Auto-closed by severity threshold"
  echo "  This week:  ${closed_week}  (threshold: ${threshold})"
  echo "  Today:      ${closed_today}"
  echo "  Parse fail: ${parse_fail}"
  echo "  See: ${counter_file}"
}

# ────────────────────────────────────────────────────────────────────────────
# Self-test mode
# ────────────────────────────────────────────────────────────────────────────
if [ "${ROBOREV_SUMMARY_WRAP_SELFTEST:-0}" = "1" ]; then
  echo "=== roborev_summary_wrap.sh self-test ==="
  PASS=0
  FAIL=0

  TMPDIR_TEST=$(mktemp -d)
  SYNTHETIC_COUNTER="$TMPDIR_TEST/test_counters.json"
  # Stash real counter file aside if it exists
  COUNTER_STASH=""
  if [ -f "$COUNTER_FILE" ]; then
    COUNTER_STASH="$COUNTER_FILE.selftest_stash"
    cp "$COUNTER_FILE" "$COUNTER_STASH"
    rm "$COUNTER_FILE"
  fi

  # Ensure COUNTER_FILE is absent for test 1
  [ -f "$COUNTER_FILE" ] && rm "$COUNTER_FILE"

  # Test 1: counter file absent — wrapper must not error, must print absence line
  result1=$(_print_autoclose_section "$COUNTER_FILE" "llm" 2>&1 || true)
  if printf '%s' "$result1" | grep -qF "counter file absent"; then
    echo "Test 1 PASS: absent counter file handled gracefully"
    PASS=$((PASS + 1))
  else
    echo "Test 1 FAIL: expected 'counter file absent' in output"
    echo "  Got: $result1"
    FAIL=$((FAIL + 1))
  fi

  # Test 2: synthetic counter file with known values — output must match schema
  TODAY=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%d'))")
  cat > "$SYNTHETIC_COUNTER" << JSONEOF
{
  "schema_version": 1,
  "by_date": {
    "${TODAY}": {
      "threshold_observed": {"llm": "medium", "mycare": "off"},
      "closed_count": 12,
      "skipped_count": 3,
      "parse_fail_count": 2,
      "by_repo": {
        "llm": {"closed": 8, "skipped": 2},
        "mycare": {"closed": 4}
      }
    }
  },
  "last_run_utc": "${TODAY}T15:00:01Z"
}
JSONEOF
  result2=$(_print_autoclose_section "$SYNTHETIC_COUNTER" "llm" 2>&1 || true)
  t2_ok=1
  printf '%s' "$result2" | grep -qF "threshold: medium" || t2_ok=0
  printf '%s' "$result2" | grep -qF "Today:      8"     || t2_ok=0
  printf '%s' "$result2" | grep -qF "Parse fail: 2"     || t2_ok=0
  if [ "$t2_ok" = "1" ]; then
    echo "Test 2 PASS: synthetic counter file parsed correctly (threshold=medium, today=8, fail=2)"
    PASS=$((PASS + 1))
  else
    echo "Test 2 FAIL: synthetic counter parsing wrong"
    echo "  Got: $result2"
    FAIL=$((FAIL + 1))
  fi

  # Test 3: restore original counter file and verify wrapper runs without error
  if [ -n "$COUNTER_STASH" ] && [ -f "$COUNTER_STASH" ]; then
    cp "$COUNTER_STASH" "$COUNTER_FILE"
    rm "$COUNTER_STASH"
    result3=$(_print_autoclose_section "$COUNTER_FILE" "llm" 2>&1; echo "exit:$?")
  else
    # No original — use the synthetic file as a stand-in
    cp "$SYNTHETIC_COUNTER" "$COUNTER_FILE" 2>/dev/null || true
    result3=$(_print_autoclose_section "$COUNTER_FILE" "llm" 2>&1; echo "exit:$?")
    # Clean up the temp counter file we just placed
    rm -f "$COUNTER_FILE" 2>/dev/null || true
  fi
  if printf '%s' "$result3" | grep -qF "exit:0"; then
    echo "Test 3 PASS: counter file restored, wrapper exits 0"
    PASS=$((PASS + 1))
  else
    echo "Test 3 FAIL: unexpected error after restore"
    echo "  Got: $result3"
    FAIL=$((FAIL + 1))
  fi

  # Cleanup temp dir
  rm -rf "$TMPDIR_TEST"

  TOTAL=$((PASS + FAIL))
  echo ""
  echo "${PASS}/${TOTAL} PASS"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ────────────────────────────────────────────────────────────────────────────
# Normal operation: run roborev summary, append autoclose section
# ────────────────────────────────────────────────────────────────────────────
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")")

# Run roborev summary with all passed arguments; pass through exit code
if [ -x "$ROBOREV_BIN" ]; then
  "$ROBOREV_BIN" summary "$@" || true
else
  echo "(roborev binary not found at $ROBOREV_BIN)"
fi

_print_autoclose_section "$COUNTER_FILE" "$REPO_NAME"
