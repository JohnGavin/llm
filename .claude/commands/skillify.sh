#!/usr/bin/env bash
# skillify.sh — Extract repeatable patterns from conversation history into skills
# Usage: skillify.sh [N] where N = number of recent tool calls to analyze (default: 20)
set -euo pipefail

N="${1:-20}"
SKILLS_DIR="$HOME/.claude/skills"
MANIFEST="$SKILLS_DIR/MANIFEST.md"
QUALITY_HOOK="$HOME/.claude/hooks/skill_quality_onwrite.sh"

# Find current session transcript
PROJECT_DIR="$HOME/.claude/projects/-Users-johngavin-docs-gh-llm"
TRANSCRIPT=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1)

if [ ! -f "$TRANSCRIPT" ]; then
  echo "❌ No session transcript found at $PROJECT_DIR" >&2
  exit 1
fi

echo "📊 Analyzing last $N tool calls from session: $(basename "$TRANSCRIPT" .jsonl)"
echo ""

# Extract last N tool calls and user messages using Python
ANALYSIS=$(python3 - "$TRANSCRIPT" "$N" <<'PYTHON'
import json
import sys
from collections import Counter
from datetime import datetime

transcript_path = sys.argv[1]
n_calls = int(sys.argv[2])

tool_calls = []
user_messages = []

with open(transcript_path, 'r') as f:
    for line in f:
        try:
            event = json.loads(line)
            if event.get('type') == 'tool_call_result':
                data = event.get('data', {})
                tool_calls.append({
                    'tool': data.get('tool_name', 'unknown'),
                    'params': data.get('params', {}),
                    'timestamp': event.get('timestamp', '')
                })
            elif event.get('type') == 'message' and event.get('data', {}).get('role') == 'user':
                content = event.get('data', {}).get('content', '')
                if content and not content.startswith('/'):
                    user_messages.append(content[:200])  # First 200 chars
        except json.JSONDecodeError:
            continue

# Take last N tool calls
recent_calls = tool_calls[-n_calls:] if len(tool_calls) > n_calls else tool_calls
recent_messages = user_messages[-10:] if len(user_messages) > 10 else user_messages

if len(recent_calls) < 3:
    print("INSUFFICIENT_DATA")
    sys.exit(0)

# Analyze patterns
tool_counts = Counter([c['tool'] for c in recent_calls])
most_common_tools = tool_counts.most_common(5)

# Find repeated operations (same tool called multiple times)
repeated_ops = [(tool, count) for tool, count in most_common_tools if count >= 2]

# Extract trigger phrases (last 3 user messages)
triggers = [msg for msg in recent_messages[-3:] if len(msg) > 10]

# Identify file modifications (Edit/Write calls)
file_mods = []
for call in recent_calls:
    if call['tool'] in ['Edit', 'Write']:
        path = call['params'].get('file_path', '')
        if path:
            file_mods.append(path)

# Identify bash commands
bash_cmds = []
for call in recent_calls:
    if call['tool'] == 'Bash':
        cmd = call['params'].get('command', '')
        if cmd:
            bash_cmds.append(cmd[:100])  # First 100 chars

# Detect workflow type based on patterns
workflow_type = "unknown"
if any('test' in cmd.lower() for cmd in bash_cmds):
    workflow_type = "testing"
elif any('git' in cmd for cmd in bash_cmds):
    workflow_type = "git-workflow"
elif any('nix' in cmd for cmd in bash_cmds):
    workflow_type = "nix-environment"
elif len([c for c in recent_calls if c['tool'] in ['Edit', 'Write']]) >= 3:
    workflow_type = "multi-file-edit"
elif any('Rscript' in cmd for cmd in bash_cmds):
    workflow_type = "r-execution"

# Generate summary
print(f"WORKFLOW_TYPE:{workflow_type}")
print(f"TOOL_CALLS:{len(recent_calls)}")
print(f"REPEATED_OPS:{';'.join([f'{t}({c})' for t, c in repeated_ops])}")
print(f"FILE_MODS:{len(file_mods)}")
print(f"TRIGGER_SAMPLE:{triggers[0] if triggers else 'No user messages found'}")
print(f"TOP_TOOLS:{';'.join([t for t, _ in most_common_tools[:3]])}")
PYTHON
)

if [ "$ANALYSIS" = "INSUFFICIENT_DATA" ]; then
  echo "❌ Insufficient data: Need at least 3 tool calls to extract a pattern" >&2
  exit 1
fi

# Parse analysis output
WORKFLOW_TYPE=$(echo "$ANALYSIS" | grep "^WORKFLOW_TYPE:" | cut -d: -f2)
TOOL_CALLS=$(echo "$ANALYSIS" | grep "^TOOL_CALLS:" | cut -d: -f2)
REPEATED_OPS=$(echo "$ANALYSIS" | grep "^REPEATED_OPS:" | cut -d: -f2-)
FILE_MODS=$(echo "$ANALYSIS" | grep "^FILE_MODS:" | cut -d: -f2)
TRIGGER_SAMPLE=$(echo "$ANALYSIS" | grep "^TRIGGER_SAMPLE:" | cut -d: -f2-)
TOP_TOOLS=$(echo "$ANALYSIS" | grep "^TOP_TOOLS:" | cut -d: -f2-)

echo "Workflow type: $WORKFLOW_TYPE"
echo "Tool calls analyzed: $TOOL_CALLS"
echo "Repeated operations: $REPEATED_OPS"
echo "Files modified: $FILE_MODS"
echo "Trigger sample: $TRIGGER_SAMPLE"
echo ""

# Generate skill name from workflow type
SKILL_NAME=$(echo "$WORKFLOW_TYPE" | tr '_' '-')
SKILL_DIR="$SKILLS_DIR/$SKILL_NAME"

# Check if skill already exists
if [ -d "$SKILL_DIR" ]; then
  echo "⚠️  Skill '$SKILL_NAME' already exists at $SKILL_DIR"
  echo "Options:"
  echo "  1. Edit manually: Edit ~/.claude/skills/$SKILL_NAME/SKILL.md"
  echo "  2. Delete and regenerate: rm -rf ~/.claude/skills/$SKILL_NAME && /skillify $N"
  exit 1
fi

# Create skill directory
mkdir -p "$SKILL_DIR"

# Generate skill markdown
cat > "$SKILL_DIR/SKILL.md" <<EOF
---
name: $SKILL_NAME
description: Use when working on $WORKFLOW_TYPE workflows. Extracted from conversation analysis. Triggers: ${TRIGGER_SAMPLE:0:100}
---

# $(echo "$SKILL_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')

Auto-generated skill from conversation analysis on $(date +%Y-%m-%d).

## When to Use

- When working on $WORKFLOW_TYPE tasks
- When you need to repeat the pattern: "$TRIGGER_SAMPLE"
- When the workflow involves: $(echo "$TOP_TOOLS" | tr ';' ',')

## Pattern Analysis

This skill was extracted from analyzing $TOOL_CALLS recent tool calls.

**Repeated operations:**
$REPEATED_OPS

**Common tools:**
$(echo "$TOP_TOOLS" | tr ';' '\n' | sed 's/^/- /')

**Files typically modified:**
$FILE_MODS file(s)

## Implementation Steps

Based on the extracted pattern, the typical workflow is:

EOF

# Add step-by-step based on workflow type
case "$WORKFLOW_TYPE" in
  testing)
    cat >> "$SKILL_DIR/SKILL.md" <<'EOF'
1. Run tests: `Bash("timeout 120 Rscript -e 'devtools::test()'")`
2. Analyze failures: Read test output
3. Fix code: `Edit(R/file.R, old_string, new_string)`
4. Re-run tests: Verify fixes
5. Commit: Document changes
EOF
    ;;
  git-workflow)
    cat >> "$SKILL_DIR/SKILL.md" <<'EOF'
1. Check status: `git -C /path/to/repo status`
2. Stage changes: `git -C /path/to/repo add file`
3. Commit: `git -C /path/to/repo commit -m "message"`
4. Push: `git -C /path/to/repo push`

**Note:** Never use compound commands with `&&` — see `git-no-compound-cd` rule.
EOF
    ;;
  nix-environment)
    cat >> "$SKILL_DIR/SKILL.md" <<'EOF'
1. Check shell: `echo $IN_NIX_SHELL`
2. Verify packages: `nix-shell /path/to/default.nix --run "which R"`
3. Enter project shell: `nix-shell /path/to/project/default.nix --run "cmd"`
4. Regenerate if needed: `Rscript default.R` (via rix.setup shell)

**Note:** Always use absolute paths — see `nix-agent-shell-protocol` rule.
EOF
    ;;
  multi-file-edit)
    cat >> "$SKILL_DIR/SKILL.md" <<'EOF'
1. Read files: `Read(file_path)` for each file
2. Plan changes: Identify what needs to change and why
3. Edit sequentially: `Edit(file, old, new)` for each change
4. Verify: Check that changes are consistent across files
5. Test: Run relevant tests or checks
EOF
    ;;
  r-execution)
    cat >> "$SKILL_DIR/SKILL.md" <<'EOF'
1. Load package: `timeout 60 Rscript -e 'pkgload::load_all()'`
2. Run function: `timeout 60 Rscript -e 'my_function(args)'`
3. Check output: Verify results
4. Debug if needed: Add browser() or print statements

**Note:** NEVER use MCP btw_tool_run_r — see `btw-timeouts` rule.
EOF
    ;;
  *)
    cat >> "$SKILL_DIR/SKILL.md" <<'EOF'
1. [Step 1 — extract from analysis]
2. [Step 2 — extract from analysis]
3. [Step 3 — extract from analysis]

*Note: This is a generated template. Review and edit based on the actual pattern.*
EOF
    ;;
esac

# Add standard sections
cat >> "$SKILL_DIR/SKILL.md" <<EOF

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| [Add anti-patterns here] | [Reason] | [Correct approach] |

*TODO: Add forbidden patterns based on common mistakes in this workflow.*

## Verification

Run these commands to verify the workflow succeeded:

\`\`\`bash
# [Add verification commands based on workflow type]
\`\`\`

Expected output: [Describe success criteria]

## Related

- Skill: [related-skill-1]
- Rule: [related-rule-1]
- Command: [related-command]

*TODO: Add cross-references to related skills, rules, and commands.*

## Notes

This skill was auto-generated from conversation analysis. Review and refine:

1. Add concrete before/after examples
2. Fill in forbidden patterns with real anti-patterns
3. Add verification steps
4. Update related skills/rules/commands
5. Remove this notes section when complete

Generated: $(date +%Y-%m-%d)
Tool calls analyzed: $TOOL_CALLS
Workflow type: $WORKFLOW_TYPE
EOF

echo "✅ Skill created at $SKILL_DIR/SKILL.md"
echo ""

# Register in MANIFEST.md if not already present
if ! grep -q "^| $SKILL_NAME |" "$MANIFEST" 2>/dev/null; then
  # Find the last line before the ## Counts section
  LAST_LINE=$(grep -n "^## Counts" "$MANIFEST" | cut -d: -f1)
  if [ -z "$LAST_LINE" ]; then
    LAST_LINE=$(wc -l < "$MANIFEST")
  else
    LAST_LINE=$((LAST_LINE - 1))
  fi

  # Insert new entry
  # Determine category based on workflow type
  CATEGORY="Project Mgmt"
  case "$WORKFLOW_TYPE" in
    testing|r-execution) CATEGORY="R Package Dev" ;;
    git-workflow) CATEGORY="DevOps & CI" ;;
    nix-environment) CATEGORY="AI/LLM Tools" ;;
  esac

  # Create temporary file with new entry
  {
    head -n "$LAST_LINE" "$MANIFEST"
    echo "| $SKILL_NAME | $CATEGORY | workflow | beta | $(date +%Y-%m) | pending |"
    tail -n +"$((LAST_LINE + 1))" "$MANIFEST"
  } > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"

  echo "✅ Registered in MANIFEST.md (category: $CATEGORY, tier: workflow, maturity: beta)"
else
  echo "ℹ️  Already in MANIFEST.md"
fi

echo ""

# Run quality check
if [ -x "$QUALITY_HOOK" ]; then
  echo "🔍 Running quality check..."
  if "$QUALITY_HOOK" "$SKILL_DIR/SKILL.md"; then
    echo "✅ Quality check passed"
  else
    echo "⚠️  Quality check returned warnings — review and refine the skill"
  fi
else
  echo "ℹ️  Quality hook not found at $QUALITY_HOOK — skipping quality check"
fi

echo ""
echo "📝 Next steps:"
echo "  1. Review: Edit ~/.claude/skills/$SKILL_NAME/SKILL.md"
echo "  2. Add examples: Include before/after code snippets"
echo "  3. Add forbidden patterns: Document common mistakes"
echo "  4. Add verification: Describe how to test the skill"
echo "  5. Update MANIFEST: Change status to 'stable' when ready"
echo ""
echo "Test the skill by invoking it with: /use-skill $SKILL_NAME"
