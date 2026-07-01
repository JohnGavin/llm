# explorations/2026-06-30_watcher-pilot/default.R
#
# Minimal nix environment for the watcher v0.2.0 pilot (r-lib/watcher).
# watcher bundles libfswatch - no external system library needed.
# On macOS the bundled configure appends -framework CoreServices automatically.
#
# Pin: same 2026-02-02 as top-level default.R.
# To regenerate default.nix (Form A subshell - documented exception to cd ban):
#   (cd /path/to/this/dir && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")

library(rix)

r_pkgs <- c("later", "R6", "rlang")

git_pkgs <- list(
  list(
    package_name = "watcher",
    repo_url = "https://github.com/r-lib/watcher",
    commit = "ab79639335c519a9cc7eeca272ea744ade462329"  # v0.2.0 released 2026-06-22
  )
)

system_pkgs <- c("git")

rix(
  date = "2026-02-02",
  project_path = ".",
  overwrite = TRUE,
  r_pkgs = r_pkgs,
  system_pkgs = system_pkgs,
  git_pkgs = git_pkgs,
  ide = "none"
)
