---
name: feedback-agent-salvage-unlanded-work
description: When a dispatched agent stops before committing, salvage its worktree — verify then commit — rather than re-dispatching and paying twice
metadata:
  type: feedback
---

# Agents Often Stop With Work Complete But Unlanded — Salvage, Don't Re-dispatch

**Observed 2026-08-02: three of five dispatched agents stopped before committing.**
In every case the work was complete and sound — only unlanded.

| Agent | Stopped at | Work state |
|---|---|---|
| `fixer` (#870 ccusage merge) | after commit, before PR | committed + pushed; PR missing |
| `fixer` (#877 codexbar) | mid `devtools::test()` run | all edits present, uncommitted |
| `r-debugger` (5 test failures) | killed by monthly-spend-limit API error | all 5 files edited, uncommitted |

The harness reports these as `completed` (or `failed`) with a truncated or
placeholder final message — e.g. *"I'll stop polling and wait for the background
monitor notification"*. That message is **not** evidence the work is missing.

**Why:** re-dispatching pays the full token cost twice and risks a different,
possibly worse, solution. The expensive part (diagnosis + edits) is already done
and sitting in the agent's worktree. The cheap part (verify + commit + PR) is
what remains.

**A `failed` status is not a failed task.** The spend-limit kill produced a
worktree whose full test suite passed with zero failures — the agent died at the
commit step, not the work step.

## How to apply — the salvage path

1. **Check the worktree before believing the report.**
   `git -C <worktree> status --short` and `git -C <worktree> log --oneline origin/main..HEAD`.
   The notification's `worktreePath` field gives the path. Do NOT read the
   agent's `.output` transcript — it overflows context.
2. **Check whether it already committed/pushed/PR'd.** Ordering is
   commit → push → PR; it may have done 1 or 2 of the 3. A PR may exist even
   when the final message suggests otherwise (`gh pr list --head <branch>`).
3. **Verify the OUTCOME independently — never commit unverified agent work.**
   Run the full suite in the worktree; run whatever gate the task targeted;
   confirm the diff is scoped to the intended files. Re-check the specific
   numeric claims that distinguish a correct implementation from a plausible
   broken one (e.g. cost conservation through an aggregation, not just row count).
4. **Commit with provenance stated.** Record in the commit AND the PR body:
   that an agent produced it, that it stopped before reporting, what you verified
   yourself, and — critically — **what reasoning was never delivered**. A reviewer
   must not mistake a verified outcome for a reviewed rationale.
5. **Keep the `Dispatch-Id:` / `Agent-Type:` footers** so the audit trail in
   [[agent-identity-and-task-scopes]] still resolves.

## Gotcha: the push guard misparses `-u`

`git -C <worktree> push -u origin <branch>` is rejected by `agent_push_guard.sh`
as a cross-worktree push — it reads `origin` as the target ref. Use
`git -C <worktree> push origin <branch>` with the branch named explicitly.
Tell dispatched agents this in the prompt.

## Related

- [[feedback_delegation-under-pressure]] — when to delegate at all
- [[feedback_parallel-model-allocation]] — cheapest sufficient model per task
- [[deploy-gap-stale-main-checkout]] — merged ≠ live; salvaged ≠ deployed either
