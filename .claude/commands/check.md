# /check - Run R Package Checks

Run the full R package check suite and report results.

## Steps

1. Run `devtools::document()` to update NAMESPACE and docs
2. Run `devtools::test()` and report any failures
3. Run `devtools::check()` with `--as-cran` flag
4. If `_targets.R` exists, run `targets::tar_validate()` and report target count
5. Summarize: errors, warnings, notes
6. If all pass, confirm ready for PR push

## Commands to Execute

```r
devtools::document()
devtools::test()
devtools::check(args = "--as-cran")

# Only if _targets.R exists
if (file.exists("_targets.R")) {
  targets::tar_validate()
  cat("Pipeline valid:", length(targets::tar_manifest()$name), "targets\n")
}
```

## Output Format

```
## Check Results

- Documentation: [OK/Issues]
- Tests: [X passed, Y failed]
- R CMD check: [X errors, Y warnings, Z notes]
- Pipeline: [valid, N targets / no _targets.R]

## Verdict
[Ready to push / Needs fixes]
```
