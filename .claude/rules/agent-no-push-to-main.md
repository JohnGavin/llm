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

## CRITICAL: This Rule Is ENFORCED, Not Advisory

`~/.claude/hooks/agent_push_guard.sh` fires as a **PreToolUse:Bash** hook and
exits non-zero (code 2) before the command reaches the shell. The hook cannot
be bypassed by prompt wording alone.

### Rollout: LOG-only mode (48h soak, then enforce)

The hook defaults to `AGENT_PUSH_GUARD_MODE=log` for the first 48 hours after deployment. In log-only mode:
- A would-be-blocked push is **allowed through** but recorded to `~/.claude/logs/agent_push_would_block.log`
- After 48h of clean audit (no unexpected blocks), the default flips to `block` in a follow-up commit
- To force enforcement before the flip: set `AGENT_PUSH_GUARD_MODE=block` in your shell

Once the default is `block`, the bypass remains via `AGENT_PUSH_OK=1` (per-command override with audit log).

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
