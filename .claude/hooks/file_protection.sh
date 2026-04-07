#!/usr/bin/env bash
# file_protection.sh - Block or warn on edits to critical files
# Hook: PreToolUse (Edit, Write)
# Exit 2 = BLOCK (auto-generated files). Exit 0 = WARN (config files).

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$FILE_PATH" ] && exit 0

# Auto-generated files: BLOCK (exit 2) — these are overwritten by devtools::document()
BLOCK_PATTERNS=("NAMESPACE" "man/")
for pattern in "${BLOCK_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "BLOCKED: $FILE_PATH is auto-generated (matched: $pattern)"
    echo "Run devtools::document() instead of editing directly."
    exit 2
  fi
done

# raw/ folders are append-only: BLOCK edits to existing files
# New files (Write to non-existent path) are allowed.
# See: raw-folder-readonly rule
if [[ "$FILE_PATH" == *"/raw/"* ]] && [ -f "$FILE_PATH" ]; then
  TOOL_NAME=$(echo "$INPUT" | sed -n 's/.*"tool_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [[ "$TOOL_NAME" == "Edit" ]]; then
    echo "BLOCKED: $FILE_PATH is in a raw/ folder (append-only)"
    echo "raw/ files are the source of truth and must not be edited in place."
    echo "See: raw-folder-readonly rule. To redact PHI, save to raw/anonymized/."
    exit 2
  fi
fi

# Config/infrastructure files: WARN (exit 0) — allow but flag
WARN_PATTERNS=("inst/extdata/" "default.nix" "_pkgdown.yml" ".github/workflows/")
for pattern in "${WARN_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "WARN: Editing protected path: $FILE_PATH (matched: $pattern)"
    exit 0
  fi
done

exit 0
