---
name: branch-salvage-workflow
description: Three-step pre-salvage check before rebasing or cherry-picking stale branches; prevents dispatching subagents to no-op work
type: rule
---

# Rule: Branch Salvage Workflow

## When This Applies

Every time you consider rebasing, cherry-picking, or "salvaging work from" a stale branch. Triggered by `/cleanup`, manual branch triage, "what should I do with branch X?" questions, or any orchestrator decision to spawn a subagent on a stale branch.

## CRITICAL: `git cherry` Is Necessary But Not Sufficient

The standard "branch ahead/behind" view (`git rev-list --count`) only counts commits by **SHA**. It cannot detect commits whose content was incorporated via squash-merge, rebase, or independent re-implementation — these show as "N commits ahead" even when the patch is already applied.

`git cherry main <branch>` compares branches by **patch-id** (the hash of the diff content), not commit SHA. This catches cherry-picks and rebases — but it **does NOT catch squash-merges** (one diff becomes the union of N original diffs, matching none of them).

In a 2026-05-19/20 llmtelemetry cleanup pass, **4 of 6 "salvage candidates" turned out to be no-ops**:

| Branch | Detected by `git cherry`? | Actually obsolete via |
|---|---|---|
| `chore/backup-config-version-bump` | Yes (`-`) | Direct match |
| `feat/unified-duckdb-migration` | Yes (`-`) | Direct match |
| `fix/aria-fullscreen-sweep` | **No** (`+`) | Squash-merge of #64 (commit `469d709`) |
| `feat/dashboard-refresh-issue27-phase3` | **No** (`+`) | Squash-merge of PR #67 (commit `d6482fe`) |
| `feat/commits-tab-multiproject` | **No** (`+`) | Re-implementation via PR #103 |
| `fix/issue-83-privacy-sanitization-job-936` | n/a | Independent sanitization pass |

`git cherry` caught 2 out of 6. The other 4 needed deeper checks.

## The 3-Step Pre-Salvage Workflow (MANDATORY)

For every unmerged branch under consideration:

### Step 1 — Patch-id check

```bash
git cherry main <branch>
```

- All lines `-` → patch already in main → **DISCARD**
- All lines `+` → continue to step 2
- Mixed → investigate per-commit; partial overlap

This catches the cheap cases. Cost: <1 second per branch.

### Step 2 — Closing-PR check (catches squash-merges)

If the branch references an issue (look at last commit subject for `#N` or branch name like `feat/issue-83-...`):

```bash
issue=$(git -C <repo> log <branch> --oneline | grep -oE '#[0-9]+' | head -1 | tr -d '#')
gh issue view "$issue" --comments | tail -30
gh pr list --search "closed:$issue" --state closed
```

- Issue closed with a merge commit not in the branch → branch is OBSOLETE
- Closing PR shipped equivalent work via squash → branch's commits won't match by patch-id but content is in main
- Closing PR re-implemented the feature differently → branch is REDUNDANT

This catches the squash-merge case. Cost: ~10 seconds per branch.

### Step 3 — Unique-strings check (catches re-implementations)

Take 2-3 distinctive strings from the branch's diff (function names, comment fragments, error messages) and grep current main:

```bash
git -C <repo> diff main...<branch> | grep '^+' | head -30   # what does the branch add?
# pick 2-3 distinctive strings, then:
grep -rn "<unique-string-1>" R/ inst/ vignettes/ tests/
grep -rn "<unique-string-2>" R/ inst/ vignettes/ tests/
```

- String exists in main → re-implementation detected → DISCARD
- String absent from main → genuinely new work → SALVAGE CANDIDATE

This catches the re-implementation case (different code, same outcome). Cost: ~30 seconds per branch.

## Decision Matrix

| Step 1 (cherry) | Step 2 (closing PR) | Step 3 (strings) | Verdict |
|---|---|---|---|
| All `-` | n/a | n/a | DISCARD — patch-id match |
| Some `+` | Issue closed via squash | n/a | DISCARD — squash-merged |
| Some `+` | Issue still open or no issue | All strings in main | DISCARD — re-implemented |
| Some `+` | Issue still open or no issue | Strings absent from main | SALVAGE CANDIDATE — investigate before rebasing |

## Helper Script

`~/.claude/scripts/branch-cherry-check.sh <branch>` runs all 3 steps and prints a verdict.

## Orchestrator Responsibilities

Before dispatching a subagent to rebase or cherry-pick a stale branch, the orchestrator MUST:

1. Run the 3-step workflow (manually or via the helper)
2. If verdict is DISCARD, do NOT spawn an agent. Delete the branch with appropriate user authorization.
3. Only dispatch a salvage agent if verdict is SALVAGE CANDIDATE — and only after confirming with the user when the branch is non-trivial (3+ commits, multiple files).

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Dispatching a fixer agent to rebase a branch without running step 1 | Wastes a subagent turn on a no-op; agent's only finding will be "empty diff" | Run `git cherry` first |
| Relying solely on `git cherry` for salvage decisions | Misses squash-merges and re-implementations — 4 of 6 cases in the original incident | Always run all 3 steps |
| Treating "issue is closed" as automatic discard | Some closing PRs don't fully address the issue; branch may have unique work | Run step 3 to verify |
| Skipping step 3 because step 2 is inconclusive | Re-implementations don't show in PR threads | Step 3 catches what 1 and 2 miss |

## Related

- [llmtelemetry#129](https://github.com/JohnGavin/llmtelemetry/issues/129) — origin issue documenting the squash-merge limitation discovery
- `auto-delegation` — orchestrator rules; this workflow is a pre-delegation check
- `~/.claude/scripts/branch-cherry-check.sh` — runnable helper

## Origin

Discovered 2026-05-19/20 in a llmtelemetry cleanup pass: `git cherry` correctly identified 2 of 6 already-applied branches but missed the other 4 (squash-merges + re-implementations). Three subagents (F, G, K) were dispatched on no-op work before the orchestrator added steps 2 and 3 to the workflow.
