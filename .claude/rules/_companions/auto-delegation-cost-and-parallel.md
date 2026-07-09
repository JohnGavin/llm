# Companion: Auto-Delegation — Context Summarisation + Parallel Worktree Sessions

Illustrative/edge-case detail split out of the always-loaded [`auto-delegation`](../auto-delegation.md) rule. The normative tier model, delegation tables, burn-rate escalation table, and `isolation:"worktree"` mandate stay in the rule; these two example-driven sections load on demand.

## Lightweight Tier for Context Summarisation (Cost Compression)

When `context_monitor.sh` reports ≥ 65% context usage, or before a loop expected to exceed 20 turns, **the orchestrator tier decides to delegate** the summarisation of `CURRENT_WORK.md` to the lightweight tier. This is a deliberate delegation decision by the orchestrator — it is not the lightweight tier autonomously writing session state. The orchestrator determines what to summarise and when; the lightweight tier executes the write:

```
Agent(
  subagent_type = "quick-fix",
  model = "haiku",  # lightweight tier
  prompt = "Read CURRENT_WORK.md and the recent conversation state. Write a concise prose summary (max 300 words) of: (1) what was accomplished this session, (2) key decisions made and why, (3) exact next step. Overwrite CURRENT_WORK.md with this summary. No preamble."
)
```

Triggers: context ≥ 65%, starting a `/loop`, or spawning 3+ sequential subagents. Do NOT trigger when context < 40% or during active debugging. The orchestrator tier retains ownership of CURRENT_WORK.md; the lightweight tier is a delegate writer, not an autonomous updater.

## Parallel Worktree Sessions

For independent tasks, spawn a worker-tier worktree session:

```bash
# Orchestrator creates worktree for delegated work
git worktree add ../<repo>-<task> feat/<task>
# User runs: cd ../<repo>-<task> && claude --model sonnet
```

Worktrees share `.git` and `.claude/` config. Each gets its own branch.
Use `tar_config_set(store = "_targets_<branch>")` to isolate targets stores.
