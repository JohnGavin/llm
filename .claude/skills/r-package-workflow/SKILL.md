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

## The 9-Step Workflow

### Step 1: Architecture & Planning (New)
**Goal:** Validate design and dependencies.

*   **Action:** Run the "Brainstorming & Planning" protocol (see `architecture-planning` skill).
*   **Check:** `DESCRIPTION` and `default.nix` for dependencies.
*   **Sync:** DESCRIPTION is the single source of truth for Nix deps. `default.R` must
    use `read.dcf("DESCRIPTION")` to extract packages -- NEVER maintain a separate list.
    Include `R/tar_plans/plan_nix_sync.R` for drift detection. Use safe `import <nixpkgs> {}`
    pattern in `default.sh` (never `curl -sl` for rix expression). See `nix-rix-r-environment` skill.
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

*   Create `R/setup/fix_issue_123.R`.
*   Initialize `logger`.

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

### Step 4b: Run Targets Pipeline (MANDATORY - NEVER SKIP)
**Goal:** Build all targets, generate precomputed data for vignettes.

**YOU MUST run `targets::tar_make()` yourself. NEVER ask the user to do it.**

```r
# Validate pipeline definition first (fast, catches syntax/dependency errors)
targets::tar_validate()
cat("Pipeline valid:", length(targets::tar_manifest()$name), "targets\n")

# Run the full pipeline
targets::tar_make()

# Verify all targets built
targets::tar_meta() |> dplyr::filter(error != "") # Should be empty
```

*   **`tar_validate()` runs on every push/PR** via R-CMD-check CI (catches definition errors fast).
*   **Full `tar_make()` runs on schedule or manual trigger** via weekly-update/run-pipeline CI.
*   Pipeline state is stored on the `targets-runs` orphan branch (not on main).
*   Run BEFORE committing - pipeline must succeed.
*   If new targets were added, verify they appear in `inst/extdata/`.
*   If the pipeline saves RDS files, commit those files.
*   If `tar_make()` fails due to Nix segfaults, document the failure and proceed with the commit noting the pre-existing issue. Do NOT ask the user to run it manually.

See `targets-ci-pipeline` skill for full CI workflow patterns.

### Step 5: Full Local Checks
**Goal:** Ensure package integrity.

```r
devtools::document()
devtools::test()
devtools::check() # Must be 0 errors/warnings/notes
```

*   **IF FAILURE:** Do NOT guess. Switch to `systematic-debugging` skill protocol.
    *   Isolate -> Hypothesize -> Experiment -> Fix.

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
*   `usethis::pr_merge_main()` — merges PR, switches to main, pulls.
*   `usethis::pr_finish()` — deletes local branch, removes upstream tracking.

### Step 9: Verify & Cleanup
**Goal:** Close loop.
*   Verify issue is closed (`gh issue view <N> --json state`).
*   Delete log file (optional, or archive it).
*   **Branch cleanup (MANDATORY):**
    1.  Verify local branch was deleted by `pr_finish()`: `git branch`
    2.  Verify remote branch was deleted: `gh api repos/OWNER/REPO/git/refs/heads/BRANCH` (should 404)
    3.  If remote branch still exists: `gh api repos/OWNER/REPO/git/refs/heads/BRANCH -X DELETE`
    4.  Prune stale remote-tracking refs: `git remote prune origin`

### Periodic Branch Hygiene
Run during `/cleanup` or `/session-end`:
1.  List merged branches: `git branch -a --merged main`
2.  List unmerged branches: `git branch -a --no-merged main`
3.  For each unmerged branch, check PR status: `gh pr list --head BRANCH --state all`
4.  **Safe to delete:** branches whose PRs are MERGED or CLOSED
5.  **Never delete:** `main`, `targets-runs`, `gh-pages`
6.  Delete local: `git branch -d BRANCH`
7.  Delete remote: `gh api repos/OWNER/REPO/git/refs/heads/BRANCH -X DELETE`
8.  Prune: `git remote prune origin`

## CRITICAL: Never Skip or Rationalize Away Steps

**Every step in the 9-step workflow is MANDATORY. No exceptions.**

**Anti-pattern:** Marking a step as "N/A" or "not needed" with a rationalization.
Example: Skipping Step 5 (cachix push) because "CI doesn't use it directly."

**Rule:** If a step is blocked:
1. Identify the specific blocker (e.g., "cachix binary not on PATH")
2. Solve it (e.g., `nix-shell -p cachix --run './push_to_cachix.sh'`)
3. Execute the step
4. NEVER skip, NEVER mark as "N/A"

**If a CLI tool isn't available:**
```bash
# Pattern: nix-shell -p <tool> --run "<command>"
nix-shell -p cachix --run "./push_to_cachix.sh"
nix-shell -p git-lfs --run "git lfs pull"
```

## File Organization

```
package/
├── R/
│   ├── setup/
│   │   └── fix_issue_123.R  # Session Log
├── tests/testthat/          # TDD happens here
└── .claude/skills/          # Reference skills
```

## Related Skills

*   **`architecture-planning`**: Step 1 instructions.
*   **`systematic-debugging`**: Step 5 failure handling.
*   **`nix-rix-r-environment`**: The required execution environment.
