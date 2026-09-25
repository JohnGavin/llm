---
paths:
  - ".claude/rules/auto-delegation.md"
---

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


## Sections Moved from the Rule Body (2026-09-21 line-limit pass)

Original verbatim text moved out of the rule; the normative summary stays in the rule. (Dispatch-related originals are in this file rather than auto-delegation-dispatch-details.md, which is already over its own line limit.)

A dispatch is the most expensive thing the orchestrator can do (~300k tokens and
5–20 minutes each). Spending one to discover "already fixed" is pure waste, and
it happens often: on 2026-09-02, **2 of 5** issues worked in one session were
already resolved — #1075 by a commit landed the day after it was filed, and the
body of #1035 by a PR merged a week earlier. Neither had been closed. A third
item's four sub-tasks were already tracked verbatim in another repo's tracker.

1. **Grep `main` for the concrete thing it names** — the file, symbol, config
   key, or behaviour. `git log --oneline --all -S '<symbol>' -- <path>` finds
   the commit that introduced or removed a string, which is usually decisive.
2. **Look for a merged PR** — `gh pr list --state merged --search "<number>"`.
3. **Check unmerged branches and worktrees** — the work may be complete but
   unlanded: `git log --all --oneline --grep '#<number>'` covers every branch
   without visiting each of the (often dozens of) worktrees.

An issue too vague to have a checkable "fixed" state is itself a finding: it
cannot be verified done later either, so it wants rewriting before working.

Corollary for the agent: a dispatch prompt should tell the agent to confirm the
premise before implementing, and to report "already fixed" as a **successful**
outcome rather than manufacturing a diff to justify the dispatch.

**Therefore:** ANY Agent dispatch where the agent may invoke Bash — `fixer`,
`r-debugger`, `targets-runner`, `nix-env`, `shiny-async-debugger`,
`data-quality-guardian`, `data-engineer`, `shinylive-builder`, `wiki-curator` —
MUST be called with `isolation: "worktree"`. `quick-fix` (no Bash) and `critic`
(read-only) are exempt. Per-agent table + the quick-fix tool-limitation note
(#223) are in [`_companions/auto-delegation-dispatch-details.md`](_companions/auto-delegation-dispatch-details.md).

Every Bash-capable agent dispatch with `isolation: "worktree"` MUST include BOTH prefixes verbatim at the top of the prompt, before any task-specific instructions. Missing either prefix causes the failure modes in `JohnGavin/llm#182` and `JohnGavin/llm#191`.

See [_companions/auto-delegation-dispatch-details.md](_companions/auto-delegation-dispatch-details.md) for the full verbatim text of both prefixes, orchestrator responsibilities, Tier 3 post-verification pattern, and right/wrong examples.

When the follow-up work for an agent involves any **write** (edit, commit, push),
do NOT use `SendMessage` to continue the agent.

See the "SendMessage Continuations" section in the companion doc for the full anti-pattern table and evidence from llm#304.

Agents dispatched with `isolation: "worktree"` cannot write outside their sandbox.

See the "Cross-Repo Writes" section in the companion doc for the full pattern,
dual-repo post-verify example, and the #182 decision rationale.

Dispatch read-only verifiers (`critic`, `reviewer`, `Explore`, or `general-purpose`
restricted to Read/Grep/Glob) that target a separate repo in parallel, WITHOUT
`isolation: "worktree"`. See the companion doc for the full rule, the cross-repo
task/isolation/concurrency table, the write-side corollary, and the 2026-07-03/04
origin incident.
