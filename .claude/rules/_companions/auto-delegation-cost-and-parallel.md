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

## Sections Moved from the Rule Body (2026-07-29 line-limit pass, llm#749)

### Model Tier Lookup — maintenance note

> **This table is the single source of truth for model IDs.** All prose in this rule uses tier names. Update only this table when Anthropic releases new models — nothing else in this rule needs to change.
> <!-- current as of 2026-06; verify at https://docs.anthropic.com/en/docs/models-overview -->

### Orchestrator-Tier Role — Clarification

> **Clarification:** "delegate code/script edits" does NOT mean the orchestrator tier never uses Edit/Write. It DOES use Edit/Write directly for the bounded exceptions listed below (prose files, memory, rules, CHANGELOG, CURRENT_WORK.md). The constraint is on code-level edits to the package source tree, not on all file writes.

### Three-tier model

- **Orchestrator tier:** plan + decompose + synthesise + prose exceptions above
- **Worker tier:** all multi-step edits, new files, complex content
- **Lightweight tier:** single-file edits, doc updates, version bumps

### Do Not Use Orchestrator Tier for Lightweight Work — dispatch example

```
Agent(subagent_type="quick-fix", model="haiku",  # lightweight tier
      prompt="In <file>, change <old> to <new>. Reason: <why>")
```

### quick-fix tool-limitation note

> **Lightweight-tier (`quick-fix`) tool limitation:** the quick-fix agent has Read, Grep, Glob, Edit — but NO Bash. It cannot `git commit`, `git push`, `gh pr create`, or `roborev close`. Dispatching quick-fix for tasks that require any of these is a dispatch error — use fixer (worker tier) instead. Documented to prevent the recurrence pattern from #223.
