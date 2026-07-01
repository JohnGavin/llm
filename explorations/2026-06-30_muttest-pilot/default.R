# =============================================================================
# Nix Environment for muttest pilot exploration
# =============================================================================
# Purpose: Self-contained nix shell for piloting the muttest R mutation-testing
#   package. muttest is not in the pinned nixpkgs (2026-02-02); installed via
#   git_pkgs. Regenerate with Form A (nix-agent-shell-protocol rule):
#   (cd /path/to/this/dir && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")
# =============================================================================

library(rix)

# Core dependencies of muttest (from its DESCRIPTION Imports)
# Plus usethis: loaded transitively during nix fixupPhase namespace verification
r_pkgs <- c(
  "checkmate",    # muttest dep: argument checking
  "cli",          # muttest dep: user messaging
  "fs",           # muttest dep: file system
  "mirai",        # muttest dep: parallel mutation evaluation
  "R6",           # muttest dep: OOP framework
  "rlang",        # muttest dep: tidy evaluation
  "testthat",     # muttest dep + our test runner
  "treesitter",   # muttest dep: code parsing (R bindings to tree-sitter C lib)
  "treesitter.r", # muttest dep: R grammar for tree-sitter (>= 1.3.0)
  "withr",        # muttest dep: environment management
  "usethis",      # loaded by nix fixupPhase namespace verification chain
  "digest"        # used by muttest PackageCopyStrategy (undeclared dep in muttest DESCRIPTION)
)

# muttest from GitHub - not in nixpkgs pin 2026-02-02
muttest_sha <- "6cec45271f67b155175c18a663c339af86db5942"

git_pkgs <- list(
  list(
    package_name = "muttest",
    repo_url     = "https://github.com/jakubsob/muttest",
    commit       = muttest_sha
  )
)

# Use the same nixpkgs pin as the main project
rix(
  date         = "2026-02-02",
  project_path = ".",
  overwrite    = TRUE,
  r_pkgs       = r_pkgs,
  git_pkgs     = git_pkgs,
  ide          = "none",
  shell_hook   = "export R_MAKEVARS_USER=/dev/null"
)

cli::cli_alert_info("Generated default.nix for muttest pilot.")
