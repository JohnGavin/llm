---
name: agent-no-push-to-main
description: Prevents worktree-isolated agents from pushing to protected branches (main/master/release/prod).
type: enforcement
---

# Rule: Agent Worktree — No Push to Protected Branches

## Source

llm#189 — 2026-05-18 session observation: 3 of 5 round-4 fixer agents
auto-pushed to `origin/main` despite "do NOT push" instructions in the
dispatch prompt. This rule enforces the boundary at the tool-call level,
independent of prompt wording.

---

## When This Applies

Any Bash tool call from inside a Claude worktree or ephemeral `/tmp/`
workspace that contains `git push` or `gh repo sync` targeting a protected
branch.

---

## CRITICAL: This Rule Is Enforced — Block Mode Active After Soak Period

`~/.claude/hooks/agent_push_guard.sh` fires as a **PreToolUse:Bash** hook.
After the 48-hour soak period ended (`SOAK_END_UTC=2026-05-21T17:00:09Z`), the
hook defaults to **block** mode and exits non-zero (code 2) before the command
reaches the shell. The hook cannot be bypassed by prompt wording alone.

### Soak period and automatic expiry

The hook contains a hardcoded `SOAK_END_UTC` timestamp. Before that date the
hook defaults to log-only mode (records would-be-blocked pushes, allows them
through). After that date the hook automatically defaults to block mode.

The soak period for this hook ended on `2026-05-21T17:00:09Z` — **block mode
is now the default**.

- In log-only mode: a would-be-blocked push is **allowed through** but recorded to `~/.claude/logs/agent_push_would_block.log`
- In block mode: the push is rejected with exit code 2 and logged to `~/.claude/logs/agent_push_blocked.log`
- To override the automatic default, set `AGENT_PUSH_GUARD_MODE=log` (revert to log-only) or `AGENT_PUSH_GUARD_MODE=block` (force enforce)

The bypass for legitimate orchestrator pushes remains: `AGENT_PUSH_OK=1 git push origin <branch>` (per-command override, audit-logged).

---

## Detection Logic

The hook blocks a command iff ALL THREE conditions hold simultaneously:

| # | Condition | Detail |
|---|---|---|
| 1 | Command is a push | Starts with `git push`, `git -C <path> push`, or `gh repo sync` (after stripping leading `KEY=value` env vars) |
| 2 | Effective path is a worktree | Path contains `.claude/worktrees/`, OR path is under `/private/tmp/` or `/tmp/` |
| 3 | Target ref is protected | Ref matches `main`, `master`, `production`, `release/*`, or `prod/*` |

### Decision Table

| Push from | Target | Action |
|---|---|---|
| Main checkout | `main` | **ALLOW** — orchestrator is pushing directly |
| Worktree | `feat/foo` | **ALLOW** — feature branch push is the correct workflow |
| Worktree | `main` | **BLOCK** (exit 2) |
| `-C /tmp/scratch` | `main` | **BLOCK** — `/tmp/` treated as worktree |
| Worktree | `release/2.0` | **BLOCK** — protected prefix |
| Worktree | `main` (bypass) | **ALLOW** — `AGENT_PUSH_OK=1` present |

---

## Bypass (Orchestrator / User Only)

When a push to a protected branch is genuinely required from a worktree:

```bash
AGENT_PUSH_OK=1 git push origin <branch>
```

This mirrors the `DESTRUCTIVE_CONFIRM=` pattern in `destructive_fs_guard.sh`.
The bypass variable must be set explicitly — it cannot be inherited silently
from the environment across command boundaries.

---

## Example Flow

### What agents MUST do

```
1. Commit work to a feature branch inside the worktree:
     git -C /path/to/worktree commit -m "feat(hook): ..."

2. Push to the feature branch (not main):
     git -C /path/to/worktree push origin feat/your-branch

3. Open a PR via gh:
     gh pr create --base main --head feat/your-branch --title "..."

4. Stop. Orchestrator reviews and merges.
```

### What happens if the agent tries to push to main

```
Bash("git push origin main")
  → hook detects: worktree + protected branch
  → exits 2 with stderr message
  → agent sees: BLOCKED — Agent worktree push to protected branch
  → command never reaches the network
  → attempt logged to ~/.claude/logs/agent_push_blocked.log
```

---

## Audit Logs

| Log file | Contents |
|---|---|
| `~/.claude/logs/agent_push_blocked.log` | Every blocked push attempt with timestamp, command, path, and target (enforce mode) |
| `~/.claude/logs/agent_push_would_block.log` | Pushes that would have been blocked but were allowed through (log-only mode soak) |

---

## Self-Test

```bash
CLAUDE_HOOK_SELFTEST=1 bash ~/.claude/hooks/agent_push_guard.sh
```

Expected output: `8/8 PASS`

---

## Related

- `permission-discipline` rule — `bypassPermissions` is safe only in worktrees and `/tmp/`; this rule covers the complementary risk: agents in those locations pushing out
- `destructive-fs-guard` rule — same PreToolUse:Bash hook pattern, same exit-2 convention
- `bash-safety` rule — compound command guard (a different PreToolUse hook)
- `auto-delegation` rule — "Mandatory: isolation:'worktree' for Agent dispatches with Bash"
- Hook: `~/.claude/hooks/agent_push_guard.sh`
- Issue: llm#189
