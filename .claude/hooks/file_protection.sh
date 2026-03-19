#!/usr/bin/env bash
# file_protection.sh - Block accidental edits to critical files
# Hook: PreToolUse (Edit, Write)
# Warns before overwriting protected paths; requires explicit user intent.

set -euo pipefail

# Read the tool input from stdin
INPUT=$(cat)

# Extract file path from the tool input
FILE_PATH=$(echo "$INPUT" | grep -oP '"file_path":\s*"\K[^"]+' 2>/dev/null || echo "")

if [ -z "$FILE_PATH" ]; then
  exit 0  # No file path found, allow
fi

# Protected path patterns (relative to project root)
PROTECTED_PATTERNS=(
  "inst/extdata/"
  "default.nix"
  "_pkgdown.yml"
  ".github/workflows/"
  "NAMESPACE"
  "man/"
)

# Check if file matches any protected pattern
for pattern in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "WARN: Editing protected path: $FILE_PATH"
    echo "Pattern matched: $pattern"
    echo "These files are auto-generated or critical infrastructure."
    echo "Proceed only if this edit is explicitly requested."
    # Exit 0 to allow (warn only, don't block)
    # Change to exit 2 to block edits
    exit 0
  fi
done

exit 0
