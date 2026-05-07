---
paths:
  - "R/**"
  - "tests/**"
---
# Systematic Debugging for R Packages

Scientific method for `R CMD check` failures, test failures, and Nix issues. Replaces "try random fixes" with "Hypothesis → Experiment → Conclusion".

## When to Use

- `devtools::check()` or `devtools::test()` fails
- CI/CD workflows fail
- "Object not found" in `nix-shell`
- Stuck in repeated error cycle

## The Protocol

**STOP. Do not edit code immediately.**

### Phase 1: Isolate
Run the smallest failing code:
- `devtools::test_file("tests/testthat/test-fail.R")` (not full `check()`)
- `devtools::run_examples(test = "my_function")`

### Phase 2: Hypothesize
State *why* you think it's failing:
- Observation: "Error: could not find function 'ggplot'"
- Hypothesis A: `ggplot2` not loaded in test file
- Hypothesis B: Missing from DESCRIPTION Imports
- Hypothesis C: Missing from NAMESPACE

### Phase 3: Experiment
Test hypothesis WITHOUT changing source:
- Add `library(ggplot2)` to test file, re-run
- If passes → Hypothesis A correct, implement permanent fix

### Phase 4: Implement & Verify
1. Apply fix (e.g., `usethis::use_package("ggplot2")`)
2. Run isolated test
3. Run full `devtools::test()` for regressions

## Common R Failures

| Error | Hypothesis | Fix |
|-------|-----------|-----|
| "Namespace in Imports not imported" | Package in DESCRIPTION but unused | Use `pkg::fn()` or remove from Imports |
| "Object 'foo' not found" | Internal function not exported | Use `devtools::load_all()` or `pkg:::fn` |
| "Command not found" in nix | Not in nix-shell | `Sys.getenv("IN_NIX_SHELL")`, enter shell |
| CI fails, local passes | Dirty local env or version mismatch | Re-run `source("default.R")`, reboot shell |

## Never Accept Unverified Justifications

**Red flags:** "expected", "normal", "probably fine", "should be okay"

If justifying a violation: (1) Is it documented as exception? (2) Did you check actual data? (3) Can you cite the rule?

## Ops Failures (Same Protocol)

Credentials, volumes, DNS, tokens — same loop. **Canonical violation: "fix by deletion"** — agent deletes and recreates hoping fresh copy works. This is guessing, not debugging.

| Wrong | Right |
|-------|-------|
| `volumeDelete` + `volumeCreate` | Check token scope, `printenv API_KEY`, verify expiry |
| No user ask | Ask before ANY destructive op |

**Before destructive ops:** State hypothesis → cheapest non-destructive test → ask user.

## Stuck > 10 Minutes?

Output this table:

| Observation | Hypothesis | Test Command | Result |
|-------------|-----------|--------------|--------|
| Test X fails with NA | Data not cleaned | `debugonce(fn)` | `clean_data` was NULL |
