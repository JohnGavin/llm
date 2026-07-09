# Companion: Agent Identity & Task Scopes — Worked Example + Phase Roadmap

Illustrative detail split out of the always-loaded [`agent-identity-and-task-scopes`](../agent-identity-and-task-scopes.md) rule to keep that mandatory rule lean. The normative content (CRITICAL statements, dispatch-ID propagation table, scope-block format, Forbidden Patterns) stays in the rule; this file is the worked example and roadmap, loaded on demand.

## Worked Example

```
# Orchestrator mints identity
DISPATCH_ID="3f8a1c2d-4b5e-6f7a-8c9d-0e1f2a3b4c5d"
EXPIRES_AT="2026-06-05T15:00:00Z"   # 45 minutes from now

# Orchestrator dispatches
Agent(
  subagent_type = "fixer",
  isolation     = "worktree",
  prompt = """
**CRITICAL — Bash discipline:** [standard prefix]

**CRITICAL — Worktree isolation:** Your worktree is /path/to/worktree
[standard prefix]

TASK SCOPE (dispatch_id=3f8a1c2d, expires=2026-06-05T15:00:00Z):
  write-paths:
    - /path/to/worktree/**
  allowed-external-ops:
    - gh pr create
    - git push origin feat/fix-foo
  forbidden-external-ops:
    - gh pr merge
    - writes to ~/.claude/**
  ttl-minutes: 45

Fix R/foo.R line 42: add NA check before division.
Include in every commit footer:
  Dispatch-Id: 3f8a1c2d
  Agent-Type: fixer
"""
)

# After agent completes, orchestrator runs post-verify
~/.claude/scripts/agent-post-verify.sh check ~/docs_gh/llm --id "$DISPATCH_ID"

# Audit: find everything the agent touched
git log --all --grep="Dispatch-Id: 3f8a1c2d" --name-only --format=""
```

The agent commits with:

```
fix(R/foo.R): add NA check before division (#476)

Dispatch-Id: 3f8a1c2d
Agent-Type: fixer
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

## Phase Roadmap

| Phase | What lands | Status |
|---|---|---|
| 1 (parent rule) | Dispatch ID protocol documented; commit footer format; scope block format | Shipped |
| 2 | Hooks read identity env vars for expiry + scope checks | Future (llm#476) |
| 3 | Helper script `mint-dispatch.sh` automates ID + scope block generation | Future |
