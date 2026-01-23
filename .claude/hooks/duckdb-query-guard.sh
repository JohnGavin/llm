#!/bin/bash
# DuckDB Query Guard Hook
# Warns about potentially expensive queries (SELECT * without LIMIT, etc.)

set -e

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash commands
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Skip if not duckdb-related
if [[ "$CMD" != *"duckdb"* ]] && [[ "$CMD" != *"DuckDB"* ]]; then
    exit 0
fi

WARNINGS=""

# Check for SELECT * without LIMIT
if echo "$CMD" | grep -qi 'SELECT[[:space:]]*\*' && ! echo "$CMD" | grep -qi 'LIMIT'; then
    WARNINGS="${WARNINGS}• SELECT * without LIMIT may load entire dataset\n"
fi

# Check for CREATE TABLE AS without LIMIT/SAMPLE
if echo "$CMD" | grep -qi 'CREATE[[:space:]]*TABLE.*AS[[:space:]]*SELECT' && ! echo "$CMD" | grep -qiE 'LIMIT|SAMPLE'; then
    WARNINGS="${WARNINGS}• CREATE TABLE AS SELECT without LIMIT/SAMPLE\n"
fi

# Check for COPY without WHERE/LIMIT
if echo "$CMD" | grep -qi 'COPY.*TO' && ! echo "$CMD" | grep -qiE 'WHERE|LIMIT'; then
    WARNINGS="${WARNINGS}• COPY TO without WHERE/LIMIT exports all rows\n"
fi

# Check for missing file existence on read
if echo "$CMD" | grep -qi "read_parquet\|read_csv\|read_json" && echo "$CMD" | grep -qi "\.parquet\|\.csv\|\.json"; then
    WARNINGS="${WARNINGS}• Verify input files exist before query\n"
fi

# If warnings found, output them
if [[ -n "$WARNINGS" ]]; then
    # Escape for JSON
    WARNINGS_ESCAPED=$(echo -e "$WARNINGS" | sed 's/"/\\"/g' | tr '\n' ' ')
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "additionalContext": "⚠️ DUCKDB QUERY REVIEW\n\n${WARNINGS_ESCAPED}\nConsider adding LIMIT for testing. Proceed?"
  }
}
EOF
fi

exit 0
