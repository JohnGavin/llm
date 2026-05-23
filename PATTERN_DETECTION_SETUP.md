# Pattern Detection Setup (Option 4: Hybrid)

<!-- Roborev closure: #801 resolved in commit 9e8f030 (PR #166 — fix(hooks): gate
     pattern detection to /bye only).
     Original finding: guide said wire detect_patterns.sh into session_stop.sh "as if
     it runs only at /bye", but the Stop hook fires after every Claude response, so
     a bare integration would incur a paid Opus API call after every reply.
     Fix: sentinel-file gate documented and implemented. /bye command writes
     ~/.claude/.bye-requested; session_stop.sh checks for that sentinel and deletes it
     immediately (one-shot) before invoking detect_patterns.sh. Normal replies produce
     zero cost because the sentinel is absent. This guide now includes the IMPORTANT
     warning block and the correct sentinel-gated code block under Step 1. -->

**Created**: 2026-05-11
**Status**: Integrated
**Cost**: ~$0.01-0.03 per /bye invocation (zero cost on normal replies)

## What This Does

Automatically detects repeated workflows when you run `/bye` and schedules `/skillify`
for the next session if patterns are found.

**Flow**:
1. You run `/bye` — the command writes `~/.claude/.bye-requested` (sentinel file)
2. The Stop hook fires; it checks for the sentinel and deletes it (one-shot)
3. Pattern detection runs (Opus API call) only because the sentinel was present
4. If patterns found, `/hi` in next session auto-runs skillify

**IMPORTANT — Stop fires on every reply, not only /bye.**
The sentinel-file gate is mandatory: without it, pattern detection (a paid Opus
API call) would run after every single Claude response, causing massive cost
regression. Only the `/bye` command writes the sentinel, so only /bye triggers
detection.

## Files Created

| File | Purpose |
|------|---------|
| `~/.claude/scripts/detect_patterns.sh` | AI pattern detection (Opus API) |
| `~/.claude/scripts/process_pending_skillify.sh` | Execute pending skillify at session start |
| `PATTERN_DETECTION_SETUP.md` | This file (integration guide) |

## Integration Steps

### Step 1: session_stop.sh — already integrated with sentinel gate

The block below is already in `~/.claude/hooks/session_stop.sh`. Do **not** use
the old pattern (bare `if detect_patterns.sh` without sentinel check) — that runs
on every reply and incurs an Opus API call each time.

```bash
# === Pattern Detection — gated on /bye sentinel ===
# The Stop hook fires after every Claude response, not only /bye.
# We gate on ~/.claude/.bye-requested written by the /bye command.
# The sentinel is deleted immediately (one-shot) to avoid stale triggers.
_BYE_SENTINEL="${HOME}/.claude/.bye-requested"
if [ -f "$_BYE_SENTINEL" ] && [ -f "${HOME}/.claude/scripts/detect_patterns.sh" ]; then
  rm -f "$_BYE_SENTINEL"  # consume sentinel immediately — one-shot
  TRANSCRIPT=$(ls -t "${HOME}/.claude/projects/"*/*.jsonl 2>/dev/null | head -1)
  if [ -n "$TRANSCRIPT" ]; then
    PATTERNS=$(timeout 30 "${HOME}/.claude/scripts/detect_patterns.sh" "$TRANSCRIPT" 2>&1) || PATTERNS=""
    if echo "$PATTERNS" | grep -q "Detected workflow patterns"; then
      echo ""
      echo "$PATTERNS"
      echo ""
      # No interactive read — hooks run non-interactively; auto-schedule skillify.
      echo "$TRANSCRIPT" > "${HOME}/.claude/.pending_skillify"
      echo "✓ Patterns detected — /skillify will run at next session start."
    fi
  fi
fi
```

### Step 1b: /bye command — already integrated

The `/bye` (session-end) command writes the sentinel before the hook fires.
This is already in `~/.claude/commands/session-end.md`:

```bash
# Written by /bye before doing anything else:
touch ~/.claude/.bye-requested
```

If you add a new alias for /bye, add the same `touch` to that alias's first step.

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
# At session end, run /bye (NOT just ending the session — must run the /bye command)
# Should see pattern detection output only when /bye was used

# Expected output when patterns found:
# 🔍 Detected workflow patterns:
#
#   3× git-pr-workflow [HIGH confidence]
#      Steps: Bash → Edit → Bash → Bash
#      → Consistent git branch → edit → commit → push sequence
#
# ✓ Patterns detected — /skillify will run at next session start.

# Verify no output on normal replies (sentinel absent):
# ls ~/.claude/.bye-requested  # should NOT exist between /bye invocations
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
