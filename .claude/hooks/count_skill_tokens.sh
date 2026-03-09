#!/usr/bin/env bash
# Count lines per skill SKILL.md and references, warn if over limits
# Threshold: SKILL.md > 500 lines, description > 100 words
# Usage: count_skill_tokens.sh [skill_dir]
#   If no skill_dir given, scans all skills in ~/.claude/skills/

set -euo pipefail

SKILLS_DIR="${HOME}/.claude/skills"
SKILL_LINE_LIMIT=500
REF_LINE_LIMIT=1000
WARN_COUNT=0
TOTAL_SKILLS=0
TOTAL_LINES=0

check_skill() {
  local skill_dir="$1"
  local skill_name
  skill_name=$(basename "$skill_dir")
  local skill_file="${skill_dir}/SKILL.md"

  if [[ ! -f "$skill_file" ]]; then
    # Check for non-directory skills (single .md files)
    if [[ -f "${skill_dir}" && "${skill_dir}" == *.md ]]; then
      local lines
      lines=$(wc -l < "$skill_dir")
      TOTAL_LINES=$((TOTAL_LINES + lines))
      TOTAL_SKILLS=$((TOTAL_SKILLS + 1))
      if [[ $lines -gt $SKILL_LINE_LIMIT ]]; then
        echo "WARNING: ${skill_name} has ${lines} lines (limit: ${SKILL_LINE_LIMIT})"
        WARN_COUNT=$((WARN_COUNT + 1))
      fi
    fi
    return
  fi

  TOTAL_SKILLS=$((TOTAL_SKILLS + 1))
  local skill_lines
  skill_lines=$(wc -l < "$skill_file")
  TOTAL_LINES=$((TOTAL_LINES + skill_lines))

  local status="OK"
  if [[ $skill_lines -gt $SKILL_LINE_LIMIT ]]; then
    status="OVER"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi

  # Detect lowercase skill.md duplicate (should not exist)
  # Use ls to check actual filename case (macOS APFS is case-insensitive)
  if ls -1 "${skill_dir}" 2>/dev/null | grep -q '^skill\.md$'; then
    echo "DELETE: ${skill_name}/skill.md — lowercase duplicate of SKILL.md"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi

  # Detect extra .md files at skill root (not SKILL.md, not in references/)
  local extra_md=0
  for md_file in "${skill_dir}"/*.md; do
    if [[ -f "$md_file" ]]; then
      local md_name
      md_name=$(basename "$md_file")
      if [[ "$md_name" != "SKILL.md" && "$md_name" != "skill.md" ]]; then
        extra_md=$((extra_md + 1))
        if [[ $extra_md -eq 1 ]]; then
          echo "NOTE:   ${skill_name}/ has extra root .md files (consider moving to references/):"
        fi
        local el
        el=$(wc -l < "$md_file")
        echo "        - ${md_name} (${el} lines)"
      fi
    fi
  done

  # Count reference files
  local ref_lines=0
  local ref_count=0
  if [[ -d "${skill_dir}/references" ]]; then
    for ref_file in "${skill_dir}/references/"*.md; do
      if [[ -f "$ref_file" ]]; then
        local rl
        rl=$(wc -l < "$ref_file")
        ref_lines=$((ref_lines + rl))
        ref_count=$((ref_count + 1))
        TOTAL_LINES=$((TOTAL_LINES + rl))
      fi
    done
  fi

  # Check description length
  local desc_words=0
  if command -v grep &>/dev/null; then
    local desc
    desc=$(sed -n '/^description:/,/^[a-zA-Z]/p' "$skill_file" | head -20 | grep -v '^[a-zA-Z]' | grep -v '^description:' || true)
    if [[ -n "$desc" ]]; then
      desc_words=$(echo "$desc" | wc -w | tr -d ' ')
    fi
  fi

  local desc_status=""
  if [[ $desc_words -gt 100 ]]; then
    desc_status=" [desc: ${desc_words}w OVER]"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi

  # Report: show OVER skills, or skills with notable refs
  if [[ "$status" == "OVER" || -n "$desc_status" ]]; then
    printf "%-40s %4d lines %-5s  refs: %d (%d lines)%s\n" \
      "$skill_name" "$skill_lines" "$status" "$ref_count" "$ref_lines" "$desc_status"
  fi
}

# Header
echo "=== Skill Token/Line Audit ==="
echo "Limits: SKILL.md <= ${SKILL_LINE_LIMIT} lines, description <= 100 words"
echo ""

# Check specific skill or all
if [[ $# -ge 1 ]]; then
  check_skill "$1"
else
  # Check directory-based skills
  for skill_dir in "${SKILLS_DIR}"/*/; do
    if [[ -d "$skill_dir" ]]; then
      check_skill "$skill_dir"
    fi
  done
  # Check file-based skills (skip non-skill files like README.md, SKILLS_UPDATE_*.md)
  for skill_file in "${SKILLS_DIR}"/*.md; do
    if [[ -f "$skill_file" ]]; then
      _base=$(basename "$skill_file")
      # Skip files that aren't skills
      [[ "$_base" == "README.md" || "$_base" == SKILLS_UPDATE_* ]] && continue
      check_skill "$skill_file"
    fi
  done
fi

echo ""
echo "Summary: ${TOTAL_SKILLS} skills, ${TOTAL_LINES} total lines, ${WARN_COUNT} warnings"

if [[ $WARN_COUNT -gt 0 ]]; then
  echo "ACTION: ${WARN_COUNT} skill(s) exceed limits. Consider progressive disclosure (references/*.md)."
  exit 1
fi

echo "All skills within limits."
exit 0
