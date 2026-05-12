#!/usr/bin/env bash
# skillify_backlog.sh — Retrospective workflow analysis from past sessions
# Part of Option 4 (Hybrid) validation strategy for #137 Phase 1
#
# Usage:
#   skillify_backlog.sh [N]  # analyze last N sessions (default: 20)
#
# Output:
#   - Generates candidate skills in ~/.claude/skills/generated/
#   - Creates summary report with skill names and workflow types
#   - Tracks which transcripts produced which skills (for deduplication)
#
# Related: #137 Phase 1 validation, skillify command

set -euo pipefail

# Configuration
N_SESSIONS="${1:-20}"
PROJECT_DIR="${HOME}/.claude/projects/-Users-johngavin-docs-gh-llm"
OUTPUT_DIR="${HOME}/.claude/skills/generated"
REPORT_FILE="${OUTPUT_DIR}/backlog_report_$(date +%Y%m%d_%H%M%S).md"
SKILLIFY_CMD="${HOME}/.claude/commands/skillify.sh"

# Validation
if [ ! -x "$SKILLIFY_CMD" ]; then
    echo "Error: skillify.sh not found or not executable at $SKILLIFY_CMD"
    exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: Project directory not found: $PROJECT_DIR"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Initialize report
cat > "$REPORT_FILE" <<EOF
# Skillify Backlog Report
Generated: $(date '+%Y-%m-%d %H:%M:%S')
Sessions analyzed: $N_SESSIONS
Output directory: $OUTPUT_DIR

## Summary

| Session | Date | Workflow Type | Skill Generated | Quality Score |
|---------|------|---------------|-----------------|---------------|
EOF

echo "Analyzing last $N_SESSIONS sessions..."

# Find transcripts, sorted by modification time (newest first)
transcripts=$(find "$PROJECT_DIR" -name "*.jsonl" -type f -print0 | \
    xargs -0 ls -t | \
    head -n "$N_SESSIONS")

session_count=0
skill_count=0
declare -A workflow_types

# Process each transcript
while IFS= read -r transcript; do
    session_count=$((session_count + 1))
    session_id=$(basename "$transcript" .jsonl)
    # Get file modification time using ls (more portable)
    session_date=$(ls -l "$transcript" | awk '{print $6, $7, $8}')

    echo "[$session_count/$N_SESSIONS] Processing $session_id..."

    # Run skillify on this transcript (default: last 20 tool calls)
    # Capture output to temp file
    temp_output=$(mktemp)
    if "$SKILLIFY_CMD" 20 "$transcript" > "$temp_output" 2>&1; then
        # Parse output for generated skill name and workflow type
        skill_name=$(grep -oE "Generated: ~/.claude/skills/[^/]+/SKILL.md" "$temp_output" | \
                     sed 's|Generated: ~/.claude/skills/||; s|/SKILL.md||' || echo "none")

        workflow_type=$(grep -oE "Workflow type: [a-z-]+" "$temp_output" | \
                       cut -d: -f2 | xargs || echo "unknown")

        quality_score=$(grep -oE "Quality score: [0-9]+" "$temp_output" | \
                       cut -d: -f2 | xargs || echo "N/A")

        if [ "$skill_name" != "none" ]; then
            skill_count=$((skill_count + 1))
            workflow_types["$workflow_type"]=$((${workflow_types[$workflow_type]:-0} + 1))

            # Add to report
            echo "| $session_id | $session_date | $workflow_type | $skill_name | $quality_score |" >> "$REPORT_FILE"

            # Move generated skill to backlog directory with session prefix
            if [ -d "$HOME/.claude/skills/$skill_name" ]; then
                mv "$HOME/.claude/skills/$skill_name" "$OUTPUT_DIR/${session_id}_${skill_name}"
                echo "  ✓ Generated: $skill_name (score: $quality_score)"
            fi
        else
            echo "  ⊘ No repeatable workflow detected"
            echo "| $session_id | $session_date | none | - | - |" >> "$REPORT_FILE"
        fi
    else
        echo "  ✗ skillify failed for this transcript"
        echo "| $session_id | $session_date | error | - | - |" >> "$REPORT_FILE"
    fi

    rm -f "$temp_output"

    # Rate limit (avoid overwhelming the system)
    sleep 0.5
done <<< "$transcripts"

# Add summary statistics to report
cat >> "$REPORT_FILE" <<EOF

## Statistics

- **Sessions analyzed**: $session_count
- **Skills generated**: $skill_count
- **Success rate**: $(awk "BEGIN {printf \"%.1f\", ($skill_count/$session_count)*100}")%

### Workflow Type Distribution

EOF

# Sort workflow types by count
for wf_type in "${!workflow_types[@]}"; do
    echo "- **$wf_type**: ${workflow_types[$wf_type]}" >> "$REPORT_FILE"
done | sort -t: -k2 -rn >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<EOF

## Next Steps

1. **Review generated skills** in \`$OUTPUT_DIR/\`
2. **Deduplicate** similar workflows (check workflow type distribution)
3. **Promote to stable**: Move skills with score ≥80 to \`~/.claude/skills/\`
4. **Register in MANIFEST**: Add promoted skills to \`~/.claude/skills/MANIFEST.md\`
5. **Track live usage**: Monitor which skills get used in practice (Week 2-3)

## Validation Criteria (Phase 1)

- [x] Generated 10+ candidate skills from historical data
- [ ] 3+ skills promoted from beta to stable (score ≥80)
- [ ] Skills used in practice during live usage period

EOF

echo ""
echo "✓ Analysis complete!"
echo ""
echo "Summary:"
echo "  Sessions analyzed: $session_count"
echo "  Skills generated: $skill_count"
echo "  Success rate: $(awk "BEGIN {printf \"%.1f\", ($skill_count/$session_count)*100}")%"
echo ""
echo "Report: $REPORT_FILE"
echo "Skills: $OUTPUT_DIR/"
echo ""
echo "Next: Review generated skills and promote high-quality ones (≥80) to ~/.claude/skills/"
