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

# llm#1067: `timeout 10 Rscript "$AUDIT_SCRIPT" 2>/dev/null || echo "R not
# available or timed out"` collapsed FOUR different causes into one message
# that was, in two of the four cases, actively wrong: audit_skills.R deleted
# (No such file or directory), Rscript itself crashing on the audit, and a
# genuine 10s timeout ALL produced the same "R not available or timed out"
# line — even though "R not available" had already been ruled out by the
# `command -v Rscript` check above. Distinguish each case explicitly so a
# deleted/broken audit script is never reported as a mere timeout.
if [ ! -f "$AUDIT_SCRIPT" ]; then
  echo "Skills audit: INDETERMINATE — audit script not found at $AUDIT_SCRIPT (did not run)"
elif command -v Rscript >/dev/null 2>&1; then
  _audit_err="$(mktemp)"
  _audit_rc=0
  timeout 10 Rscript "$AUDIT_SCRIPT" 2>"$_audit_err" || _audit_rc=$?
  if [ "$_audit_rc" -eq 0 ]; then
    : # audit_skills.R already printed its own result to stdout above.
  elif [ "$_audit_rc" -eq 124 ] || [ "$_audit_rc" -eq 137 ]; then
    echo "Skills audit: INDETERMINATE — timed out after 10s"
  else
    echo "Skills audit: INDETERMINATE — Rscript exited $_audit_rc: $(tail -1 "$_audit_err" 2>/dev/null)"
  fi
  rm -f "$_audit_err"
else
  echo "Skills audit: INDETERMINATE — Rscript not in PATH (outside nix shell?)"
fi
touch "$AUDIT_STAMP"
