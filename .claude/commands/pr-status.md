# /pr-status - Check PR and CI Status

Check the current branch's PR status and all GitHub Actions workflows.

## Steps

1. Get current branch name via `gert::git_branch()`
2. Check if PR exists for this branch via `gh` package
3. List all workflow runs for the PR
4. Report status of each workflow
5. Summarize: ready to merge or what's blocking

## Commands to Execute

```r
library(gert)
library(gh)

branch <- git_branch()
cat("Current branch:", branch, "\n")

# Find PR for this branch
prs <- gh("GET /repos/{owner}/{repo}/pulls",
          owner = "JohnGavin",
          repo = "randomwalk",
          head = paste0("JohnGavin:", branch),
          state = "open")

if (length(prs) > 0) {
  pr <- prs[[1]]
  cat("PR #", pr$number, ": ", pr$title, "\n")
  cat("State:", pr$state, "\n")
  cat("Mergeable:", pr$mergeable, "\n")

  # Get check runs
  checks <- gh("GET /repos/{owner}/{repo}/commits/{ref}/check-runs",
               owner = "JohnGavin",
               repo = "randomwalk",
               ref = pr$head$sha)

  for (check in checks$check_runs) {
    cat("-", check$name, ":", check$conclusion, "\n")
  }
}
```

## Output Format

```
## PR Status: #[number]

Branch: [branch-name]
PR State: [open/closed/merged]
Mergeable: [yes/no/pending]

## CI Workflows
- R-CMD-check: [success/failure/pending]
- deploy-pages: [success/failure/pending]
- coverage: [success/failure/pending]

## Verdict
[Ready to merge / Waiting on CI / Has conflicts / Needs review]
```
