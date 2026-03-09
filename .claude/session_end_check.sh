#!/bin/bash
# Claude Code SessionEnd hook - reminder about uncommitted work
# This script runs when the session ends

echo ""
echo "## Session End Check"
echo ""

# 1. Check for uncommitted changes
BRANCH=$(git branch --show-current 2>/dev/null)
if [[ -n "$BRANCH" ]]; then
  CHANGES=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$CHANGES" -gt 0 ]]; then
    echo "### Uncommitted Changes Found"
    echo ""
    git status --short 2>/dev/null
    echo ""
    echo "Consider running /session-end before leaving to:"
    echo "- Commit or stash changes"
    echo "- Update CURRENT_WORK.md"
    echo "- Push to remote"
  else
    echo "- Working tree: Clean"
  fi
  
  # Check if ahead of remote
  AHEAD=$(git rev-list --count @{upstream}..HEAD 2>/dev/null || echo "0")
  if [[ "$AHEAD" -gt 0 ]]; then
    echo "- Unpushed commits: $AHEAD"
    echo "- Consider: git push"
  fi
else
  echo "- Not in a git repository"
fi
echo ""
