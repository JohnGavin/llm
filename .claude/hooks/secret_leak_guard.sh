#!/usr/bin/env bash
# secret_leak_guard.sh — Block shell command-substitution / echo patterns
# that splice credentials into a Bash command before it runs.
# Hook: PreToolUse:Bash
# Exit 2 = BLOCK. Exit 0 = allow.
#
# Source: 2026-08-11 incident — `gh issue comment --body "…`printenv`…"` let
# the shell perform command substitution BEFORE `gh` ran, splicing 92
# environment variables (14 live credentials) into a comment on a PUBLIC
# GitHub repo. Four provider keys were auto-revoked by scanners.
# Rule: .claude/rules/secret-leak-prevention.md
#
# Self-test: bash secret_leak_guard.sh --selftest
#
# Performance: exactly ONE python3 invocation per real hook call, gated by a
# pure-bash substring fast-path so the common (no-secret-related-text) case
# never spawns a subprocess at all.

set -uo pipefail

# ─── Rule detection + logging, all in one python3 process ──────────────────
# Reads the hook JSON on stdin, extracts tool_input.command (falls back to a
# top-level "command" key), applies Rules 1-4, writes the block/bypass log
# entry itself (with Rule-4-shaped literals redacted), and exits 2 to BLOCK
# or 0 to ALLOW. ANY internal error is swallowed and treated as ALLOW
# (fail-open) — a broken guard must never wedge the session.
PY_CODE=$(cat <<'PYEOF'
import sys, json, re, os, datetime

# Literal credential token shapes (Rule 4). Order matters: more specific
# prefixes (sk-ant-) must be checked before their generic parents (sk-) so
# the reported description is the most useful one.
CRED_PATTERNS = [
    (r'ghp_[A-Za-z0-9]{20,}',            'GitHub personal access token (ghp_)'),
    (r'gho_[A-Za-z0-9]{20,}',            'GitHub OAuth token (gho_)'),
    (r'ghs_[A-Za-z0-9]{20,}',            'GitHub server-to-server token (ghs_)'),
    (r'github_pat_[A-Za-z0-9_]{20,}',    'GitHub fine-grained PAT (github_pat_)'),
    (r'sk-ant-[A-Za-z0-9\-_]{20,}',      'Anthropic API key (sk-ant-)'),
    (r'sk-[A-Za-z0-9]{20,}',             'API key (sk-...)'),
    (r'hf_[A-Za-z0-9]{20,}',             'HuggingFace token (hf_)'),
    (r'xoxb-[A-Za-z0-9\-]{10,}',         'Slack bot token (xoxb-)'),
    (r'xoxp-[A-Za-z0-9\-]{10,}',         'Slack user token (xoxp-)'),
    (r'AIza[A-Za-z0-9_\-]{30,}',         'Google API key (AIza)'),
    (r'AKIA[A-Z0-9]{16}',                'AWS access key ID (AKIA)'),
    (r'glpat-[A-Za-z0-9\-_]{15,}',       'GitLab personal access token (glpat-)'),
    (r'-----BEGIN[ A-Z]*PRIVATE KEY-----', 'PEM private key block'),
]

LOG_DIR = os.environ.get('SECRET_GUARD_LOG_DIR') or os.path.expanduser('~/.claude/logs')
LOG_FILE = os.path.join(LOG_DIR, 'secret_leak_guard.log')
BYPASS_FILE = os.path.join(LOG_DIR, 'secret_leak_guard_bypass.log')


def redact(text):
    """Replace any Rule-4-shaped literal with <REDACTED> — never log a real credential."""
    out = text
    for pat, _ in CRED_PATTERNS:
        out = re.sub(pat, '<REDACTED>', out)
    return out


def _append(path, line):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(path, 'a') as fh:
            fh.write(line + '\n')
    except Exception:
        pass  # logging must never block


def _utc_ts():
    # timezone.utc (not datetime.UTC) — portable back to Python 3.2, no
    # DeprecationWarning noise on stderr where the model would see it.
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def log_block(rule_num, cmd):
    _append(LOG_FILE, '%s\trule=%s\t%s' % (_utc_ts(), rule_num, redact(cmd)[:200]))


def log_bypass(cmd):
    _append(BYPASS_FILE, '%s\t%s' % (_utc_ts(), redact(cmd)[:200]))


def block(rule_num, message, cmd, bypassable):
    if bypassable and os.environ.get('SECRET_GUARD_BYPASS') == '1':
        log_bypass(cmd)
        sys.exit(0)
    sys.stderr.write('BLOCKED (secret_leak_guard rule %s): %s\n' % (rule_num, message))
    sys.stderr.write('Command (redacted, truncated to 200 chars): %s\n' % redact(cmd)[:200])
    sys.stderr.write('Log: %s\n' % LOG_FILE)
    log_block(rule_num, cmd)
    sys.exit(2)


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        return
    cmd = ''
    if isinstance(data, dict):
        tool_input = data.get('tool_input')
        if isinstance(tool_input, dict):
            cmd = tool_input.get('command', '') or ''
        if not cmd:
            cmd = data.get('command', '') or ''
    if not cmd or not isinstance(cmd, str):
        return

    # ── Rule 4 — literal credential in argv. Highest severity, NO bypass. ──
    for pat, desc in CRED_PATTERNS:
        if re.search(pat, cmd):
            block('4', 'literal credential detected: %s' % desc, cmd, bypassable=False)

    # ── Rule 1 — gh ... --body command substitution. NO bypass (trivial fix). ──
    if re.search(r'\bgh\s+(issue|pr|release|gist|api)\b', cmd):
        body_flag = re.search(r'(--body(?:\s|=|$))|(?:^|\s)-b\s', cmd)
        if body_flag and ('`' in cmd or '$(' in cmd):
            block(
                '1',
                "gh ... --body contains a backtick or $() — the shell evaluates this "
                "BEFORE gh sees it. Use --body-file <path> instead of a double-quoted "
                "--body string.",
                cmd, bypassable=False,
            )

    # ── Rule 2 — echo/printf of a secret-named variable expansion. Bypassable. ──
    # Only a violation when the expansion is an argument to echo/printf in the
    # SAME command segment — `[ -n "${VAR:-}" ] && echo set` must stay allowed.
    secret_var_re = re.compile(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)')
    secret_name_re = re.compile(r'(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL)', re.IGNORECASE)
    for seg in re.split(r';|&&|\|\||\n', cmd):
        if re.search(r'\b(echo|printf)\b', seg):
            for vm in secret_var_re.finditer(seg):
                if secret_name_re.search(vm.group(1)):
                    block(
                        '2',
                        'echo/printf expands ${%s} — if the variable holds a secret this '
                        'prints it verbatim (":-"/":+ " expand to the VALUE when set). Use '
                        '`[ -n "${VAR:-}" ] && echo set` to test presence without exposing it.'
                        % vm.group(1),
                        cmd, bypassable=True,
                    )

    # ── Rule 3 — env/printenv dump routed toward a publish/transport path. Bypassable. ──
    bare_printenv = re.search(r'\bprintenv\b\s*(?=$|[;&|])', cmd)
    bare_env = re.search(r'\benv\b\s*(?=$|[;&|])', cmd)
    transport = any(t in cmd for t in ('gh ', 'curl ', '|', '>', 'tee'))
    if (bare_printenv or bare_env) and transport:
        block(
            '3',
            'printenv/env output is routed toward gh/curl/tee/a redirect — this can splice '
            'every environment variable (including credentials) into a public destination.',
            cmd, bypassable=True,
        )
    body_match = re.search(r'--body\s+(["\'])(.*?)\1', cmd, re.DOTALL)
    if body_match and re.search(r'\b(printenv|env)\b', body_match.group(2)):
        block(
            '3',
            'printenv/env appears inside a gh --body argument — the shell expands it before '
            'gh runs, publishing your environment to a public comment/issue/PR.',
            cmd, bypassable=True,
        )


try:
    main()
except SystemExit:
    raise
except Exception:
    pass  # fail-open: any unhandled internal error allows the command
sys.exit(0)
PYEOF
)

# ─── run_guard <raw_stdin_json> ──────────────────────────────────────────────
# Pure-bash substring fast-path first (no subprocess for the common case),
# then exactly one python3 invocation carrying the full detection logic.
# Returns 2 to signal BLOCK, 0 to signal ALLOW.
run_guard() {
  local input="$1"
  case "$input" in
    *"gh "*|*"printenv"*|*"env"*|*"echo"*|*"printf"*|*'$'*|*'`'*| \
    *"ghp_"*|*"gho_"*|*"ghs_"*|*"github_pat_"*|*"sk-"*|*"hf_"*| \
    *"xoxb-"*|*"xoxp-"*|*"AIza"*|*"AKIA"*|*"glpat-"*|*"PRIVATE KEY"*)
      ;;  # potential match — fall through to python
    *)
      return 0
      ;;
  esac
  local rc=0
  printf '%s' "$input" | python3 -c "$PY_CODE" || rc=$?
  [ "$rc" -eq 2 ] && return 2
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  TMP_LOG_DIR=$(mktemp -d /tmp/secret_leak_guard_selftest_XXXXXX)
  export SECRET_GUARD_LOG_DIR="$TMP_LOG_DIR"
  unset SECRET_GUARD_BYPASS

  TOTAL=0
  PASS=0

  _case() {
    local desc="$1" cmd="$2" expected="$3"
    TOTAL=$((TOTAL + 1))
    local payload
    payload=$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}}))' "$cmd")
    local rc=0
    run_guard "$payload" >/dev/null 2>/dev/null || rc=$?
    local actual="ALLOW"
    [ "$rc" -eq 2 ] && actual="BLOCK"
    if [ "$actual" = "$expected" ]; then
      PASS=$((PASS + 1))
      printf 'PASS  [%-5s] %s\n' "$expected" "$desc"
    else
      printf 'FAIL  [want=%-5s got=%-5s] %s\n' "$expected" "$actual" "$desc"
      printf '      cmd: %s\n' "$cmd"
    fi
  }

  # ── MUST BLOCK ──────────────────────────────────────────────────────────
  _case "gh body backtick command substitution" \
    'gh issue comment 791 --body "env is `printenv`"' \
    "BLOCK"
  _case "gh body \$() command substitution" \
    'gh pr create --title x --body "$(cat /etc/passwd)"' \
    "BLOCK"
  _case "echo secret-named var (:+ / :- leak idiom)" \
    'echo "${GEMINI_API_KEY:+SET}${GEMINI_API_KEY:-UNSET}"' \
    "BLOCK"
  _case "printf secret-named var" \
    'printf '"'"'%s'"'"' "$OPENAI_API_KEY"' \
    "BLOCK"
  _case "bare printenv piped into gh --body-file" \
    'printenv | gh issue comment 1 --body-file -' \
    "BLOCK"
  _case "literal ghp_ token in curl header" \
    'curl -H "Authorization: Bearer ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123" https://api.github.com' \
    "BLOCK"
  _case "literal sk-ant- token in echo" \
    'echo sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
    "BLOCK"

  # ── MUST ALLOW (regression guards — over-blocking is a real cost) ───────
  _case "gh --body-file (the correct pattern)" \
    'gh issue comment 791 --body-file /tmp/body.md' \
    "ALLOW"
  _case "gh pr list, no body flag" \
    'gh pr list --limit 5' \
    "ALLOW"
  _case "safe is-it-set idiom, no echo of the value" \
    '[ -n "${GEMINI_API_KEY:-}" ] && echo set' \
    "ALLOW"
  _case "unrelated git status" \
    'git -C /repo status' \
    "ALLOW"
  _case "env VAR=1 cmd prefix form (not a dump)" \
    'env VAR=1 Rscript -e '"'"'print(1)'"'"'' \
    "ALLOW"
  _case "echo with no secret-named variable" \
    'echo "no secrets here"' \
    "ALLOW"
  _case "printenv with an explicit argument (not a dump)" \
    'printenv PATH' \
    "ALLOW"
  _case "unrelated duckdb query" \
    'duckdb /tmp/x.db "SELECT 1"' \
    "ALLOW"

  # ── Additional regression / coverage cases ───────────────────────────────
  _case "gh --body with literal text, no substitution" \
    'gh pr create --title "Fix" --body "Simple description, no shell tricks"' \
    "ALLOW"
  _case "gh --body containing \$() AND printenv (rule 1 catches first)" \
    'gh issue comment 5 --body "$(printenv)"' \
    "BLOCK"
  _case "literal gho_ OAuth token (extended fast-path coverage)" \
    'curl -H "Authorization: token gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ01" https://api.github.com' \
    "BLOCK"
  _case "AWS AKIA literal key id" \
    'echo "AKIAIOSFODNN7EXAMPLE"' \
    "BLOCK"
  _case "no trigger substrings at all — never spawns python" \
    'Rscript -e "1 + 1"' \
    "ALLOW"

  # ── Bypass coverage: Rule 2/3 bypassable, Rule 4 is not ──────────────────
  export SECRET_GUARD_BYPASS=1
  _case "bypass=1 allows rule 2 (bypassable)" \
    'echo "$MY_SECRET_TOKEN"' \
    "ALLOW"
  unset SECRET_GUARD_BYPASS
  _case "bypass unset: same rule 2 command blocks again" \
    'echo "$MY_SECRET_TOKEN"' \
    "BLOCK"
  export SECRET_GUARD_BYPASS=1
  _case "bypass=1 does NOT allow rule 4 (no-bypass rule)" \
    'echo ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123' \
    "BLOCK"
  unset SECRET_GUARD_BYPASS

  rm -rf "$TMP_LOG_DIR"

  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL HOOK OPERATION
# ═══════════════════════════════════════════════════════════════════════════
INPUT=$(cat)
run_guard "$INPUT"
exit $?
