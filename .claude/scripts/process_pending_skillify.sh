#!/usr/bin/env bash
# process_pending_skillify.sh — Execute pending skillify from previous session
# Called by session_init.sh when .pending_skillify flag exists
#
# Related: #137 Phase 1 validation, detect_patterns.sh

set -euo pipefail

PENDING_FILE="${HOME}/.claude/.pending_skillify"

if [ ! -f "$PENDING_FILE" ]; then
    exit 0
fi

# Read transcript path and patterns
TRANSCRIPT=$(head -1 "$PENDING_FILE")
SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)

if [ ! -f "$TRANSCRIPT" ]; then
    echo "⚠️  Pending transcript not found: $TRANSCRIPT"
    rm -f "$PENDING_FILE"
    exit 0
fi

echo ""
echo "📊 Processing patterns from previous session: $SESSION_ID"
echo ""

# Extract stored patterns (if any)
if grep -q "<!-- PATTERNS:" "$PENDING_FILE"; then
    PATTERNS=$(sed -n '/<!-- PATTERNS:/,/-->/p' "$PENDING_FILE" | sed '1d;$d')
    echo "Detected patterns:"
    echo "$PATTERNS"
    echo ""
fi

# Run skillify on the transcript
echo "Running /skillify on session..."
SKILLIFY_CMD="${HOME}/.claude/commands/skillify.sh"

if [ ! -x "$SKILLIFY_CMD" ]; then
    echo "⚠️  skillify.sh not found"
    rm -f "$PENDING_FILE"
    exit 0
fi

# Execute skillify
if "$SKILLIFY_CMD" 20 "$TRANSCRIPT"; then
    echo ""
    echo "✓ Skillify completed"

    # Log usage if skill was generated
    if [ -f "/tmp/skillify_last_generated.txt" ]; then
        SKILL_NAME=$(cat /tmp/skillify_last_generated.txt)
        if [ -n "$SKILL_NAME" ]; then
            "${HOME}/.claude/scripts/skill_usage_tracker.sh" log "$SKILL_NAME" 2>/dev/null || true
            echo "✓ Logged usage: $SKILL_NAME"
        fi
        rm -f /tmp/skillify_last_generated.txt
    fi
else
    echo ""
    echo "⚠️  Skillify failed or no pattern detected"
fi

# Clean up
rm -f "$PENDING_FILE"
echo ""
