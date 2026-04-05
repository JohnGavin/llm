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

Projects without DESCRIPTION need `tests/setup.R`:
```r
testthat::local_edition(3, .env = testthat::teardown_env())
```

And run with `NOT_CRAN=true`:
```bash
NOT_CRAN=true Rscript tests/run_tests.R
```

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
