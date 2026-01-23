#!/bin/bash
# Operation Logger Hook (PostToolUse)
# Logs expensive operations for audit trail and reproducibility

set -e

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/operations.jsonl"
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Log R package operations
if [[ "$TOOL_NAME" =~ ^mcp__r-btw__btw_tool_pkg ]]; then
    OPERATION=$(echo "$TOOL_NAME" | sed 's/mcp__r-btw__btw_tool_pkg_//')

    # Get tool input for context
    PKG=$(echo "$INPUT" | jq -r '.tool_input.pkg // "."')
    FILTER=$(echo "$INPUT" | jq -r '.tool_input.filter // ""')

    echo "{\"timestamp\": \"$DATE\", \"type\": \"r_pkg\", \"operation\": \"$OPERATION\", \"pkg\": \"$PKG\", \"filter\": \"$FILTER\", \"cwd\": \"$CWD\", \"session\": \"$SESSION_ID\"}" >> "$LOG_FILE"
fi

# Log R code execution
if [[ "$TOOL_NAME" == "mcp__r-btw__btw_tool_run_r" ]]; then
    CODE_PREVIEW=$(echo "$INPUT" | jq -r '.tool_input.code // ""' | head -c 100 | tr '\n' ' ')
    echo "{\"timestamp\": \"$DATE\", \"type\": \"r_code\", \"preview\": \"$CODE_PREVIEW\", \"cwd\": \"$CWD\", \"session\": \"$SESSION_ID\"}" >> "$LOG_FILE"
fi

# Log DuckDB operations
if [[ "$TOOL_NAME" == "Bash" ]]; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

    if [[ "$CMD" == *"duckdb"* ]]; then
        CMD_PREVIEW=$(echo "$CMD" | head -c 200 | tr '\n' ' ')
        echo "{\"timestamp\": \"$DATE\", \"type\": \"duckdb\", \"command\": \"$CMD_PREVIEW\", \"cwd\": \"$CWD\", \"session\": \"$SESSION_ID\"}" >> "$LOG_FILE"
    fi
fi

# Update test cache with result if this was a test/check
if [[ "$TOOL_NAME" == "mcp__r-btw__btw_tool_pkg_test" ]] || [[ "$TOOL_NAME" == "mcp__r-btw__btw_tool_pkg_check" ]]; then
    PROJECT_HASH=$(echo "$CWD" | md5 | cut -c1-8)
    CACHE_FILE="$HOME/.claude/cache/test-cache-${PROJECT_HASH}.json"

    if [[ -f "$CACHE_FILE" ]]; then
        # Check if tool succeeded (exit code in result)
        # Note: PostToolUse only fires on success, so we mark as passed
        CURRENT=$(cat "$CACHE_FILE")
        echo "$CURRENT" | jq '.result = "passed"' > "$CACHE_FILE"
    fi
fi

# Rotate log if > 10MB
LOG_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
if [[ "$LOG_SIZE" -gt 10485760 ]]; then
    mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d)"
    gzip "$LOG_FILE.$(date +%Y%m%d)" 2>/dev/null || true
fi

exit 0
