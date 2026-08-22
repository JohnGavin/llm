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


# --- grep binary pinning (2026-08-18) -------------------------------------
# Every pattern below uses \b word boundaries. On this machine `grep` on PATH
# resolves to ugrep, which does NOT honour \b in -E mode — so every check in
# this hook silently failed to match and the hook could never block anything.
# It was also never wired into settings.json, so the defect went unnoticed.
# Verified: `command grep -qE '\b[0-9]{3}...'` on "NHS 123 456 7890" exits 1
# (no match) while /usr/bin/grep exits 0 (match).
# Pin to the system grep, which is guaranteed present on macOS and supports \b.
GREP="${PHI_SCAN_GREP:-/usr/bin/grep}"
# Same story for sed: the sed on PATH here is a non-standard
# replacement that rejects POSIX bracket classes in -E patterns.
SED="${PHI_SCAN_SED:-/usr/bin/sed}"
[ -x "$SED" ] || SED="sed"
[ -x "$GREP" ] || GREP="grep"   # fail soft on non-macOS

# Neutralise known anonymisation placeholders ONCE, centrally, before the
# pattern checks run. Without this the all-zeros NHS placeholder (000 000 0000)
# clears the NHS check by design and then trips the UK-landline check, so
# correctly anonymised data gets blocked. That flaw was invisible while the \b
# patterns never matched anything; fixing the grep binding exposed it.
CONTENT=$(printf '%s' "$CONTENT" | "$SED" -E \
  -e 's/0{3}[[:space:]-]*0{3}[[:space:]-]*0{4}/[NHS_PLACEHOLDER]/g' \
  -e 's/\[PHONE[^]]*\]/[PHONE]/g')

# === PHI Pattern Checks ===

# NHS Number (###-###-#### or ### ### ####)
if echo "$CONTENT" | "$GREP" -qE '\b[0-9]{3}[[:space:]-]*[0-9]{3}[[:space:]-]*[0-9]{4}\b'; then
  # Check if it's NOT the anonymized placeholder (000 000 0000)
  if ! echo "$CONTENT" | "$GREP" -qE '\b0{3}[[:space:]-]*0{3}[[:space:]-]*0{4}\b'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "Potential NHS number detected in content. Verify this is anonymized data."}' >&2
    exit 2
  fi
fi

# UK Mobile Phone (07xxx xxxxxx)
if echo "$CONTENT" | "$GREP" -qE '\b07[0-9]{3}[[:space:]]*[0-9]{6}\b'; then
  if ! echo "$CONTENT" | "$GREP" -qE '\[PHONE[^\]]*\]'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "UK mobile number pattern detected. Verify this is anonymized."}' >&2
    exit 2
  fi
fi

# UK Landline Phone (0xx xxxx xxxx)
if echo "$CONTENT" | "$GREP" -qE '\b0[0-9]{2,4}[[:space:]]*[0-9]{3,4}[[:space:]]*[0-9]{3,4}\b'; then
  if ! echo "$CONTENT" | "$GREP" -qE '\[PHONE[^\]]*\]'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "UK phone number pattern detected. Verify this is anonymized."}' >&2
    exit 2
  fi
fi

# UK Postcode (full format like SW6 7SX, EC2Y 8NH)
if echo "$CONTENT" | "$GREP" -qiE '\b[A-Z]{1,2}[0-9][0-9A-Z]?[[:space:]]*[0-9][A-Z]{2}\b'; then
  if ! echo "$CONTENT" | "$GREP" -qE '\[POSTCODE\]'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "UK postcode detected. Verify this is anonymized."}' >&2
    exit 2
  fi
fi

# Email addresses (not ending in @example.com)
if echo "$CONTENT" | "$GREP" -qE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'; then
  if ! echo "$CONTENT" | "$GREP" -qE '@example\.com'; then
    echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "Email address detected. Verify this is anonymized (should be @example.com)."}' >&2
    exit 2
  fi
fi

# 8-digit number (potential MRN/hospital number)
# Only flag if writing to data files, not code
if [[ "$FILE_PATH" =~ \.(txt|csv|json)$ ]]; then
  if echo "$CONTENT" | "$GREP" -qE '\b[0-9]{8}\b'; then
    # Check if it's NOT the placeholder (12345678)
    if ! echo "$CONTENT" | "$GREP" -qE '\b12345678\b'; then
      echo '{"hookSpecificOutput": {"permissionDecision": "ask"}, "systemMessage": "8-digit number detected (potential MRN). Verify this is anonymized."}' >&2
      exit 2
    fi
  fi
fi

# All checks passed
exit 0
