# /new-issue - Create GitHub Issue with Branch

Create a new GitHub issue and development branch following the 9-step workflow.

## Required Input
- Issue title
- Issue description/body

## Steps

1. Create GitHub issue via `gh` package
2. Get the issue number
3. Create branch with `usethis::pr_init("fix-issue-{number}-{slug}")`
4. Create log file `R/dev/issues/fix_issue_{number}.R`
5. Report the issue URL and branch name

## Commands to Execute

```r
library(gh)
library(usethis)

# Create issue (user provides title and body)
issue <- gh("POST /repos/{owner}/{repo}/issues",
            owner = "JohnGavin",
            repo = "randomwalk",
            title = "$TITLE",
            body = "$BODY")

cat("Created issue #", issue$number, "\n")
cat("URL:", issue$html_url, "\n")

# Create branch
branch_name <- paste0("fix-issue-", issue$number, "-", "$SLUG")
pr_init(branch_name)

# Create log file
log_file <- paste0("R/dev/issues/fix_issue_", issue$number, ".R")
writeLines(c(
  paste0("# Fix for issue #", issue$number),
  paste0("# ", issue$title),
  paste0("# URL: ", issue$html_url),
  "",
  "# Session setup",
  "library(devtools)",
  "library(testthat)",
  "",
  "# Commands executed:",
  ""
), log_file)

cat("Log file:", log_file, "\n")
```

## Output Format

```
## New Issue Created

Issue: #[number] - [title]
URL: [github-url]
Branch: fix-issue-[number]-[slug]
Log file: R/dev/issues/fix_issue_[number].R

## Next Steps
1. Make changes on this branch
2. Run /check before pushing
3. Run /pr-status after CI completes
```
