# Systematic Debugging for R Packages

## Description

This skill defines a rigorous scientific method for resolving `R CMD check` failures, test failures, and Nix environment issues. It replaces "try random fixes" with a "Hypothesis -> Experiment -> Conclusion" loop.

## Purpose

Use this skill when:
- `devtools::check()` fails
- `devtools::test()` reports failures
- CI/CD workflows fail
- "Object not found" errors occur in `nix-shell`
- You are stuck in a cycle of repeated error messages

## The Debugging Protocol

**STOP. Do not edit code immediately.**

Follow this 4-step process:

### Phase 1: Isolate (Reproduce)
**Goal:** Run the smallest piece of code that fails.
*   **Don't** run `devtools::check()` repeatedly (too slow).
*   **Do** run the specific test file: `devtools::test_file("tests/testthat/test-fail.R")`
*   **Do** run the specific example: `devtools::run_examples(test = "my_function")`

### Phase 2: Hypothesize
**Goal:** State *why* you think it's failing.
*   **Observation:** "Error: could not find function 'ggplot'"
*   **Hypothesis A:** `ggplot2` is not loaded in the test file.
*   **Hypothesis B:** `ggplot2` is missing from `DESCRIPTION` Imports.
*   **Hypothesis C:** `ggplot2` is missing from `NAMESPACE`.

### Phase 3: Experiment (Verify)
**Goal:** Test the hypothesis without changing the source code yet.
*   *Experiment A:* Add `library(ggplot2)` to the top of the test file and re-run.
*   *Result:* If it passes, Hypothesis A was correct (partially). Now implement the permanent fix (add to Imports/NAMESPACE).

### Phase 4: Implement & Verify
**Goal:** Apply the permanent fix and ensure no regressions.
1.  Apply fix (e.g., `usethis::use_package("ggplot2")`).
2.  Run the isolated test again.
3.  Run the full suite `devtools::test()` to check for regressions.

## Specific R Failure Patterns

### 1. `R CMD check` - "Namespace in Imports field not imported from"
*   **Hypothesis:** You added `usethis::use_package("dplyr")` but didn't use `dplyr::` or `@importFrom dplyr` in any roxygen comments.
*   **Fix:** Use the package in code or remove it from DESCRIPTION.

### 2. `testthat` - "Object 'foo' not found"
*   **Hypothesis:** The function `foo` is internal (not exported) and you are testing it from a context that doesn't see internal functions.
*   **Fix:** Use `devtools::load_all()` before running tests interactively. In test files, use `pkg:::internal_fn` only if absolutely necessary, or test the public API that calls it.

### 3. Nix - "Command not found" or Library Load Error
*   **Hypothesis:** You are not in the `nix-shell`.
*   **Experiment:** Run `Sys.getenv("IN_NIX_SHELL")`.
*   **Fix:** Run `caffeinate -i ~/docs_gh/rix.setup/default.sh` to enter the shell.

### 4. CI/CD - Fails on GitHub, Passes Locally
*   **Hypothesis:** Local environment is "dirty" or Nix versions desynchronized.
*   **Experiment:** Check `default.R` date against the CI configuration.
*   **Fix:** Re-run `source("default.R")` and reboot nix shell.

## Checklist for Complex Bugs

If stuck > 10 minutes, output this table:

| Observation | Hypothesis | Test Command | Result |
| :--- | :--- | :--- | :--- |
| Test X fails with NA | Data not cleaned | `debugonce(fn)` | `clean_data` was NULL |
| ... | ... | ... | ... |
