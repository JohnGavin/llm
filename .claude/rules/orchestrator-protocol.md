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

### Activity signal: combined process + filesystem

A long network or nix-build step can produce zero filesystem activity for 5-10 min while still being live. So mtime alone is a noisy signal. **The agent is "active" if EITHER condition holds:**

1. A live process (R / Rscript / nix-shell / nix-build / curl / quarto-cli) tied to the agent's worktree exists with non-zero recent CPU
2. A file in the worktree was modified in the last 3 minutes

If NEITHER condition holds, the agent is idle.

### Intervention thresholds

Calibrated against observed run times: 12-13 min for clean completions; >15 min idle = stalled; >30 min total runtime is rare and often masks an unrecoverable issue.

| Elapsed since dispatch | Idle for | Action |
|---|---|---|
| < 8 min | — | Continue waiting. Do not poll proactively. |
| 8-12 min | < 3 min idle | Wait. Likely still working. |
| 8-12 min | ≥ 3 min idle | Inspect worktree state. Tabulate completed vs missing tasks. Report to user. |
| 12-20 min | regardless | Mandatory intermediate check-in: tabulate completed checkpoints, report progress to user, surface any failed-fetch or "unable to" patterns visible in the file system (cached HTTP error files, partial JSONL). |
| > 20 min total | regardless | **HARD CAP.** Even if "active" by signal, prompt user explicitly: "agent has run N min vs forecast M min — intervene now, wait, or re-dispatch?" Do not silently keep waiting past this point. |
| > 15 min | ≥ 5 min idle | **MANDATORY INTERVENTION.** Take over directly OR re-dispatch a fresh agent with the partial state as input. |
| Any time, completion notification arrives late | — | Verify the agent's claimed output matches what landed (e.g. compare commit SHAs, file contents). |

### Network-failure heuristics

A "network failure during a long agent run" looks like: filesystem mtime stale, no commits for >5 min, but a live R / nix-shell / curl process exists with very high cumulative time. The agent is technically "active" by process signal but is blocked on a network operation that may never return.

When you see this pattern, do NOT keep waiting. Symptoms to flag (if visible):

| Signal | What it suggests |
|---|---|
| `ps` shows R / curl / nix-build with >5 min CPU+wall but worktree mtime stale | Likely retrying a failed HTTP / package fetch |
| `*.partial`, `*.tmp`, `*.lock` files appearing then disappearing | Download retry loop |
| The same agent's prior turns took ≤10 min for similar scope | Current run is anomalous; intervene |
| Notification arrives with `"API Error"`, `"ConnectionRefused"`, `"timeout"`, or `"network"` in the result | Already-failed agent — take over the worktree state immediately, do not re-dispatch the same prompt |

### Take-over from a network-failed agent

When the notification finally arrives with a network-error result (rare but observed in practice — e.g. 2026-05-03, an agent ran for 106 min on issue #45 before the API connection refused, after committing 4 of 5 checkpoints):

1. **Do NOT re-dispatch the same prompt.** The agent already did the work locally; only the wrap-up commit is missing.
2. Check `git log` on the agent's branch for partial commits.
3. Check `git status` for uncommitted but rendered/edited files (the dropped final-commit material).
4. Inspect for completeness; if the rendered output looks correct, commit the residual files yourself with a take-over message that names the skipped checkpoint.
5. Push, PR, merge as normal.

This pattern recovered ~106 min of work in about 5 min of orchestrator time. Re-dispatching would have wasted both.

### Strategies to AVOID hitting the hard cap

Prefer dispatching agent runs that fit within ~10-15 min:

- **Smaller scope per dispatch.** A "5-checkpoint" plan with 5 small tasks (each 2-3 min) finishes faster than one 10-task agent in a single dispatch. Each checkpoint commits, so even if the run is interrupted, partial progress is preserved.
- **Reuse existing infrastructure.** If the project already has a fetcher or helper, point the agent at it; do not have it rebuild. Saves time and reduces network calls.
- **Delegate single-file edits to `quick-fix`** (haiku, mechanical) rather than `general-purpose` (sonnet, exploration). Faster + cheaper for narrow tasks.
- **Front-load CDN / nix dependencies.** If a CDN library install or nix derivation rebuild is on the critical path, do it once at session start, not per-agent.

### Calibration: when to allow longer waits

Some legitimate operations take longer:
- Full WFS pull with pagination over slow API: 10-15 min of mostly-idle waiting on HTTP
- Nix build of derivations with new dependencies: 5-15 min of nix-build process activity
- Quarto render of a 50+ MB dashboard: 1-3 min

If the agent's prompt explicitly forecasts a long step (e.g. "the Overpass call may take 10 min"), scale the idle-timeout window for that step accordingly. The hard cap (30 min total) still applies.

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
