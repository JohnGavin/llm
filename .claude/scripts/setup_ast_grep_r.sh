#!/usr/bin/env bash
# setup_ast_grep_r.sh — One-time setup for ast-grep R language support
# Compiles tree-sitter-r grammar and creates ast-grep config.
# Requires: ast-grep, tree-sitter (both in nix via default.R system_pkgs)
#
# Run once after entering the nix shell:
#   bash ~/.claude/scripts/setup_ast_grep_r.sh

set -euo pipefail

CONFIG_DIR="$HOME/.config/ast-grep"
GRAMMAR_LIB="$CONFIG_DIR/r.dylib"
CONFIG_FILE="$CONFIG_DIR/sgconfig.yml"

# Check prerequisites
command -v ast-grep >/dev/null 2>&1 || { echo "ERROR: ast-grep not found. Enter nix shell first."; exit 1; }
command -v tree-sitter >/dev/null 2>&1 || { echo "ERROR: tree-sitter not found. Enter nix shell first."; exit 1; }

# Skip if already set up
if [ -f "$GRAMMAR_LIB" ] && [ -f "$CONFIG_FILE" ]; then
  echo "ast-grep R support already configured."
  echo "  Grammar: $GRAMMAR_LIB"
  echo "  Config:  $CONFIG_FILE"
  echo "  Test:    ast-grep -c $CONFIG_FILE -l r -p 'library(___)' ."
  exit 0
fi

mkdir -p "$CONFIG_DIR"

# Clone and compile the R grammar
echo "Compiling tree-sitter-r grammar..."
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git clone --depth 1 https://github.com/r-lib/tree-sitter-r.git 2>/dev/null
cd tree-sitter-r
tree-sitter build --output "$GRAMMAR_LIB" 2>/dev/null
echo "Grammar compiled: $GRAMMAR_LIB"

# Clean up
rm -rf "$TMPDIR"

# Create config
cat > "$CONFIG_FILE" <<EOF
customLanguages:
  r:
    libraryPath: $GRAMMAR_LIB
    extensions: [r, R]
    expandoChar: _
EOF
echo "Config created: $CONFIG_FILE"

echo ""
echo "ast-grep R support ready. Usage:"
echo "  ast-grep -c $CONFIG_FILE -l r -p 'library(___)' ."
echo "  ast-grep -c $CONFIG_FILE -l r -p 'suppressWarnings(___)' R/"
echo "  ast-grep -c $CONFIG_FILE -l r -p 'function(_A, _B, _C, _D, _E) _BODY' R/"
echo ""
echo "Alias (add to shell_hook or .zshrc):"
echo "  alias sg='ast-grep -c $CONFIG_FILE'"
