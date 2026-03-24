#!/bin/bash
# phi-scan-hook.sh - PreToolUse hook for Write/Edit operations
#
# Blocks file writes containing PHI patterns in medical data projects.
# Configure in settings.json or hooks.json.
#
# Hook type: PreToolUse
# Tools: Write, Edit
#
# Exit codes:
#   0 - Allow operation (no PHI found)
#   2 - Deny/Ask (PHI detected, outputs JSON with permissionDecision)

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract relevant fields
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only check Write and Edit operations
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

# Skip non-medical data directories (check for .claude/rules/data-anonymization.md)
if [[ ! -f "$CWD/.claude/rules/data-anonymization.md" ]]; then
  exit 0
fi

# Extract content to check
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
fi

# Skip if no content
if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# === PHI Pattern Checks ===

# NHS Number (###-###-#### or ### ### ####)
if echo "$CONTENT" | grep -qE '\b[0-9]{3}[[:space:]-]*[0-9]{3}[[:space:]-]*[0-9]{4}\b'; then
  # Check if it's NOT the anonymized placeholder (000 000 0000)
  if ! echo "$CONTENT" | grep -qE '\b0{3}[[:space:]-]*0{3}[[:space:]-]*0{4}\b'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "Potential NHS number detected in content. Verify this is anonymized data."}' >&2
    exit 2
  fi
fi

# UK Mobile Phone (07xxx xxxxxx)
if echo "$CONTENT" | grep -qE '\b07[0-9]{3}[[:space:]]*[0-9]{6}\b'; then
  if ! echo "$CONTENT" | grep -qE '\[PHONE[^\]]*\]'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "UK mobile number pattern detected. Verify this is anonymized."}' >&2
    exit 2
  fi
fi

# UK Landline Phone (0xx xxxx xxxx)
if echo "$CONTENT" | grep -qE '\b0[0-9]{2,4}[[:space:]]*[0-9]{3,4}[[:space:]]*[0-9]{3,4}\b'; then
  if ! echo "$CONTENT" | grep -qE '\[PHONE[^\]]*\]'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "UK phone number pattern detected. Verify this is anonymized."}' >&2
    exit 2
  fi
fi

# UK Postcode (full format like SW6 7SX, EC2Y 8NH)
if echo "$CONTENT" | grep -qiE '\b[A-Z]{1,2}[0-9][0-9A-Z]?[[:space:]]*[0-9][A-Z]{2}\b'; then
  if ! echo "$CONTENT" | grep -qE '\[POSTCODE\]'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "UK postcode detected. Verify this is anonymized."}' >&2
    exit 2
  fi
fi

# Email addresses (not ending in @example.com)
if echo "$CONTENT" | grep -qE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'; then
  if ! echo "$CONTENT" | grep -qE '@example\.com'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "Email address detected. Verify this is anonymized (should be @example.com)."}' >&2
    exit 2
  fi
fi

# 8-digit number (potential MRN/hospital number)
# Only flag if writing to data files, not code
if [[ "$FILE_PATH" =~ \.(txt|csv|json)$ ]]; then
  if echo "$CONTENT" | grep -qE '\b[0-9]{8}\b'; then
    # Check if it's NOT the placeholder (12345678)
    if ! echo "$CONTENT" | grep -qE '\b12345678\b'; then
      echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "8-digit number detected (potential MRN). Verify this is anonymized."}' >&2
      exit 2
    fi
  fi
fi

# All checks passed
exit 0
