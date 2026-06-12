---
description: Quadratic context growth in agentic loops — estimate per-loop budget and compress context before /loop or /schedule runs exceeding 10 turns
paths:
  - ".claude/scripts/burn_rate*"
---

# Rule: Quadratic Agentic Loop Cost Guard

## Source

MachineLearningMastery.com — "Implementing Prompt Compression to Reduce Agentic Loop Costs". Core finding: agentic loops accumulate context quadratically (O(n²)), not linearly — each step re-sends all prior context. A 60-turn loop at 100k context/turn costs ~15× more than 60 turns at 10k context/turn.

## When This Applies

Any `/loop`, `/schedule`, or multi-step agent run exceeding 10 tool calls in a single session context.

## CRITICAL: Context Grows Quadratically in Loops

```
Turn 1: sends  1k tokens
Turn 2: sends  2k tokens (all prior + new)
Turn 3: sends  4k tokens
...
Turn N: sends  N×avg_tokens tokens
Total:  N²/2 × avg_tokens  ← quadratic
```

A loop that looks cheap per-turn becomes expensive across turns. Your weekly burn cap (`CLAUDE_WEEKLY_CAP_USD`) catches cumulative overrun but NOT a single runaway loop within a session.

## Per-Loop Budget Guard

Before starting any automated loop or long agent run, estimate:

```
budget_usd = (expected_turns × avg_context_k × turns/2) × price_per_Mtok / 1e6
```

For claude-sonnet-4-6 at ~$3/Mtok input:
- 20 turns × 50k avg context = 20×50k×10 = 10M tokens → ~$30
- 50 turns × 80k avg context = 50×80k×25 = 100M tokens → ~$300

**If estimated cost > $20: compress context before starting the loop.**

## Mandatory Compression Before Long Loops

When `context_monitor.sh` reports ≥ 65% OR before spawning a loop expected to exceed 20 turns:

1. Write a prose session summary to `CURRENT_WORK.md` (via haiku agent or manual)
2. Run `/compact` to flush accumulated context
3. Restore from `CURRENT_WORK.md` summary
4. Start the loop in a fresh context window

This converts O(n²) to O(n) by resetting the baseline before the loop begins.

## Burn Rate Check Frequency

`context_monitor.sh` checks burn rate every 20 tool calls. For loops running faster than this:

- Add explicit `~/.claude/scripts/burn_rate_check.sh` call inside the loop skill
- Or run loop via `/schedule` (each scheduled invocation gets a fresh context)

## Anti-Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `/loop 5m /babysit` with 100k context window already full | Each iteration re-sends full history | Compact before starting loop |
| Long agent chain with no intermediate compaction | Quadratic cost accumulates silently | Check burn_rate every 10 turns |
| Spawning sub-agents with full orchestrator context in prompt | Each agent gets all prior context | Summarise → pass summary to subagent |

## Related

- `context_monitor.sh` hook — per-tool-call context % warnings
- `context_survival.sh` hook — PreCompact save/restore
- `auto-delegation` rule — haiku-for-summarisation trigger
- `btw-timeouts` rule — prevents session hangs during loops
