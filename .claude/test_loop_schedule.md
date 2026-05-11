# /loop and /schedule Feature Validation

**Version tested:** Claude Code v2.1.138
**Date:** 2026-05-11
**Related issues:** #133, #134

## Feature Availability Status

| Feature | Available in v2.1.138 | Notes |
|---------|----------------------|-------|
| `--bare` | ✓ | Minimal mode: skips hooks, LSP, plugin sync, attribution, auto-memory |
| `--remote-control` | ✓ | Start interactive session with Remote Control enabled (optionally named) |
| `--effort` | ✓ | Effort levels: low, medium, high, xhigh, max |
| `/loop` | ✗ | Not found in `--help` output; may be a skill or future feature |
| `/schedule` | ✗ | Not found in `--help` output; may be a skill or future feature |
| `/btw` | ✗ | Not found in `--help` output; may be a skill or future feature |
| `/teleport` | ✗ | Not found in `--help` output; may be a skill or future feature |

**Conclusion:** The Boris Cherny thread features `/loop`, `/schedule`, `/btw`, and `/teleport` are NOT available in the current public release (v2.1.138). These may be:
- Internal/experimental features not yet released
- Features described aspirationally rather than as existing functionality
- Skills that need to be explicitly installed via plugins

The Stephen Turner blog features (`--bare`, `--effort`, `--remote-control`, PostToolUse hooks) ARE available and validated.

## Test Plan

### Phase 1: Basic /loop Functionality

**Test 1.1: Simple echo loop**
```
/loop 1m echo "Test at $(date)"
```
- **Expected:** Confirmation message with job ID
- **Verify:** Command runs every minute
- **Check:** How to view running loops? (`/schedule list`?)

**Test 1.2: R CMD check loop**
```
/loop 30m /check
```
- **Expected:** Runs `/check` skill every 30 minutes
- **Verify:** Check runs automatically, results logged
- **Duration:** Let run for 2 hours (4 executions)

**Test 1.3: ctx-check loop**
```
/loop 1h /ctx-check
```
- **Expected:** Hourly ctx.yaml verification
- **Verify:** Issues caught automatically

### Phase 2: /schedule Cron Patterns

**Test 2.1: Daily cleanup**
```
/schedule '0 9 * * *' /cleanup
```
- **Expected:** Runs at 9 AM daily
- **Verify:** Schedule confirms next run time

**Test 2.2: Weekday PR checks**
```
/schedule '0 9 * * 1-5' /pr-status
```
- **Expected:** Runs 9 AM Monday-Friday only
- **Verify:** Skips weekends

**Test 2.3: List scheduled jobs**
```
/schedule list
```
- **Expected:** Shows all active loops and schedules
- **Verify:** Job IDs, next run times, commands

### Phase 3: Loop Management

**Test 3.1: Stop a loop**
```
/schedule stop <job-id>
```
- **Expected:** Loop terminates
- **Verify:** No longer in `/schedule list`

**Test 3.2: Persistence across sessions**
- Start loop, end session, start new session
- **Expected:** Loop still running
- **Question:** Where are loops stored? Survive laptop restart?

### Phase 4: /btw Side Queries

**Test 4.1: Query during tar_make()**
```
# Start long pipeline
tar_make()

# In same session, while pipeline runs:
/btw "What's the current status?"
```
- **Expected:** Answer without interrupting pipeline
- **Verify:** Pipeline continues, /btw doesn't pollute main history

**Test 4.2: Multiple /btw queries**
```
/btw "How many tasks completed?"
/btw "Any errors so far?"
```
- **Expected:** Both answered independently
- **Verify:** Queries tracked separately from main conversation

### Phase 5: Remote Control

**Test 5.1: Enable remote control**
```
claude --remote-control
```
- **Expected:** Session accessible from mobile app
- **Verify:** Can view and interact from phone

**Test 5.2: Teleport cloud session**
```
# From mobile: start session
# From laptop:
/teleport
```
- **Expected:** Full history and context loaded locally
- **Verify:** Can continue work seamlessly

## Success Criteria

- [ ] /loop runs commands at specified intervals
- [ ] /schedule respects cron expressions
- [ ] Jobs persist across terminal sessions
- [ ] /schedule list shows all active jobs
- [ ] /btw doesn't interrupt main work
- [ ] Loops can be stopped cleanly
- [ ] Remote control enables mobile access

## Known Issues to Document

- Minimum /schedule interval: 1 hour (use /loop for shorter)
- Loop persistence: TBD (launchd integration?)
- Error handling: What happens if looped command fails?
- Resource usage: Does /loop spawn new processes or reuse?

## Integration Questions

1. **Should we replace launchd pulse scripts with /schedule?**
   - Current: `config_pulse.sh`, `knowledge_pulse.sh` via launchd
   - Alternative: `/schedule '0 9 * * *' /config-pulse`
   - Benefit: Centralized scheduling, visible in `/schedule list`

2. **How to monitor loop health?**
   - Logs location?
   - Notification on failure?
   - Integration with `session_stop.sh`?

3. **Budget implications**
   - Does each loop execution count against burn rate?
   - Should loops use `--model haiku` for cheaper runs?

## Next Steps

After validation:
1. Update #133 and #134 with test results
2. Add validated patterns to CLAUDE.md (already done)
3. Create loop-optimized skills (`/check-loop`, `/roborev-loop`)
4. Document loop management workflow
5. Integrate with burn rate monitoring
