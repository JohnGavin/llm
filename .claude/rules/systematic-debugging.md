# Systematic Debugging

Scientific method for `R CMD check` failures, test failures, Nix issues, shell
scripts, SQL, and config debugging. Replaces "try random fixes" with
"Hypothesis → Experiment → Conclusion" — the discipline is language-agnostic;
the worked examples below happen to be R-heavy because that is where it was
first codified.

## When to Use

- `devtools::check()` or `devtools::test()` fails
- CI/CD workflows fail
- "Object not found" in `nix-shell`
- A shell script exits non-zero or produces unexpected output
- A SQL query returns the wrong rows/count or errors
- A config file (YAML/TOML/JSON) fails to parse or produces wrong behavior downstream
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

## Measure the Baseline Before Claiming a Regression

**A recent change is visible. The baseline is not. So the recent change gets blamed.**

Before asserting that a change caused a problem, measure the same quantity
**without** the change. Usually one command.

| Symptom | Wrong first move | Right first move |
|---|---|---|
| CI job slow after your PR | "My PR slowed it down" | Time the same step on the last run before your PR |
| Check fails right after your merge | "My merge broke it" | Read the failure; check whether it fails on the parent commit too |
| Data looks stale | "The refresh broke" | Confirm a refresh ever existed and when it last ran |
| Test fails on your branch | "I broke it" | Run it on `main` — it may be a known baseline failure |

**A step that passes is not a step that is fine.** In the 2026-08-01 incident a
CI install step had taken ~51 minutes for months. Nobody had looked, because it
had always *succeeded*. It was only questioned when a PR touched it — and then
wrongly blamed on that PR.

Timing evidence is usually one API call:

```bash
gh run view <run-id> --json jobs \
  --jq '.jobs[] | "\(.name): \(.startedAt) -> \(.completedAt)"'
```

Correlation in time is not evidence of causation. A merge that *triggers* a
scheduled check is not the cause of what that check finds.

See `knowledge/wiki/lessons-learned-false-attribution.md` for three worked cases.

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
