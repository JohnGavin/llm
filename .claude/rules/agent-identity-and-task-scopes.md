---
description: Every dispatched agent carries a propagated identity (dispatch_id) and an explicit task scope (write-paths, TTL). Permissions expire. All writes are tagged for audit.
type: mandatory
---

# Rule: Agent Identity and Task Scopes (Mandatory)

## When This Applies

Every Agent tool dispatch that uses `isolation: "worktree"`, regardless of
agent type. Applies to: `fixer`, `r-debugger`, `nix-env`, `targets-runner`,
`shiny-async-debugger`, `data-quality-guardian`, `data-engineer`,
`shinylive-builder`, `wiki-curator`.

Does NOT apply to read-only agents (`critic`, `reviewer`) or haiku `quick-fix`
dispatches with no Bash access.

---

## CRITICAL: Identity Is Propagated End-to-End; Scope Is Explicit and Expiring

Every dispatched agent carries an identity bundle minted by the orchestrator.
That identity propagates across every Bash, Edit, and Write call the agent makes —
through environment variables, commit-message footers, and post-verify state
files. No agent may invent or inherit another agent's identity. Every write the
agent performs is tagged with its dispatch ID so the orchestrator can later answer
"what did agent X touch and when?"

Permissions are scoped and time-limited. An agent authorised at minute 0 to open
a PR is NOT authorised at minute 61 without a fresh dispatch. An agent authorised
to edit `R/foo.R` is NOT authorised to edit `~/.claude/scripts/` — even if that
path happens to be accessible via symlink.

---

## Dispatch ID Propagation

The orchestrator generates one UUID per dispatch before the Agent tool call:

```bash
DISPATCH_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
```

This ID appears in FOUR places:

| Place | What it looks like |
|---|---|
| Agent's prompt | `DISPATCH_ID=abc123ef ...` injected into Prefix 2 |
| Worktree git note | `git notes --ref=dispatch add -m "dispatch=$DISPATCH_ID ..."` on the tip commit |
| Post-verify state file | `~/.claude/logs/agent_post_verify_${DISPATCH_ID}.json` |
| Every commit footer | `Dispatch-Id: abc123ef` on every commit the agent creates |

### Why four places

One is not enough. The prompt can be ignored (agent still exposes the env var).
The commit footer survives rebases. The git note survives branch deletion (until
`git notes prune`). The state file is the orchestrator's ground truth for
post-verify reconciliation.

### Commit footer format

Every commit the agent creates MUST end with:

```
Dispatch-Id: <dispatch_id>
Agent-Type: <fixer|r-debugger|nix-env|...>
```

The orchestrator can then query: `git log --grep="Dispatch-Id: abc123ef"` to
enumerate every commit the agent made without having to track branch names.

---

## Task Scope Declaration

The orchestrator's dispatch prompt MUST include an explicit scope block AFTER
the two mandatory prefixes (Bash discipline + worktree isolation). The scope
block uses this format:

```
TASK SCOPE (dispatch_id=<uuid>, expires=<ISO-8601 timestamp>):
  write-paths:
    - <worktree-absolute-path>/**          # the agent's own worktree
  read-paths:
    - ~/docs_gh/llm/**                     # main checkout — READ ONLY
    - /nix/store/**                        # read-only by definition
  allowed-external-ops:
    - gh issue create                      # OK
    - gh pr create                         # OK
    - git push origin <own-branch>         # OK — own branch only
  forbidden-external-ops:
    - gh pr merge                          # orchestrator only
    - AGENT_PUSH_OK=1 (unless scope says so)
    - writes to any path under ~/.claude/  # symlink-trapped (see #517 Pattern 2)
  ttl-minutes: 45
```

### Symlink-trapped paths

`~/.claude/scripts/` and `~/.claude/hooks/` are symlinks that resolve into the
orchestrator's main checkout (`~/docs_gh/llm/.claude/scripts/`). An agent writing
to these paths via their `~/.claude/` address is writing OUTSIDE its worktree
sandbox — the write lands in the orchestrator's working tree, not the agent's PR
diff. This is the Pattern 2 failure from llm#517.

The scope block MUST list `~/.claude/` as forbidden in `forbidden-external-ops`.
The `PreToolUse:Edit|Write` hook (future: llm#517) will resolve symlinks before
the boundary check.

---

## Expiring Permissions

| Time window | Authorised | Not authorised |
|---|---|---|
| 0–TTL | All scope block operations | Anything outside scope |
| After TTL | Nothing new | All new operations |

The TTL is advisory in Phase 1 — the orchestrator checks expiry after the agent
returns. In Phase 2, hooks will check `CLAUDE_DISPATCH_EXPIRES_AT` (ISO
timestamp) before allowing each Bash call and reject calls after expiry.

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

---

## Audit Trail

The orchestrator can reconstruct a full audit of any dispatch:

```bash
# All commits from a dispatch
git log --all --grep="Dispatch-Id: abc123ef" --format="%h %s"

# All paths touched
git log --all --grep="Dispatch-Id: abc123ef" --name-only --format="" | sort -u

# Post-verify outcome
cat ~/.claude/logs/agent_post_verify_abc123ef.json
```

The post-verify state file (`agent-post-verify.sh capture/check`) is written
with the dispatch ID in its path, making dispatch-to-outcome reconciliation
unambiguous.

---

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Agent invents its own dispatch ID | Breaks audit reconciliation | ID minted by orchestrator before dispatch |
| Agent operates on paths not in its scope | Worktree isolation breach | Declare ALL write-paths in scope block |
| `AGENT_PUSH_OK=1` without scope authorisation | Bypasses guard without justification | Only use when scope explicitly authorises it |
| Agent writes to `~/.claude/scripts/` from a worktree | Symlink exits worktree sandbox (#517 Pattern 2) | Forbidden in scope block; hook check in Phase 2 |
| TTL expires; agent continues operating | Stale permissions | Orchestrator post-verify checks expiry; Phase 2 hooks block |
| Commit footer missing `Dispatch-Id:` | Cannot audit what agent touched | Always include footer |
| SendMessage continuation after TTL expires | Continuation carries expired identity | Fresh dispatch with new ID and TTL |

---

## Worked Example & Phase Roadmap

See [`_companions/agent-identity-details.md`](_companions/agent-identity-details.md)
for the full dispatch worked example (mint → dispatch → post-verify → audit) and
the phase roadmap. The normative protocol above is complete without it.

---

## Related

- [`auto-delegation`](.claude/rules/auto-delegation.md) — dispatch model; Mandatory Prefixes 1 + 2; this rule adds Prefix 3 (scope block)
- [`agent-no-push-to-main`](.claude/rules/agent-no-push-to-main.md) — Guard A + Guard B; Phase 2 will add Guard C (scope + expiry)
- [`permission-discipline`](.claude/rules/permission-discipline.md) — workspace-based policy; gains identity dimension in Phase 2
- [`auto-delegation-dispatch-details`](.claude/rules/_companions/auto-delegation-dispatch-details.md) — verbatim prefixes; scope block is Prefix 3
- `unified-observability-schema` (#475) — the dispatch audit log feeds into the unified schema
- llm#476 — origin issue (Salesforce Principle 4: Build with trust)
- llm#517 — two concrete failure modes this rule addresses (AGENT_PUSH_OK misuse + symlink breach)
