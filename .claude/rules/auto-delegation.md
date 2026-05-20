---
description: Auto-delegate to cheaper models when trigger patterns match
---
# Rule: Auto-Delegation to Cheaper Models

## When This Applies
Every orchestrator decision about whether to do work directly or delegate.

## CRITICAL: Opus Role — Plan, Decompose, Synthesise (+ bounded prose exceptions)

**Default rule:** opus delegates all code, script, and configuration edits to subagents. This includes everything under `R/`, `inst/`, `tests/`, `vignettes/`, `.github/`, `default.R`, `default.nix`, shell scripts in `.claude/scripts/` and `.claude/hooks/`, and any new file in the package source tree.

| Work type | Delegate to |
|-----------|-------------|
| Single-file edits, doc updates, version bumps | `quick-fix` (haiku) |
| Multi-step implementations, new files, complex content | `fixer` (sonnet) |
| Code review | `reviewer` (sonnet) |
| Bug fixing | `r-debugger` (sonnet) |

### Bounded exceptions — opus MAY use Edit/Write/Bash directly for

Opus retains write access for these — they are too small/dialog-driven to be worth the round-trip cost of a subagent, AND they don't benefit from sonnet's deeper code reasoning:

| Path | Scope |
|------|-------|
| `~/.claude/CLAUDE.md`, `.claude/CLAUDE.md` | Prose updates only (rule wording, table edits) |
| `.claude/rules/*.md`, `.claude/memory/*.md` | Prose edits to existing rules and memory files; new rule creation OK |
| `CHANGELOG.md` (session-end append) | Session-end changelog entries only |
| `.claude/CURRENT_WORK.md` | Opus writes session state directly; OR delegates to haiku for context-compression summarisation (see "Haiku for Context Summarisation" below) — haiku writes the file, opus decides when |
| Roborev DB closure comments via `/usr/local/bin/roborev comment`/`close` | Triage actions, not code |
| Read-only investigation: `Read`, `Grep`, `Glob`, `Bash` for queries (`git log`, `gh pr view`, `du`, SQL reads) | Pre-decomposition reconnaissance |

What "prose edit" means: text/markdown content where no code parses or executes from the change. Editing a shell snippet inside a markdown code fence is NOT a prose edit — delegate that to a subagent so the snippet is actually tested.

### Three-tier model
- **Opus:** plan + decompose + synthesise + prose exceptions above
- **Sonnet:** all multi-step edits, new files, complex content
- **Haiku:** single-file edits, doc updates, version bumps

## CRITICAL: Do Not Use Opus for Haiku-Level Work

If ALL of these are true, MUST use `quick-fix` agent (haiku):
- Single file affected
- Fewer than 5 lines changed
- No reasoning about correctness needed (typo, rename, version bump, URL fix)
- No test verification required after the change

```
Agent(subagent_type="quick-fix", model="haiku",
      prompt="In <file>, change <old> to <new>. Reason: <why>")
```

## Haiku for Context Summarisation (Cost Compression)

When `context_monitor.sh` reports ≥ 65% context usage, or before a loop expected to exceed 20 turns, **opus decides to delegate** the summarisation of `CURRENT_WORK.md` to haiku. This is a deliberate delegation decision by opus — it is not haiku autonomously writing session state. Opus determines what to summarise and when; haiku executes the write:

```
Agent(
  subagent_type = "quick-fix",
  model = "haiku",
  prompt = "Read CURRENT_WORK.md and the recent conversation state. Write a concise prose summary (max 300 words) of: (1) what was accomplished this session, (2) key decisions made and why, (3) exact next step. Overwrite CURRENT_WORK.md with this summary. No preamble."
)
```

This implements recursive summarisation: a cheap model compresses the expensive model's accumulated context before it grows quadratically. Opus retains ownership of CURRENT_WORK.md; haiku is a delegate writer, not an autonomous updater.

**Trigger conditions (ANY ONE):**
- `CLAUDE_CONTEXT_USAGE_PERCENT` ≥ 65
- About to start a `/loop` or multi-turn automation
- About to spawn 3+ sequential subagents

**Do NOT use haiku for summarisation when:**
- Context < 40% (premature compression adds latency)
- The session involves active debugging with many intermediate states needed

## CRITICAL: Do Not Use Opus for Sonnet-Level Work

If the task matches a named agent's trigger, MUST delegate:

| Signal in user request | Agent |
|------------------------|-------|
| "run tests", "fix test failure" | `r-debugger` |
| "review this PR/code" | `reviewer` |
| "nix shell broken", "package missing" | `nix-env` |
| "pipeline failed", "tar_make", "build targets" | `targets-runner` (wraps in `nix develop --command` for T lang projects) |
| "shinylive", "WASM build" | `shinylive-builder` |
| "async", "ExtendedTask", "crew bug" | `shiny-async-debugger` |
| "validate data", "pointblank" | `data-quality-guardian` |
| "dbt", "SQL pipeline" | `data-engineer` |
| "review for issues" (read-only) | `critic` |
| "apply fixes from report" | `fixer` |
| "compile wiki from raw" | `wiki-curator` |

## Keep in Opus (Do NOT Delegate)

- Multi-file architecture decisions
- Plan creation requiring user dialogue
- Synthesising results from multiple agents
- Prose edits to memory, rules, CLAUDE.md, CHANGELOG (scope above)
- CURRENT_WORK.md updates (opus writes directly, or delegates the write to haiku when context compression is needed — opus always decides when and what to compress)
- Ambiguous requirements needing clarification
- Roborev triage closures (`comment` + `close` on individual reviews)

## Burn-Rate-Aware Escalation

When `burn_rate_check.sh` reports WARN or CRITICAL:

| Severity | Orchestrator action |
|----------|---------------------|
| WARN | Prefer sonnet agents. Use haiku for all single-file edits. Defer speculative exploration. |
| CRITICAL | Opus for user dialogue only. ALL code work via sonnet/haiku agents. Suggest worktree: `git worktree add ../<repo>-sonnet feat/<task> && cd ../<repo>-sonnet && claude --model sonnet` |

## Mandatory: isolation:"worktree" for Agent Dispatches with Bash

For the canonical path to use when creating worktrees, see the `worktree-location`
rule and `~/.claude/scripts/cc-worktree.sh`.

Per the `permission-discipline` rule, `bypassPermissions` is safe ONLY inside
worktrees and `/tmp/*`. It is NEVER safe in the main checkout, where live API
tokens and credentials sit. An agent running `bypassPermissions` in the main
checkout can silently overwrite `.Renviron`, `default.nix`, or any other
file without a confirmation prompt.

**Therefore:** ANY Agent dispatch where the agent may invoke Bash MUST be
called with `isolation: "worktree"`. This includes:

| Agent | Bash? | Worktree required? |
|-------|-------|--------------------|
| `fixer` | Yes | **Yes** |
| `r-debugger` | Yes | **Yes** |
| `targets-runner` | Yes | **Yes** |
| `nix-env` | Yes | **Yes** |
| `shiny-async-debugger` | Yes | **Yes** |
| `data-quality-guardian` | Yes | **Yes** |
| `data-engineer` | Yes | **Yes** |
| `shinylive-builder` | Yes | **Yes** |
| `wiki-curator` | Yes | **Yes** |
| `quick-fix` (haiku) | No | Optional |
| `critic` (read-only) | No | Optional |

### Mandatory Agent Dispatch Prefixes (BOTH required)

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

### Tier 3 — Post-Agent Verification

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

### Right vs Wrong

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

## Parallel Worktree Sessions

For independent tasks, spawn a sonnet-only worktree session:

```bash
# Orchestrator creates worktree for delegated work
git worktree add ../<repo>-<task> feat/<task>
# User runs: cd ../<repo>-<task> && claude --model sonnet
```

Worktrees share `.git` and `.claude/` config. Each gets its own branch.
Use `tar_config_set(store = "_targets_<branch>")` to isolate targets stores.
