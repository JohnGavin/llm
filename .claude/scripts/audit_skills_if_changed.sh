#!/usr/bin/env bash
# audit_skills_if_changed.sh — Run audit_skills.R only if skills have changed
# Uses timestamp comparison: ~1ms when unchanged, ~3s when changed.

set -euo pipefail

SKILLS_DIR="$HOME/.claude/skills"
AUDIT_STAMP="$HOME/.claude/.audit_skills_stamp"
AUDIT_SCRIPT="$HOME/docs_gh/llm/.claude/scripts/audit_skills.R"

# Check if any file in skills/ is newer than the stamp
if [ -f "$AUDIT_STAMP" ]; then
  newest=$(find "$SKILLS_DIR" -maxdepth 3 -name "SKILL.md" -newer "$AUDIT_STAMP" -print -quit 2>/dev/null || true)
  if [ -z "$newest" ]; then
    echo "Skills audit: up to date"
    exit 0
  fi
fi

# Skills changed or first run — run the audit
echo "Skills audit: changes detected, running..."
if command -v Rscript >/dev/null 2>&1; then
  timeout 10 Rscript "$AUDIT_SCRIPT" 2>/dev/null || echo "Skills audit: R not available or timed out"
else
  echo "Skills audit: Rscript not in PATH (outside nix shell?)"
fi
touch "$AUDIT_STAMP"
