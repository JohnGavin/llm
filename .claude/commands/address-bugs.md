# /address-bugs - Fix CI and Review Issues

Parse CI failures and review comments, then systematically fix each issue.

## When to Use

- After receiving review comments on a PR
- When CI checks fail
- Called by `/pr-pass` during automation

## Sources of Issues

1. **CI Check Failures** - R-CMD-check, tests, coverage, linting
2. **Review Comments** - Reviewer feedback requiring changes
3. **Automated Bot Comments** - Codecov, lintr, etc.

## Implementation

### Step 1: Gather All Issues

```bash
# Get PR number
PR_NUM=$(gh pr view --json number --jq '.number')

# Get failed checks
echo "## CI Failures"
gh pr checks $PR_NUM --json name,conclusion,detailsUrl --jq '
  .[] | select(.conclusion == "failure") | "- \(.name): \(.detailsUrl)"
'

# Get review comments
echo "## Review Comments"
gh pr view $PR_NUM --json reviews,comments --jq '
  .reviews[]? | select(.state == "CHANGES_REQUESTED") | .body,
  .comments[]? | .body
'

# Get inline review comments
echo "## Inline Comments"
gh api repos/{owner}/{repo}/pulls/$PR_NUM/comments --jq '
  .[] | "- \(.path):\(.line // .original_line): \(.body)"
'
```

### Step 2: Parse CI Failure Logs

For each failed check:

```bash
# Get the failed run
RUN_ID=$(gh run list --branch $(git branch --show-current) --json databaseId,conclusion --jq '
  .[] | select(.conclusion == "failure") | .databaseId
' | head -1)

# Get failed job logs
gh run view $RUN_ID --log-failed 2>&1 | tail -100
```

### Step 3: Categorize Issues

Group issues by type:

| Type | Pattern | Fix Strategy |
|------|---------|--------------|
| Test failure | `Error in test-*.R` | Read test, fix assertion or code |
| R CMD check | `ERROR`, `WARNING` | Check man/, NAMESPACE, DESCRIPTION |
| Coverage drop | `Coverage decreased` | Add tests for uncovered lines |
| Lint error | `Linting failed` | Run styler or fix manually |
| Build error | `installation failed` | Check dependencies, syntax |
| Review comment | `path:line: comment` | Address reviewer's concern |

### Step 4: Fix Each Issue

For each issue:

1. **Read the relevant file(s)**
2. **Understand the problem**
3. **Apply minimal fix**
4. **Verify locally if possible**

```r
# For R issues, verify fix locally
devtools::test(filter = "affected_test")
devtools::check(args = "--no-manual")
```

### Step 5: Commit Fixes

Group related fixes into logical commits:

```bash
# Stage and commit
git add -A
git commit -m "fix: Address [category] issues

- Fixed [specific issue 1]
- Fixed [specific issue 2]

Addresses review comments from @reviewer"
```

## Output Format

```
## Issues Found

### CI Failures (2)
1. R-CMD-check: Error in examples for `simulate_walk()`
   - File: R/simulate.R
   - Issue: Missing required argument in example

2. test-coverage: Coverage dropped to 78% (threshold: 80%)
   - Uncovered: R/utils.R lines 45-52

### Review Comments (1)
1. @reviewer on R/walk.R:123
   "Consider using vapply instead of sapply for type safety"

## Fixes Applied

### Fix 1: R-CMD-check example error
- File: R/simulate.R
- Change: Added missing `n_steps` argument to example
- Verified: `devtools::run_examples()` passes

### Fix 2: Coverage improvement
- File: tests/testthat/test-utils.R
- Change: Added tests for edge cases in helper function
- Verified: Coverage now 82%

### Fix 3: Review comment
- File: R/walk.R
- Change: Replaced sapply with vapply
- Verified: Tests pass

## Commits Created
- abc1234: "fix: Correct simulate_walk() example"
- def5678: "test: Add coverage for utils edge cases"
- ghi9012: "refactor: Use vapply for type safety"

Ready to push? Run `git push` or continue with `/pr-pass`.
```

## Common R Package Issues

### R CMD check Errors

| Error | Fix |
|-------|-----|
| `no visible binding for global variable` | Add `utils::globalVariables()` or use `.data$col` |
| `Undefined global functions` | Add `@importFrom` or `pkg::func()` |
| `Examples with CPU time > 5s` | Add `\donttest{}` wrapper |
| `Missing documentation` | Run `devtools::document()` |

### Test Failures

| Pattern | Fix |
|---------|-----|
| `object 'x' not found` | Check test setup, fixtures |
| `Error: FALSE is not TRUE` | Verify expected values |
| `Test skipped on CRAN` | Ensure skip conditions are correct |

### Coverage Drops

1. Identify uncovered lines: `covr::package_coverage()`
2. Add tests targeting those lines
3. Verify coverage improved

## Integration with /pr-pass

This command is called by `/pr-pass` in each iteration. It should:
1. Return structured list of issues found
2. Return list of fixes applied
3. Indicate if all issues resolved or if manual help needed
