# Architecture Planning and Design

## Description

This skill defines the mandatory "Planning Phase" that must precede any coding. It prevents "hallucination-driven development" by forcing the agent to validate dependencies against `DESCRIPTION` and `default.nix`, and to produce a concrete implementation plan.

## Purpose

Use this skill when:
- Starting work on a new GitHub issue
- Planning complex refactoring
- Adding new features to an R package
- You need to prevent introducing unlisted dependencies
- You want to ensure the solution fits the existing architecture

## The "Brainstorming & Planning" Protocol

**Before `usethis::pr_init()`, you must run this phase.**

### Phase 1: Brainstorming (Design Validation)

**Goal:** Agree on *what* to build and *how* it fits.

1.  **Analyze the Request:** Read the issue/request.
2.  **Check Constraints:**
    *   Read `DESCRIPTION` to see available R packages.
    *   Read `default.nix` (or `default.R`) to see available system libraries.
    *   **Rule:** You CANNOT use a package not listed here without explicitly adding it to the plan as a task.
3.  **Propose Solution:**
    *   Describe the architectural approach.
    *   List specific functions to create/modify.
    *   Identify potential breaking changes.
    *   Ask the user: "Does this approach look correct?"

### Phase 2: Detailed Planning (The Checklist)

**Goal:** Create a step-by-step execution list.

**Output Format:**
Produce a markdown checklist that includes:
1.  **Dependency Updates:** (e.g., `usethis::use_package("dplyr")`)
2.  **File Creation:** (e.g., `usethis::use_r("new_module")`)
3.  **Test Creation:** (e.g., `usethis::use_test("new_module")`)
4.  **Implementation Steps:** Granular coding tasks.
5.  **Verification:** Specific commands to prove it works.

## Example Plan Output

```markdown
# Plan: Add Rolling Average to Time Series Module

## Dependencies
- [ ] Check if `zoo` is in DESCRIPTION. If not, add it: `usethis::use_package("zoo")`
- [ ] Verify `zoo` is available in `default.nix`.

## Implementation
1. [ ] Create test file: `tests/testthat/test-rolling_avg.R`
2. [ ] Define `calculate_rolling_avg` signature in `R/time_series.R`
3. [ ] Implement TDD cycle:
    - [ ] Write failing test for basic window calculation
    - [ ] Implement code using `zoo::rollmean`
    - [ ] Verify test passes
4. [ ] Export function and add roxygen documentation
5. [ ] Update NAMESPACE via `devtools::document()`

## Verification
- [ ] Run `devtools::test_file("tests/testthat/test-rolling_avg.R")`
- [ ] Run full `devtools::check()`
```

## Integration with R-Package-Workflow

This skill is **Step 0** of the `r-package-workflow`.
1.  **Step 0:** Architecture & Planning (This Skill)
2.  **Step 1:** Create Issue
3.  **Step 2:** Create Branch
4.  ...

## Common Pitfalls

*   **The "Phantom Dependency":** Planning to use `fs::dir_ls` when `fs` is not in `DESCRIPTION`.
    *   *Fix:* Always check `DESCRIPTION` during brainstorming.
*   **The "Nix Blindspot":** Adding a system dependency (e.g., `libxml2`) in R but forgetting it in `default.nix`.
    *   *Fix:* Check `default.R` / `default.nix` during brainstorming.
*   **Vague Plans:** "Implement the function."
    *   *Fix:* "Implement `process_data()` in `R/processing.R` handling NA values."
