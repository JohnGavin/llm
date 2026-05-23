#!/usr/bin/env bash
# codex_show_overnight_learning.sh - Print the latest unseen Codex learning digest.

set -euo pipefail

SUMMARY_DIR="${CODEX_LEARNING_DIR:-$HOME/.codex/learning}"
STATE_FILE="${CODEX_LEARNING_STATE_FILE:-$SUMMARY_DIR/.last_seen_summary}"
MARK_SEEN=1
SHOW_ALL=0

for arg in "$@"; do
  case "$arg" in
    --no-mark-seen) MARK_SEEN=0 ;;
    --all) SHOW_ALL=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [ ! -d "$SUMMARY_DIR" ]; then
  exit 0
fi

LATEST_JSON=$(find "$SUMMARY_DIR" -maxdepth 1 -name '*-summary.json' -type f | sort | tail -1)
[ -n "${LATEST_JSON:-}" ] || exit 0

LATEST_SHA=$(python3 - <<'PY' "$LATEST_JSON"
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
print(hashlib.sha1(path.read_bytes()).hexdigest())
PY
)

if [ "$SHOW_ALL" -eq 0 ] && [ -f "$STATE_FILE" ]; then
  LAST_SHA=$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)
  if [ "$LAST_SHA" = "$LATEST_SHA" ]; then
    exit 0
  fi
fi

python3 - <<'PY' "$LATEST_JSON"
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
counts = data.get("counts", {})
targets = counts.get("candidate_targets", {})
top = data.get("top_signals", [])

print("")
print(f"Overnight learning summary for {data.get('summary_date', 'unknown')}")
print(f"- {counts.get('workflow_candidates', 0)} workflow candidate(s)")
print(f"- {counts.get('correction_candidates', 0)} repeated user correction(s)")
print(f"- {counts.get('failure_candidates', 0)} repeated failure pattern(s)")
if targets:
    ordered = ", ".join(f"{k}={v}" for k, v in sorted(targets.items()))
    print(f"- Suggested targets: {ordered}")

if top:
    print("")
    print("Top signals:")
    for idx, signal in enumerate(top[:3], start=1):
        print(
            f"{idx}. {signal['title']} "
            f"[{signal['target']}; sessions={signal['session_count']}; repeats={signal['repetition_count']}]"
        )

print("")
print(f"Full report: {path.with_suffix('.md')}")
print("")
PY

if [ "$MARK_SEEN" -eq 1 ]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n%s\n' "$LATEST_SHA" "$LATEST_JSON" > "$STATE_FILE"
fi
