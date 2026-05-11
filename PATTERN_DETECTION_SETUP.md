# Pattern Detection Setup (Option 4: Hybrid)

**Created**: 2026-05-11
**Status**: Ready to integrate
**Cost**: ~$0.01-0.03 per session

## What This Does

Automatically detects repeated workflows at session end and prompts you to run `/skillify` in the next session.

**Flow**:
1. At `/bye`, system analyzes tool call patterns using Opus API
2. Presents detected workflows with confidence levels
3. You decide whether to skillify in next session
4. If yes, `/hi` in next session auto-runs skillify

## Files Created

| File | Purpose |
|------|---------|
| `~/.claude/scripts/detect_patterns.sh` | AI pattern detection (Opus API) |
| `~/.claude/scripts/process_pending_skillify.sh` | Execute pending skillify at session start |
| `PATTERN_DETECTION_SETUP.md` | This file (integration guide) |

## Integration Steps

### Step 1: Add to `~/.claude/hooks/session_stop.sh`

Add this block **before the final "Session ended"** message:

```bash
# === Pattern Detection (Phase 1 Validation) ===
if [ -f "${HOME}/.claude/scripts/detect_patterns.sh" ]; then
    echo ""
    PATTERNS=$(${HOME}/.claude/scripts/detect_patterns.sh "$TRANSCRIPT" 2>&1)

    if echo "$PATTERNS" | grep -q "🔍 Detected workflow patterns"; then
        echo "$PATTERNS"
        echo ""
        read -p "Run /skillify in next session for these patterns? [Y/n] " -t 30 -n 1 -r || REPLY="n"
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            # Store transcript path and patterns
            echo "$TRANSCRIPT" > "${HOME}/.claude/.pending_skillify"
            echo "<!-- PATTERNS:" >> "${HOME}/.claude/.pending_skillify"
            echo "$PATTERNS" | sed -n '/<!-- JSON_START/,/JSON_END -->/p' >> "${HOME}/.claude/.pending_skillify"
            echo "-->" >> "${HOME}/.claude/.pending_skillify"

            echo "✓ Will run /skillify on next session start"
        else
            echo "⊘ Skipped pattern capture"
        fi
    else
        echo "$PATTERNS"
    fi
fi
```

### Step 2: Add to `~/.claude/hooks/session_init.sh`

Add this block **after Phase 1 (environment check)**, before Phase 2:

```bash
# === Process Pending Skillify (Phase 1 Validation) ===
if [ -f "${HOME}/.claude/.pending_skillify" ]; then
    ${HOME}/.claude/scripts/process_pending_skillify.sh
fi
```

### Step 3: Verify API Key

Ensure `ANTHROPIC_API_KEY` is in your environment:

```bash
# Check
echo $ANTHROPIC_API_KEY

# If not set, add to ~/.claude/.env or shell profile
echo "export ANTHROPIC_API_KEY=your_key_here" >> ~/.claude/.env
```

### Step 4: Test

```bash
# Start a session, do some repetitive work (3+ tool calls repeated 2+ times)
# At session end, run /bye
# Should see pattern detection output

# Example output:
# 🔍 Detected workflow patterns:
#
#   3× git-pr-workflow [HIGH confidence]
#      Steps: Bash → Edit → Bash → Bash
#      → Consistent git branch → edit → commit → push sequence
#
# Run /skillify in next session for these patterns? [Y/n]
```

## Configuration

### Disable Pattern Detection

Comment out the integration blocks in hooks, or:

```bash
# Temporarily disable
mv ~/.claude/scripts/detect_patterns.sh ~/.claude/scripts/detect_patterns.sh.disabled
```

### Adjust Confidence Threshold

Edit `detect_patterns.sh` line with prompt:
- Current: Reports MEDIUM and HIGH confidence
- More aggressive: Report LOW, MEDIUM, HIGH (more suggestions, more noise)
- More conservative: Report only HIGH (fewer suggestions, less noise)

## Cost Management

- **Per-session cost**: ~$0.01 (single Opus API call)
- **Monthly cost** (20 sessions/month): ~$0.20
- **Budget cap**: Set `PATTERN_DETECTION_BUDGET=5` in `.env` to limit to $5/month

To track costs:

```bash
# Count pattern detections this month
grep "Detected workflow patterns" ~/.claude/logs/session_*.log | wc -l
# Multiply by $0.01
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "ANTHROPIC_API_KEY not set" | Add to ~/.claude/.env |
| "No patterns detected" every session | Session too short (<10 tool calls) or no repetition |
| API timeout | Increase timeout in detect_patterns.sh curl call |
| JSON parse error | Check Opus API response format, may need prompt adjustment |

## Rollback

To remove pattern detection:

```bash
# 1. Remove integration from hooks (reverse Step 1 & 2)
# 2. Delete scripts
rm ~/.claude/scripts/detect_patterns.sh
rm ~/.claude/scripts/process_pending_skillify.sh
rm ~/.claude/.pending_skillify  # if exists
```

## Next Steps

After 2-3 weeks of use:
1. Review pattern detection accuracy (false positive rate)
2. Tune confidence threshold if needed
3. Consider adding auto-logging when skill is generated
4. Evaluate whether to keep or simplify based on value

## Related

- #137 Phase 1 validation
- PHASE1_VALIDATION.md (Option 3 baseline)
- `/skillify` command
- `skill_usage_tracker.sh`
