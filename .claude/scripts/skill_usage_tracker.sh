#!/usr/bin/env bash
# skill_usage_tracker.sh — Track skill usage for Phase 1 validation
# Part of Option 4 (Hybrid) validation strategy
#
# Usage:
#   skill_usage_tracker.sh log <skill_name>      # log usage
#   skill_usage_tracker.sh report                 # generate usage report
#   skill_usage_tracker.sh stats                  # quick stats
#
# Called by: Skills can self-report usage via this script
# Data: Stored in ~/.claude/logs/skill_usage.log
#
# Related: #137 Phase 1 validation

set -euo pipefail

ACTION="${1:-}"
LOG_FILE="${HOME}/.claude/logs/skill_usage.log"
GENERATED_DIR="${HOME}/.claude/skills/generated"

# Ensure log file exists
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

case "$ACTION" in
    log)
        SKILL_NAME="${2:-unknown}"
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"

        echo "$TIMESTAMP|$SKILL_NAME|$SESSION_ID" >> "$LOG_FILE"
        echo "✓ Logged usage: $SKILL_NAME" >&2
        ;;

    report)
        REPORT_FILE="${HOME}/.claude/skills/generated/usage_report_$(date +%Y%m%d_%H%M%S).md"

        cat > "$REPORT_FILE" <<EOF
# Skill Usage Report (Phase 1 Validation)
Generated: $(date '+%Y-%m-%d %H:%M:%S')

## Usage Summary

| Skill | Usage Count | First Used | Last Used | Status |
|-------|-------------|------------|-----------|--------|
EOF

        # Parse log and aggregate by skill
        awk -F'|' '{
            skill = $2
            timestamp = $1
            count[skill]++
            if (first[skill] == "" || timestamp < first[skill]) first[skill] = timestamp
            if (last[skill] == "" || timestamp > last[skill]) last[skill] = timestamp
        }
        END {
            for (skill in count) {
                # Determine status based on usage
                status = "beta"
                if (count[skill] >= 3) status = "candidate for stable"
                if (count[skill] >= 5) status = "promote to stable"
                printf "| %s | %d | %s | %s | %s |\n", skill, count[skill], first[skill], last[skill], status
            }
        }' "$LOG_FILE" | sort -t'|' -k2 -rn >> "$REPORT_FILE"

        cat >> "$REPORT_FILE" <<EOF

## Validation Criteria

- **Target**: 3+ skills promoted from beta to stable
- **Threshold**: ≥3 uses + quality score ≥80

### Candidates for Promotion

EOF

        # List skills with ≥3 uses
        awk -F'|' '{count[$2]++} END {for (s in count) if (count[s] >= 3) print "- " s " (" count[s] " uses)"}' "$LOG_FILE" | \
            sort >> "$REPORT_FILE"

        cat >> "$REPORT_FILE" <<EOF

## Next Steps

1. Review candidate skills (≥3 uses)
2. Verify quality scores ≥80
3. Move from \`~/.claude/skills/generated/\` to \`~/.claude/skills/\`
4. Update MANIFEST.md maturity from beta to stable
5. Document in CHANGELOG.md

EOF

        echo "Report generated: $REPORT_FILE"
        cat "$REPORT_FILE"
        ;;

    stats)
        if [ ! -s "$LOG_FILE" ]; then
            echo "No skill usage logged yet"
            exit 0
        fi

        echo "Skill Usage Statistics"
        echo "======================"
        echo ""
        echo "Total uses: $(wc -l < "$LOG_FILE" | xargs)"
        echo "Unique skills: $(cut -d'|' -f2 "$LOG_FILE" | sort -u | wc -l | xargs)"
        echo ""
        echo "Top 5 most-used skills:"
        cut -d'|' -f2 "$LOG_FILE" | sort | uniq -c | sort -rn | head -5 | \
            awk '{printf "  %2d uses: %s\n", $1, $2}'
        echo ""
        echo "Skills ready for promotion (≥3 uses):"
        cut -d'|' -f2 "$LOG_FILE" | sort | uniq -c | sort -rn | \
            awk '$1 >= 3 {printf "  ✓ %s (%d uses)\n", $2, $1}'
        ;;

    *)
        echo "Usage: skill_usage_tracker.sh {log|report|stats} [skill_name]"
        echo ""
        echo "Commands:"
        echo "  log <skill_name>  - Log a skill usage"
        echo "  report            - Generate full usage report"
        echo "  stats             - Show quick statistics"
        exit 1
        ;;
esac
