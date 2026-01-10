# R Package Development Workflow

## Description

This skill provides a structured workflow for R package development following best practices, integrating **Architecture Planning**, **Test-Driven Development (TDD)**, and **Systematic Debugging**.

## ⚠️ CRITICAL: MANDATORY REQUIREMENTS ⚠️

1.  **Nix Environment:** ALL commands must run inside the persistent Nix shell (`caffeinate -i ~/docs_gh/rix.setup/default.sh`).
2.  **R Packages for Git:** Use `gert`, `gh`, `usethis` for all git operations.
3.  **Logging:** Document every session in `R/setup/fix_issue_XXX.R`.
4.  **Planning First:** You MUST run the **Architecture Planning** phase before writing code.
5.  **TDD:** You MUST write failing tests *before* implementing code.

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
│   ├── setup/
│   │   └── fix_issue_123.R  # Session Log
├── tests/testthat/          # TDD happens here
└── .claude/skills/          # Reference skills
```

## Related Skills

*   **`architecture-planning`**: Step 1 instructions.
*   **`systematic-debugging`**: Step 5 failure handling.
*   **`nix-rix-r-environment`**: The required execution environment.