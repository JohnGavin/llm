#!/bin/bash
# Setup script for global Git hooks
# Run once to enable global pre-commit hooks for all repositories

HOOKS_DIR="$HOME/docs_gh/llm/git-hooks"

echo "Setting up global Git hooks..."

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Make hooks executable
chmod +x "$HOOKS_DIR"/*

# Set global hooks path
git config --global core.hooksPath "$HOOKS_DIR"

# Verify the setting
CURRENT_PATH=$(git config --global core.hooksPath)

if [ "$CURRENT_PATH" = "$HOOKS_DIR" ]; then
    echo "✅ Global hooks successfully configured at: $HOOKS_DIR"
    echo ""
    echo "Active hooks:"
    ls -la "$HOOKS_DIR" | grep -v "^total" | grep -v "^d" | grep -v "\.sh$"
    echo ""
    echo "These hooks will now run for ALL Git repositories on this machine."
    echo ""
    echo "To disable for a specific repo, run inside that repo:"
    echo "  git config core.hooksPath .git/hooks"
    echo ""
    echo "To disable globally:"
    echo "  git config --global --unset core.hooksPath"
else
    echo "❌ Failed to set global hooks path"
    exit 1
fi