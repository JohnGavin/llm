#!/usr/bin/env bash
# compound_command_guard.sh — PreToolUse:Bash hook
#
# Detects compound bash commands (&&, ||, |, unescaped ;) and either logs
# or blocks them depending on COMPOUND_GUARD_MODE.
#
# Mode (env var COMPOUND_GUARD_MODE):
#   off   — exit 0 immediately, no check, no log  [DEFAULT]
#   log   — detect + log, always exit 0
#   block — detect + log + exit 1 with retry message
#
# Self-test: COMPOUND_GUARD_SELFTEST=1 bash compound_command_guard.sh
#
# Issue: #176

set -euo pipefail

LOG="$HOME/.claude/logs/compound_guard.log"
MODE="${COMPOUND_GUARD_MODE:-off}"

# ── Self-test mode ──────────────────────────────────────────────────────
if [ "${COMPOUND_GUARD_SELFTEST:-0}" = "1" ]; then
  _pass=0; _fail=0
  SCRIPT_PATH="$(realpath "$0")"

  _selftest_case() {
    local desc="$1" cmd="$2" expect="$3" tool_name="${4:-Bash}"
    local payload
    # Escape for JSON
    local escaped
    escaped=$(printf '%s' "$cmd" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" 2>/dev/null || printf '"%s"' "$cmd")
    payload="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"command\":$escaped}}"
    local exit_code=0
    printf '%s' "$payload" | \
      env COMPOUND_GUARD_MODE=block COMPOUND_GUARD_SELFTEST=0 \
      /usr/bin/env bash "$SCRIPT_PATH" >/dev/null 2>/dev/null || exit_code=$?
    # exit_code=1 means detected (blocked), exit_code=0 means not detected
    case "$expect" in
      DETECT)
        if [ "$exit_code" = "1" ]; then
          printf '  PASS  [%s]\n' "$desc"; _pass=$((_pass+1))
        else
          printf '  FAIL  [%s] -- expected DETECT (exit 1), got exit %s\n' "$desc" "$exit_code"; _fail=$((_fail+1))
        fi ;;
      ALLOW)
        if [ "$exit_code" = "0" ]; then
          printf '  PASS  [%s]\n' "$desc"; _pass=$((_pass+1))
        else
          printf '  FAIL  [%s] -- expected ALLOW (exit 0), got exit %s\n' "$desc" "$exit_code"; _fail=$((_fail+1))
        fi ;;
    esac
  }

  echo "=== compound_command_guard.sh self-test ==="
  echo "--- Must DETECT (compound operators outside strings/heredocs) ---"

  _selftest_case "pipe: git status | wc -l"                  "git status | wc -l"                          DETECT
  _selftest_case "ampamp: cd /tmp && ls"                      "cd /tmp && ls"                               DETECT
  _selftest_case "semicolon: ls /a; ls /b"                    "ls /a; ls /b"                                DETECT
  _selftest_case "oror: cmd1 || cmd2"                         "cmd1 || cmd2"                                DETECT
  _selftest_case "multi-pipe: git status | grep mod | wc -l"  "git status | grep modified | wc -l"         DETECT

  echo "--- Must ALLOW (operators inside strings, heredocs, or subshells) ---"

  _selftest_case "pipe in double-quoted string"               'echo "a | b"'                                ALLOW
  _selftest_case "ampamp in single-quoted string"             "echo 'a && b'"                               ALLOW
  _selftest_case "escaped semicolon (find -exec)"             'find . -name "*.tmp" -exec rm {} \;'        ALLOW
  _selftest_case "subshell (documented exception)"            "(cd /tmp && tar czf /backup.tgz .)"          ALLOW
  _selftest_case "background operator at end of line"         "sleep 5 &"                                   ALLOW
  _selftest_case "simple command, no operators"               "ls /tmp"                                      ALLOW
  _selftest_case "heredoc with pipe in body"                  "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nmessage with | in it\nEOF\n)"')"  ALLOW

  echo "--- Must ALLOW (non-Bash tool_name — belt-and-braces for issue #391) ---"

  _selftest_case "non-Bash tool: Grep with pipe-like input"   "ls | head"                                    ALLOW  Grep
  _selftest_case "non-Bash tool: Read with pipe-like input"   "cat file | head"                              ALLOW  Read

  echo "=== Results: $_pass passed, $_fail failed ==="
  [ "$_fail" -eq 0 ] && exit 0 || exit 1
fi

# ── Normal hook execution ───────────────────────────────────────────────

# Mode=off: skip everything (fast path — no stdin read needed)
if [ "$MODE" = "off" ]; then
  exit 0
fi

# Read JSON from stdin
INPUT=$(cat)

# Belt-and-braces: only inspect Bash tool calls (settings.json matcher is
# already "Bash", but harness-internal bundles may produce payloads with a
# different tool_name — exit 0 immediately for non-Bash tools).
# Fixes issue #391 false positives on Search/Read/Glob harness bundles.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# Can't parse command — allow
if [ -z "$COMMAND" ]; then
  exit 0
fi

# ── Detection via Python (handles heredocs and quoted strings cleanly) ──
DETECTED=$(CMD_TO_CHECK="$COMMAND" /usr/bin/python3 <<'PY'
import sys, re, os

cmd = os.environ.get('CMD_TO_CHECK', '')

# Strip single-quoted strings (cannot contain single quotes)
cmd = re.sub(r"'[^']*'", "''", cmd)

# Strip double-quoted strings (with backslash escape handling)
cmd = re.sub(r'"(?:[^"\\]|\\.)*"', '""', cmd)

# Strip heredoc bodies — match <<'WORD', <<"WORD", <<WORD, <<-WORD variants
# Everything between the opening line and the matching closing word
cmd = re.sub(
    r"<<-?\s*['\"]?(\w+)['\"]?.*?\n.*?\1\s*\n?",
    "<<HEREDOC\nHEREDOC\n",
    cmd,
    flags=re.DOTALL
)

# Strip escaped semicolons used by find -exec ... \;
cmd = cmd.replace(r'\;', '')

# Strip subshells (...) — documented exception in bash-safety rule
# Remove content of balanced parens at depth 1 (simple — not nested)
cmd = re.sub(r'\([^()]*\)', '()', cmd)

# Now detect compound operators in what remains
found = []
if re.search(r'\|\|', cmd):
    found.append('||')
# Bare pipe: | not preceded or followed by |
if re.search(r'(?<!\|)\|(?!\|)', cmd):
    found.append('|')
if re.search(r'&&', cmd):
    found.append('&&')
# Semicolon not at end of line (trailing ; is harmless)
if re.search(r';(?!\s*$)', cmd, re.MULTILINE):
    found.append(';')

print(','.join(found))
PY
)

# No operators found — allow
if [ -z "$DETECTED" ]; then
  exit 0
fi

# Compound operator found — log it
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
CMD_TRUNCATED="${COMMAND:0:120}"
[ ${#COMMAND} -gt 120 ] && CMD_TRUNCATED="${CMD_TRUNCATED}..."

mkdir -p "$(dirname "$LOG")"
printf '%s mode=%s detected=%s cmd_truncated=%s\n' \
  "$TIMESTAMP" "$MODE" "$DETECTED" "$CMD_TRUNCATED" >> "$LOG"

# Mode=log: logged but always allow
if [ "$MODE" = "log" ]; then
  exit 0
fi

# Mode=block: emit actionable retry message and exit 1
cat >&2 <<EOF

⛔ Compound bash command blocked by compound_command_guard (issue #176)

Detected operator(s): $DETECTED

This command chains multiple operations. Per the bash-safety rule
(.claude/rules/bash-safety.md), every Bash tool call should execute
exactly one command. Compound commands cannot match the allowlist patterns
in settings.json, so they trigger permission prompts.

To retry, split into separate Bash tool calls:
  - Run cmd1 in one call
  - Use git -C <dir> instead of cd <dir> && cmd
  - For Read/Edit, use the dedicated tools instead of cat/sed

If this command genuinely requires atomicity, wrap in a subshell:
  (cd /tmp && tar czf backup.tgz .)
Subshells are allowed; bare && chains are not.

To disable this guard temporarily: COMPOUND_GUARD_MODE=off <command>
EOF

exit 1
