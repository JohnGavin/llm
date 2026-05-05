#!/usr/bin/env bash
# destructive_api_guard.sh - Block destructive API calls before execution
# Hook: PreToolUse:Bash
# Exit 2 = BLOCK. Exit 0 = allow.
#
# Source: PocketOS/Cursor/Railway incident 2026-04-25 — an agent deleted a
# production volume via a single GraphQL mutation curl call in 9 seconds.
# See rule: destructive-api-calls.md
#
# Two-key principle (rule: two-key-irreversible-ops): when a destructive
# pattern fires, the hook extracts and displays the target name so the user
# knows what to type when running the command manually outside Claude Code.

set -euo pipefail

# Read the full hook input JSON from stdin
INPUT=$(cat)

# Extract the command string using python3 (handles escaped quotes in JSON values).
# python3 is available in both the nix dev shell and macOS system.
# Fail open (allow) if extraction fails — don't block unknown formats.
COMMAND=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # PreToolUse hook format: {tool_input: {command: ...}}
    cmd = d.get('tool_input', {}).get('command', '')
    if not cmd:
        # Fallback: top-level command key
        cmd = d.get('command', '')
    print(cmd, end='')
except Exception:
    pass
" 2>/dev/null) || true

# If we couldn't parse a command, allow
if [ -z "$COMMAND" ]; then
  exit 0
fi

# ─── Read project environment class ─────────────────────────────────────────
# Reads $PWD/.claude/CLAUDE.md for an Environment: field.
# Fail open (default to "research") if the file is absent or unparseable.
# See rule: prod-staging-context-guard
ENV_CLASS="research"
_project_claude="$PWD/.claude/CLAUDE.md"
if [ -f "$_project_claude" ]; then
  _env_raw=$(grep -iE '^Environment:[[:space:]]*(research|dev|prod|mixed)' "$_project_claude" \
             | head -1 | sed -E 's/^[Ee]nvironment:[[:space:]]*//' | tr -d '`' | tr -d ' ') || true
  case "$_env_raw" in
    research|dev|prod|mixed) ENV_CLASS="$_env_raw" ;;
  esac
fi

# ─── Target extraction helper ────────────────────────────────────────────────
# extract_target <python_snippet>
# Runs a python3 one-liner against $COMMAND; prints the extracted target.
# Falls back to the first 80 chars of $COMMAND on any error.
#
# The python snippet receives the command string as `cmd` and must print the
# target to stdout (no trailing newline required). It may raise an exception
# to trigger the fallback.

extract_target() {
  local snippet="$1"
  local result
  result=$(printf '%s' "$COMMAND" | python3 -c "
import re, sys
cmd = sys.stdin.read()
try:
${snippet}
except Exception:
    print(cmd[:80], end='')
" 2>/dev/null) || true
  if [ -z "$result" ]; then
    printf '%.80s' "$COMMAND"
  else
    printf '%s' "$result"
  fi
}

# ─── Pattern matching helper ─────────────────────────────────────────────────
# block_match <pattern> <description> <target_snippet>
# Uses grep -E (POSIX ERE). grep is toybox/GNU on the nix shell — [[:space:]] works.

block_match() {
  local pattern="$1"
  local description="$2"
  local target_snippet="$3"

  if printf '%s' "$COMMAND" | grep -qE "$pattern"; then
    local target
    target=$(extract_target "$target_snippet")

    printf '🛑 BLOCKED: %s\n' "$description" >&2
    printf 'Pattern matched: %s\n' "$pattern" >&2
    printf 'Target: %s\n' "$target" >&2
    printf 'Why: this is an irreversible op. The two-key principle (rule: two-key-irreversible-ops)\n' >&2
    printf '     requires you to type the target name yourself, not paste it.\n' >&2
    printf '\n' >&2
    printf 'To proceed: exit Claude Code and run the command from a regular shell,\n' >&2
    printf '            typing "%s" verbatim from memory.\n' "$target" >&2
    printf '\n' >&2
    if [ "$ENV_CLASS" = "prod" ]; then
      printf 'Environment: PROD — verify the target carefully before running manually.\n' >&2
    else
      printf 'Environment: %s\n' "$ENV_CLASS" >&2
    fi
    printf '\n(full command, truncated to 200 chars):\n' >&2
    printf '%.200s\n' "$COMMAND" >&2
    exit 2
  fi
}

# ─── Pattern table ────────────────────────────────────────────────────────────
# Intentionally narrow: false positives are worse than false negatives.
# Each pattern includes a python3 target-extraction snippet.

# curl destructive HTTP verbs (handles -X at any position in the command)
block_match \
  'curl[[:space:]].*-X[[:space:]]+(DELETE|PATCH|PUT)' \
  "curl -X DELETE/PATCH/PUT — destructive HTTP verb" \
  "
    # Try to find -X VERB and extract the URL (first https?:// arg after that)
    m = re.search(r'-X\s+(?:DELETE|PATCH|PUT)\s+(\S+)', cmd)
    if m:
        print(m.group(1), end='')
    else:
        # Fall back: extract any URL in the command
        m2 = re.search(r'(https?://\S+)', cmd)
        print(m2.group(1) if m2 else cmd[:80], end='')"

# curl GraphQL mutations via POST -X
block_match \
  'curl[[:space:]].*-X[[:space:]]+POST[[:space:]].*mutation[[:space:]]*\{' \
  "curl POST GraphQL mutation" \
  "
    # Try volumeId or similar key:\"value\" in the mutation
    m = re.search(r'volumeId[\":\s]+[\"\\x27]([^\"\\x27]+)[\"\\x27]', cmd)
    if m:
        print(m.group(1), end='')
    else:
        # Fall back to the URL host
        m2 = re.search(r'(https?://[^/\s]+)', cmd)
        print(m2.group(1) if m2 else cmd[:80], end='')"

# curl GraphQL mutations via -d payload (single-quoted)
block_match \
  "curl[[:space:]].*-d[^[:space:]]*[[:space:]]+'[^']*mutation[[:space:]]*\{" \
  "curl -d '...mutation{...' GraphQL mutation (single-quoted)" \
  "
    m = re.search(r'volumeId[\":\s]+[\"\\x27]([^\"\\x27]+)[\"\\x27]', cmd)
    if m:
        print(m.group(1), end='')
    else:
        m2 = re.search(r'(https?://[^/\s]+)', cmd)
        print(m2.group(1) if m2 else cmd[:80], end='')"

# curl GraphQL mutations via -d payload (double-quoted — after JSON unescaping)
block_match \
  'curl[[:space:]].*-d[^[:space:]]*[[:space:]]+"[^"]*mutation[[:space:]]*\{' \
  'curl -d "...mutation{..." GraphQL mutation (double-quoted)' \
  "
    m = re.search(r'volumeId[\":\s]+[\"\\x27]([^\"\\x27]+)[\"\\x27]', cmd)
    if m:
        print(m.group(1), end='')
    else:
        m2 = re.search(r'(https?://[^/\s]+)', cmd)
        print(m2.group(1) if m2 else cmd[:80], end='')"

# gh api destructive verbs — short form (-X DELETE/PATCH/PUT)
block_match \
  'gh[[:space:]]+api[[:space:]].*-X[[:space:]]+(DELETE|PATCH|PUT)' \
  "gh api -X DELETE/PATCH/PUT — destructive GitHub API call" \
  "
    # Extract the path argument (first non-flag arg after 'gh api')
    m = re.search(r'gh\s+api\s+([^\s-][^\s]*)', cmd)
    print(m.group(1) if m else cmd[:80], end='')"

# gh api destructive verbs — long form (--method DELETE/PATCH/PUT)
block_match \
  'gh[[:space:]]+api[[:space:]].*--method[[:space:]]+(DELETE|PATCH|PUT)' \
  "gh api --method DELETE/PATCH/PUT — destructive GitHub API call" \
  "
    # Extract the path argument (first non-flag arg after 'gh api')
    m = re.search(r'gh\s+api\s+([^\s-][^\s]*)', cmd)
    print(m.group(1) if m else cmd[:80], end='')"

# AWS S3 bucket/object delete
block_match \
  'aws[[:space:]]+s3[[:space:]]+(rb|rm)[[:space:]]' \
  "aws s3 rb/rm — S3 bucket or object delete" \
  "
    # Extract the s3:// URI (stop before any flag)
    m = re.search(r'(s3://[^\s]+)', cmd)
    print(m.group(1) if m else cmd[:80], end='')"

# AWS delete-* subcommand family (ec2 delete-volume, rds delete-db-instance, etc.)
block_match \
  'aws[[:space:]]+.*[[:space:]]delete-' \
  "aws ...delete-... — AWS delete subcommand" \
  "
    # Extract first --flag value after delete- subcommand, or the subcommand itself
    m = re.search(r'--[a-z-]+\s+([^\s-][^\s]*)', cmd)
    if m:
        print(m.group(1), end='')
    else:
        m2 = re.search(r'(delete-\S+)', cmd)
        print(m2.group(1) if m2 else cmd[:80], end='')"

# fly.io volume destroy
block_match \
  'flyctl[[:space:]]+volumes?[[:space:]]+destroy' \
  "flyctl volumes destroy — fly.io volume deletion" \
  "
    # Extract the volume id (first non-flag arg after destroy)
    m = re.search(r'destroy\s+([^\s-]\S*)', cmd)
    print(m.group(1) if m else cmd[:80], end='')"

# railway volume delete/destroy
block_match \
  'railway[[:space:]]+volumes?[[:space:]]+(delete|destroy)' \
  "railway volumes delete/destroy — railway volume deletion" \
  "
    # Extract the volume id (first non-flag arg after delete/destroy)
    m = re.search(r'(?:delete|destroy)\s+([^\s-]\S*)', cmd)
    print(m.group(1) if m else cmd[:80], end='')"

# psql DROP TABLE/SCHEMA/DATABASE via -c flag
block_match \
  'psql[[:space:]].*-c[[:space:]]+["'"'"'][[:space:]]*(DROP|TRUNCATE)[[:space:]]+(TABLE|SCHEMA|DATABASE)' \
  "psql -c DROP/TRUNCATE — irreversible SQL via psql" \
  "
    # Extract table/schema/database name from the SQL statement
    m = re.search(r'(?:DROP|TRUNCATE)\s+(?:TABLE|SCHEMA|DATABASE)\s+(\S+?)[\s;\"\']*$',
                  cmd, re.IGNORECASE)
    print(m.group(1) if m else cmd[:80], end='')"

# DuckDB / SQLite destructive SQL on command line
block_match \
  '(duckdb|sqlite3)[[:space:]].*[[:space:]]+"[[:space:]]*(DROP|TRUNCATE)[[:space:]]+(TABLE|SCHEMA)' \
  "duckdb/sqlite3 DROP/TRUNCATE — local DB schema destruction" \
  "
    # Extract table/schema name from the SQL statement
    m = re.search(r'(?:DROP|TRUNCATE)\s+(?:TABLE|SCHEMA)\s+(\S+?)[\s;\"\']*\s*\"?\s*$',
                  cmd, re.IGNORECASE)
    print(m.group(1) if m else cmd[:80], end='')"

# ─── Allow ────────────────────────────────────────────────────────────────────
exit 0
