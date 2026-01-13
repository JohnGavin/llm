# /check - Run R Package Checks

Run the full R package check suite and report results.

## Steps

1. Run `devtools::document()` to update NAMESPACE and docs
2. Run `devtools::test()` and report any failures
3. Run `devtools::check()` with `--as-cran` flag
4. Summarize: errors, warnings, notes
5. If all pass, confirm ready for PR push

## Commands to Execute

```r
devtools::document()
devtools::test()
devtools::check(args = "--as-cran")
```

## Output Format

```
## Check Results

- Documentation: [OK/Issues]
- Tests: [X passed, Y failed]
- R CMD check: [X errors, Y warnings, Z notes]

## Verdict
[Ready to push / Needs fixes]
```
