#!/usr/bin/env bash
# detect_patterns.sh — AI-powered workflow pattern detection
# Analyzes session transcript to identify repeated workflows worth skillifying
#
# Usage:
#   detect_patterns.sh <transcript_path>
#
# Output: JSON with detected patterns, confidence levels, and explanations
#
# Cost: ~$0.01 per session analysis (Opus API)
# Related: #137 Phase 1 validation, Option 4 (Hybrid)

set -euo pipefail

TRANSCRIPT="${1:-}"

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    echo "Error: Transcript file required" >&2
    exit 1
fi

# Check for API key
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Error: ANTHROPIC_API_KEY not set" >&2
    exit 1
fi

# Extract tool call summary from transcript (last 50 tool calls)
TOOL_SUMMARY=$(python3 - "$TRANSCRIPT" <<'PYTHON'
import json
import sys
from collections import Counter

transcript_path = sys.argv[1]
tool_calls = []

with open(transcript_path, 'r') as f:
    for line in f:
        try:
            event = json.loads(line)
            if event.get('type') == 'tool_call_result':
                data = event.get('data', {})
                tool_calls.append({
                    'tool': data.get('tool_name', 'unknown'),
                    'description': data.get('params', {}).get('description', '')
                })
        except:
            continue

# Take last 50 tool calls
recent_calls = tool_calls[-50:] if len(tool_calls) > 50 else tool_calls

# Format as readable summary
if len(recent_calls) < 3:
    print("Insufficient tool calls (<3)")
    sys.exit(0)

output = []
for i, call in enumerate(recent_calls, 1):
    desc = call['description'][:80] if call['description'] else '(no description)'
    output.append(f"{i}. {call['tool']}: {desc}")

print('\n'.join(output))
PYTHON
)

if [ "$TOOL_SUMMARY" = "Insufficient tool calls (<3)" ]; then
    echo "⊘ No patterns detected (insufficient tool calls)"
    exit 0
fi

# Call Opus API for pattern analysis
ANALYSIS=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d @- <<EOF
{
    "model": "claude-opus-4-5-20251101",
    "max_tokens": 2048,
    "messages": [
        {
            "role": "user",
            "content": "Analyze this tool call sequence from a development session. Identify repeated workflows (patterns of 3+ consecutive tool calls that appear 2+ times). For each pattern, provide:

1. **workflow_name** (short kebab-case identifier)
2. **confidence** (HIGH/MEDIUM/LOW based on repetition and semantic coherence)
3. **repetitions** (how many times this exact sequence appeared)
4. **steps** (array of tool names in the workflow)
5. **explanation** (1-2 sentences: why this is worth capturing as a skill)

Only report patterns with confidence MEDIUM or HIGH. Ignore single tool calls or random sequences.

Format response as JSON array:
\`\`\`json
[
  {
    \"workflow_name\": \"git-pr-workflow\",
    \"confidence\": \"HIGH\",
    \"repetitions\": 3,
    \"steps\": [\"Bash\", \"Edit\", \"Bash\", \"Bash\"],
    \"explanation\": \"Consistent git branch → edit → commit → push → PR creation sequence, repeated 3 times with same tool pattern.\"
  }
]
\`\`\`

Tool call sequence:
$TOOL_SUMMARY"
        }
    ]
}
EOF
)

# Extract content from API response
PATTERNS=$(echo "$ANALYSIS" | jq -r '.content[0].text // ""')

if [ -z "$PATTERNS" ] || [ "$PATTERNS" = "null" ]; then
    echo "⊘ No patterns detected (API returned empty)"
    exit 0
fi

# Extract JSON from potential markdown code block
PATTERNS_JSON=$(echo "$PATTERNS" | sed -n '/```json/,/```/p' | sed '1d;$d')

if [ -z "$PATTERNS_JSON" ]; then
    # Try without markdown wrapper
    PATTERNS_JSON="$PATTERNS"
fi

# Validate JSON
if ! echo "$PATTERNS_JSON" | jq empty 2>/dev/null; then
    echo "⊘ No patterns detected (invalid JSON response)"
    exit 0
fi

# Check if empty array
PATTERN_COUNT=$(echo "$PATTERNS_JSON" | jq 'length')
if [ "$PATTERN_COUNT" -eq 0 ]; then
    echo "⊘ No patterns detected"
    exit 0
fi

# Format output for user
echo ""
echo "🔍 Detected workflow patterns:"
echo ""

echo "$PATTERNS_JSON" | jq -r '.[] |
"  \(.repetitions)× \(.workflow_name) [\(.confidence) confidence]
     Steps: \(.steps | join(" → "))
     → \(.explanation)
"'

# Return JSON for programmatic use
echo ""
echo "<!-- JSON_START"
echo "$PATTERNS_JSON"
echo "JSON_END -->"
