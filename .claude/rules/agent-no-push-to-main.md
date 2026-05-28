---
name: agent-no-push-to-main
description: Prevents worktree-isolated agents from pushing to protected branches (main/master/release/prod) or to any branch other than their own worktree branch.
type: enforcement
---

# Rule: Agent Worktree — No Push to Protected Branches or Sibling Branches

## Source

- llm#189 — 2026-05-18: 3 of 5 round-4 fixer agents auto-pushed to `origin/main`
  despite "do NOT push" prompts.
- llm#318 — 2026-05-28: a nix-env agent pushed its commit to the orchestrator's
  active session branch (`feat/cc-20260524-221709`) instead of its own worktree
  branch (`worktree-agent-aab7e5cc16712b02c`), producing a dirty PR and
  contaminating another session's working tree.

Both cases are now blocked at the hook level, independent of prompt wording.

---

## When This Applies

Any Bash tool call from inside a Claude worktree or ephemeral `/tmp/`
workspace that contains `git push` or `gh repo sync`.

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

---

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

---

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

### Audit logs

| Log file | Contents |
|---|---|
| `~/.claude/logs/agent_push_blocked.log` | Pushes blocked by Guard A (protected branch) |
| `~/.claude/logs/agent_push_blocked_crossbranch.log` | Pushes blocked by Guard B (cross-worktree) — **new in llm#318** |
| `~/.claude/logs/agent_push_would_block.log` | Pushes that would have been blocked (log-only mode, both guards) |

Keeping the two block logs separate allows auditing the two failure modes independently.

---

## Audit Logs

| Log file | Contents |
|---|---|
| `~/.claude/logs/agent_push_blocked.log` | Every blocked push attempt (Guard A — protected branch) with timestamp, command, path, and target (enforce mode) |
| `~/.claude/logs/agent_push_blocked_crossbranch.log` | Every blocked push attempt (Guard B — cross-worktree branch) |
| `~/.claude/logs/agent_push_would_block.log` | Pushes that would have been blocked but were allowed through (log-only mode soak) |

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

- `permission-discipline` rule — `bypassPermissions` is safe only in worktrees and `/tmp/`; this rule covers the complementary risk: agents in those locations pushing out
- `destructive-fs-guard` rule — same PreToolUse:Bash hook pattern, same exit-2 convention
- `bash-safety` rule — compound command guard (a different PreToolUse hook)
- `auto-delegation` rule — "Mandatory: isolation:'worktree' for Agent dispatches with Bash"
- Hook: `~/.claude/hooks/agent_push_guard.sh`
- Issues: llm#189, llm#318
