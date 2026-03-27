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

## Guardrails

- NEVER skip the VERIFY step (even in "just do it" mode)
- NEVER claim completion without fresh `devtools::check()` output
- NEVER exceed 3 orchestrator rounds — escalate to user if stuck
- ALWAYS save orchestrator state to CURRENT_WORK.md (survives compression)
