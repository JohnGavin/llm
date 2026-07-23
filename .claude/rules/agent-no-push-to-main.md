---
name: agent-no-push-to-main
description: Prevents worktree-isolated agents from pushing to protected branches (main/master/release/prod) or to any branch other than their own worktree branch.
type: enforcement
paths:
  - ".claude/hooks/**"
  - ".claude/settings*.json"
---

# Rule: Agent Worktree — No Push to Protected Branches or Sibling Branches

## Source

- llm#189 — 2026-05-18: 3 of 5 round-4 fixer agents auto-pushed to `origin/main`
  despite "do NOT push" prompts.
- llm#318 — 2026-05-28: a nix-env agent pushed its commit to the orchestrator's
  active session branch instead of its own worktree branch, producing a dirty
  PR and contaminating another session's working tree. Full incident narrative
  and the surgical fix are in the companion doc.

Both cases are now blocked at the hook level, independent of prompt wording.

---

## When This Applies

Any Bash tool call from inside a Claude worktree or ephemeral `/tmp/`
workspace that contains `git push` or `gh repo sync`.

---

## CRITICAL: This Rule Is Enforced — Block Mode Active After Soak Period

`~/.claude/hooks/agent_push_guard.sh` fires as a **PreToolUse:Bash** hook. Block
mode is now the default (the soak period ended `2026-05-21T17:00:09Z`) — the
hook exits non-zero (code 2) before the command reaches the shell and cannot
be bypassed by prompt wording alone.

- In log-only mode: a would-be-blocked push is **allowed through** but recorded to `~/.claude/logs/agent_push_would_block.log`
- In block mode: the push is rejected with exit code 2 and logged to `~/.claude/logs/agent_push_blocked.log`
- Override the default: `AGENT_PUSH_GUARD_MODE=log` (revert to log-only) or `AGENT_PUSH_GUARD_MODE=block` (force enforce)

The bypass for legitimate orchestrator pushes remains: `AGENT_PUSH_OK=1 git push origin <branch>` (per-command override, audit-logged to the relevant log file).

---

## Detection Logic

The hook evaluates TWO independent block conditions. A push is blocked if
either condition fires.

### Guard A — Protected branch (llm#189)

Blocks iff ALL THREE hold:

| # | Condition | Detail |
|---|---|---|
| 1 | Command is a push | Starts with `git push`, `git -C <path> push`, or `gh repo sync` (after stripping leading `KEY=value` env vars) |
| 2 | Effective path is a worktree | Path contains `.claude/worktrees/`, OR path is under `/private/tmp/` or `/tmp/` |
| 3 | Target ref is protected | Ref matches `main`, `master`, `production`, `release/*`, or `prod/*` |

### Guard B — Cross-worktree branch (llm#318)

Blocks iff ALL THREE hold:

| # | Condition | Detail |
|---|---|---|
| 1 | Command is a push | Same as Guard A condition 1 |
| 2 | Effective path is a worktree | Same as Guard A condition 2 |
| 3 | Target ref was explicitly named AND differs from the worktree's current branch | Detects pushes to a sibling worktree's branch |

Guard B only fires when the caller explicitly names a push ref. A bare `git push origin` (no refspec) is always allowed because it can only push to the tracking branch, which is always the current branch.

---

### Decision Table

| Push from | Target | Guard A | Guard B | Action |
|---|---|---|---|---|
| Main checkout | `main` | no (not worktree) | no | **ALLOW** — orchestrator is pushing directly |
| Worktree on `worktree-agent-X` | own branch `worktree-agent-X` | no | no (same branch) | **ALLOW** — correct workflow |
| Worktree | `feat/foo` (own branch) | no | no (same branch) | **ALLOW** |
| Worktree on `worktree-agent-X` | `feat/cc-20260524` (sibling branch) | no | **yes** | **BLOCK** (exit 2) — cross-worktree |
| Worktree | `main` | **yes** | — | **BLOCK** (exit 2) — protected |
| `-C /tmp/scratch` | `main` | **yes** | — | **BLOCK** — `/tmp/` treated as worktree |
| Worktree | `release/2.0` | **yes** | — | **BLOCK** — protected prefix |
| Worktree | `main` (bypass) | bypassed | bypassed | **ALLOW** — `AGENT_PUSH_OK=1` present |
| Worktree on X | sibling branch Y (bypass) | bypassed | bypassed | **ALLOW** — `AGENT_PUSH_OK=1` present |

---

## Bypass (Orchestrator / User Only)

When a push to a protected or cross-worktree branch is genuinely required:

```bash
AGENT_PUSH_OK=1 git push origin <branch>
```

This mirrors the `DESTRUCTIVE_CONFIRM=` pattern in `destructive_fs_guard.sh`.
The bypass variable must be set explicitly — it cannot be inherited silently
from the environment across command boundaries.

The correct agent workflow (commit to own branch → push own branch → `gh pr
create` → stop for orchestrator review) and worked examples of both block
paths (push to `main`, push to a sibling worktree's branch) are in the
companion doc.

---

## Audit Logs

| Log file | Contents |
|---|---|
| `~/.claude/logs/agent_push_blocked.log` | Every blocked push attempt (Guard A — protected branch), enforce mode |
| `~/.claude/logs/agent_push_blocked_crossbranch.log` | Every blocked push attempt (Guard B — cross-worktree branch) |
| `~/.claude/logs/agent_push_would_block.log` | Pushes that would have been blocked but were allowed through (log-only mode soak) |

Keeping the two block logs separate allows auditing the two failure modes independently.

---

## Self-Test

```bash
CLAUDE_HOOK_SELFTEST=1 bash ~/.claude/hooks/agent_push_guard.sh
```

Expected output: `12/12 PASS`

The 12 cases cover:
- Cases 1–8: original protected-branch guard (Guard A) + mode checks
- Cases 9–12: cross-worktree guard (Guard B) — own-branch allow, sibling-branch block, protected-branch-fires-first, bypass

---

## Related

- [`_companions/agent-no-push-to-main-details.md`](_companions/agent-no-push-to-main-details.md) — worked example flow (correct workflow + both block paths) and the llm#318 incident narrative with its surgical fix
- `permission-discipline` rule — `bypassPermissions` is safe only in worktrees and `/tmp/`; this rule covers the complementary risk: agents in those locations pushing out
- `destructive-fs-guard` rule — same PreToolUse:Bash hook pattern, same exit-2 convention
- `bash-safety` rule — compound command guard (a different PreToolUse hook)
- `auto-delegation` rule — "Mandatory: isolation:'worktree' for Agent dispatches with Bash"
- Hook: `~/.claude/hooks/agent_push_guard.sh`
- Issues: llm#189, llm#318
