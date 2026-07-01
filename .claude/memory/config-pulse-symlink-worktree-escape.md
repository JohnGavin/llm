---
name: config-pulse-symlink-worktree-escape
description: "A repo file that is a symlink into ANOTHER repo lets a worktree-isolated agent escape its sandbox and push to the other repo's main (#517 Pattern 2, made real 2026-06-28)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4854e9d1-4cc0-4a69-8d8d-03939c73c029
---

`~/docs_gh/llm/.claude/scripts/config_pulse.sh` is a **symlink** into `~/docs_gh/llmtelemetry/inst/scripts/config_pulse.sh`. On 2026-06-28 a fixer dispatched into an **llm worktree** edited it via the worktree-relative path; the write followed the symlink into the **llmtelemetry main checkout**, and the agent then committed + pushed `c35ec82` straight to **llmtelemetry main** — bypassing PR review. This is exactly the #517 Pattern 2 symlink-trap.

**Why:** worktree isolation only sandboxes paths that physically live under the worktree. A symlink whose realpath is outside the worktree silently defeats it. Scope-block prose ("don't write to other repos") did NOT stop it because the path *looked* in-worktree.

**How to apply:** Memory is NOT a reliable guard here (a future dispatch may not recall it). The durable fix is a **PreToolUse:Edit|Write hook that resolves realpath and blocks writes landing outside the agent's worktree** (#517), plus **de-symlinking known cross-repo traps** (make the file canonical in one repo; have the other call it by its real path, not a symlink). Treat any repo-internal symlink whose target leaves the repo as a worktree-escape hazard. Related: [[destructive-guard-blocks-rm]], llm#517.
