---
description: Auto-delegate to cheaper models when trigger patterns match
---
# Rule: Auto-Delegation to Cheaper Models

## When This Applies
Every orchestrator decision about whether to do work directly or delegate.

## Model Tier Lookup

> **This table is the single source of truth for model IDs.** All prose in this rule uses tier names. Update only this table when Anthropic releases new models — nothing else in this rule needs to change.
> <!-- current as of 2026-06; verify at https://docs.anthropic.com/en/docs/models-overview -->

| Tier | Role | Current model alias |
|------|------|---------------------|
| **Orchestrator** | Plan, decompose, synthesise; main loop | `opus` |
| **Worker** | Multi-step implementations, complex edits | `sonnet` |
| **Lightweight** | Single-file edits, doc updates, version bumps | `haiku` |

In Agent() calls use the alias (`model="haiku"`, `model="sonnet"`, `model="opus"`) — Claude Code resolves these to the latest tier model. Do not hardcode dated model IDs (e.g. `claude-sonnet-4-6`) in dispatch prompts; see `llm-portability-statement` rule for the portability rationale.

## CRITICAL: Orchestrator-Tier Role — Plan, Decompose, Synthesise (+ bounded prose exceptions)

**Default rule:** the orchestrator tier delegates all code, script, and configuration edits to subagents. This includes everything under `R/`, `inst/`, `tests/`, `vignettes/`, `.github/`, `default.R`, `default.nix`, shell scripts in `.claude/scripts/` and `.claude/hooks/`, and any new file in the package source tree.

> **Clarification:** "delegate code/script edits" does NOT mean the orchestrator tier never uses Edit/Write. It DOES use Edit/Write directly for the bounded exceptions listed below (prose files, memory, rules, CHANGELOG, CURRENT_WORK.md). The constraint is on code-level edits to the package source tree, not on all file writes.

| Work type | Delegate to |
|-----------|-------------|
| Single-file edits, doc updates, version bumps | `quick-fix` (lightweight tier) |
| Multi-step implementations, new files, complex content | `fixer` (worker tier) |
| Code review | `reviewer` (worker tier) |
| Bug fixing | `r-debugger` (worker tier) |

### Bounded exceptions — the orchestrator tier MAY use Edit/Write/Bash directly for

The orchestrator tier retains write access for these — they are too small/dialog-driven to be worth the round-trip cost of a subagent, AND they don't benefit from the worker tier's deeper code reasoning:

| Path | Scope |
|------|-------|
| `~/.claude/CLAUDE.md`, `.claude/CLAUDE.md` | Prose updates only (rule wording, table edits) |
| `.claude/rules/*.md`, `.claude/memory/*.md` | Prose edits to existing rules and memory files; new rule creation OK |
| `CHANGELOG.md` (session-end append) | Session-end changelog entries only |
| `.claude/CURRENT_WORK.md` | The orchestrator tier **owns** this file and writes session state directly. Exception: when context ≥ 65%, the orchestrator tier **decides** to delegate the physical write to the lightweight tier (see "Lightweight Tier for Context Summarisation" below) — the lightweight tier writes under the orchestrator's direction; it NEVER autonomously updates this file |
| Roborev DB closure comments via `/usr/local/bin/roborev comment`/`close` | Triage actions, not code |
| Read-only investigation: `Read`, `Grep`, `Glob`, `Bash` for queries (`git log`, `gh pr view`, `du`, SQL reads) | Pre-decomposition reconnaissance |

What "prose edit" means: text/markdown content where no code parses or executes from the change. Editing a shell snippet inside a markdown code fence is NOT a prose edit — delegate that to a subagent so the snippet is actually tested.

### Three-tier model
- **Orchestrator tier:** plan + decompose + synthesise + prose exceptions above
- **Worker tier:** all multi-step edits, new files, complex content
- **Lightweight tier:** single-file edits, doc updates, version bumps

## CRITICAL: Do Not Use Orchestrator Tier for Lightweight Work

If ALL of these are true, MUST use `quick-fix` agent (lightweight tier):
- Single file affected
- Fewer than 5 lines changed
- No reasoning about correctness needed (typo, rename, version bump, URL fix)
- No test verification required after the change

```
Agent(subagent_type="quick-fix", model="haiku",  # lightweight tier
      prompt="In <file>, change <old> to <new>. Reason: <why>")
```

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

## CRITICAL: Do Not Use Orchestrator Tier for Worker-Tier Work

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

## Keep in Orchestrator Tier (Do NOT Delegate)

- Multi-file architecture decisions
- Plan creation requiring user dialogue
- Synthesising results from multiple agents
- Prose edits to `.claude/rules/*.md`, `.claude/memory/*.md`, `CLAUDE.md`, `CHANGELOG.md` (bounded exceptions in the table above)
- `CURRENT_WORK.md` **ownership** — the orchestrator tier always decides what to write and when to compress; it writes directly OR delegates the physical write to the lightweight tier (which executes, not directs — see "Lightweight Tier for Context Summarisation" above)
- Ambiguous requirements needing clarification
- Roborev triage closures (`comment` + `close` on individual reviews)

## Burn-Rate-Aware Escalation

When `burn_rate_check.sh` reports WARN or CRITICAL:

| Severity | Orchestrator action |
|----------|---------------------|
| WARN | Prefer worker-tier agents. Use lightweight tier for all single-file edits. Defer speculative exploration. |
| CRITICAL | Orchestrator tier for user dialogue only. ALL code work via worker/lightweight agents. Suggest worktree: `git worktree add ../<repo>-worker feat/<task>` then `claude --model sonnet` in that tree |

## Mandatory: isolation:"worktree" for Agent Dispatches with Bash

For the canonical path to use when creating worktrees, see the `worktree-location`
rule and `~/.claude/scripts/cc-worktree.sh`.

Per the `permission-discipline` rule, `bypassPermissions` is safe ONLY inside
worktrees and `/tmp/*`. It is NEVER safe in the main checkout, where live API
tokens and credentials sit. An agent running `bypassPermissions` in the main
checkout can silently overwrite `.Renviron`, `default.nix`, or any other
file without a confirmation prompt.

**Therefore:** ANY Agent dispatch where the agent may invoke Bash MUST be
called with `isolation: "worktree"`. This includes:

| Agent | Bash? | Worktree required? |
|-------|-------|--------------------|
| `fixer` | Yes | **Yes** |
| `r-debugger` | Yes | **Yes** |
| `targets-runner` | Yes | **Yes** |
| `nix-env` | Yes | **Yes** |
| `shiny-async-debugger` | Yes | **Yes** |
| `data-quality-guardian` | Yes | **Yes** |
| `data-engineer` | Yes | **Yes** |
| `shinylive-builder` | Yes | **Yes** |
| `wiki-curator` | Yes | **Yes** |
| `quick-fix` (lightweight tier) | No | Optional |
| `critic` (read-only) | No | Optional |

> **Lightweight-tier (`quick-fix`) tool limitation:** the quick-fix agent has Read, Grep, Glob, Edit — but NO Bash. It cannot `git commit`, `git push`, `gh pr create`, or `roborev close`. Dispatching quick-fix for tasks that require any of these is a dispatch error — use fixer (worker tier) instead. Documented to prevent the recurrence pattern from #223.

### Mandatory Agent Dispatch Prefixes (BOTH required)

Every Bash-capable agent dispatch with `isolation: "worktree"` MUST include BOTH prefixes verbatim at the top of the prompt, before any task-specific instructions. Missing either prefix causes the failure modes in `JohnGavin/llm#182` and `JohnGavin/llm#191`.

See [_companions/auto-delegation-dispatch-details.md](_companions/auto-delegation-dispatch-details.md) for the full verbatim text of both prefixes, orchestrator responsibilities, Tier 3 post-verification pattern, and right/wrong examples.

### CRITICAL — SendMessage Continuations for Write Operations (#304)

When the follow-up work for an agent involves any **write** (edit, commit, push),
do NOT use `SendMessage` to continue the agent. SendMessage continuations may
fall back to the orchestrator's cwd when the original harness worktree is gone or
when the harness restarts — writing to the main checkout or to the orchestrator's
session branch (`feat/cc-*`) on a stale base.

| Continuation | Action |
|---|---|
| Write (edit/commit/push) | Dispatch a **fresh `isolation: "worktree"` agent** |
| Read-only / advisory | SendMessage is safe |
| Original worktree verifiably live (confirm pwd) | SendMessage MAY be used |

See the "SendMessage Continuations" section in the companion doc for the full
anti-pattern table and evidence from llm#304.

### Cross-Repo Writes (#182 resolution)

Agents dispatched with `isolation: "worktree"` cannot write outside their sandbox.
For cross-repo writes (e.g. llm session edits llmtelemetry): pre-create the target
repo's worktree via `cc-worktree.sh`, set `$WORKTREE_PATH` to that path in the
dispatch prompt, and run dual-repo post-verify after completion.

See the "Cross-Repo Writes" section in the companion doc for the full pattern,
dual-repo post-verify example, and the #182 decision rationale.

## Parallel Worktree Sessions

For independent tasks, spawn a worker-tier worktree session:

```bash
# Orchestrator creates worktree for delegated work
git worktree add ../<repo>-<task> feat/<task>
# User runs: cd ../<repo>-<task> && claude --model sonnet
```

Worktrees share `.git` and `.claude/` config. Each gets its own branch.
Use `tar_config_set(store = "_targets_<branch>")` to isolate targets stores.
