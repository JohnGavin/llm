---
description: Auto-delegate to cheaper models when trigger patterns match
---
# Rule: Auto-Delegation to Cheaper Models

## When This Applies
Every orchestrator decision about whether to do work directly or delegate.

## Model Tier Lookup

| Tier | Role | Current model alias |
|------|------|---------------------|
| **Orchestrator** | Plan, decompose, synthesise; main loop | `opus` |
| **Worker** | Multi-step implementations, complex edits | `sonnet` |
| **Lightweight** | Single-file edits, doc updates, version bumps | `haiku` |

In Agent() calls use the alias (`model="haiku"`, `model="sonnet"`, `model="opus"`) — Claude Code resolves these to the latest tier model. Do not hardcode dated model IDs (e.g. `claude-sonnet-4-6`) in dispatch prompts; see `llm-portability-statement` rule for the portability rationale.

## CRITICAL: Orchestrator-Tier Role — Plan, Decompose, Synthesise (+ bounded prose exceptions)

**Default rule:** the orchestrator tier delegates all code, script, and configuration edits to subagents. This includes everything under `R/`, `inst/`, `tests/`, `vignettes/`, `.github/`, `default.R`, `default.nix`, shell scripts in `.claude/scripts/` and `.claude/hooks/`, and any new file in the package source tree. See the companion doc for the "Clarification" note on when the orchestrator tier still uses Edit/Write directly.

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

## CRITICAL: Do Not Use Orchestrator Tier for Lightweight Work

If ALL of these are true, MUST use `quick-fix` agent (lightweight tier):
- Single file affected
- Fewer than 5 lines changed
- No reasoning about correctness needed (typo, rename, version bump, URL fix)
- No test verification required after the change

See the companion doc for the "Three-tier model" summary and a worked
`Agent(subagent_type="quick-fix", ...)` dispatch example.

## Lightweight Tier for Context Summarisation (Cost Compression)

At ≥ 65% context usage (or before a >20-turn `/loop`, or when spawning 3+ sequential subagents), the orchestrator tier delegates the `CURRENT_WORK.md` summary write to the lightweight tier — it decides what/when; the lightweight tier only executes. Do NOT trigger below 40% or during active debugging. Trigger detail + example prompt: [`_companions/auto-delegation-cost-and-parallel.md`](_companions/auto-delegation-cost-and-parallel.md).

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

When `burn_rate_check.sh` reports **WARN**, prefer worker/lightweight agents, use the lightweight tier for all single-file edits, and defer speculative exploration. At **CRITICAL**, the orchestrator tier handles user dialogue only — ALL code work goes to worker/lightweight agents (or a `claude --model sonnet` worktree). Full severity→action table: [`_companions/auto-delegation-dispatch-details.md`](_companions/auto-delegation-dispatch-details.md).

## Mandatory: isolation:"worktree" for Agent Dispatches with Bash

Per the `permission-discipline` rule, `bypassPermissions` is safe ONLY inside worktrees and `/tmp/*`. Full rationale (main-checkout credential risk, `~/.claude/` symlink sandbox-escape, `worktree_symlink_guard` hook llm#692) is in the companion doc.

**Therefore:** ANY Agent dispatch where the agent may invoke Bash — `fixer`,
`r-debugger`, `targets-runner`, `nix-env`, `shiny-async-debugger`,
`data-quality-guardian`, `data-engineer`, `shinylive-builder`, `wiki-curator` —
MUST be called with `isolation: "worktree"`. `quick-fix` (no Bash) and `critic`
(read-only) are exempt. Per-agent table + the quick-fix tool-limitation note
(#223) are in [`_companions/auto-delegation-dispatch-details.md`](_companions/auto-delegation-dispatch-details.md).

### Mandatory Agent Dispatch Prefixes (BOTH required)

Every Bash-capable agent dispatch with `isolation: "worktree"` MUST include BOTH prefixes verbatim at the top of the prompt, before any task-specific instructions. Missing either prefix causes the failure modes in `JohnGavin/llm#182` and `JohnGavin/llm#191`.

See [_companions/auto-delegation-dispatch-details.md](_companions/auto-delegation-dispatch-details.md) for the full verbatim text of both prefixes, orchestrator responsibilities, Tier 3 post-verification pattern, and right/wrong examples.

### CRITICAL — Long verification commands go in the prompt VERBATIM, never as prose

Any dispatch that requires the agent to run a multi-minute verification command
(`scripts/verify.sh`, `devtools::check()`, a full test suite) MUST embed the literal
`Bash(...)` invocation in the prompt's Verification section, **plus** an explicit
"do NOT use `run_in_background` for this" sentence:

```
Bash(command="<worktree>/scripts/verify.sh > /tmp/verify.txt 2>&1", timeout=600000)
```

**Describing the intent does not work.** Writing "run verify.sh in the foreground, up
to 10 minutes" reads as satisfied by a backgrounded run, and agents then end their turn
with "waiting for the build to complete" — which is not a result. Each stall costs a
`SendMessage` resume, and the agent typically has already finished the real work, so
the delay buys nothing.

Observed **five times across two sessions** (2026-08-05 issues #640/#641/#645;
2026-08-24 issues #738/#748 and #740/#697). In the 2026-08-24 pair the orchestrator's
dispatch *did* say "foreground" in prose and both agents backgrounded anyway. The
affirmative instruction alone has now failed every time it has been relied on; the
verbatim call plus the negative instruction is the only form that has held.

A warm nix shell is ~13s and a full suite runs in a few minutes, so foreground fits
inside a 600000 ms timeout comfortably. If a run genuinely exceeds that, require
polling the output file with repeated `Read` calls until a terminal completion marker
appears — never a bare "wait for the notification".

### CRITICAL — SendMessage Continuations for Write Operations (#304)

When the follow-up work for an agent involves any **write** (edit, commit, push),
do NOT use `SendMessage` to continue the agent.

See the "SendMessage Continuations" section in the companion doc for the full anti-pattern table and evidence from llm#304.

### Cross-Repo Writes (#182 resolution)

Agents dispatched with `isolation: "worktree"` cannot write outside their sandbox.

See the "Cross-Repo Writes" section in the companion doc for the full pattern,
dual-repo post-verify example, and the #182 decision rationale.

### Read-Only Cross-Repo Verify → Parallel, NO Worktree

Dispatch read-only verifiers (`critic`, `reviewer`, `Explore`, or `general-purpose`
restricted to Read/Grep/Glob) that target a separate repo in parallel, WITHOUT
`isolation: "worktree"`. See the companion doc for the full rule, the cross-repo
task/isolation/concurrency table, the write-side corollary, and the 2026-07-03/04
origin incident.

## Parallel Worktree Sessions

For independent tasks, spawn a worker-tier worktree session (`git worktree add` + `claude --model sonnet`); worktrees share `.git`/`.claude/`, each on its own branch. Full example + targets-store isolation: [`_companions/auto-delegation-cost-and-parallel.md`](_companions/auto-delegation-cost-and-parallel.md).
