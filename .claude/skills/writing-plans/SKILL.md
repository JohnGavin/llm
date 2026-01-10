# Writing Implementation Plans for R Packages

## Description

Write comprehensive implementation plans with bite-sized tasks (2-5 minutes each) before touching code. Plans assume the implementer has minimal context and needs explicit file paths, code snippets, and verification steps.

## Purpose

Use this skill when:
- After `architecture-planning` approves the design
- Before `usethis::pr_init()` (Step 2 of 9-step workflow)
- For multi-file changes
- When work will span multiple sessions
- To enable parallel work or subagent execution

## Relationship to Other Skills

```
architecture-planning  →  writing-plans  →  executing-plans
     (WHAT)                  (HOW)            (DO)
```

## Plan Document Structure

**Save plans to:** `docs/plans/YYYY-MM-DD-<feature-name>.md`

### Required Header

```markdown
# [Feature Name] Implementation Plan

> **Execution:** Use `executing-plans` skill to implement task-by-task.
> **Verification:** Use `verification-before-completion` skill after each task.

**Issue:** #123
**Branch:** `fix-issue-123-feature-name`
**Goal:** [One sentence describing what this builds]
**Architecture:** [2-3 sentences about approach]

**Dependencies Check:**
- [ ] All packages in DESCRIPTION: `usethis::use_package("pkg")`
- [ ] All system deps in default.nix

---
```

## Task Granularity

**Each task is ONE action (2-5 minutes):**

```markdown
### Task 1: Create test file for new function

### Task 2: Write failing test for basic case

### Task 3: Run test, verify it fails

### Task 4: Create function file

### Task 5: Implement minimal code to pass test

### Task 6: Run test, verify it passes

### Task 7: Add edge case test

### Task 8: Implement edge case handling

### Task 9: Run all tests

### Task 10: Document function with roxygen

### Task 11: Run devtools::document()

### Task 12: Run devtools::check()

### Task 13: Commit changes
```

**NOT:**
```markdown
### Task 1: Implement the feature with tests
```

## Task Template

```markdown
### Task N: [Specific Action]

**Files:**
- Create: `R/new_function.R`
- Modify: `R/existing.R` (lines 45-60)
- Test: `tests/testthat/test-new_function.R`

**R Commands:**
```r
# Step 1: [What to do]
usethis::use_r("new_function")

# Step 2: [What to do]
# [Exact code to write or modify]
```

**Verification:**
```r
devtools::test_active_file()
# Expected: [ FAIL 1 | ... ] (RED phase)
```

**Commit Message:** `Add skeleton for new_function`
```

## Example Plan: Add Validation Function

```markdown
# Add Input Validation Implementation Plan

> **Execution:** Use `executing-plans` skill to implement task-by-task.

**Issue:** #42
**Branch:** `fix-issue-42-input-validation`
**Goal:** Add validate_input() function to check user inputs
**Architecture:** Single exported function with testthat tests

**Dependencies Check:**
- [x] cli (already in DESCRIPTION for error messages)
- [ ] rlang: `usethis::use_package("rlang")` for type checking

---

### Task 1: Add rlang dependency

**R Commands:**
```r
usethis::use_package("rlang")
```

**Verification:**
```r
desc::desc_get_deps() |> dplyr::filter(package == "rlang")
# Expected: Shows rlang in Imports
```

**Commit Message:** `Add rlang to Imports`

---

### Task 2: Create test file

**Files:**
- Create: `tests/testthat/test-validate_input.R`

**R Commands:**
```r
usethis::use_test("validate_input")
```

**Verification:**
```r
file.exists("tests/testthat/test-validate_input.R")
# Expected: TRUE
```

**Commit Message:** `Add test file for validate_input`

---

### Task 3: Write failing test for NULL rejection

**Files:**
- Modify: `tests/testthat/test-validate_input.R`

**Code:**
```r
test_that("validate_input rejects NULL", {
  expect_error(
    validate_input(NULL),
    class = "validation_error"
  )
})
```

**Verification:**
```r
devtools::test_active_file()
# Expected: Error - function not found (RED)
```

---

### Task 4: Create function file with minimal implementation

**Files:**
- Create: `R/validate_input.R`

**R Commands:**
```r
usethis::use_r("validate_input")
```

**Code:**
```r
#' Validate user input
#' @param x Input to validate
#' @return x (invisibly) if valid
#' @export
validate_input <- function(x) {
  if (is.null(x)) {
    cli::cli_abort(
      "Input cannot be NULL",
      class = "validation_error"
    )
  }
  invisible(x)
}
```

**Verification:**
```r
devtools::load_all()
devtools::test_active_file()
# Expected: [ FAIL 0 | PASS 1 ] (GREEN)
```

**Commit Message:** `Add validate_input with NULL check`

---

### Task 5: Add test for numeric validation

**Files:**
- Modify: `tests/testthat/test-validate_input.R`

**Code (append):**
```r
test_that("validate_input accepts numeric", {
  expect_invisible(validate_input(42))
  expect_equal(validate_input(1:3), 1:3)
})
```

**Verification:**
```r
devtools::test_active_file()
# Expected: [ FAIL 0 | PASS 2 ]
```

**Commit Message:** `Add numeric validation tests`

---

### Task 6: Run full check

**R Commands:**
```r
devtools::document()
devtools::check()
```

**Verification:**
```
0 errors ✔ | 0 warnings ✔ | 0 notes ✔
```

**Commit Message:** `Document validate_input, passes R CMD check`

---

### Task 7: Update package documentation

**Files:**
- Modify: `R/package.R` or relevant file

**Code:**
Add to @seealso or reference in package docs if needed.

**Verification:**
```r
devtools::document()
?validate_input
# Expected: Help page renders correctly
```
```

## Plan Writing Principles

### YAGNI (You Aren't Gonna Need It)
- Only include tasks for requested functionality
- No "while we're here" additions
- No speculative features

### DRY (Don't Repeat Yourself)
- If pattern repeats, note it once and reference
- Use "Repeat Task N pattern for..." shorthand

### TDD Throughout
- Test task always comes BEFORE implementation task
- Verification shows expected RED then GREEN

### Explicit Over Implicit
- Full file paths, not "the test file"
- Complete code snippets, not "add a test"
- Exact commands, not "run tests"

## Integration with 9-Step Workflow

Plans are created between Step 1 and Step 2:

```
Step 1: Create GitHub Issue
        ↓
   [architecture-planning skill]
        ↓
   [writing-plans skill] ← YOU ARE HERE
        ↓
Step 2: Create dev branch (usethis::pr_init())
        ↓
   [executing-plans skill]
        ↓
Steps 3-9: Implementation...
```

## Tidyverse Alignment

From [workflow vs script](https://tidyverse.org/blog/2017/12/workflow-vs-script/):
- Plans are **source** (reproducible), not memory (ephemeral)
- Each task starts fresh (`devtools::load_all()`)

From [tidyverse design](https://design.tidyverse.org/):
- **Composable**: Tasks combine into complete features
- **Consistent**: Same task structure throughout
- **Human-centered**: Readable by any implementer
