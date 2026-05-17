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

# ── Self-test mode ──────────────────────────────────────────────────────
# Usage: PERMISSION_REQUEST_SELFTEST=1 bash .claude/hooks/permission_request.sh
#
# Tests exercise the compound-command guard and the read-only matchers.
# Each case passes a synthetic JSON payload and checks whether the script
# outputs an approval JSON (APPROVE) or falls through with no JSON (REJECT).
# A missing compound-command rejection is a FAIL.
if [ "${PERMISSION_REQUEST_SELFTEST:-0}" = "1" ]; then
  _pass=0; _fail=0
  SCRIPT_PATH="$(realpath "$0")"

  _selftest_case() {
    local desc="$1" payload="$2" expect="$3"
    local out
    out=$(printf '%s' "$payload" | \
      env PERMISSION_REQUEST_SELFTEST=0 /usr/bin/env bash "$SCRIPT_PATH" 2>/dev/null \
      || true)
    local approved=0
    printf '%s' "$out" | grep -q '"approve"' && approved=1

    case "$expect" in
      APPROVE)
        if [ "$approved" = "1" ]; then
          printf '  PASS  [%s]\n' "$desc"; _pass=$((_pass+1))
        else
          printf '  FAIL  [%s] -- expected APPROVE, got: %s\n' "$desc" "$out"; _fail=$((_fail+1))
        fi ;;
      REJECT)
        if [ "$approved" = "0" ]; then
          printf '  PASS  [%s]\n' "$desc"; _pass=$((_pass+1))
        else
          printf '  FAIL  [%s] -- expected REJECT (no auto-approve), got: %s\n' "$desc" "$out"; _fail=$((_fail+1))
        fi ;;
    esac
  }

  echo "=== permission_request.sh self-test ==="

  # --- Must-REJECT (compound commands must NOT be auto-approved) ---
  _selftest_case \
    "semicolon injection: git status; rm -rf /tmp/x" \
    '{"tool_name":"Bash","tool_input":{"command":"git status; rm -rf /tmp/x"}}' \
    REJECT

  _selftest_case \
    "pipe injection: find . | sh" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -name '\''*.tmp'\'' | sh"}}' \
    REJECT

  _selftest_case \
    'subshell injection: ls $(echo /etc)' \
    '{"tool_name":"Bash","tool_input":{"command":"ls $(echo /etc)"}}' \
    REJECT

  # --- Must-APPROVE (single read-only commands, no metacharacters) ---
  _selftest_case \
    "plain: git status" \
    '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
    APPROVE

  _selftest_case \
    "git -C with path: git -C /tmp status" \
    '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp status"}}' \
    APPROVE

  _selftest_case \
    "ls -la /tmp" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -la /tmp"}}' \
    APPROVE

  echo "=== Results: $_pass passed, $_fail failed ==="
  [ "$_fail" -eq 0 ] && exit 0 || exit 1
fi

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
  # SECURITY GUARD (Finding 1): reject compound commands before any auto-approval.
  # A command containing shell metacharacters that join multiple commands (;, &&,
  # ||, |, backtick, $(, newline, or bare & for backgrounding) is NOT a single
  # read-only command — it is a potential injection vector. Attackers can prefix a
  # malicious payload with an innocent command ("git status; rm -rf /") to bypass
  # the matchers below. Reject such strings; require human approval.
  #
  # Note: we match on the raw action string (first 120 chars captured above).
  # The regex is intentionally broad: false-positive on a complex-but-safe command
  # is acceptable; false-negative on a compound-malicious command is not.
  if printf '%s' "$_action" | grep -qE '(;|&&|\|\||`|\$\(|[\n]| &$| & )'; then
    log "COMPOUND-REJECTED (metachar): $_action"
    exit 0  # fall through to normal human-approval prompt
  fi
  # Also reject bare pipe (|) not preceded/followed by | (|| already caught above).
  if printf '%s' "$_action" | grep -qP '\|(?!\|)'; then
    log "COMPOUND-REJECTED (pipe): $_action"
    exit 0
  fi

  # Read-only git (single command, no metacharacters — guard above already fired)
  if printf '%s' "$_action" | grep -qE "^git (status|log|diff|show|branch|remote|tag|describe|rev-parse)"; then
    log "AUTO-APPROVE: read-only git: $_action"
    printf '{"decision":"approve","reason":"Read-only git command"}\n'
    exit 0
  fi
  # Safe inspection commands (single command, no metacharacters)
  if printf '%s' "$_action" | grep -qE "^(ls |find |which |stat |wc |head |tail |cat |file |du |df |pwd|echo |printf |uname|sw_vers)"; then
    log "AUTO-APPROVE: read-only bash: $_action"
    printf '{"decision":"approve","reason":"Read-only inspection command"}\n'
    exit 0
  fi
  # Rscript REMOVED from auto-approve (Finding 2):
  # Rscript can execute arbitrary code — system("rm -rf /"), file writes, network
  # calls, etc. Blanket approval gives Rscript the same trust as a read-only tool,
  # which is incorrect. Decision: require human approval for every Rscript call.
  # The slight friction is intentional; it is cheap insurance against shell injection
  # via the -e argument or a sourced script. Do not restore this without a narrower
  # allowlist (e.g. only specific -e literals that are verifiably safe).
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
