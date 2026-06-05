#!/usr/bin/env bash
# burn_rate_check_codexbar.sh — Weekly burn-rate check using CodexBar data.
#
# Sibling of burn_rate_check.sh. Reads codexbar_cost_daily.json (the
# date-level rollup committed to llmtelemetry) instead of the ccusage source.
#
# Output contract (matches burn_rate_check.sh compact mode):
#   burn:NN%           — success; NN = integer percent of weekly cap
#   burn:err:<kind>    — failure; kind ∈ {no-cb-json, parse, empty-data}
#
# Exit code: always 0 (fail-open; non-zero breaks session_init).
#
# Usage:
#   burn_rate_check_codexbar.sh           # live run
#   burn_rate_check_codexbar.sh --selftest # run self-contained test suite
#
# Env vars:
#   CLAUDE_WEEKLY_CAP_USD   — weekly budget cap in USD (default: 1500)
#   CB_JSON_PATH            — override JSON path (for testing)

set -uo pipefail

# ── Selftest mode ────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${CLAUDE_HOOK_SELFTEST:-}" = "1" ]; then
  PASS=0
  FAIL=0

  _run_test() {
    local name="$1"
    local expected="$2"
    local json_content="$3"
    local fixture="/tmp/codexbar_test_$$.json"
    echo "$json_content" > "$fixture"
    local actual
    actual=$(CB_JSON_PATH="$fixture" "$0" 2>/dev/null)
    rm -f "$fixture"
    if [ "$actual" = "$expected" ]; then
      echo "  PASS: $name (got: $actual)"
      PASS=$(( PASS + 1 ))
    else
      echo "  FAIL: $name — expected '$expected', got '$actual'"
      FAIL=$(( FAIL + 1 ))
    fi
  }

  echo "burn_rate_check_codexbar.sh selftest"

  # Test 1: Happy path — 7 days at $100/day each, cap=$1000 → 70%
  TODAY=$(date +%Y-%m-%d)
  D1=$(python3 -c "import datetime; print((datetime.date.today()-datetime.timedelta(days=1)).isoformat())")
  D2=$(python3 -c "import datetime; print((datetime.date.today()-datetime.timedelta(days=2)).isoformat())")
  D3=$(python3 -c "import datetime; print((datetime.date.today()-datetime.timedelta(days=3)).isoformat())")
  D4=$(python3 -c "import datetime; print((datetime.date.today()-datetime.timedelta(days=4)).isoformat())")
  D5=$(python3 -c "import datetime; print((datetime.date.today()-datetime.timedelta(days=5)).isoformat())")
  D6=$(python3 -c "import datetime; print((datetime.date.today()-datetime.timedelta(days=6)).isoformat())")

  HAPPY_JSON='[{"provider":"claude","daily":[
    {"date":"'"$TODAY"'","totalCost":100},
    {"date":"'"$D1"'","totalCost":100},
    {"date":"'"$D2"'","totalCost":100},
    {"date":"'"$D3"'","totalCost":100},
    {"date":"'"$D4"'","totalCost":100},
    {"date":"'"$D5"'","totalCost":100},
    {"date":"'"$D6"'","totalCost":100}
  ]}]'
  CLAUDE_WEEKLY_CAP_USD=1000 _run_test "7x100 / cap=1000 => burn:70%" "burn:70%" "$HAPPY_JSON"

  # Test 2: Missing JSON → burn:err:no-cb-json
  actual_missing=$(CB_JSON_PATH="/tmp/codexbar_nonexistent_$$.json" "$0" 2>/dev/null)
  if [ "$actual_missing" = "burn:err:no-cb-json" ]; then
    echo "  PASS: missing JSON => burn:err:no-cb-json (got: $actual_missing)"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: missing JSON — expected 'burn:err:no-cb-json', got '$actual_missing'"
    FAIL=$(( FAIL + 1 ))
  fi

  # Test 3: Malformed JSON → burn:err:parse
  _run_test "malformed JSON => burn:err:parse" "burn:err:parse" "THIS IS NOT JSON"

  # Test 4: Empty daily array → burn:err:empty-data
  _run_test "empty daily array => burn:err:empty-data" "burn:err:empty-data" \
    '[{"provider":"claude","daily":[]}]'

  # Test 5: Old data only (> 7 days ago) → burn:0%
  OLD=$(python3 -c "import datetime; print((datetime.date.today()-datetime.timedelta(days=14)).isoformat())")
  _run_test "all data older than 7d => burn:0%" "burn:0%" \
    '[{"provider":"claude","daily":[{"date":"'"$OLD"'","totalCost":999}]}]'

  echo ""
  echo "Results: ${PASS}/$((PASS+FAIL)) PASS"
  exit 0
fi

# ── Live mode ────────────────────────────────────────────────────────────────
CB_JSON="${CB_JSON_PATH:-${HOME}/docs_gh/llmtelemetry/inst/extdata/codexbar_cost_daily.json}"
CAP_USD="${CLAUDE_WEEKLY_CAP_USD:-1500}"

# Guard: file must exist
if [ ! -f "$CB_JSON" ]; then
  echo "burn:err:no-cb-json"
  exit 0
fi

# Parse: find the claude provider entry; sum last 7 days of totalCost.
WEEK_USD=$(/usr/bin/python3 -c "
import json, sys, datetime

try:
    data = json.load(open('${CB_JSON}'))
except Exception:
    print('parse_error')
    sys.exit(0)

# Support both structures:
#   Array of provider objects: [{\"provider\":\"claude\",\"daily\":[...]},...]
#   Single object:             {\"provider\":\"claude\",\"daily\":[...]}
if isinstance(data, dict):
    data = [data]

if not isinstance(data, list):
    print('parse_error')
    sys.exit(0)

# Prefer the entry with provider='claude'; fall back to the entry whose
# models look like Claude models.
claude_entry = None
for e in data:
    if isinstance(e, dict) and e.get('provider', '').lower() in ('claude', 'anthropic'):
        claude_entry = e
        break

if claude_entry is None:
    # Fallback: pick the entry with claude-* models
    for e in data:
        if isinstance(e, dict):
            for d in e.get('daily', []):
                for m in d.get('modelsUsed', []):
                    if 'claude' in str(m).lower():
                        claude_entry = e
                        break
            if claude_entry:
                break

if claude_entry is None:
    print('no_claude_entry')
    sys.exit(0)

daily = claude_entry.get('daily', [])
if not daily:
    print('empty_data')
    sys.exit(0)

cutoff = (datetime.date.today() - datetime.timedelta(days=7)).isoformat()
week_cost = sum(
    float(r.get('totalCost', 0))
    for r in daily
    if isinstance(r, dict) and r.get('date', '') >= cutoff
)
print(f'{week_cost:.4f}')
" 2>/dev/null)

case "${WEEK_USD:-}" in
  parse_error)
    echo "burn:err:parse"
    exit 0
    ;;
  no_claude_entry)
    echo "burn:err:no-claude-entry"
    exit 0
    ;;
  empty_data)
    echo "burn:err:empty-data"
    exit 0
    ;;
  "")
    echo "burn:err:parse"
    exit 0
    ;;
esac

# Compute integer percentage
PCT=$(/usr/bin/python3 -c "print(int(round(100 * float('${WEEK_USD}') / float('${CAP_USD}'))))" 2>/dev/null)

if [ -z "$PCT" ]; then
  echo "burn:err:cap"
  exit 0
fi

echo "burn:${PCT}%"
exit 0
