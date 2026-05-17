---
description: Auto-delegate to cheaper models when trigger patterns match
---
# Rule: Auto-Delegation to Cheaper Models

## When This Applies
Every orchestrator decision about whether to do work directly or delegate.

## CRITICAL: Opus Role — Plan, Decompose, Synthesise (+ bounded prose exceptions)

**Default rule:** opus delegates all code, script, and configuration edits to subagents. This includes everything under `R/`, `inst/`, `tests/`, `vignettes/`, `.github/`, `default.R`, `default.nix`, shell scripts in `.claude/scripts/` and `.claude/hooks/`, and any new file in the package source tree.

| Work type | Delegate to |
|-----------|-------------|
| Single-file edits, doc updates, version bumps | `quick-fix` (haiku) |
| Multi-step implementations, new files, complex content | `fixer` (sonnet) |
| Code review | `reviewer` (sonnet) |
| Bug fixing | `r-debugger` (sonnet) |

### Bounded exceptions — opus MAY use Edit/Write/Bash directly for

Opus retains write access for these — they are too small/dialog-driven to be worth the round-trip cost of a subagent, AND they don't benefit from sonnet's deeper code reasoning:

| Path | Scope |
|------|-------|
| `~/.claude/CLAUDE.md`, `.claude/CLAUDE.md` | Prose updates only (rule wording, table edits) |
| `.claude/rules/*.md`, `.claude/memory/*.md` | Prose edits to existing rules and memory files; new rule creation OK |
| `.claude/CURRENT_WORK.md`, `CHANGELOG.md` (session-end append) | Session state and changelog entries |
| Roborev DB closure comments via `/usr/local/bin/roborev comment`/`close` | Triage actions, not code |
| Read-only investigation: `Read`, `Grep`, `Glob`, `Bash` for queries (`git log`, `gh pr view`, `du`, SQL reads) | Pre-decomposition reconnaissance |

What "prose edit" means: text/markdown content where no code parses or executes from the change. Editing a shell snippet inside a markdown code fence is NOT a prose edit — delegate that to a subagent so the snippet is actually tested.

### Three-tier model
- **Opus:** plan + decompose + synthesise + prose exceptions above
- **Sonnet:** all multi-step edits, new files, complex content
- **Haiku:** single-file edits, doc updates, version bumps

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

## Haiku for Context Summarisation (Cost Compression)

When `context_monitor.sh` reports ≥ 65% context usage, or before a loop expected to exceed 20 turns, spawn haiku to write a compressed session summary:

```
Agent(
  subagent_type = "quick-fix",
  model = "haiku",
  prompt = "Read CURRENT_WORK.md and the recent conversation state. Write a concise prose summary (max 300 words) of: (1) what was accomplished this session, (2) key decisions made and why, (3) exact next step. Overwrite CURRENT_WORK.md with this summary. No preamble."
)
```

This implements recursive summarisation: a cheap model compresses the expensive model's accumulated context before it grows quadratically.

**Trigger conditions (ANY ONE):**
- `CLAUDE_CONTEXT_USAGE_PERCENT` ≥ 65
- About to start a `/loop` or multi-turn automation
- About to spawn 3+ sequential subagents

**Do NOT use haiku for summarisation when:**
- Context < 40% (premature compression adds latency)
- The session involves active debugging with many intermediate states needed

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
- Prose edits to memory, rules, CLAUDE.md, CHANGELOG, CURRENT_WORK (scope above)
- Ambiguous requirements needing clarification
- Roborev triage closures (`comment` + `close` on individual reviews)

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
