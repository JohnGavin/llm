---
paths:
  - ".claude/agents/**"
  - ".claude/rules/auto-delegation.md"
---
# Auto-Delegation — Dispatch Details

Full verbatim prefixes, Tier 3 verification pattern, SendMessage caveat,
cross-repo write pattern, and right/wrong examples.
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

**Substitution table referenced in Prefix 1** — orchestrators MUST point agents to this table when handing off Bash-heavy work:

| Don't write              | Write instead                                |
|--------------------------|----------------------------------------------|
| `cat F \| head -N`         | `Read(F, limit=N)`                           |
| `grep -rn P path \| head`  | `Grep(pattern=P, path=path, head_limit=N)`   |
| `find ... \| head`         | `Glob(pattern)`                              |
| `cmd 2>&1 \| head -50`     | `cmd >/tmp/x 2>&1`, then `Read(/tmp/x)`      |
| `cmd \|\| echo "missing"` | plain `cmd`; check exit code in next call    |

Single trailing `\| head` / `\| tail` / `\| wc` / `\| sort -u` / `\| uniq` is allowed by the compound guard since #393 Phase 1.

**Prefix 2 — Worktree isolation** (closes `JohnGavin/llm#191`; strengthened
for `llm#304` and `llm#318`):

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

When you finish, your report MUST include FOUR self-check lines:
  1. pwd — must start with $WORKTREE_PATH
  2. git -C $WORKTREE_PATH rev-parse --abbrev-ref HEAD — must NOT be `main`
     AND must NOT be a `feat/cc-*` branch belonging to the parent session
  3. Last commit SHA on YOUR worktree's branch (from git log -1 --format=%H)
  4. Exact `git push` ref used — must equal the result of self-check (2)
     (the push target MUST equal your current branch, nothing else)

If self-check (1) fails: STOP — you are in the wrong directory.
If self-check (2) returns `main` or a `feat/cc-*` branch: STOP — you are on
the wrong branch; do NOT commit or push.
If self-check (4) does not match self-check (2): STOP — wrong push target.

The agent_push_guard.sh hook (#318) will also block mismatched push targets
at the hook level; the self-check here provides early warning before you reach
the push call.
```

**Prefix 3 — Progress markers for long-running operations** (closes llm#541):

```
**CRITICAL — Stream-watchdog:** The harness fires a 600s stream-watchdog if no
output appears. Before every operation that may take >30s (nix-shell builds,
duckdb queries, devtools::check, tar_make), emit a one-line progress marker:
  echo "PROGRESS: starting nix-shell build for <reason>"
  echo "PROGRESS: running duckdb migration"
This prevents false-positive watchdog kills on legitimate long-running work.
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

**Extended in llm#304 / llm#318:** the script now snapshots BOTH the main
HEAD AND the orchestrator's current-branch HEAD. A Tier-3 check that only
watches `main` misses breaches where the agent commits to the orchestrator's
active session branch (`feat/cc-*`) instead of its own harness-worktree branch.

**Pattern (use the helper script; manual pattern shown for reference):**

```bash
# Before dispatch — capture BOTH heads
STATE=$(~/.claude/scripts/agent-post-verify.sh capture <repo> --id "$DISPATCH_ID")

# ... dispatch agent, wait for completion ...

# After completion — checks main AND current branch
~/.claude/scripts/agent-post-verify.sh check <repo> --id "$DISPATCH_ID"
```

The helper (`agent-post-verify.sh`) handles both main-only and current-branch
drift. Pass the same `--id` token to both calls so the state file is found.

**When the check fires:**

| Verdict | Meaning | Action |
|---|---|---|
| `HEAD_MOVED_SAME_BRANCH` | Agent committed directly to the checked-out branch | Preserve as `agent-recovery-*` branch; reset HEAD; alert user |
| `HEAD_MOVED_BRANCH_CHANGED` | Agent switched + committed | Switch back to original branch; cherry-pick from new branch |
| `BRANCH_CHANGED_NO_COMMITS` | Agent switched without committing | Switch back; no data loss |
| `UNCOMMITTED_WRITES` | Agent wrote to working tree without committing | Review diff; commit to feature branch or discard |
| `SESSION_BRANCH_HEAD_MOVED` (NEW #304/#318) | Agent committed to orchestrator's session branch | See SESSION_BRANCH recovery in the script; dispatch fresh agent |
| `SESSION_BRANCH_SWITCHED` (NEW #304/#318) | Agent switched the orchestrator away from its session branch | `git -C <repo> checkout <session-branch-before>` |
| No drift | Agent honoured isolation | Proceed normally |

**Logging:** every check writes to `~/.claude/logs/worktree_post_verify.log`
with timestamp, agent ID, before/after SHA, and verdict. Review this log
periodically to gauge whether Tier 1+3 alone is sufficient or whether Tier 2
(hook enforcement) is needed.

---

## SendMessage Continuations — Write Safety (#304)

**CRITICAL:** Do NOT use `SendMessage` to continue an agent when the follow-up
work involves any write (edit, commit, push).

### Why

SendMessage continues an existing agent. When the original agent's worktree has
been cleaned (branch merged, harness worktree removed) or when the harness
restarts, the continuation falls back to the **orchestrator's cwd** and writes
to the main checkout or to the orchestrator's session branch (`feat/cc-*`). This
happened twice in a 2026-05-25 llmtelemetry session (#304):

- Case 1: merged branch cleaned → continuation committed to main checkout.
- Case 2: live branch, continuation ran in orchestrator checkout → stale commit
  on `feat/cc-*`, 40 commits behind main, re-creating already-deleted files.

Fresh `isolation: "worktree"` dispatches were always correctly isolated. Only
SendMessage continuations failed.

### Rule

| Continuation type | Action |
|---|---|
| Write (edit/commit/push) | Dispatch a **fresh `isolation: "worktree"` agent** — never SendMessage |
| Read-only / advisory | SendMessage is safe (no write surface) |
| Original worktree is verifiably live (confirm pwd before proceeding) | SendMessage MAY be used if you verify the live worktree path first |

### Anti-patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `SendMessage` to fixer agent after merging its PR | Worktree cleaned; continuation runs in orchestrator checkout | Fresh fixer dispatch |
| `SendMessage` to continue a fix iteration | Falls back to orchestrator cwd when harness restarts | Fresh fixer dispatch with the iteration context in the prompt |
| `SendMessage` for a "quick follow-up commit" | No worktree guarantee — any write goes to the wrong branch | If truly quick, orchestrator does it; if not, fresh dispatch |

---

## Cross-Repo Writes from a Worktree-Isolated Agent (#182)

When an llm session needs to edit another repo (e.g., `llmtelemetry`), subagents
launched with `isolation: "worktree"` are sandbox-confined to their harness
worktree and cannot write to external paths. The established workaround is to
pre-create a target-repo worktree that the agent uses as its `$WORKTREE_PATH`.

### Pattern

1. **Orchestrator pre-creates a target-repo worktree:**
   ```bash
   ~/.claude/scripts/cc-worktree.sh llmtelemetry feat/my-fix
   # → ~/worktrees/llmtelemetry/feat/my-fix/
   ```

2. **Dispatch the agent with `isolation: "worktree"`.** The harness creates an
   llm worktree that the agent ignores. The dispatch prompt explicitly overrides
   `$WORKTREE_PATH` to the target-repo worktree and authorises ALL writes only
   under that path:
   ```
   **CRITICAL — Worktree isolation:** Your worktree is
   /Users/johngavin/worktrees/llmtelemetry/feat/my-fix/
   ALL writes target that path only ...
   ```

3. **Agent commits + pushes** to the target repo's feature branch; opens PR
   in the target repo (not in llm).

4. **Orchestrator captures BOTH repos' states** (main + current branch) before
   dispatch; calls `agent-post-verify.sh check` on **both repos** after the
   agent finishes.

### Dual-repo post-verify example

```bash
# Before dispatch
~/.claude/scripts/agent-post-verify.sh capture ~/docs_gh/llm --id "$ID"
~/.claude/scripts/agent-post-verify.sh capture ~/worktrees/llmtelemetry/feat/my-fix --id "${ID}-target"
# ... dispatch agent ...
# After completion
~/.claude/scripts/agent-post-verify.sh check ~/docs_gh/llm --id "$ID"
~/.claude/scripts/agent-post-verify.sh check ~/worktrees/llmtelemetry/feat/my-fix --id "${ID}-target"
```

### Decision: status-quo + documented pattern (#182 resolution)

After review (see llm#182), the decision is **status quo + this documented
pattern**. Subagents cannot write outside their sandbox unconditionally. The
pre-created target-repo worktree gives them an explicit, scoped write surface.
This preserves blast-radius containment and keeps `destructive-fs-guard`,
`no-compound-cd`, and `destructive-api-calls` active.

Evidence: PR #243 (llmtelemetry roborev dashboard) shipped via this pattern in
2026-05-28. References #182 + #190 (cross-project-scope) + #287 Part B.

---

## `gh` CLI — Always Use `--body-file` (#200)

**CRITICAL:** Never use `--body "$(cat ...)"` or `--body "$var"` with multiline content
in any `gh` CLI call. Use `--body-file <path>` instead.

### Why

`--body "$(cat /tmp/file.md)"` is a command substitution. Claude Code's static
analyser cannot see inside `$(...)`, so every such call triggers an approval prompt
("Contains shell syntax that cannot be statically analysed"). With `--body-file`,
the path is visible in the command and the allowlist works correctly — zero prompts.

The same applies to `--body "$multiline_var"` when the variable contains markdown
with pipes, backticks, or tables (heredoc-body failures, see llm#200).

### Supported commands

`--body-file` exists on all these subcommands:

```
gh pr create  --body-file <path>
gh pr edit    --body-file <path>
gh pr comment --body-file <path>
gh issue create  --body-file <path>
gh issue edit    --body-file <path>
gh issue comment --body-file <path>
gh release create --notes-file <path>
```

### Required pattern (agents AND scripts)

```bash
# WRONG — triggers approval prompt
gh pr create --title "..." --body "$(cat /tmp/body.md)"
gh issue comment 42 --body "$multiline_var"

# RIGHT — statically analysable, zero prompts
_body=$(mktemp /tmp/gh_body_XXXXXX.md)
printf '%s' "$body_content" > "$_body"
gh pr create --title "..." --body-file "$_body"
rm -f "$_body"
```

Cleanup is mandatory. Use `rm -f` immediately after the `gh` call, or register a
`trap 'rm -f "$_body"' EXIT` at the top of the function.

**Exception:** `git commit -m "$(cat <<'EOF' ... EOF)"` patterns are NOT affected —
these are git, not gh CLI, and do not trigger the same approval path. Leave those
as-is. Document the exception with a comment when the two patterns appear near each
other.

### Reference

- llm#200 — origin issue with full options analysis
- `bash-safety` rule — compound commands; `$(...)` is a related surface

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

# RIGHT: isolation set + BOTH prefixes injected + FOUR self-checks required
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
NEVER git checkout to a different branch. End-of-run report MUST include FOUR
self-checks:
  1. pwd — must start with the worktree path above
  2. git rev-parse --abbrev-ref HEAD — must NOT be main, must NOT be feat/cc-*
  3. Last commit SHA (git log -1 --format=%H)
  4. Exact git push ref used — must equal self-check (2)

Fix R/foo.R line 42 — add NA check before division.""")
```

---

## Sections Moved from the Rule Body (2026-07-29 line-limit pass, llm#749)

### Cross-Repo Writes — dispatch-prompt detail

For cross-repo writes (e.g. llm session edits llmtelemetry): pre-create the target
repo's worktree via `cc-worktree.sh`, set `$WORKTREE_PATH` to that path in the
dispatch prompt, and run dual-repo post-verify after completion.

### Read-Only Cross-Repo Verify → Parallel, NO Worktree (full section)

The `isolation: "worktree"` requirement is a WRITE-safety guard (stop a
`bypassPermissions` agent clobbering the main checkout). It does NOT apply to
read-only agents, and when the target files live in a **different repo** from the
session cwd, worktree isolation is actively HARMFUL — the harness worktrees the
*session's* repo, so the agent cannot reach the other repo at all (the #182
cross-repo failure). This is common when a project session verifies content in the
local-only knowledge hub (`~/docs_gh/llm/knowledge/**`).

**Rule:** dispatch read-only verifiers (`critic`, `reviewer`, `Explore`, or
`general-purpose` restricted to Read/Grep/Glob) that target a separate repo:

- **in parallel** — multiple `Agent` calls in ONE message, each a distinct
  adversarial lens (e.g. citation-faithfulness · domain-correctness ·
  schema/structural-integrity). Parallelism belongs in *verification*.
- **WITHOUT `isolation: "worktree"`** — read-only needs no write sandbox, and a
  worktree would sever cross-repo access.

**Corollary for the write side.** The fixer/curator half of a cross-repo
*local-hub* task (a repo that is never pushed, e.g. the knowledge hub) also runs
**without worktree**, restricted to file-tools (no Bash, no git), with the
orchestrator doing the commit afterward. Do NOT parallelise a single-file fix —
concurrent edits to one file conflict; the parallelism was spent in verification.
(For cross-repo writes to a *pushed* repo, use the `$WORKTREE_PATH` pre-create
pattern above instead.)

| Cross-repo task | Isolation | Concurrency |
|---|---|---|
| Read-only verify (separate repo) | none (read-only) | parallel, diverse lenses |
| Write to local-only hub (never pushed) | none; file-tools + no Bash; orchestrator commits | serial per file |
| Write to a pushed repo | pre-created `$WORKTREE_PATH` worktree (#182) | per dual-repo post-verify |

Origin: 2026-07-03/04 oncology-hub immunoparesis note — curator/fixer written and
critic-verified across the mycare→knowledge-hub boundary; a 3-lens parallel
read-only re-audit ran with no worktrees. See `agent-identity-and-task-scopes`
(scope propagation) and `worktree-location` (harness worktree conventions).

### Mandatory: isolation:"worktree" — bypassPermissions rationale

Per the `permission-discipline` rule, `bypassPermissions` is safe ONLY inside
worktrees and `/tmp/*`. It is NEVER safe in the main checkout, where live API
tokens and credentials sit. An agent running `bypassPermissions` in the main
checkout can silently overwrite `.Renviron`, `default.nix`, or any other
file without a confirmation prompt.

`~/.claude/` symlinks and cross-repo symlinks (e.g. a `.claude/scripts/` file
pointing into a sibling repo) are sandbox-escaping — the path looks
in-worktree but the bytes land outside it; the `worktree_symlink_guard` hook
(llm#692) now enforces this at every `PreToolUse:Edit|Write` call.

### Canonical worktree path cross-reference

For the canonical path to use when creating worktrees, see the `worktree-location`
rule and `~/.claude/scripts/cc-worktree.sh`.

### Relocated reference tables (from auto-delegation.md, llm#749 trim)

**Per-agent `isolation:"worktree"` requirement.** ANY Agent dispatch where the
agent may invoke Bash MUST use `isolation: "worktree"`:

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
| `quick-fix` (lightweight tier) | No | Optional |
| `critic` (read-only) | No | Optional |

> **quick-fix tool limitation (#223 recurrence pattern):** the lightweight tier
> `quick-fix` agent has Read/Grep/Glob/Edit but NO Bash — it cannot `git commit`,
> `git push`, `gh pr create`, or `roborev close`. Dispatching it for tasks needing
> any of those is a dispatch error — use `fixer` (worker tier) instead.

**Burn-Rate-Aware Escalation.** When `burn_rate_check.sh` reports WARN or CRITICAL:

| Severity | Orchestrator action |
|----------|---------------------|
| WARN | Prefer worker-tier agents. Use lightweight tier for all single-file edits. Defer speculative exploration. |
| CRITICAL | Orchestrator tier for user dialogue only. ALL code work via worker/lightweight agents. Suggest worktree: `git worktree add ../<repo>-worker feat/<task>` then `claude --model sonnet` in that tree |
