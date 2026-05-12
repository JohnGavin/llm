#!/usr/bin/env bash
# permission_request.sh - Granular permission routing for PermissionRequest events
# Hook: PermissionRequest event
# Input: JSON on stdin with tool_name, tool_input fields
# Output: {"decision":"approve"} to auto-approve
#         {"decision":"deny","reason":"..."} to auto-deny
#         exit 0 with no output → show normal permission prompt

set -euo pipefail

LOG="$HOME/.claude/logs/permission_requests.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

_input=$(cat)

_tool=$(printf '%s' "$_input" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('tool_name','unknown'))
" 2>/dev/null || echo "unknown")

_action=$(printf '%s' "$_input" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=d.get('tool_input',{})
v=t.get('command',t.get('path',t.get('url','')))
print(str(v)[:120])
" 2>/dev/null || echo "")

log "REQUEST: tool=$_tool action=$_action"

# ── Auto-approve: read-only tools ──────────────────────────────────────
case "$_tool" in
  Read|Glob|Grep|WebFetch|WebSearch|ListMcpResourcesTool|ReadMcpResourceTool)
    log "AUTO-APPROVE: read-only tool $_tool"
    printf '{"decision":"approve","reason":"Read-only tool"}\n'
    exit 0
    ;;
esac

# ── Auto-approve: safe Bash patterns ───────────────────────────────────
if [ "$_tool" = "Bash" ]; then
  # Read-only git
  if printf '%s' "$_action" | grep -qE "^git (status|log|diff|show|branch|remote|tag|describe|rev-parse)"; then
    log "AUTO-APPROVE: read-only git: $_action"
    printf '{"decision":"approve","reason":"Read-only git command"}\n'
    exit 0
  fi
  # Safe inspection commands
  if printf '%s' "$_action" | grep -qE "^(ls |find |which |stat |wc |head |tail |cat |file |du |df |pwd|echo |printf |uname|sw_vers)"; then
    log "AUTO-APPROVE: read-only bash: $_action"
    printf '{"decision":"approve","reason":"Read-only inspection command"}\n'
    exit 0
  fi
  # Rscript (non-destructive R execution)
  if printf '%s' "$_action" | grep -qE "^(timeout [0-9]+ )?Rscript"; then
    log "AUTO-APPROVE: Rscript execution: $_action"
    printf '{"decision":"approve","reason":"Rscript execution"}\n'
    exit 0
  fi
fi

# ── Needs human approval: notify and fall through ─────────────────────
log "NEEDS-APPROVAL: tool=$_tool action=$_action"

# Distinctive sound (Sosumi = "so sue me" — the classic Mac warning)
(/usr/bin/afplay -v 0.5 /System/Library/Sounds/Sosumi.aiff &) 2>/dev/null

# Optional ntfy.sh push notification (set NTFY_TOPIC env var to enable)
NTFY_TOPIC="${NTFY_TOPIC:-}"
if [ -n "$NTFY_TOPIC" ]; then
  _short="${_action:0:80}"
  curl -s \
    -H "Title: Claude Code: Permission Needed" \
    -H "Priority: high" \
    -H "Tags: warning,lock" \
    -d "Tool: $_tool | $_short" \
    "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 &
fi

# Exit 0 → normal permission prompt shown to user
exit 0
