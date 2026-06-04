#!/usr/bin/env bash
# r_code_check.sh - Run ast-grep + jarl scan on R project code
# Called by: /check command, quality-gates skill, manual invocation
#
# Requires:
#   ast-grep 0.40+ with R grammar at ~/.config/ast-grep/  (provided by nix shell)
#
# Optional (LAPTOP-LOCAL ONLY — see llm#99):
#   jarl 0.5.0+  — currently a manual install at /usr/local/bin/jarl
#   - NOT provided by nix-shell (nixpkgs only has 0.3.0, fails to build)
#   - NOT available on GitHub Actions runners — jarl checks are silently skipped in CI
#   - The script auto-detects /usr/local/bin/jarl so it works inside nix-shell
#     even though /usr/local/bin is not on PATH there.
#   - To install: download release from https://github.com/krlmlr/jarl/releases
#     and place at /usr/local/bin/jarl (chmod +x).
#   - Migration to nix tracked in llm#99.
#
# Usage:
#   r_code_check.sh [TARGET_DIR] [--json]
#   r_code_check.sh R/
#   r_code_check.sh ~/docs_gh/proj/mypackage/R/ --json
#
# Also runs check_qmd_fence_parity.sh on any *.qmd files in the project root
# vignettes/ and docs/ directories (parallel to TARGET_DIR).
# See JohnGavin/llm#465.

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
n_error=0
n_warning=0

if [ -z "$scan_output" ]; then
  echo "No ast-grep violations found."
else
  echo "$scan_output"
  echo ""
  echo "--- Summary ---"
  n_error=$(echo "$scan_output" | grep -ci "error\[" || true)
  n_warning=$(echo "$scan_output" | grep -ci "warning\[" || true)
  echo "Errors:   $n_error"
  echo "Warnings: $n_warning"
fi

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

# jarl R idiom linter (separate tool, different rule set from ast-grep)
# LAPTOP-LOCAL ONLY: see llm#99. Manual install at /usr/local/bin/jarl.
# Skipped silently inside CI runners (no /usr/local/bin/jarl) — that is by design
# until nixpkgs ships a working jarl >= 0.5.0.
echo ""
echo "=== jarl R Idiom Linter ==="
jarl_errors=0
JARL_BIN=""
if command -v jarl >/dev/null 2>&1; then
  JARL_BIN="jarl"
elif [ -x /usr/local/bin/jarl ]; then
  # /usr/local/bin is not on PATH inside nix-shell; reach the manual install directly
  JARL_BIN="/usr/local/bin/jarl"
fi

if [ -n "$JARL_BIN" ]; then
  jarl_output=$("$JARL_BIN" check "$TARGET_DIR" 2>&1) || true
  if [ -n "$jarl_output" ]; then
    echo "$jarl_output"
    jarl_errors=$(echo "$jarl_output" | grep -c "^error" || true)
  else
    echo "No jarl violations found."
  fi
else
  echo "jarl not found — skipping R idiom checks."
  echo "  Laptop-local manual install required (see llm#99)."
  echo "  Install: download https://github.com/krlmlr/jarl/releases >= 0.5.0"
  echo "           to /usr/local/bin/jarl (chmod +x)."
  echo "  Note: jarl is not available on GitHub Actions runners."
fi

# ─── Quarto fence parity check (llm#465) ────────────────────────────────────
# Run check_qmd_fence_parity.sh on vignettes/ and docs/ relative to TARGET_DIR
# so staged .qmd edits are caught at pre-commit time.
QMD_FENCE_SCRIPT="$(dirname "$0")/check_qmd_fence_parity.sh"
qmd_errors=0
if [ -x "$QMD_FENCE_SCRIPT" ]; then
  echo ""
  echo "=== Quarto Fence Parity Check ==="
  # Derive project root from TARGET_DIR: walk up until we find a DESCRIPTION or .git
  PROJ_ROOT="$TARGET_DIR"
  while [ "$PROJ_ROOT" != "/" ] && [ ! -f "$PROJ_ROOT/DESCRIPTION" ] && [ ! -d "$PROJ_ROOT/.git" ]; do
    PROJ_ROOT=$(dirname "$PROJ_ROOT")
  done
  qmd_exit=0
  for qmd_dir in "$PROJ_ROOT/vignettes" "$PROJ_ROOT/docs"; do
    if [ -d "$qmd_dir" ]; then
      if ! "$QMD_FENCE_SCRIPT" "$qmd_dir"; then
        qmd_exit=1
      fi
    fi
  done
  if [ "$qmd_exit" -ne 0 ]; then
    echo "Quarto fence parity: FAIL — fix orphan triple-backtick fences above"
    qmd_errors=1
  else
    echo "Quarto fence parity: OK"
  fi
else
  echo ""
  echo "=== Quarto Fence Parity Check ==="
  echo "check_qmd_fence_parity.sh not found at $QMD_FENCE_SCRIPT — skipping"
fi

# Exit code: 1 if any errors (ast-grep, jarl, or qmd fence), 0 if clean or warnings only
[ "$n_error" -gt 0 ] || [ "$jarl_errors" -gt 0 ] || [ "$qmd_errors" -gt 0 ] && exit 1 || exit 0
