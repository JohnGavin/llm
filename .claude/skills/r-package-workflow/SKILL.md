# R Package Development Workflow

## Description

This skill provides a structured workflow for R package development following best practices, integrating **Architecture Planning**, **Test-Driven Development (TDD)**, and **Systematic Debugging**.

## ⚠️ CRITICAL: MANDATORY REQUIREMENTS ⚠️

1.  **Nix Environment:** ALL commands must run inside the persistent Nix shell (`caffeinate -i ~/docs_gh/rix.setup/default.sh`).
2.  **R Packages for Git:** Use `gert`, `gh`, `usethis` for all git operations.
3.  **Logging:** Document every session in `R/setup/fix_issue_XXX.R`.
4.  **Planning First:** You MUST run the **Architecture Planning** phase before writing code.
5.  **TDD:** You MUST write failing tests *before* implementing code.
6.  **Unique Chunk Labels:** In ALL `.qmd` and `.Rmd` files, every code chunk must have a **unique, descriptive label**. Duplicate labels cause Quarto rendering failures.
    *   **Bad:** ````{r setup}` (repeated), ````{r}` (unlabeled)
    *   **Good:** ````{r usage-setup}`, ````{r ci-prep}`, ````{r cost-trend}`

## Git Worktrees for Risky Changes

Use `isolation: "worktree"` on subagents or manual `git worktree add` when changes are risky, multi-session, or experimental. The worktree gets an isolated copy of the repo — if the approach fails, delete it with no trace in main.

| Situation | Use Worktree? |
|-----------|--------------|
| Risky refactor (changing >5 files) | **Yes** |
| Experimental approach (might abandon) | **Yes** |
| Multi-session feature (WIP across days) | **Yes** |
| Simple bug fix (1-2 files) | No |
| Documentation-only changes | No |

```bash
# Create worktree for a feature branch
git worktree add .worktrees/feat-units -b feat/adopt-units

# Work in the worktree (isolated from main)
cd .worktrees/feat-units

# If it works: squash-merge back to main
git checkout main
git merge --squash feat/adopt-units

# Clean up
git worktree remove .worktrees/feat-units
git branch -d feat/adopt-units
```

**Agent usage:** Set `isolation: "worktree"` on any Agent tool call for risky operations. The agent works on an isolated copy and returns the branch/path if changes were made.

## The 9-Step Workflow

### Step 1: Architecture & Planning (New)
**Goal:** Validate design and dependencies.

*   **Action:** Run the "Brainstorming & Planning" protocol (see `architecture-planning` skill).
*   **Check:** `DESCRIPTION` and `default.nix` for dependencies.
*   **Output:** A markdown checklist of tasks.

### Step 2: Create Issue & Branch
**Goal:** Formalize the task.

```r
library(gh)
library(usethis)

# 1. Create Issue
issue <- gh::gh("POST /repos/{owner}/{repo}/issues", ...)
issue_num <- issue$number

# 2. Init Branch
usethis::pr_init(paste0("fix-issue-", issue_num, "-feature"))
```

### Step 3: Create Session Log
**Goal:** Ensure traceability.

*   Update `.claude/CURRENT_WORK.md` with session context (issue number, branch, plan summary).
*   Alternative (legacy): Create `R/setup/fix_issue_123.R` if the project uses that convention.
*   The session log location is `.claude/CURRENT_WORK.md` — this file persists across Claude Code sessions and is read at session start.

### Step 4: TDD Implementation Loop (The Coding Phase)
**Goal:** Write robust, testable code.

**Repeat this cycle for each task in your Plan:**

1.  **RED (Test):**
    *   Create/Edit `tests/testthat/test-feature.R`.
    *   Write a test for the new functionality.
    *   Run `devtools::test_file(...)`.
    *   **Confirm it fails.**

2.  **GREEN (Code):**
    *   Write the *minimum* code in `R/feature.R` to pass the test.
    *   Run `devtools::test_file(...)`.
    *   **Confirm it passes.**

3.  **REFACTOR:**
    *   Clean up code, add `roxygen2` comments.
    *   Run `devtools::document()`.

4.  **COMMIT (Granular):**
    *   `gert::git_add(c("R/feature.R", "tests/testthat/test-feature.R"))`
    *   `gert::git_commit("Feat: Implement X (Red-Green verified)")`

### Step 5: Full Local Checks
**Goal:** Ensure package integrity.

```r
devtools::document()
devtools::test()
devtools::check() # Must be 0 errors/warnings/notes
```

*   **IF FAILURE:** Do NOT guess. Switch to `systematic-debugging` skill protocol.
    *   Isolate -> Hypothesize -> Experiment -> Fix.

### Step 5b: Push to Cachix
**Goal:** Push the package derivation to johngavin cachix.

**Requires:** `package.nix` and `push_to_cachix.sh` in project root. See `nix-rix-r-environment` skill (Pattern 4) for how to create these files.

```bash
# From project root
./push_to_cachix.sh
```

**Key distinction:** `default.nix` (dev shell via rix) ≠ `package.nix` (installable R package via buildRPackage). Both are needed — `default.nix` for development, `package.nix` for cachix.

*   **IF `package.nix` doesn't exist:** Create it following Pattern 4 in the `nix-rix-r-environment` skill.
*   **IF cachix not in PATH:** Use `~/.nix-profile/bin/cachix` or ensure it's in the dev shell.

### Step 6: Push & PR
**Goal:** Upload changes.

```r
# Log file must be included!
gert::git_add("R/setup/fix_issue_123.R")
gert::git_commit("Docs: Add session log")

usethis::pr_push()
```

### Step 7: Monitor CI/CD
**Goal:** Verify remote environment.
*   Use `gh` to check workflow status.

### Step 8: Merge
**Goal:** Integrate changes.
*   Only after CI passes.
*   `usethis::pr_merge_main()`
*   `usethis::pr_finish()`

### Step 9: Verify & Cleanup
**Goal:** Close loop.
*   Verify issue is closed.
*   Delete log file (optional, or archive it).

## File Organization

```
package/
├── R/
│   ├── setup/               # Legacy session logs (optional)
├── tests/testthat/          # TDD happens here
├── .claude/
│   ├── CURRENT_WORK.md      # Session log (primary)
│   └── skills/              # Reference skills
```

## Reference Files

- **[references/api-design-patterns.md](references/api-design-patterns.md)** —
  `.by` parameter, `{{ }}` forwarding, `...` patterns, internal vs exported decisions.
- **[references/dependency-decisions.md](references/dependency-decisions.md)** —
  When to add tidyverse deps vs use base R, DESCRIPTION placement.

## Related Skills

*   **`architecture-planning`**: Step 1 instructions.
*   **`quality-gates`**: Steps 4/6/8 scoring — Bronze (commit), Silver (PR), Gold (merge). Run `tar_make(names = starts_with("qa_"))` and check grade via `tar_read(qa_quality_gate)$grade`.
*   **`systematic-debugging`**: Step 5 failure handling.
*   **`nix-rix-r-environment`**: The required execution environment.

## Quality Gate Integration

The 9-step workflow requires quality gate checks at 3 points:
- **Step 4 (TDD loop):** Score must be >= Bronze (80) before committing
- **Step 6 (Push & PR):** Score must be >= Silver (90) before PR creation
- **Step 8 (Merge):** Score must be >= Gold (95) before merging to main

Run `~/.claude/hooks/qa_gate_check.sh` to verify freshness, or run the targets directly. See `quality-gates` skill for scoring formula and enforcement mechanisms.
