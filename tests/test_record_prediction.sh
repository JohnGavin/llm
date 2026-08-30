#!/usr/bin/env bash
# tests/test_record_prediction.sh
#
# Unit tests for .claude/scripts/record_prediction.sh — the prediction/outcome
# JSONL logger that JohnGavin/llm#839 wires into roborev's adversarial-verify
# flow. This script already existed (unwired, untested) before #839; these
# tests are new coverage for pre-existing behaviour, not a bug-fix TDD cycle.
#
# Isolation: every invocation overrides HOME to a scratch directory, matching
# the existing test_roborev_verify_closure.sh convention — record_prediction.sh
# derives its output directory from $HOME/.claude/predictions, so this never
# touches the real ~/.claude/predictions/.
#
# Issue: JohnGavin/llm#839 (Phase 1-2)

set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PASS=0
FAIL=0

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_TEST_DIR}/.." && pwd)"
RECORD_SCRIPT="${_REPO_ROOT}/.claude/scripts/record_prediction.sh"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

_check() {
  local label="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS+1))
    echo "  PASS [$label]"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL [$label]: $result"
  fi
}

if [ ! -f "$RECORD_SCRIPT" ]; then
  echo "SKIP: record_prediction.sh not found at ${RECORD_SCRIPT}"
  exit 0
fi

# ── Test A: predict writes one well-formed JSON line, correct field types ────

echo "Test A: predict() writes one well-formed JSON line"

TA="${SCRATCH}/ta"
mkdir -p "$TA"

OUT_A=$(HOME="$TA" bash "$RECORD_SCRIPT" predict "slug1" "proj1" "task_x" "0.75" \
  "desc text" "approach text" 2>&1)
PRED_ID_A=$(printf '%s\n' "$OUT_A" | sed -n 's/^Recorded prediction: \([^ ]*\).*/\1/p')

JSONL_A="${TA}/.claude/predictions/slug1.jsonl"

if [ -f "$JSONL_A" ]; then
  N_LINES=$(wc -l < "$JSONL_A" | tr -d ' ')
  if [ "$N_LINES" = "1" ]; then
    _check "a-one-line" "pass"
  else
    _check "a-one-line" "fail: got ${N_LINES} lines"
  fi

  FIELDS=$(/usr/bin/python3 -c "
import json, re, sys
rec = json.loads(open(sys.argv[1]).readline())
errs = []
if not isinstance(rec.get('prediction_id'), str) or not rec['prediction_id'].startswith('pred_'):
    errs.append('prediction_id')
if not re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\$', rec.get('recorded_at','')):
    errs.append('recorded_at')
if rec.get('project_slug') != 'slug1': errs.append('project_slug')
if rec.get('project_name') != 'proj1': errs.append('project_name')
if rec.get('task_type') != 'task_x': errs.append('task_type')
if rec.get('task_description') != 'desc text': errs.append('task_description')
if rec.get('approach_summary') != 'approach text': errs.append('approach_summary')
if not isinstance(rec.get('p_success'), float) or abs(rec['p_success'] - 0.75) > 1e-9:
    errs.append('p_success')
if rec.get('confidence_bucket') != 'high': errs.append('confidence_bucket')
if rec.get('outcome') is not None: errs.append('outcome-not-null')
if rec.get('outcome_recorded_at') is not None: errs.append('outcome_recorded_at-not-null')
if rec.get('outcome_notes') is not None: errs.append('outcome_notes-not-null')
print(','.join(errs) if errs else 'ok')
" "$JSONL_A")
  if [ "$FIELDS" = "ok" ]; then
    _check "a-field-types" "pass"
  else
    _check "a-field-types" "fail: bad fields: ${FIELDS}"
  fi
else
  _check "a-one-line" "fail: jsonl file not written"
  _check "a-field-types" "fail: jsonl file not written"
fi

if [ -n "$PRED_ID_A" ]; then
  _check "a-prediction-id-parsed" "pass"
else
  _check "a-prediction-id-parsed" "fail: could not parse prediction_id from stdout: ${OUT_A}"
fi

# ── Test B: predict twice appends, never truncates ────────────────────────────

echo ""
echo "Test B: predict() appends on second call, does not truncate"

HOME="$TA" bash "$RECORD_SCRIPT" predict "slug1" "proj1" "task_y" "0.30" \
  "second desc" "second approach" >/dev/null 2>&1

N_LINES_B=$(wc -l < "$JSONL_A" | tr -d ' ')
if [ "$N_LINES_B" = "2" ]; then
  _check "b-appends" "pass"
else
  _check "b-appends" "fail: got ${N_LINES_B} lines, expected 2"
fi

FIRST_LINE_UNCHANGED=$(/usr/bin/python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    first = json.loads(f.readline())
print('ok' if first.get('task_type') == 'task_x' else 'changed')
" "$JSONL_A")
if [ "$FIRST_LINE_UNCHANGED" = "ok" ]; then
  _check "b-first-line-intact" "pass"
else
  _check "b-first-line-intact" "fail: first line was modified"
fi

# ── Test C: outcome() appends an update line, original line stays append-only ─

echo ""
echo "Test C: outcome() appends update, preserves original line (append-only)"

HOME="$TA" bash "$RECORD_SCRIPT" outcome "$PRED_ID_A" true "worked first try" >/dev/null 2>&1

N_LINES_C=$(wc -l < "$JSONL_A" | tr -d ' ')
if [ "$N_LINES_C" = "3" ]; then
  _check "c-outcome-appends" "pass"
else
  _check "c-outcome-appends" "fail: got ${N_LINES_C} lines, expected 3"
fi

LAST_LINE_OK=$(/usr/bin/python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    lines = [json.loads(l) for l in f if l.strip()]
last = lines[-1]
errs = []
if last.get('prediction_id') != sys.argv[2]: errs.append('prediction_id')
if last.get('outcome') is not True: errs.append('outcome')
if last.get('outcome_notes') != 'worked first try': errs.append('outcome_notes')
if not last.get('outcome_recorded_at'): errs.append('outcome_recorded_at')
# The ORIGINAL (first) line for this prediction_id must still show outcome=None
first_for_pred = [l for l in lines if l.get('prediction_id') == sys.argv[2]][0]
if first_for_pred.get('outcome') is not None: errs.append('original-line-mutated')
print(','.join(errs) if errs else 'ok')
" "$JSONL_A" "$PRED_ID_A")
if [ "$LAST_LINE_OK" = "ok" ]; then
  _check "c-outcome-fields" "pass"
else
  _check "c-outcome-fields" "fail: ${LAST_LINE_OK}"
fi

# ── Test D: outcome() for an unknown prediction_id exits non-zero ────────────

echo ""
echo "Test D: outcome() for unknown prediction_id fails loudly"

TD="${SCRATCH}/td"
mkdir -p "$TD"
HOME="$TD" bash "$RECORD_SCRIPT" predict "slugD" "projD" "t" "0.5" "d" "a" >/dev/null 2>&1

if HOME="$TD" bash "$RECORD_SCRIPT" outcome "pred_does_not_exist" true "x" >/dev/null 2>/tmp/test_record_prediction_stderr; then
  _check "d-unknown-id-fails" "fail: exited 0, expected non-zero"
else
  _check "d-unknown-id-fails" "pass"
fi

# ── Test E: confidence_bucket boundaries ──────────────────────────────────────

echo ""
echo "Test E: confidence_bucket boundaries (low<0.40, medium<=0.70, high>0.70)"

TE="${SCRATCH}/te"
mkdir -p "$TE"
declare -A EXPECTED_BUCKET=( ["0.10"]="low" ["0.39"]="low" ["0.40"]="medium" ["0.70"]="medium" ["0.71"]="high" ["0.99"]="high" )
E_ALL_OK="pass"
for p in "${!EXPECTED_BUCKET[@]}"; do
  slug="slugE_${p//./_}"
  HOME="$TE" bash "$RECORD_SCRIPT" predict "$slug" "projE" "t" "$p" "d" "a" >/dev/null 2>&1
  got=$(/usr/bin/python3 -c "
import json
print(json.loads(open('${TE}/.claude/predictions/${slug}.jsonl').readline())['confidence_bucket'])
")
  if [ "$got" != "${EXPECTED_BUCKET[$p]}" ]; then
    E_ALL_OK="fail: p=${p} expected ${EXPECTED_BUCKET[$p]} got ${got}"
    break
  fi
done
_check "e-bucket-boundaries" "$E_ALL_OK"

# ── Summary ────────────────────────────────────────────────────────────────────

TOTAL=$((PASS+FAIL))
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "${PASS}/${TOTAL} PASS"
  exit 0
else
  echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED"
  exit 1
fi
