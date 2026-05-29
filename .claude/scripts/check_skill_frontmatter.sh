#!/usr/bin/env bash
# check_skill_frontmatter.sh — Validate SKILL.md front matter against strict YAML 1.2
#
# Usage: ./check_skill_frontmatter.sh [skills_dir]
#   skills_dir defaults to .claude/skills relative to the repo root
#
# Exits 0 if all SKILL.md files have valid strict-YAML front matter.
# Exits 1 if any file fails, printing the file path and error.
#
# Designed to be called from skill_quality_onwrite.sh or run manually before commit.
# See llm#230 for motivation (Codex uses serde_yaml / YAML 1.2 strict parser).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR/../..")"

SKILLS_DIR="${1:-$REPO_ROOT/.claude/skills}"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "ERROR: skills directory not found: $SKILLS_DIR" >&2
  exit 1
fi

FAIL_COUNT=0
OK_COUNT=0

while IFS= read -r -d '' skill_file; do
  # Skip .system and generated directories
  case "$skill_file" in
    */.system/*|*/generated/*) continue ;;
  esac

  result=$(/usr/bin/python3 - "$skill_file" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
with open(path) as f:
    content = f.read()

if not content.startswith('---'):
    print(f"NO_FM: no front matter")
    sys.exit(1)

end = content.find('\n---', 3)
if end == -1:
    print(f"NO_END: no closing ---")
    sys.exit(1)

fm = content[3:end].strip()
try:
    yaml.safe_load(fm)
    sys.exit(0)
except Exception as e:
    print(str(e))
    sys.exit(1)
PYEOF
  ) && true

  exit_code=$?
  short="${skill_file#$SKILLS_DIR/}"

  if [ $exit_code -eq 0 ]; then
    OK_COUNT=$((OK_COUNT + 1))
  else
    echo "FAIL: $short" >&2
    echo "  $result" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done < <(find "$SKILLS_DIR" -name 'SKILL.md' -print0)

echo "check_skill_frontmatter: OK=$OK_COUNT FAIL=$FAIL_COUNT"

if [ $FAIL_COUNT -gt 0 ]; then
  echo "Fix: wrap description values in double-quotes so Triggers: is not parsed as a YAML key." >&2
  exit 1
fi

exit 0
