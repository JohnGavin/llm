---
paths:
  - "R/**"
  - "vignettes/**"
  - "plans/**"
---
# Orchestrator Protocol

Auto-coordinates agents after any plan is approved. Implements the verify→review→fix→score loop.

## Activation

Activates when:
1. A plan (from `architecture-planning` or `writing-plans`) is approved by the user
2. User says "approved", "looks good", "go ahead", or "just do it"

Does NOT activate for: trivial edits (<3 files), single-function fixes, documentation-only changes.

## The Loop

```
Plan approved
  → Step 1: IMPLEMENT — Execute the plan checklist
  → Step 2: VERIFY — Run devtools::check() or quarto render
  → Step 3: REVIEW — Select agents by file type, run in parallel
  → Step 4: FIX — Critical → Major → Minor
  → Step 5: RE-VERIFY — Fresh check after fixes
  → Step 6: SCORE — quality-gates rubric
  → If score < Bronze (80): loop to Step 3 (max 3 rounds)
  → If score >= Bronze: present summary to user
```

## Agent Selection by File Type

| Files Modified | Agents Selected |
|---|---|
| `R/*.R` | `reviewer` (code quality) + `r-debugger` (if tests fail) |
| `vignettes/*.qmd` | `reviewer` + critic pass (read-only) |
| `R/tar_plans/*.R` | `targets-runner` (pipeline validation) |
| `inst/shiny/**` | `shiny-async-debugger` (if async) |
| `default.nix` / `default.R` | `nix-env` (environment check) |
| Multiple formats | Run applicable agents in parallel |

## Critic-Fixer Integration

When review finds issues:
1. **Critic pass** (read-only): Identify all issues with severity
2. **Fixer pass** (read-write): Apply fixes for Critical, then Major, then Minor
3. **Re-critic** (read-only): Verify fixes, find remaining issues
4. Max 3 critic-fixer rounds per orchestrator loop

See `critic.md` and `fixer.md` agents for details.

## "Just Do It" Mode

When user says "just do it": run the full loop but skip final approval pause.
Auto-commit if score >= Bronze (80). Report summary after.

## Scoring Integration

Uses `quality-gates` skill thresholds:
- **>= 95 (Gold)**: Ready to merge
- **>= 90 (Silver)**: Ready for PR
- **>= 80 (Bronze)**: Safe to commit
- **< 80**: BLOCKED — must fix before proceeding

## Auto-Revert on Score Regression

If the quality-gate score **drops** compared to the previous commit's score:

1. `git stash` or `git checkout -- .` to revert the changes
2. Log the failure to CHANGELOG.md under "Failed Approaches" with the score delta
3. Report to user: "Score dropped from X to Y. Changes reverted."

**Commit-or-revert rule:** Every experiment/change results in one of two outcomes:
- Score improved or maintained → **COMMIT** with structured message
- Score dropped → **REVERT** and log why it failed

This prevents accumulation of "small regressions" that compound into large quality debt.

## Session Log Entry

After each orchestrator run, append to CURRENT_WORK.md:
```markdown
### Orchestrator Run [timestamp]
- Plan: [plan name]
- Rounds: [N]
- Agents used: [list]
- Final score: [score] ([grade])
- Issues fixed: [N critical, N major, N minor]
```

## Background Agent Activity Timeout (MANDATORY)

When a background agent is running (`run_in_background: true`), the orchestrator MUST track activity and intervene if it stalls. The Agent runtime does not always emit a completion notification when an agent is killed by a rate limit, OOM, network drop, or stuck prompt — silence beyond the threshold is a signal, not a wait condition.

### Detection

The orchestrator MUST check, no later than 20 minutes after dispatch and at every subsequent user turn while the agent is still pending:

| Signal | How to check (non-intrusive — never read the agent JSONL transcript) |
|---|---|
| Filesystem activity in the agent's worktree | `ls -la <worktree>/<expected-output-files>` — compare mtime to dispatch time |
| Live process | `ps -eo pid,etime,command \| grep -E "(Rscript\|nix-shell\|quarto-cli)" \| grep <worktree>` |
| Branch commits | `git -C <worktree> log --oneline -3` — has the agent committed yet? |
| Worktree status | `git -C <worktree> status -s` — is there uncommitted work? |

### Intervention thresholds

| Elapsed since last activity | Action |
|---|---|
| < 15 min | Continue waiting. Do not poll proactively. |
| 15-20 min, NO live process AND NO mtime change in last 5 min | Inspect worktree state (tabulate completed vs missing tasks). Report to user. |
| > 20 min, no completion notification | **MANDATORY INTERVENTION.** Take over directly OR re-dispatch a fresh agent with the partial state as input. |
| Any time, completion notification arrives late | Verify the agent's claimed output matches what landed (e.g. compare commit SHAs, file contents). |

### Take-over protocol (when intervening)

1. **Tabulate** what the agent completed vs. what's missing. Use grep/find on the agent's worktree to score each task.
2. **Preserve uncommitted work.** Do NOT `git worktree remove --force` until either:
   - The agent's completion notification has arrived, OR
   - You have committed any uncommitted edits in the agent's worktree to the same branch
3. **Continue on the same branch in the same worktree** when finishing partial work — preserves the agent's commits and lets you build on them.
4. **Commit and push** before any further action. Lost work in an orphaned worktree is irrecoverable.
5. **Force-remove the worktree** only after merge or after confirming the branch is pushed.
6. **Document the takeover** in CURRENT_WORK.md and the resulting commit message — when the agent's late report arrives you'll need to compare outcomes.

### When the agent's late report arrives after takeover

This is a race condition. Resolution:
- If the agent's branch was deleted (orphaned commit): note in the response that the orphan is harmless and the work landed via the orchestrator's path. Compare key outcome signals (HTML size, error count, tab presence) and confirm consistency.
- If the agent's commit ended up on the merged branch (lucky case): no action needed.
- If the agent's commit conflicts with the merged work: investigate; usually safe to discard the agent's branch since the same scope landed via the orchestrator.

### Lesson logged 2026-05-02

In the acd_area_climate_design Phase 3 dashboard rework, an agent stalled for ~30 min with `dashboard.qmd` modified hours earlier and no `git commit`. The orchestrator took over, finished render + commit, merged. The agent's completion notification arrived ~20 min after merge, with a commit on the deleted branch (orphaned). Outcomes matched. Cost: zero data loss; ~10 min orchestrator time finishing the last 2 of 8 tasks.

## Guardrails

- NEVER skip the VERIFY step (even in "just do it" mode)
- NEVER claim completion without fresh `devtools::check()` output
- NEVER exceed 3 orchestrator rounds — escalate to user if stuck
- NEVER wait indefinitely on a background agent — apply the activity-timeout protocol above
- NEVER force-remove an agent's worktree until the agent's commits are pushed OR the completion notification has arrived
- ALWAYS save orchestrator state to CURRENT_WORK.md (survives compression)
- ALWAYS tabulate agent progress before intervening — gives the user a clear picture and the agent's late report a place to land
