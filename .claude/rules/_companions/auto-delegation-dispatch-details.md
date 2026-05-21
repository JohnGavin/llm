# Auto-Delegation — Dispatch Details

Full verbatim prefixes, Tier 3 verification pattern, and right/wrong examples.
Companion to `auto-delegation.md`.

---

## Mandatory Agent Dispatch Prefixes (BOTH required)

Every Bash-capable agent dispatch with `isolation: "worktree"` MUST include
BOTH of the following prefixes verbatim at the top of the prompt, BEFORE any
task-specific instructions. The orchestrator owns the responsibility for
injecting both. Agents that receive a prompt missing either prefix exhibit
the failure modes documented in `JohnGavin/llm#182` (sandbox over-restrict)
and `JohnGavin/llm#191` (silent drift to main checkout).

**Prefix 1 — Bash discipline** (from `bash-safety.md`):

```
**CRITICAL — Bash discipline:** Compound bash commands (`&&`/`||`/`;`/`|`) are
HOOK-REJECTED in block mode. Every Bash tool call must contain exactly ONE
command. The ONLY exception is subshell `(cd dir && cmd)` for atomic cd+cmd.
Use `git -C <path>` for git operations. For multi-step shell logic, write a
script file and run it.
```

**Prefix 2 — Worktree isolation** (closes `JohnGavin/llm#191`):

```
**CRITICAL — Worktree isolation:** Your worktree is $WORKTREE_PATH (the
orchestrator replaces this with the actual absolute path before dispatch).
ALL writes (Edit, Write, Bash) MUST target paths under $WORKTREE_PATH.
NEVER write to the orchestrator's main checkout. For read-only reference
you may Read/Grep from main-checkout paths.

Git operations MUST use `git -C $WORKTREE_PATH ...`. Your worktree's branch
is set by the orchestrator — NEVER `git checkout main` or any other branch.
If you need to switch branches, STOP and report back — let the orchestrator
decide.

When you finish, your report MUST include three self-check lines:
  - pwd (must start with $WORKTREE_PATH)
  - git -C $WORKTREE_PATH rev-parse --abbrev-ref HEAD (must NOT be `main`)
  - Last commit SHA on YOUR worktree's branch

If pwd doesn't start with $WORKTREE_PATH, STOP — something is wrong.
```

Orchestrator responsibilities when dispatching:

1. Compute the worktree path the harness will create (typically `.claude/worktrees/agent-<id>/`) and inject it as the literal `$WORKTREE_PATH` value — OR instruct the agent to capture its own `pwd` at startup (more robust since the agent ID is generated at dispatch time)
2. Stop referencing absolute paths to the main checkout for write-target file references — use `$WORKTREE_PATH`-relative paths or omit the prefix and use repo-relative paths
3. **Tier 3 post-verify (MANDATORY):** Before dispatching, capture the main checkout's HEAD SHA. After the agent completes, verify HEAD hasn't moved. See "Tier 3 — Post-Agent Verification" below.

---

## Tier 3 — Post-Agent Verification

Even with both prefixes in place, an agent may ignore them. The orchestrator's
last line of defence is a HEAD-snapshot check around every `isolation: "worktree"`
dispatch. This is Tier 3 of the multi-tier plan in `JohnGavin/llm#191`.

**Pattern:**

```bash
# Before dispatch
main_head_before=$(git -C <main-checkout> rev-parse HEAD)
main_branch_before=$(git -C <main-checkout> rev-parse --abbrev-ref HEAD)

# ... dispatch agent, wait for completion ...

# After completion
main_head_after=$(git -C <main-checkout> rev-parse HEAD)
main_branch_after=$(git -C <main-checkout> rev-parse --abbrev-ref HEAD)

if [ "$main_head_before" != "$main_head_after" ] || [ "$main_branch_before" != "$main_branch_after" ]; then
    echo "ISOLATION VIOLATION: agent mutated main checkout"
    # Auto-recovery (with user confirmation):
    #   git -C <main-checkout> branch <agent-recovery-branch> $main_head_after
    #   git -C <main-checkout> reset --hard $main_head_before
    # Then re-merge from the recovery branch.
fi
```

Helper script: `~/.claude/scripts/agent-post-verify.sh` wraps this pattern.
Usage: capture state with `agent-post-verify.sh capture <repo-path>` before
dispatch; check with `agent-post-verify.sh check <repo-path>` after.

**When the check fires:**

| Drift detected | Action |
|---|---|
| Main HEAD moved but branch is still `main` | Agent committed directly to main. Move the new commit to a feature branch, reset main, alert user. |
| Main HEAD moved AND branch changed (e.g. from `main` to `fix/something`) | Agent switched + committed. Switch main back, leave the feature branch in place. |
| Main HEAD unchanged but branch changed | Agent switched without committing. Switch main back. No data loss. |
| No drift | Agent honoured isolation. Proceed normally. |

**Logging:** every check writes to `~/.claude/logs/worktree_post_verify.log`
with timestamp, agent ID, before/after SHA, and verdict. Review this log
periodically to gauge whether Tier 1+3 alone is sufficient or whether Tier 2
(hook enforcement) is needed.

---

## Right vs Wrong

```
# WRONG: fixer runs in main checkout — live tokens exposed, may overwrite .Renviron
Agent(subagent_type="fixer",
      prompt="Fix R/foo.R line 42 — add NA check before division.")

# WRONG: isolation set but neither prefix injected — agent may drift to main checkout (llm#191)
Agent(subagent_type="fixer",
      isolation="worktree",
      prompt="Fix R/foo.R line 42 — add NA check before division.")

# RIGHT: isolation set + BOTH prefixes injected
Agent(subagent_type="fixer",
      isolation="worktree",
      prompt="""**CRITICAL — Bash discipline:** Compound bash commands
(`&&`/`||`/`;`/`|`) are HOOK-REJECTED in block mode. Every Bash tool call
must contain exactly ONE command. The ONLY exception is subshell `(cd dir && cmd)`
for atomic cd+cmd. Use `git -C <path>` for git operations. For multi-step
shell logic, write a script file and run it.

**CRITICAL — Worktree isolation:** Your worktree is /Users/johngavin/docs_gh/<repo>/.claude/worktrees/agent-<id>.
ALL writes MUST target paths under that worktree. NEVER write to the main checkout
at /Users/johngavin/docs_gh/<repo>. Git operations MUST use git -C <worktree-path>.
NEVER git checkout to a different branch. End-of-run report MUST include pwd,
git rev-parse --abbrev-ref HEAD, and last commit SHA — all from the worktree.

Fix R/foo.R line 42 — add NA check before division.""")
```
