#!/bin/bash
# Test Cache Hook
# Tracks R package test results and warns if re-running unchanged tests
# Uses file modification times to detect changes

set -e

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only check btw_tool_pkg_test and btw_tool_pkg_check
if [[ "$TOOL_NAME" != "mcp__r-btw__btw_tool_pkg_test" ]] && [[ "$TOOL_NAME" != "mcp__r-btw__btw_tool_pkg_check" ]]; then
    exit 0
fi

CACHE_DIR="$HOME/.claude/cache"
mkdir -p "$CACHE_DIR"

# Create a hash of the project path
PROJECT_HASH=$(echo "$CWD" | md5 | cut -c1-8)
CACHE_FILE="$CACHE_DIR/test-cache-${PROJECT_HASH}.json"
R_DIR="$CWD/R"
TESTS_DIR="$CWD/tests"

# Get latest modification time of R/ and tests/ directories
get_latest_mtime() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        find "$dir" -name "*.R" -type f -exec stat -f "%m" {} \; 2>/dev/null | sort -rn | head -1
    else
        echo "0"
    fi
}

R_MTIME=$(get_latest_mtime "$R_DIR")
TESTS_MTIME=$(get_latest_mtime "$TESTS_DIR")
CURRENT_MTIME=$((R_MTIME > TESTS_MTIME ? R_MTIME : TESTS_MTIME))

# Check cache
if [[ -f "$CACHE_FILE" ]]; then
    CACHED_MTIME=$(jq -r '.last_mtime // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
    CACHED_TIME=$(jq -r '.last_run // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
    CACHED_RESULT=$(jq -r '.result // "unknown"' "$CACHE_FILE" 2>/dev/null || echo "unknown")

    # If no changes since last run
    if [[ "$CURRENT_MTIME" -le "$CACHED_MTIME" ]] && [[ "$CACHED_MTIME" != "0" ]]; then
        ELAPSED=$(($(date +%s) - CACHED_TIME))
        MINS=$((ELAPSED / 60))

        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "additionalContext": "ℹ️ TEST CACHE HIT\n\nNo R/test files changed since last run (${MINS}m ago).\nLast result: ${CACHED_RESULT}\n\nRe-run anyway?"
  }
}
EOF
        exit 0
    fi
fi

# Update cache with current state (will be updated with result by post-hook)
echo "{\"last_mtime\": $CURRENT_MTIME, \"last_run\": $(date +%s), \"result\": \"running\", \"project\": \"$CWD\"}" > "$CACHE_FILE"

exit 0
