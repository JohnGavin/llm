#!/bin/sh
# Check skill file sizes against SLASH_COMMAND_TOOL_CHAR_BUDGET
# Placeholder: pass if no .claude/ skill files exceed 12000 chars

BUDGET=${SLASH_COMMAND_TOOL_CHAR_BUDGET:-12000}
exit_code=0

for f in .claude/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  chars=$(wc -c < "$f")
  if [ "$chars" -gt "$BUDGET" ]; then
    echo "OVER BUDGET: $f ($chars chars > $BUDGET)"
    exit_code=1
  fi
done

exit $exit_code
