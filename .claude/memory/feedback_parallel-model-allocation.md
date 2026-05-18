---
name: feedback-parallel-model-allocation
description: "When orchestrating multi-step work, allocate the appropriate model to each task — and dispatch independent tasks in parallel rather than serially as opus"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: bb86c529-f2d4-430a-8e21-361790e1da7b
---

# Allocate the appropriate model to the appropriate task — in parallel

When orchestrating a multi-step task with independent subtasks, the right pattern is: opus plans + decomposes + synthesises, then dispatches independent subtasks **in parallel** to the cheapest sufficient model (haiku for trivial, sonnet for code, opus only for orchestration + bounded prose exceptions).

**Why:** Cost compounds across long sessions. Opus is ~10× the cost of sonnet, ~30× haiku. A 5-step session done entirely as opus burns ~30× more than the same session orchestrated by opus with 4 sonnet/haiku subagents. The parallel dispatch also wins on wall-clock — serial agent runs are O(n × t), parallel is O(t).

**How to apply:**

1. **Default rule:** opus delegates all code/script/configuration edits to subagents. See `auto-delegation` rule for the bounded exception table.
2. **Edge cases to watch for** (bounded exceptions that should still be delegated when possible):
   - Build actions that produce committable artifacts (e.g. `quarto render` followed by `git add docs/` + commit) — the render is non-edit but the commit IS a change to the prod repo. Delegate the whole sequence to fixer when feasible.
   - 1-line settings.json env-var flips — technically a config edit, not prose. Delegate to quick-fix (haiku) or fixer (sonnet) even though the diff is tiny. The discipline matters more than the byte count.
   - Multi-file fan-outs (e.g. closing 173 roborev jobs via python loop) — opus is fine for the orchestration, but if the work could be split across N independent agents, prefer that.
3. **Parallel dispatch pattern:** when launching multiple agents for independent work, send them in a **single message with multiple Agent tool uses** — they run concurrently. Never serialize independent work into sequential agent dispatches.
4. **Pre-flight check before opus-direct edits:** "Could a fixer/quick-fix agent do this in 30 seconds?" If yes, delegate.

**Origin (2026-05-17 Session 4):**

Session work was largely well-delegated (#174 implementation to fixer, #176 spike to fixer) BUT two borderline cases were done as opus directly:
- JohnGavin.github.io quarto render + commit `4778cfb` — defensible (render is a build, not edit) but the git commit is a real change to a prod repo
- `settings.json` env flip from `off` → `log` (commit `9c3d133`) — 1-line config change, should have been delegated

User reinforced: even when the diff is tiny, the discipline of delegating to the appropriate model matters. Cost may be small per instance but compounds across hundreds of sessions.

**Related memories:**

- [[feedback_delegation-under-pressure]] — after the FIRST fix in an iterative cycle, delegate subsequent fixes
- [[agent-patterns]] — model selection (haiku $ / sonnet $$ / opus $$$)
- `auto-delegation` rule (`.claude/rules/auto-delegation.md`) — bounded exception table

**Related rule:** `auto-delegation` — the rule this feedback reinforces.
