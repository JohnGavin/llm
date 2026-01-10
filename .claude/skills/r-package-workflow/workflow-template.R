# R Package Development Workflow Template (Revised)
# Save as: R/setup/dev_log_issue_XXX.R

# =============================================================================
# SETUP: Issue #XXX - [Brief Description]
# Author: [Your Name]
# =============================================================================

library(usethis)
library(gert)
library(gh)
library(devtools)
library(logger)

# Logging
log_file <- "R/setup/dev_log_issue_XXX.log"
logger::log_appender(logger::appender_file(log_file))
logger::log_info("Starting work on Issue #XXX")

# =============================================================================
# STEP 1: Architecture & Planning (MANDATORY)
# =============================================================================

# [ ] Run "Brainstorming" session
# [ ] Check DESCRIPTION for dependencies
# [ ] Check default.nix for system libs
# [ ] Generate Implementation Plan (Paste below)

# PLAN:
# 1. ...
# 2. ...

# =============================================================================
# STEP 2: Create Issue & Branch
# =============================================================================

# issue <- gh::gh("POST /repos/{owner}/{repo}/issues", ...)
issue_number <- XXX
branch_name <- paste0("fix-issue-", issue_number, "-feature")

usethis::pr_init(branch_name)
logger::log_info("Branch created: {branch_name}")

# =============================================================================
# STEP 3: Create Session Log (You are here)
# =============================================================================
# Ensure this file is saved and ready to be committed later.

# =============================================================================
# STEP 4: TDD Implementation Loop (Red-Green-Refactor)
# =============================================================================

# --- Cycle 1: [Task Name] ---

# 1. RED: Write failing test
usethis::use_test("feature_x")
# Edit tests/testthat/test-feature_x.R
devtools::test_file("tests/testthat/test-feature_x.R") # Expect FAILURE

# 2. GREEN: Implement code
usethis::use_r("feature_x")
# Edit R/feature_x.R
devtools::test_file("tests/testthat/test-feature_x.R") # Expect PASS

# 3. REFACTOR & Document
devtools::document()

# 4. COMMIT
gert::git_add(c("R/feature_x.R", "tests/testthat/test-feature_x.R"))
gert::git_commit("Feat: Implement feature X (Verified)")

# --- Cycle 2: [Next Task] ---
# ... repeat ...

# =============================================================================
# STEP 5: Full Local Checks
# =============================================================================

devtools::document()
test_results <- devtools::test()

if (any(as.data.frame(test_results)$failed > 0)) {
  stop("Tests failed! See systematic-debugging protocol.")
}

check_results <- devtools::check(error_on = "warning")
# If failed: Isolate -> Hypothesize -> Experiment -> Fix

# =============================================================================
# STEP 6: Push & PR
# =============================================================================

# Commit this log file
gert::git_add("R/setup/dev_log_issue_XXX.R")
gert::git_commit("Docs: Add session log")

usethis::pr_push()

# =============================================================================
# STEP 7: Monitor CI/CD
# =============================================================================
# Check https://github.com/user/repo/actions

# =============================================================================
# STEP 8: Merge
# =============================================================================
# ONLY if CI passed
usethis::pr_merge_main()
usethis::pr_finish()

logger::log_info("Workflow complete.")