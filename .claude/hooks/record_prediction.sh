#!/usr/bin/env bash
# record_prediction.sh - Append a prediction or outcome to JSONL
#
# Usage:
#   # Record a new prediction:
#   record_prediction.sh predict <project_slug> <project_name> <task_type> \
#     <p_success> "<task_description>" "<approach_summary>"
#
#   # Record an outcome for an existing prediction:
#   record_prediction.sh outcome <prediction_id> <outcome> "<notes>"
#
# Examples:
#   ~/.claude/hooks/record_prediction.sh predict \
#     "-Users-johngavin-docs-gh-proj-data-weather-irish-buoy-network" \
#     "irishbuoys" "ci_fix" 0.85 \
#     "Fix R CMD CHECK NOTE" "Replace dot with lambda"
#
#   ~/.claude/hooks/record_prediction.sh outcome \
#     "pred_20260315T100000_abc123" true "Fixed on first attempt"

set -euo pipefail

PRED_DIR="$HOME/.claude/predictions"
mkdir -p "$PRED_DIR"

action="${1:-}"
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
short_id=$(date -u +"%Y%m%dT%H%M%S")_$(head -c 3 /dev/urandom | xxd -p | head -c 6)

confidence_bucket() {
  local p="$1"
  # Compare using bc for float comparison
  if echo "$p < 0.40" | bc -l | grep -q 1; then
    echo "low"
  elif echo "$p <= 0.70" | bc -l | grep -q 1; then
    echo "medium"
  else
    echo "high"
  fi
}

case "$action" in
  predict)
    project_slug="${2:?project_slug required}"
    project_name="${3:?project_name required}"
    task_type="${4:?task_type required}"
    p_success="${5:?p_success required}"
    task_description="${6:?task_description required}"
    approach_summary="${7:?approach_summary required}"

    pred_id="pred_${short_id}"
    bucket=$(confidence_bucket "$p_success")
    jsonl_file="$PRED_DIR/${project_slug}.jsonl"

    # Build JSON with python3 for safety (handles escaping)
    python3 -c "
import json, sys
record = {
    'prediction_id': sys.argv[1],
    'recorded_at': sys.argv[2],
    'project_slug': sys.argv[3],
    'project_name': sys.argv[4],
    'task_type': sys.argv[5],
    'task_description': sys.argv[6],
    'approach_summary': sys.argv[7],
    'p_success': float(sys.argv[8]),
    'confidence_bucket': sys.argv[9],
    'outcome': None,
    'outcome_recorded_at': None,
    'outcome_notes': None
}
print(json.dumps(record))
" "$pred_id" "$now" "$project_slug" "$project_name" "$task_type" \
  "$task_description" "$approach_summary" "$p_success" "$bucket" \
  >> "$jsonl_file"

    echo "Recorded prediction: $pred_id (p=$p_success, bucket=$bucket)"
    echo "File: $jsonl_file"
    ;;

  outcome)
    prediction_id="${2:?prediction_id required}"
    outcome="${3:?outcome required (true/false/partial)}"
    notes="${4:-}"

    # Find which JSONL file contains this prediction
    jsonl_file=""
    for f in "$PRED_DIR"/*.jsonl; do
      [ -f "$f" ] || continue
      if grep -q "\"$prediction_id\"" "$f"; then
        jsonl_file="$f"
        break
      fi
    done

    if [ -z "$jsonl_file" ]; then
      echo "ERROR: prediction_id '$prediction_id' not found in any JSONL file" >&2
      exit 1
    fi

    # Read the original prediction and append an outcome update
    python3 -c "
import json, sys

pred_id = sys.argv[1]
outcome_str = sys.argv[2]
now = sys.argv[3]
notes = sys.argv[4] if len(sys.argv) > 4 else ''

# Parse outcome
if outcome_str == 'true':
    outcome = True
elif outcome_str == 'false':
    outcome = False
elif outcome_str == 'partial':
    outcome = True  # partial counts as success
else:
    outcome = None

# Read original to get fields
with open(sys.argv[5]) as f:
    for line in f:
        rec = json.loads(line.strip())
        if rec.get('prediction_id') == pred_id:
            rec['outcome'] = outcome
            rec['outcome_recorded_at'] = now
            rec['outcome_notes'] = notes
            print(json.dumps(rec))
            break
" "$prediction_id" "$outcome" "$now" "$notes" "$jsonl_file" \
  >> "$jsonl_file"

    echo "Recorded outcome for $prediction_id: $outcome"
    [ -n "$notes" ] && echo "Notes: $notes"
    ;;

  list)
    # Quick listing of recent predictions
    project_slug="${2:-}"
    if [ -n "$project_slug" ]; then
      f="$PRED_DIR/${project_slug}.jsonl"
      [ -f "$f" ] && python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    seen = {}
    for line in f:
        rec = json.loads(line.strip())
        seen[rec['prediction_id']] = rec
    for pid, rec in seen.items():
        status = 'PENDING' if rec.get('outcome') is None else ('OK' if rec['outcome'] else 'FAIL')
        print(f\"{status:7s} p={rec['p_success']:.0%} {rec['prediction_id']} {rec['task_description'][:50]}\")
" "$f"
    else
      for f in "$PRED_DIR"/*.jsonl; do
        [ -f "$f" ] || continue
        slug=$(basename "$f" .jsonl)
        n=$(wc -l < "$f" | tr -d ' ')
        echo "$slug: $n records"
      done
    fi
    ;;

  *)
    echo "Usage: $0 {predict|outcome|list} [args...]" >&2
    echo "" >&2
    echo "  predict <slug> <name> <type> <p> <description> <summary>" >&2
    echo "  outcome <prediction_id> <true|false|partial> [notes]" >&2
    echo "  list [project_slug]" >&2
    exit 1
    ;;
esac
