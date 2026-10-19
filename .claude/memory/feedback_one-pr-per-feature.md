---
name: one-pr-per-feature
description: "Batch related changes (fix, follow-up, tests, scheduling, docs) into ONE PR on one branch; ask the owner for one \"merge\" per feature, not per step"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 13c7d939-24e5-42f3-876c-c659b8212a8f
  modified: 2026-10-19T09:25:44.519Z
---

The owner is asked to say "merge" for every PR on the exclusion list, and complained on 2026-10-19 that this is still too frequent. One feature (the auto-merge sweep) shipped as four PRs (#1477-#1480) plus fixes, each needing a verb.

**Why:** every merge is an owner decision; related steps should be one decision. Splitting by step multiplies the asks without adding review value.

**How to apply:** one branch, one PR, separate commits per step. When dispatching a subagent for the next step of a feature with an open PR, pre-create the worktree on that PR's branch (see [[feedback_agent-worktree-pinning]]) or give the whole feature to one dispatch. Separate PRs only for unrelated changes, or when one step must run live before the next is safe. Written into AGENTS.md ("One PR per feature") and `pr-shipping-discipline`. Related: [[project_scanner-triage-followups]], llm#1471.
