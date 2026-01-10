# Nix and Rix for Reproducible R Environments

## Description

This skill covers setting up and working within reproducible R development environments using Nix and the rix R package. It ensures consistent package versions across local development, CI/CD, and collaborator machines.

## Purpose

Use this skill when:
- Starting new R projects requiring reproducible environments
- Working with R packages needing specific versions
- Setting up CI/CD with Nix for R packages
- Executing R code in controlled environments
- Ensuring consistency between local and GitHub Actions environments

## Key Principles

### Single Persistent Nix Shell

**CRITICAL**: Use ONE persistent nix shell for all work in a session
- Do NOT launch new nix shells for individual commands
- Do NOT use `nix-shell --run` for every R command
- Stay in the same shell to maintain environment consistency
- All R code, git operations, and development tasks run in this shell

### Reproducibility Through Nix

- Lock package versions via nix
- Same environment locally and in CI/CD
- Use rix R package to generate nix configurations
- Pin R version and all dependencies
- Version control the nix configuration

### Environment Verification

**CRITICAL: Always Verify Nix Shell is Active Before Starting Work**

Before running ANY R commands, git operations, or development tasks, verify you're inside the nix shell:

```bash
# 1. Check R is available and correct version
R --version
# Expected output: R version 4.4.1 (2024-06-14) or similar
# If you get "command not found", you're NOT in the nix shell!

# 2. Check Rscript is available
Rscript --version
# Expected output: R scripting front-end version 4.4.1

# 3. Check quarto is available (if project uses quarto)
quarto --version
# Expected output: version number (e.g., 1.4.550)

# 4. Verify git and gh are from nix store
which git
which gh
# Expected output: /nix/store/... paths
# NOT /usr/bin/git or /usr/local/bin/git

# 5. Check you're in the correct directory
pwd
# Expected: /Users/johngavin/docs_gh/claude_rix/[project_name]

# 6. Verify IN_NIX_SHELL environment variable
echo $IN_NIX_SHELL
# Expected output: "impure" or "pure"
# If empty, you're NOT in a nix shell
```

**Common Signs You're NOT in the Nix Shell:**
- `R --version` returns "command not found"
- `which git` shows `/usr/bin/git` instead of `/nix/store/...`
- `echo $IN_NIX_SHELL` is empty
- Package loading fails with "package not found"

**If ANY Verification Fails:**
1. Exit current shell: `exit`
2. Re-enter nix shell: `caffeinate -i ~/docs_gh/rix.setup/default.sh`
   OR: `nix-shell default.nix`
3. Re-verify all commands above before proceeding

**Additional Verification (from R):**
- Check R version and package availability
- Don't install packages locally (use nix)
- Source from nix store, not user library

## How It Works

### 1. Understanding the Setup

**Location of configurations:**
```
/Users/johngavin/docs_gh/rix.setup/
├── default.R       # rix::rix() specification
└── default.nix     # Generated nix configuration
```

**Project structure:**
```
/Users/johngavin/docs_gh/claude_rix/
├── default.R       # Project-specific rix config
├── default.nix     # Generated nix environment
├── random_walk/    # Project folder
└── other_project/  # Another project folder
```

### 2. Creating a Nix Environment with rix

**Generate default.R for a project:**

```r
# default.R
library(rix)

rix(
  # R version (use date for pinning)
  r_ver = "2024-11-01",

  # R packages from CRAN/Bioconductor
  r_pkgs = c(
    "devtools",
    "usethis",
    "testthat",
    "gert",
    "gh",
    "logger",
    "dplyr",
    "ggplot2",
    "targets",
    "tarchetypes",
    "pkgdown",
    "covr",
    "shiny",
    "quarto"
  ),

  # System packages (non-R dependencies)
  system_pkgs = c(
    "git",
    "quarto"
  ),

  # R packages from GitHub (if needed)
  git_pkgs = list(
    list(
      package_name = "rix",
      repo_url = "https://github.com/ropensci/rix",
      branch_name = "main",
      commit = "HEAD"
    )
  ),

  # IDE (if desired, usually NULL for CI)
  ide = "other",

  # Project path
  project_path = ".",

  # Overwrite existing default.nix
  overwrite = TRUE
)
```

**Generate the nix environment:**

```r
# In R, run:
source("default.R")

# This creates default.nix
```

### 3. Entering the Nix Shell

**First time setup:**

```bash
# Navigate to project directory
cd /Users/johngavin/docs_gh/claude_rix/random_walk

# Enter nix shell (downloads packages first time)
nix-shell default.nix

# Now you're in the reproducible environment
# Stay here for your entire session!
```

**Verify environment:**

```r
# Check R version
R.version.string

# Check package versions
packageVersion("devtools")
packageVersion("targets")

# List all installed packages
installed.packages()[, c("Package", "Version")]

# Verify packages load
library(devtools)
library(targets)
library(usethis)
```

### 4. Working Within the Shell

**DO THIS - Work in persistent shell:**

```bash
# Enter shell ONCE
nix-shell default.nix

# Then run all commands within it:
R
git status
quarto render
# etc.
```

**DON'T DO THIS - Repeated shell launches:**

```bash
# ❌ BAD: Launching new shell for each command
nix-shell default.nix --run "Rscript -e 'devtools::test()'"
nix-shell default.nix --run "Rscript -e 'devtools::check()'"
nix-shell default.nix --run "git status"
# This is inefficient and defeats the purpose
```

### 5. Verifying Package Availability

**Check if required packages are available:**

```r
# R/setup/check_environment.R
library(logger)

log_info("Checking nix environment setup")

required_packages <- c(
  'usethis', 'devtools', 'gh', 'gert',
  'logger', 'dplyr', 'duckdb', 'targets',
  'testthat', 'ggplot2', 'shiny'
)

# Try to load each package
results <- sapply(required_packages, function(pkg) {
  tryCatch({
    library(pkg, character.only = TRUE)
    log_info("✓ Package {pkg} loaded successfully")
    TRUE
  }, error = function(e) {
    log_error("✗ Package {pkg} failed to load: {e$message}")
    FALSE
  })
})

if (all(results)) {
  log_info("All required packages available in nix environment")
} else {
  missing <- required_packages[!results]
  log_error("Missing packages: {paste(missing, collapse = ', ')}")
  log_info("Update default.R and regenerate default.nix")
}
```

### 6. GitHub Actions Integration

**Use same nix environment in CI:**

```yaml
# .github/workflows/R-CMD-check.yml
name: R-CMD-check

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

jobs:
  R-CMD-check:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Install Nix
        uses: DeterminateSystems/nix-installer-action@main

      - name: Setup Nix cache
        uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Build documentation
        run: |
          nix-shell default.nix --run "Rscript -e 'devtools::document()'"

      - name: Run tests
        run: |
          nix-shell default.nix --run "Rscript -e 'devtools::test()'"

      - name: Run R CMD check
        run: |
          nix-shell default.nix --run "Rscript -e 'devtools::check()'"
```

**Note:** GitHub Actions uses `--run` because each step is isolated. Local development should use persistent shell.

## Common Patterns

### Pattern 1: Adding New Package to Environment

```r
# 1. Edit default.R
# Add package to r_pkgs vector

# 2. Regenerate default.nix
source("default.R")

# 3. Rebuild environment
# Exit current nix shell (Ctrl+D)
# Re-enter: nix-shell default.nix

# 4. Verify package available
library(newpackage)
```

### Pattern 2: Pinning Specific Package Version

```r
# In default.R
rix(
  r_ver = "2024-11-01",  # This date determines package versions
  r_pkgs = c("dplyr"),   # Will use dplyr version from this date
  # ...
)

# For GitHub packages, pin specific commit:
git_pkgs = list(
  list(
    package_name = "mypackage",
    repo_url = "https://github.com/user/mypackage",
    branch_name = "main",
    commit = "abc123def456"  # Specific commit hash
  )
)
```

### Pattern 3: Project-Specific vs Global Environment

```r
# Global environment for all projects:
# /Users/johngavin/docs_gh/rix.setup/default.nix
# Contains common packages used across projects

# Project-specific environment:
# /Users/johngavin/docs_gh/claude_rix/random_walk/default.nix
# Contains packages specific to random_walk project
# Inherits from global or defines independently
```

### Pattern 4: Checking Environment Consistency

```r
# R/setup/verify_environment.R
library(logger)

log_info("Verifying nix environment")

# Check if in nix shell
in_nix <- Sys.getenv("IN_NIX_SHELL") != ""

if (!in_nix) {
  log_warn("NOT in nix shell - reproducibility not guaranteed")
} else {
  log_info("Running in nix shell ✓")
}

# Check R version
expected_r_version <- "4.4.1"  # Update to match your r_ver
actual_r_version <- paste(R.version$major, R.version$minor, sep = ".")

if (actual_r_version == expected_r_version) {
  log_info("R version matches: {actual_r_version}")
} else {
  log_warn("R version mismatch: expected {expected_r_version}, got {actual_r_version}")
}
```

## File Structure

```
project/
├── default.R              # rix specification
├── default.nix            # Generated nix config (commit to git)
├── .Rbuildignore          # Exclude nix files from R package
├── R/
│   └── setup/
│       ├── check_environment.R
│       └── verify_nix.R
└── .github/
    └── workflows/
        ├── R-CMD-check.yml
        └── pkgdown.yml
```

## Integration with R Package Workflow

### Development Workflow in Nix Shell

```r
# R/setup/dev_log.R
# All commands run INSIDE nix shell

library(logger)
library(usethis)
library(devtools)
library(gert)

log_appender(appender_file("inst/logs/dev_session.log"))
log_info("=== Development session in nix shell ===")

# Verify environment
log_info("R version: {R.version.string}")
log_info("In nix shell: {Sys.getenv('IN_NIX_SHELL')}")

# Issue #42: Add new feature
log_info("Working on issue #42")
usethis::pr_init("fix-issue-42-new-feature")

# Make changes...
log_info("Modified: R/new_feature.R")

# Test and check (all in same nix environment)
devtools::document()
log_info("Documentation updated")

devtools::test()
log_info("Tests passed")

devtools::check()
log_info("R CMD check passed")

# Commit
gert::git_add(".")
gert::git_commit("Add new feature for issue #42")

# Push
usethis::pr_push()
log_info("Pushed to remote")
```

## Troubleshooting

### Environment Not Activating

**Problem:** Packages not found after entering nix shell

**Solution:**
```bash
# Exit shell
exit

# Clean nix store cache (if needed)
nix-collect-garbage

# Rebuild from scratch
nix-shell default.nix
```

### Version Conflicts

**Problem:** Different package versions locally vs CI

**Solution:**
```r
# Check r_ver date in both default.R files
# Ensure they match

# Local: /path/to/project/default.R
# CI: Uses same default.nix from repo

# Re-source to sync:
source("default.R")
```

### Package Not Available

**Problem:** Package won't load in nix shell

**Solution:**
```r
# 1. Check if package in default.R
# 2. Check if package exists for that r_ver date
# 3. Try different r_ver date
# 4. Or add as git_pkg from GitHub

# Update default.R
rix(
  r_ver = "2024-12-01",  # Try newer date
  r_pkgs = c("newpackage"),
  # ...
)
source("default.R")
```

### Shell Too Slow to Start

**Problem:** `nix-shell` takes minutes to start

**Solution:**
```bash
# First time is slow (downloads everything)
# Subsequent times should be fast (cached)

# If still slow, enable nix caching:
# Add to ~/.config/nix/nix.conf:
experimental-features = nix-command flakes
```

### Environment Degradation During Long Sessions

**Problem:** Commands like `git`, `gh`, `R` start failing with "command not found" or "No such file or directory" during a multi-hour session

**Root Cause:** Nix garbage collection removed store paths that were in `$PATH` at session start

**Warning Signs:**
- Commands that worked earlier now fail
- Error: `/nix/store/xxx-package/bin/command: No such file or directory`
- R packages that loaded before won't load
- Git operations failing unexpectedly

**Immediate Recovery:**
```bash
# Option 1: Exit and re-enter (fastest)
exit
nix-shell default.nix

# Option 2: If you have unsaved R session state
# Find working binaries and use full paths temporarily
find /nix/store -name "git" -type f 2>/dev/null | head -1
```

**Prevention Strategies:**

**Strategy 1: Periodic Shell Restart (Simplest)**
```bash
# Every 2-3 hours during long sessions:
exit
nix-shell default.nix
# Takes seconds, prevents degradation
```

**Strategy 2: Use Safer Garbage Collection**
```bash
# NEVER use this:
nix-collect-garbage -d  # ❌ Too aggressive

# Instead use:
nix-collect-garbage --delete-older-than 30d  # ✅ Safer
nix-collect-garbage  # ✅ Remove orphaned only
```

**Strategy 3: Create GC Roots (Advanced)**
```bash
# Prevent GC from removing active environment
nix-build default.nix -o ~/.nix-gc-roots/project-name

# Remove when done:
rm ~/.nix-gc-roots/project-name
```

**For Detailed Troubleshooting:** See `NIX_TROUBLESHOOTING.md` in project root for comprehensive guide on environment degradation, direnv setup, and session management strategies.

## Best Practices

### 1. Commit Nix Files to Git

```bash
git add default.R default.nix
git commit -m "Add nix environment configuration"
```

### 2. Document Environment Requirements

```r
# README.md should include:

## Setup

1. Install Nix: https://nixos.org/download.html
2. Enter environment:
   ```bash
   nix-shell default.nix
   ```
3. Verify setup:
   ```r
   source("R/setup/check_environment.R")
   ```
```

### 3. Keep Environment Minimal

```r
# Only include packages you actually use
# Don't add "just in case" packages
# Heavy packages slow down environment build

# Good
r_pkgs = c("dplyr", "ggplot2", "targets")

# Bad
r_pkgs = c("tidyverse", "all_the_packages_ever")
```

### 4. Pin R Version Explicitly

```r
# Use specific date for reproducibility
r_ver = "2024-11-01"  # Not "latest"

# Update date when you want to upgrade
# But keep it consistent across team/CI
```

### 5. Test Environment Changes Locally First

```r
# Before updating default.R for team:
# 1. Test new environment locally
# 2. Run full devtools::check()
# 3. Verify all workflows
# 4. Then commit and push
```

## Integration with Other Skills

### With r-package-workflow

```r
# All package development happens in nix shell
# Ensures tests/checks use same environment as CI
nix-shell default.nix

# Inside shell:
usethis::pr_init()
devtools::test()
devtools::check()
usethis::pr_push()
```

### With targets-vignettes

```r
# Run targets pipeline in nix environment
nix-shell default.nix

# Inside shell:
targets::tar_make()

# Same versions of packages as production
```

### With project-telemetry

```r
# Log environment info in telemetry
get_nix_info <- function() {
  list(
    in_nix_shell = Sys.getenv("IN_NIX_SHELL") != "",
    r_version = R.version.string,
    nix_path = Sys.getenv("NIX_PATH")
  )
}
```

## Reference Example: rix.setup

**Reference configuration at:**
`/Users/johngavin/docs_gh/rix.setup/default.R`

This is the template configuration used for all projects. Study it to understand:
- How to structure r_pkgs
- System package requirements
- Git package specifications
- IDE settings

## Daily Workflow Summary

```bash
# Morning: Start work
cd /Users/johngavin/docs_gh/claude_rix/random_walk
nix-shell default.nix

# Inside shell: Full day of development
R                           # R session
git status                  # Git commands
quarto render vignettes/    # Build docs
# All within SAME shell

# Evening: Exit
exit  # or Ctrl+D
```

## Resources

- **rix package**: https://github.com/ropensci/rix
- **rix documentation**: https://docs.ropensci.org/rix/
- **Nix manual**: https://nixos.org/manual/nix/stable/
- **Nix for R**: https://github.com/ropensci/rix/blob/main/README.md
- **GitHub Actions Nix**: https://github.com/DeterminateSystems/nix-installer-action

## Related Skills

- r-package-workflow
- targets-vignettes
- project-telemetry
- shinylive-quarto
