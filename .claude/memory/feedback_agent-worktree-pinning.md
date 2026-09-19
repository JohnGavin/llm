---
name: feedback_agent-worktree-pinning
description: "A dispatched agent cannot work in another agent's .claude/worktrees/agent-* worktree; use ~/docs_gh/worktrees/<project>/<branch>/ instead"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b39cf87a-57ba-486e-a74d-aec69096ec3d
  modified: 2026-09-13T11:16:16.400Z
---

A dispatched agent is pinned by the harness to the worktree created for **its
own** dispatch. Pointing it at a different agent's worktree under
`.claude/worktrees/agent-*` fails three ways: `git -C <other>` is refused by the
worktree-isolation guard, `EnterWorktree` appears to succeed but then every
Bash call (even `pwd`) is blocked by a second hook comparing resolved cwd to
the original pin, and a cross-branch push is blocked by `agent_push_guard.sh`
Guard B.

A worktree under `~/docs_gh/worktrees/<project>/<branch>/` does NOT have this
problem — an agent can be pointed at one and work there normally (verified
2026-09-11, when a fixer updated an open PR's branch that way).

**Why:** to continue work on an existing PR branch, the branch must be checked
out somewhere the agent is allowed to write. Harness worktrees are private to
their own dispatch; `~/docs_gh/worktrees/` ones are not.

**How to apply:** when a dispatch must land on an existing PR branch, pre-create
`~/docs_gh/worktrees/<project>/<branch>/` (see `cc-worktree.sh`) and name that
as `$WORKTREE_PATH` in Prefix 2, per the cross-repo pattern in
[[auto-delegation-dispatch-details]]. Never name another agent's
`.claude/worktrees/agent-*` path. An agent that recovers by fast-forwarding its
own branch to the PR tip and pushing to the authorised target has done the right
thing under a bad instruction — fix the instruction.

Related: [[feedback_no-compound-cd]], [[worktree-location]]
