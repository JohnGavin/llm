# Complete R Package Development Workflow Template
# Copy and customize this for your development tasks
# Save as: R/setup/dev_log_issue_XXX.R

# =============================================================================
# SETUP: Issue #XXX - [Brief Description]
# Date: YYYY-MM-DD
# Author: Your Name
# =============================================================================

library(usethis)
library(gert)
library(gh)
library(devtools)
library(logger)

# Setup logging
log_file <- "R/setup/dev_log_issue_XXX.log"
logger::log_appender(logger::appender_file(log_file))
logger::log_info("Starting work on Issue #XXX")

# =============================================================================
# STEP 1: Create GitHub Issue (if not already created via web)
# =============================================================================

# issue <- gh::gh("POST /repos/{owner}/{repo}/issues",
#                 owner = "yourusername",
#                 repo = "yourrepo",
#                 title = "Brief description",
#                 body = "Detailed description of what needs to be done")
#
# issue_number <- issue$number
# logger::log_info("Created issue #{issue_number}")

issue_number <- XXX  # Or get from gh response above

# =============================================================================
# STEP 2: Create Development Branch
# =============================================================================

branch_name <- paste0("fix-issue-", issue_number, "-short-description")
logger::log_info("Creating branch: {branch_name}")

# Using usethis (recommended)
usethis::pr_init(branch_name)

# OR using gert
# gert::git_branch_create(branch_name)
# gert::git_branch_checkout(branch_name)

# Verify
current_branch <- gert::git_branch()
logger::log_info("Now on branch: {current_branch}")

# =============================================================================
# STEP 3: Make Code Changes
# =============================================================================

# TODO: Edit your R files here
# - R/your_function.R
# - tests/testthat/test-your_function.R
# - Update DESCRIPTION if adding dependencies
# - Add roxygen documentation

logger::log_info("Made code changes (describe what you changed)")

# =============================================================================
# STEP 4: Commit Changes Locally (DO NOT PUSH YET)
# =============================================================================

# Check status
status <- gert::git_status()
logger::log_info("Files changed: {nrow(status)}")
print(status)

# Stage files
files_to_add <- c(
  "R/your_function.R",
  "tests/testthat/test-your_function.R",
  "DESCRIPTION"  # if you changed dependencies
)

gert::git_add(files_to_add)
logger::log_info("Staged files")

# Commit
commit_msg <- "Add feature X for issue #XXX

Detailed description of what this commit does.

References #XXX"

commit_sha <- gert::git_commit(commit_msg)
logger::log_info("Committed: {commit_sha}")

# =============================================================================
# STEP 5: Run ALL Local Checks (CRITICAL - Must pass before pushing)
# =============================================================================

logger::log_info("Starting local checks")

# 5.1 Update documentation
logger::log_info("Updating documentation...")
devtools::document()
logger::log_info("Documentation updated")

# 5.2 Run tests
logger::log_info("Running tests...")
test_results <- devtools::test()
logger::log_info("Tests: {sum(test_results$passed)} passed, {sum(test_results$failed)} failed")

if (sum(test_results$failed) > 0) {
  logger::log_error("Tests failed! Fix before proceeding")
  stop("Tests failed")
}

# 5.3 Run R CMD check
logger::log_info("Running R CMD check...")
check_results <- devtools::check(error_on = "warning")
logger::log_info("Check complete")

# If check fails, fix issues and commit again
# Then re-run checks before proceeding

# 5.4 Build pkgdown site (optional but recommended)
logger::log_info("Building pkgdown site...")
pkgdown::build_site()
logger::log_info("Pkgdown site built")

logger::log_info("All local checks passed!")

# =============================================================================
# STEP 6: Push to Remote
# =============================================================================

logger::log_info("Pushing to remote...")

# Using usethis (creates PR automatically if needed)
usethis::pr_push()

# OR using gert
# gert::git_push()

logger::log_info("Pushed to remote")

# =============================================================================
# STEP 7: Monitor GitHub Actions
# =============================================================================

logger::log_info("Monitoring GitHub Actions...")

# Wait a moment for workflows to start
Sys.sleep(10)

# Check workflow status
runs <- gh::gh("/repos/{owner}/{repo}/actions/runs",
               owner = "yourusername",
               repo = "yourrepo",
               branch = branch_name,
               per_page = 5)

cat("\n=== GitHub Actions Status ===\n")
for (run in runs$workflow_runs) {
  cat(sprintf("%-30s | Status: %-12s | Conclusion: %s\n",
              run$name, run$status,
              ifelse(is.null(run$conclusion), "pending", run$conclusion)))
}

logger::log_info("Check status at: https://github.com/yourusername/yourrepo/actions")

# Note: Wait for all workflows to pass before merging!
# You can run this check script multiple times to monitor progress

# =============================================================================
# STEP 8: Merge PR (Only after all checks pass)
# =============================================================================

# WAIT! Only proceed when all GitHub Actions show: Status: completed | Conclusion: success

# Check if all workflows passed
all_complete <- all(sapply(runs$workflow_runs, function(r) r$status == "completed"))
all_success <- all(sapply(runs$workflow_runs, function(r)
  !is.null(r$conclusion) && r$conclusion == "success"))

if (!all_complete) {
  logger::log_warn("Workflows still running - wait before merging")
  stop("Workflows not complete")
}

if (!all_success) {
  logger::log_error("Some workflows failed - fix issues before merging")
  stop("Workflows failed")
}

logger::log_info("All workflows passed - ready to merge!")

# Merge using usethis
usethis::pr_merge_main()

# Clean up local branch
usethis::pr_finish()

# OR merge using gh API
# pr_number <- XXX  # Get from usethis output or gh
# gh::gh("PUT /repos/{owner}/{repo}/pulls/{number}/merge",
#        owner = "yourusername",
#        repo = "yourrepo",
#        number = pr_number,
#        merge_method = "merge")

logger::log_info("PR merged successfully!")

# =============================================================================
# STEP 9: Verify Issue Closed
# =============================================================================

# Check if issue was automatically closed
issue <- gh::gh("/repos/{owner}/{repo}/issues/{number}",
                owner = "yourusername",
                repo = "yourrepo",
                number = issue_number)

logger::log_info("Issue #{issue_number} status: {issue$state}")

if (issue$state == "closed") {
  logger::log_info("Issue closed successfully!")
} else {
  logger::log_warn("Issue not closed - check PR message included 'Fixes #XXX'")
}

# =============================================================================
# COMPLETE!
# =============================================================================

logger::log_info("Workflow complete for Issue #{issue_number}")
cat("\n✅ All done!\n")
