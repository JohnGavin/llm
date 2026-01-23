#!/bin/bash
# Nix Shell Guard Hook
# Blocks R/Rscript/bash R commands if not in nix shell
# Exit 0 = allow, Exit 2 = block

set -e

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash and MCP r-btw tools
if [[ "$TOOL_NAME" != "Bash" ]] && [[ ! "$TOOL_NAME" =~ ^mcp__r-btw ]]; then
    exit 0
fi

# For Bash, check if it's an R-related command
if [[ "$TOOL_NAME" == "Bash" ]]; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

    # Skip if not R-related
    if [[ "$CMD" != *"Rscript"* ]] && [[ "$CMD" != *"R --"* ]] && [[ "$CMD" != *"R CMD"* ]]; then
        exit 0
    fi
fi

# Check if in nix shell
if [[ "$IN_NIX_SHELL" == "1" ]] || [[ "$IN_NIX_SHELL" == "impure" ]] || [[ "$IN_NIX_SHELL" == "pure" ]]; then
    exit 0
fi

# Not in nix shell - provide warning with guidance
cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "additionalContext": "⚠️ NIX SHELL NOT DETECTED\n\nR commands should run inside nix shell for reproducibility.\n\nTo fix:\n1. Run: caffeinate -i ~/docs_gh/rix.setup/default.sh\n2. Or: nix develop\n3. Verify: echo $IN_NIX_SHELL (should be 1 or impure)\n\nProceed anyway?"
  }
}
EOF

exit 0
