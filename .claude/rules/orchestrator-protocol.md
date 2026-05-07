---
paths:
  - "R/**"
  - "vignettes/**"
  - "plans/**"
---
# Orchestrator Protocol

Auto-coordinates agents after plan approval. Implements verify→review→fix→score loop.

## Activation

Triggers when user approves a plan ("approved", "looks good", "go ahead", "just do it").
Does NOT activate for: trivial edits (<3 files), single-function fixes, docs-only changes.

## The Loop

```
Plan approved
  → IMPLEMENT — Execute checklist
  → VERIFY — devtools::check() or quarto render
  → REVIEW — Select agents by file type (parallel)
  → FIX — Critical → Major → Minor
  → RE-VERIFY — Fresh check after fixes
  → SCORE — quality-gates rubric
  → If < Bronze (80): loop (max 3 rounds)
  → If >= Bronze: present summary
```

## Agent Selection

| Files Modified | Agents |
|---|---|
| `R/*.R` | `reviewer` + `r-debugger` (if tests fail) |
| `vignettes/*.qmd` | `reviewer` + `critic` (read-only) |
| `R/tar_plans/*.R` | `targets-runner` |
| `inst/shiny/**` | `shiny-async-debugger` (if async) |
| `default.nix` / `default.R` | `nix-env` |
| Multiple formats | Run applicable agents in parallel |

## Critic-Fixer Integration

1. **Critic** (read-only): Identify issues with severity
2. **Fixer** (read-write): Apply fixes Critical→Major→Minor
3. **Re-critic**: Verify fixes. Max 3 rounds.

## Scoring

| Score | Grade | Action |
|---|---|---|
| >= 95 | Gold | Ready to merge |
| >= 90 | Silver | Ready for PR |
| >= 80 | Bronze | Safe to commit |
| < 80 | Blocked | Must fix |

**Auto-revert:** If score drops vs previous commit → `git checkout -- .`, log failure, report to user.

## Background Agent Timeout (MANDATORY)

Track background agents and intervene if stalled. Silence beyond threshold = signal, not wait condition.

### Detection

Check no later than 20 minutes after dispatch:

| Signal | How to check |
|---|---|
| Filesystem activity | `ls -la <worktree>/<expected-output-files>` — compare mtime to dispatch time |
| Live process | `ps -eo pid,etime,command \| grep -E "(Rscript\|nix-shell\|quarto-cli)" \| grep <worktree>` |
| Branch commits | `git -C <worktree> log --oneline -3` |
| Worktree status | `git -C <worktree> status -s` |

### Activity Signal

Agent is "active" if EITHER:
1. Live process (R/nix-shell/nix-build/curl/quarto-cli) with recent CPU
2. File in worktree modified in last 3 min

If NEITHER → agent is idle.

### Intervention Thresholds

| Elapsed | Idle for | Action |
|---|---|---|
| < 8 min | — | Wait |
| 8-12 min | < 3 min | Wait |
| 8-12 min | ≥ 3 min | Inspect worktree, tabulate progress, report |
| 12-20 min | — | Mandatory check-in, tabulate checkpoints |
| > 20 min | — | **HARD CAP.** Prompt user: intervene/wait/re-dispatch |
| > 15 min | ≥ 5 min | **MANDATORY INTERVENTION.** Take over or re-dispatch |

### Network-Failure Heuristics

When mtime stale + no commits >5 min + live process with high CPU → agent blocked on network.

| Signal | Meaning |
|---|---|
| `ps` shows R/curl/nix-build >5 min but mtime stale | Retrying failed HTTP/fetch |
| `*.partial`, `*.tmp`, `*.lock` appearing/disappearing | Download retry loop |
| Prior turns took ≤10 min for similar scope | Current run anomalous |
| Notification has `"API Error"`, `"timeout"`, `"network"` | Already failed — take over immediately |

### Take-over Protocol

1. Tabulate completed vs missing tasks
2. Preserve uncommitted work (commit before removing worktree)
3. Continue on same branch in same worktree
4. Document takeover in CURRENT_WORK.md and commit message
5. Force-remove worktree only after merge or push confirmed

### Reduce Runtime

- Smaller scope per dispatch (5 small tasks > 1 large)
- Reuse existing helpers; don't rebuild
- Delegate single-file edits to `quick-fix` (haiku)
- Front-load CDN/nix dependencies at session start

## Contrast Gate (post-render, MANDATORY)

After Quarto/pkgdown render or CSS edit, run:
```bash
~/docs_gh/llm/.claude/scripts/check_dark_contrast.sh "file://$(pwd)/$html"
```
Non-zero exit BLOCKS commit. When user reports contrast bug → sweep ALL uncovered elements in same commit (not just the one named). See `dark-mode-completeness` rule.

## Guardrails

- NEVER skip VERIFY step
- NEVER claim completion without fresh `devtools::check()` output
- NEVER exceed 3 rounds — escalate if stuck
- NEVER wait indefinitely on background agents
- NEVER force-remove worktree until commits pushed
- NEVER push CSS changes without contrast check passing
- ALWAYS save state to CURRENT_WORK.md
- ALWAYS tabulate agent progress before intervening
- ALWAYS use literal `#000000`/`#ffffff` when user says "black"/"white"
