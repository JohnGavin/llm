#!/usr/bin/env bash
# r_code_check.sh - Run ast-grep scan on R project code
# Called by: /check command, quality-gates skill, manual invocation
# Requires: ast-grep 0.40+ with R grammar at ~/.config/ast-grep/
#
# Usage:
#   r_code_check.sh [TARGET_DIR] [--json]
#   r_code_check.sh R/
#   r_code_check.sh ~/docs_gh/proj/mypackage/R/ --json

set -euo pipefail

AST_GREP_DIR="$HOME/.config/ast-grep"
SGCONFIG="$AST_GREP_DIR/sgconfig.yml"
TARGET_DIR="${1:-.}"
JSON_FLAG="${2:-}"

if [ ! -f "$SGCONFIG" ]; then
  echo "ERROR: sgconfig.yml not found at $SGCONFIG"
  exit 1
fi

if ! command -v ast-grep >/dev/null 2>&1; then
  echo "ERROR: ast-grep not found in PATH"
  echo "Ensure you are in a Nix shell with ast-grep available"
  exit 1
fi

# Resolve TARGET_DIR to absolute path before cd
TARGET_DIR=$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")

# Must cd to sgconfig.yml directory for custom language discovery
cd "$AST_GREP_DIR"

echo "=== ast-grep R Code Scan ==="
echo "Target: $TARGET_DIR"
echo "Rules:  $(ls rules/*.yml 2>/dev/null | wc -l | tr -d ' ') rules loaded"
echo ""

if [ "$JSON_FLAG" = "--json" ]; then
  ast-grep scan --json=compact "$TARGET_DIR" 2>/dev/null
  exit 0
fi

# Run scan with all rules
scan_output=$(ast-grep scan "$TARGET_DIR" 2>&1) || true

if [ -z "$scan_output" ]; then
  echo "No violations found."
  exit 0
fi

echo "$scan_output"
echo ""
echo "--- Summary ---"

# Count by parsing output lines that start with severity
n_error=$(echo "$scan_output" | grep -ci "error\[" || true)
n_warning=$(echo "$scan_output" | grep -ci "warning\[" || true)
echo "Errors:   $n_error"
echo "Warnings: $n_warning"

# Hardcoded path check (grep-based, not ast-grep)
echo ""
echo "=== Hardcoded Path Check ==="
hardcoded=$(grep -rn '/Users/[a-zA-Z]' "$TARGET_DIR" --include='*.R' --include='*.r' 2>/dev/null || true)
if [ -n "$hardcoded" ]; then
  n_hardcoded=$(echo "$hardcoded" | wc -l | tr -d ' ')
  echo "WARNING: $n_hardcoded lines with hardcoded /Users/ paths:"
  echo "$hardcoded"
  n_warning=$((n_warning + n_hardcoded))
else
  echo "No hardcoded paths found."
fi

# Exit code: 1 if any errors, 0 if only warnings or clean
[ "$n_error" -gt 0 ] && exit 1 || exit 0
