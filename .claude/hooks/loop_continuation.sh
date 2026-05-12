#!/usr/bin/env bash
# loop_continuation.sh - Continue session if an active loop is registered
# Hook: Stop event
# Claude Code Stop hooks can output {"continue": true, "prompt": "..."} to inject
# a continuation turn rather than ending the session.

set -euo pipefail

LOG="$HOME/.claude/logs/loop_continuation.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

LOOP_STATE="${CLAUDE_PROJECT_DIR:-.}/.claude/.loop_state.json"
COMPRESS_TRIGGER="${CLAUDE_PROJECT_DIR:-.}/.claude/.compress_trigger"

# Priority 1: pending compression trigger → continue with compression prompt
if [ -f "$COMPRESS_TRIGGER" ]; then
  _msg=$(cat "$COMPRESS_TRIGGER")
  rm -f "$COMPRESS_TRIGGER"
  log "CONTINUE: compress trigger — spawning haiku summarisation"
  printf '{"continue":true,"prompt":"Context compression needed. Spawn a haiku agent to write a 300-word prose summary of session progress to CURRENT_WORK.md (see auto-delegation rule haiku-for-summarisation), then run /compact."}\n'
  exit 0
fi

# Priority 2: no active loop → normal stop
[ -f "$LOOP_STATE" ] || exit 0

# Parse loop state
_py='import json,sys
d=json.load(sys.stdin)
print(d.get("max_turns",20))
print(d.get("current_turn",0))
print(d.get("prompt","Continue with the next iteration."))
'
_parsed=$(python3 -c "$_py" < "$LOOP_STATE" 2>/dev/null) || { rm -f "$LOOP_STATE"; exit 0; }
_max_turns=$(echo "$_parsed" | sed -n '1p')
_current=$(echo "$_parsed" | sed -n '2p')
_prompt=$(echo "$_parsed" | sed -n '3p')

_next=$(( _current + 1 ))

# Stop if max turns reached
if [ "$_next" -gt "$_max_turns" ]; then
  log "STOP: loop complete after $_max_turns turns"
  rm -f "$LOOP_STATE"
  exit 0
fi

# Increment turn counter
python3 - "$LOOP_STATE" "$_next" <<'PYEOF'
import json, sys
path, turn = sys.argv[1], int(sys.argv[2])
with open(path) as f: d = json.load(f)
d["current_turn"] = turn
with open(path, "w") as f: json.dump(d, f)
PYEOF

log "CONTINUE: loop turn $_next/$_max_turns"
# Escape prompt for JSON
_json_prompt=$(printf '%s' "$_prompt (turn $_next of $_max_turns)" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
printf '{"continue":true,"prompt":%s}\n' "$_json_prompt"
exit 0
