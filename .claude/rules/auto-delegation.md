---
description: Auto-delegate to cheaper models when trigger patterns match
---
# Rule: Auto-Delegation to Cheaper Models

## When This Applies
Every orchestrator decision about whether to do work directly or delegate.

## CRITICAL: Do Not Use Opus for Haiku-Level Work

If ALL of these are true, MUST use `quick-fix` agent (haiku):
- Single file affected
- Fewer than 5 lines changed
- No reasoning about correctness needed (typo, rename, version bump, URL fix)
- No test verification required after the change

```
Agent(subagent_type="quick-fix", model="haiku",
      prompt="In <file>, change <old> to <new>. Reason: <why>")
```

## CRITICAL: Do Not Use Opus for Sonnet-Level Work

If the task matches a named agent's trigger, MUST delegate:

| Signal in user request | Agent |
|------------------------|-------|
| "run tests", "fix test failure" | `r-debugger` |
| "review this PR/code" | `reviewer` |
| "nix shell broken", "package missing" | `nix-env` |
| "pipeline failed", "tar_make", "build targets" | `targets-runner` (wraps in `nix develop --command` for T lang projects) |
| "shinylive", "WASM build" | `shinylive-builder` |
| "async", "ExtendedTask", "crew bug" | `shiny-async-debugger` |
| "validate data", "pointblank" | `data-quality-guardian` |
| "dbt", "SQL pipeline" | `data-engineer` |
| "review for issues" (read-only) | `critic` |
| "apply fixes from report" | `fixer` |
| "compile wiki from raw" | `wiki-curator` |

## Keep in Opus (Do NOT Delegate)

- Multi-file architecture decisions
- Plan creation requiring user dialogue
- Synthesising results from multiple agents
- Memory/config updates
- Ambiguous requirements needing clarification

## Burn-Rate-Aware Escalation

When `burn_rate_check.sh` reports WARN or CRITICAL:

| Severity | Orchestrator action |
|----------|---------------------|
| WARN | Prefer sonnet agents. Use haiku for all single-file edits. Defer speculative exploration. |
| CRITICAL | Opus for user dialogue only. ALL code work via sonnet/haiku agents. Suggest worktree: `git worktree add ../<repo>-sonnet feat/<task> && cd ../<repo>-sonnet && claude --model sonnet` |

## Parallel Worktree Sessions

For independent tasks, spawn a sonnet-only worktree session:

```bash
# Orchestrator creates worktree for delegated work
git worktree add ../<repo>-<task> feat/<task>
# User runs: cd ../<repo>-<task> && claude --model sonnet
```

Worktrees share `.git` and `.claude/` config. Each gets its own branch.
Use `tar_config_set(store = "_targets_<branch>")` to isolate targets stores.
