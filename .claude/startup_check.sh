#!/bin/bash
# Claude Code SessionStart hook - comprehensive environment and context check
# This script output becomes context for Claude at session start

echo "## Session Start Check"
echo ""

# 1. Nix Environment
echo "### Environment"
if [[ -n "$IN_NIX_SHELL" ]]; then
  echo "- Nix Shell: Active ($IN_NIX_SHELL)"
  R_PATH=$(which R 2>/dev/null)
  echo "- R Path: $R_PATH"
else
  echo "- Nix Shell: INACTIVE"
  echo "- Action: Run './default.sh' or 'caffeinate -i ~/docs_gh/rix.setup/default.sh'"
fi
echo ""

# 2. Git Status
echo "### Git Status"
BRANCH=$(git branch --show-current 2>/dev/null)
if [[ -n "$BRANCH" ]]; then
  echo "- Branch: $BRANCH"
  CHANGES=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$CHANGES" -gt 0 ]]; then
    echo "- Changes: $CHANGES uncommitted files"
    git status --short 2>/dev/null | head -5
    [[ "$CHANGES" -gt 5 ]] && echo "  ... and $((CHANGES - 5)) more"
  else
    echo "- Status: Clean"
  fi
  echo ""
  echo "### Recent Commits"
  git log --oneline -3 2>/dev/null | sed 's/^/- /'
else
  echo "- Not a git repository"
fi
echo ""

# 3. Open PRs (if gh available)
if command -v gh &> /dev/null; then
  echo "### Open PRs"
  PR_COUNT=$(gh pr list --author @me --json number 2>/dev/null | grep -c "number" || echo "0")
  if [[ "$PR_COUNT" -gt 0 ]]; then
    gh pr list --author @me --limit 3 2>/dev/null | head -5
  else
    echo "- No open PRs"
  fi
  echo ""
fi

# 4. Current Work File
echo "### Current Work"
if [[ -f ".claude/CURRENT_WORK.md" ]]; then
  echo "From .claude/CURRENT_WORK.md:"
  head -20 .claude/CURRENT_WORK.md | sed 's/^/  /'
  LINES=$(wc -l < .claude/CURRENT_WORK.md | tr -d ' ')
  [[ "$LINES" -gt 20 ]] && echo "  ... ($((LINES - 20)) more lines)"
else
  echo "- No CURRENT_WORK.md found"
fi
echo ""

# 5. Plans
echo "### Active Plans"
if ls plans/PLAN_*.md 1>/dev/null 2>&1; then
  for plan in plans/PLAN_*.md; do
    TITLE=$(head -1 "$plan" | sed 's/^#* *//')
    echo "- $(basename "$plan"): $TITLE"
  done
else
  echo "- No plans found in plans/"
fi
echo ""

# 6. Reminder
echo "---"
echo "For detailed session initialization, run: /session-start"
echo "To refresh context mid-session, run: /focus"
