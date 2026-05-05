#!/usr/bin/env bash
# destructive_api_guard.sh - Block destructive API calls before execution
# Hook: PreToolUse:Bash
# Exit 2 = BLOCK. Exit 0 = allow.
#
# Source: PocketOS/Cursor/Railway incident 2026-04-25 — an agent deleted a
# production volume via a single GraphQL mutation curl call in 9 seconds.
# See rule: destructive-api-calls.md

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

# ─── Pattern matching helper ─────────────────────────────────────────────────
# Uses grep -E (POSIX ERE). grep is toybox/GNU on the nix shell — [[:space:]] works.

block_match() {
  local pattern="$1"
  local description="$2"
  if printf '%s' "$COMMAND" | grep -qE "$pattern"; then
    printf 'BLOCKED: destructive API pattern detected\n' >&2
    printf 'Pattern : %s\n' "$pattern" >&2
    printf 'Reason  : %s\n' "$description" >&2
    printf 'Command : %s\n' "$COMMAND" >&2
    printf '\nThis call has been blocked by destructive_api_guard.sh.\n' >&2
    printf 'To perform intentional destructive ops, run from a terminal (outside Claude Code).\n' >&2
    printf 'See rule: destructive-api-calls.md  |  Escape hatch: issue #103\n' >&2
    if [ "$ENV_CLASS" = "prod" ]; then
      printf '⚠ This is a PROD-tagged project. Verify the target carefully.\n' >&2
      printf '  To run this manually, exit Claude Code and run from a regular shell.\n' >&2
    else
      printf '(environment: %s)\n' "$ENV_CLASS" >&2
    fi
    exit 2
  fi
}

# ─── Pattern table ────────────────────────────────────────────────────────────
# Intentionally narrow: false positives are worse than false negatives.
# "curl -X DELETE" (flag immediately after curl) AND "curl ... -X DELETE" (flag anywhere)

# curl destructive HTTP verbs (handles -X at any position in the command)
block_match \
  'curl[[:space:]].*-X[[:space:]]+(DELETE|PATCH|PUT)' \
  "curl -X DELETE/PATCH/PUT — destructive HTTP verb"

# curl GraphQL mutations via POST -X
block_match \
  'curl[[:space:]].*-X[[:space:]]+POST[[:space:]].*mutation[[:space:]]*\{' \
  "curl POST GraphQL mutation"

# curl GraphQL mutations via -d payload (single-quoted)
block_match \
  "curl[[:space:]].*-d[^[:space:]]*[[:space:]]+'[^']*mutation[[:space:]]*\{" \
  "curl -d '...mutation{...' GraphQL mutation (single-quoted)"

# curl GraphQL mutations via -d payload (double-quoted — after JSON unescaping)
block_match \
  'curl[[:space:]].*-d[^[:space:]]*[[:space:]]+"[^"]*mutation[[:space:]]*\{' \
  'curl -d "...mutation{..." GraphQL mutation (double-quoted)'

# gh api destructive verbs — short form (-X DELETE/PATCH/PUT)
block_match \
  'gh[[:space:]]+api[[:space:]].*-X[[:space:]]+(DELETE|PATCH|PUT)' \
  "gh api -X DELETE/PATCH/PUT — destructive GitHub API call"

# gh api destructive verbs — long form (--method DELETE/PATCH/PUT)
block_match \
  'gh[[:space:]]+api[[:space:]].*--method[[:space:]]+(DELETE|PATCH|PUT)' \
  "gh api --method DELETE/PATCH/PUT — destructive GitHub API call"

# AWS S3 bucket/object delete
block_match \
  'aws[[:space:]]+s3[[:space:]]+(rb|rm)[[:space:]]' \
  "aws s3 rb/rm — S3 bucket or object delete"

# AWS delete-* subcommand family (ec2 delete-volume, rds delete-db-instance, etc.)
block_match \
  'aws[[:space:]]+.*[[:space:]]delete-' \
  "aws ...delete-... — AWS delete subcommand"

# fly.io volume destroy
block_match \
  'flyctl[[:space:]]+volumes?[[:space:]]+destroy' \
  "flyctl volumes destroy — fly.io volume deletion"

# railway volume delete/destroy
block_match \
  'railway[[:space:]]+volumes?[[:space:]]+(delete|destroy)' \
  "railway volumes delete/destroy — railway volume deletion"

# psql DROP TABLE/SCHEMA/DATABASE via -c flag
block_match \
  'psql[[:space:]].*-c[[:space:]]+["'"'"'][[:space:]]*(DROP|TRUNCATE)[[:space:]]+(TABLE|SCHEMA|DATABASE)' \
  "psql -c DROP/TRUNCATE — irreversible SQL via psql"

# DuckDB / SQLite destructive SQL on command line
block_match \
  '(duckdb|sqlite3)[[:space:]].*[[:space:]]+"[[:space:]]*(DROP|TRUNCATE)[[:space:]]+(TABLE|SCHEMA)' \
  "duckdb/sqlite3 DROP/TRUNCATE — local DB schema destruction"

# ─── Allow ────────────────────────────────────────────────────────────────────
exit 0
