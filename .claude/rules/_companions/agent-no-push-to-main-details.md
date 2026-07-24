# Companion: Agent No-Push-to-Main — Worked Flow + llm#318 Incident

Worked example flow and the dated incident narrative split out of the
always-loaded [`agent-no-push-to-main`](../agent-no-push-to-main.md) rule to
keep it lean. The normative content (CRITICAL enforcement statement, Guard
A/B detection logic, Decision Table, Bypass, Audit Logs, Self-Test) stays in
the rule; this file is the pedagogical example flow and the incident
narrative, loaded on demand.

## Example Flow

### What agents MUST do

```
1. Commit work to their feature branch inside the worktree:
     git -C /path/to/worktree commit -m "feat(hook): ..."

2. Push to THEIR OWN branch (the worktree's current branch):
     git -C /path/to/worktree push origin worktree-agent-<id>

3. Open a PR via gh:
     gh pr create --base main --head worktree-agent-<id> --title "..."

4. Stop. Orchestrator reviews and merges.
```

### What happens if the agent tries to push to main

```
Bash("git push origin main")
  → hook detects: worktree + protected branch (Guard A)
  → exits 2 with stderr message
  → agent sees: BLOCKED — Agent worktree push to protected branch
  → command never reaches the network
  → attempt logged to ~/.claude/logs/agent_push_blocked.log
```

### What happens if the agent pushes to a sibling branch

```
Bash("git push origin feat/cc-20260524-221709")
  → hook detects: worktree + explicit ref != current branch (Guard B)
  → exits 2 with stderr message
  → agent sees: BLOCKED — Agent worktree push to wrong branch (cross-worktree)
  → command never reaches the network
  → attempt logged to ~/.claude/logs/agent_push_blocked_crossbranch.log
```

## Cross-worktree push block (llm#318)

### What the incident was

A nix-env agent dispatched with `isolation: "worktree"` (worktree at
`.claude/worktrees/agent-aab7e5cc16712b02c`, branch `worktree-agent-aab7e5cc16712b02c`)
pushed its commit to `feat/cc-20260524-221709` — the orchestrator's active
session branch in a different worktree (`llm-feat-cc-20260524-221709`).

The agent's `pwd` was correctly inside its own worktree and its current branch
was correct, so the existing Tier-1 self-check passed and reported success.
The push target ref, however, was the orchestrator's branch — not the agent's.

The resulting PR (#315) appeared to revert recently-merged files because the
orchestrator's session branch was stale relative to main.

### The surgical fix

Guard B in `agent_push_guard.sh` now computes the worktree's current branch via
`git -C <effective_path> symbolic-ref --short HEAD` and compares it to the
explicitly-supplied push ref. If they differ, the push is blocked with exit 2
and logged to the cross-branch log (distinct path from the protected-branch log).
