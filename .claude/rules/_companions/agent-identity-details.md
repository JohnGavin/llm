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

## Sections Moved from the Rule Body (2026-07-29 line-limit pass, llm#749)

### Why four places

One is not enough. The prompt can be ignored (agent still exposes the env var).
The commit footer survives rebases. The git note survives branch deletion (until
`git notes prune`). The state file is the orchestrator's ground truth for
post-verify reconciliation.

### Symlink-trapped paths

`~/.claude/scripts/` and `~/.claude/hooks/` are symlinks that resolve into the
orchestrator's main checkout (`~/docs_gh/llm/.claude/scripts/`). An agent writing
to these paths via their `~/.claude/` address is writing OUTSIDE its worktree
sandbox — the write lands in the orchestrator's working tree, not the agent's PR
diff. This is the Pattern 2 failure from llm#517.

The `PreToolUse:Edit|Write` hook (future: llm#517) will resolve symlinks before
the boundary check.

### Environment variables for hooks (Phase 2)

```bash
CLAUDE_DISPATCH_ID=<uuid>
CLAUDE_AGENT_TYPE=fixer
CLAUDE_WORKTREE_PATH=/path/to/worktree
CLAUDE_ESCALATION_SCOPE=pr-create,issue-create
CLAUDE_DISPATCH_EXPIRES_AT=2026-06-05T14:30:00Z
```

Hooks read these variables to make policy decisions. Currently `agent_push_guard.sh`
and `destructive_fs_guard.sh` use workspace path only. When Phase 2 lands, they
will also check `CLAUDE_DISPATCH_EXPIRES_AT` and `CLAUDE_ESCALATION_SCOPE`.

### Audit Trail — worked commands

```bash
# All commits from a dispatch
git log --all --grep="Dispatch-Id: abc123ef" --format="%h %s"

# All paths touched
git log --all --grep="Dispatch-Id: abc123ef" --name-only --format="" | sort -u

# Post-verify outcome
cat ~/.claude/logs/agent_post_verify_abc123ef.json
```

## Phase Roadmap

| Phase | What lands | Status |
|---|---|---|
| 1 (parent rule) | Dispatch ID protocol documented; commit footer format; scope block format | Shipped |
| 2 | Hooks read identity env vars for expiry + scope checks | Future (llm#476) |
| 3 | Helper script `mint-dispatch.sh` automates ID + scope block generation | Future |
