#!/usr/bin/env bash
# test_destructive_api_guard.sh — Tests for destructive_api_guard.sh
#
# Usage: bash tests/hooks/test_destructive_api_guard.sh
# Exit 0 = all tests passed. Exit 1 = one or more failures.
#
# The hook is invoked with JSON on stdin (matching Claude Code's PreToolUse
# hook contract). The test harness feeds each test command as JSON to the
# hook and verifies the exit code. The test commands themselves are NEVER
# executed — they are only passed as data to the hook.

set -euo pipefail

HOOK="$(dirname "$0")/../../.claude/hooks/destructive_api_guard.sh"

if [ ! -f "$HOOK" ]; then
  echo "ERROR: Hook not found at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

# ─── Helpers ────────────────────────────────────────────────────────────────

# build_json <command> — produce a valid Claude Code PreToolUse JSON payload
# Uses python3 to ensure proper JSON escaping (handles single quotes, backslashes, etc.)
build_json() {
  local cmd="$1"
  python3 -c "
import json, sys
cmd = sys.argv[1]
payload = {'tool_name': 'Bash', 'tool_input': {'command': cmd}}
print(json.dumps(payload), end='')
" "$cmd"
}

# feed_hook <command> — pipe JSON to the hook; return the hook's exit code
# The test command is passed as data only — it is never executed.
feed_hook() {
  local cmd="$1"
  local code=0
  build_json "$cmd" | bash "$HOOK" 2>/dev/null || code=$?
  return $code
}

assert_blocked() {
  local label="$1"
  local cmd="$2"
  local code=0
  feed_hook "$cmd" || code=$?
  if [ "$code" -ne 0 ]; then
    echo "PASS [BLOCKED] $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL [should have blocked] $label"
    echo "     command: $cmd"
    FAIL=$((FAIL + 1))
  fi
}

assert_allowed() {
  local label="$1"
  local cmd="$2"
  local code=0
  feed_hook "$cmd" || code=$?
  if [ "$code" -eq 0 ]; then
    echo "PASS [ALLOWED] $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL [wrongly blocked] $label"
    echo "     command: $cmd"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Forbidden inputs (must be blocked / exit non-zero) ─────────────────────

echo "=== Forbidden inputs (expect BLOCKED) ==="

assert_blocked \
  "incident-exact: curl POST GraphQL mutation volumeDelete" \
  'curl -X POST https://x.com/graphql -d '"'"'{"query":"mutation { volumeDelete(volumeId: \"abc\") }"}'"'"''

assert_blocked \
  "curl -X DELETE" \
  "curl -X DELETE https://api.example.com/foo"

assert_blocked \
  "gh api -X DELETE" \
  "gh api repos/OWNER/REPO/pages -X DELETE"

assert_blocked \
  "aws s3 rm recursive" \
  "aws s3 rm s3://bucket/key --recursive"

assert_blocked \
  "flyctl volumes destroy" \
  "flyctl volumes destroy vol_abc"

assert_blocked \
  "psql DROP TABLE" \
  'psql -c "DROP TABLE users"'

assert_blocked \
  "curl -X PATCH" \
  'curl -X PATCH https://api.example.com/resource -d '"'"'{"name":"new"}'"'"''

assert_blocked \
  "curl -X PUT" \
  'curl -X PUT https://api.example.com/item/1 -d '"'"'{"value":42}'"'"''

assert_blocked \
  "gh api --method DELETE" \
  "gh api repos/OWNER/REPO/branches/main/protection --method DELETE"

assert_blocked \
  "aws ec2 delete-volume" \
  "aws ec2 delete-volume --volume-id vol-abc123"

assert_blocked \
  "railway volumes delete" \
  "railway volumes delete vol_xyz123"

assert_blocked \
  "psql TRUNCATE TABLE" \
  'psql -c "TRUNCATE TABLE events"'

assert_blocked \
  "duckdb DROP TABLE" \
  'duckdb db.duckdb "DROP TABLE sessions"'

assert_blocked \
  "sqlite3 DROP TABLE" \
  'sqlite3 app.db "DROP TABLE cache"'

# ─── Allowed inputs (must NOT be blocked / exit 0) ──────────────────────────

echo ""
echo "=== Allowed inputs (expect ALLOWED) ==="

assert_allowed \
  "curl -fsSL GET" \
  "curl -fsSL https://example.com/script.sh"

assert_allowed \
  "curl -s GET" \
  "curl -s https://api.github.com/repos/foo/bar"

assert_allowed \
  "curl POST without mutation keyword" \
  'curl -X POST https://api.github.com/repos/foo/bar/issues -d '"'"'{"title":"x"}'"'"''

assert_allowed \
  "gh issue list" \
  "gh issue list"

assert_allowed \
  "gh api GET (default)" \
  "gh api repos/foo/bar/pulls/123/comments"

assert_allowed \
  "gh pr create" \
  "gh pr create --title x"

assert_allowed \
  "aws s3 ls" \
  "aws s3 ls s3://bucket/"

assert_allowed \
  "psql SELECT" \
  'psql -c "SELECT * FROM users"'

assert_allowed \
  "git status" \
  "git -C ~/repo status"

assert_allowed \
  "nix-shell Rscript" \
  'nix-shell ~/repo/default.nix --run "Rscript script.R"'

assert_allowed \
  "curl -o download" \
  "curl -o /tmp/file.zip https://example.com/archive.zip"

assert_allowed \
  "curl -L redirect" \
  "curl -L https://example.com/redirect"

assert_allowed \
  "aws s3 cp upload" \
  "aws s3 cp localfile.txt s3://bucket/key"

assert_allowed \
  "duckdb SELECT query" \
  'duckdb db.duckdb "SELECT count(*) FROM events"'

assert_allowed \
  "empty command" \
  ""

# ─── Environment surfacing tests ────────────────────────────────────────────
# These tests verify that the block message includes the environment value.
# We feed a forbidden command with a temp project dir wired via $PWD.

echo ""
echo "=== Environment surfacing in block messages ==="

# Helper: run hook from a temp dir with optional CLAUDE.md content
# Captures stderr (where block messages go) and checks for a string.
assert_blocked_with_env_msg() {
  local label="$1"
  local cmd="$2"
  local env_content="$3"   # Content for .claude/CLAUDE.md (empty string = no file)
  local expected_msg="$4"  # String that must appear in stderr

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  if [ -n "$env_content" ]; then
    mkdir -p "$tmpdir/.claude"
    printf '%s\n' "$env_content" > "$tmpdir/.claude/CLAUDE.md"
  fi

  local stderr_out code=0
  # Run hook with PWD set to tmpdir so it reads the temp CLAUDE.md
  stderr_out=$(build_json "$cmd" | (cd "$tmpdir" && bash "$HOOK") 2>&1 >/dev/null) || code=$?

  if [ "$code" -ne 0 ] && printf '%s' "$stderr_out" | grep -qF "$expected_msg"; then
    echo "PASS [ENV-MSG] $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL [ENV-MSG] $label"
    echo "     expected exit non-zero and stderr containing: $expected_msg"
    echo "     got exit=$code stderr=$stderr_out"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
  trap - EXIT
}

assert_blocked_with_env_msg \
  "prod environment: block message contains PROD" \
  "curl -X DELETE https://api.example.com/foo" \
  "Environment: prod" \
  "PROD"

assert_blocked_with_env_msg \
  "no environment declared: block message contains 'research' (the default)" \
  "curl -X DELETE https://api.example.com/foo" \
  "" \
  "research"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed / $TOTAL total"

if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL test(s) did not pass" >&2
  exit 1
fi

echo "All tests passed."
exit 0
