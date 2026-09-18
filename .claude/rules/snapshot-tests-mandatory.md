---
paths: ["**/tests/**", "**/test-*.R", "**/test_*.R"]
---

# Rule: Snapshot Tests Mandatory

## When This Applies
Every time tests are written or modified in any R project.

## CRITICAL: Every Test File MUST Include Snapshot Tests

When writing tests for R functions, **at least 30% of test_that blocks must use `expect_snapshot()`**. Snapshots catch regressions in output structure, error messages, and API signatures that `expect_equal()` misses.

## What to Snapshot (in priority order)

| Category | What to snapshot | Example |
|----------|-----------------|---------|
| **Error messages** | `expect_snapshot(error = TRUE, fn(bad_input))` | Catches wording changes in `cli_abort()` |
| **CLI messages** | `expect_snapshot(fn_with_messages())` | Catches changes to user-facing `cli_inform()` |
| **Output structure** | `expect_snapshot(str(result))` | Catches column additions/removals in tibbles |
| **Column names** | `expect_snapshot(names(result))` | Catches schema drift |
| **Function signatures** | `expect_snapshot(args(my_fn))` | Catches API-breaking param changes |
| **Multi-row tibbles** | `expect_snapshot(print(result))` | Catches formatting + data changes together |

## Required Setup for Non-Package Projects

**`tests/setup.R` with `local_edition(3, .env = testthat::teardown_env())` does NOT work** — verified empirically (llm#799, [historical#579](https://github.com/JohnGavin/historical/pull/579)): `withr`-style scoping binds the edition to the environment named in `.env`, and `teardown_env()` is not the frame test files execute in. The `setup.R` runs, sets nothing that survives into test frames, and exits silently — edition stays 2, `expect_snapshot()` behaves differently than intended, and nothing errors. A `tests/DESCRIPTION` carrying `Config/testthat/edition: 3` was also tried and also does NOT work (re-verified 2026-09-18, `testthat::edition_get()` still reports 2 with this in place).

**What actually works, verified**: an explicit `testthat::local_edition(3)` call at the **top of every individual test file** — not in `setup.R`, not in a `DESCRIPTION`. Confirmed live 2026-09-18: only this variant makes `testthat::edition_get()` report 3 inside a test.

```r
# tests/test-foo.R — first line, every test file
testthat::local_edition(3)

test_that("...", { ... })
```

And run with `NOT_CRAN=true`:
```bash
NOT_CRAN=true Rscript tests/run_tests.R
```

If a project's `tests/setup.R` or `tests/DESCRIPTION` currently relies on either broken mechanism above believing it sets edition 3 repo-wide, its suite is silently running under edition 2 — sweep for this per llm#799's "Blast radius" section.

## Transform for Non-Deterministic Output

Always use `transform` for temp paths, timestamps, or session-specific values:
```r
expect_snapshot(
  str(result),
  transform = function(lines) gsub("file[a-f0-9]+\\.csv", "TEMPFILE.csv", lines)
)
```

## Minimum Ratios

| Test file has | Minimum snapshots |
|---------------|-------------------|
| 1-3 test_that blocks | At least 1 snapshot |
| 4-8 test_that blocks | At least 2 snapshots |
| 9+ test_that blocks | At least 30% snapshots |

## Commit Rule

Snapshot files (`_snaps/*.md`) MUST be committed alongside the test files. They are part of the test suite, not generated artifacts.

## Anti-Patterns

| Wrong | Right |
|-------|-------|
| Only `expect_equal()` for tibble output | `expect_snapshot(print(result))` for full output |
| `expect_error(fn(), "partial match")` | `expect_snapshot(error = TRUE, fn())` for full message |
| No snapshot for cli messages | `expect_snapshot(fn_that_informs())` |
| Snapshot of random/timestamped output | Use `transform` to stabilize |
