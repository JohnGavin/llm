# debrief pilot - slim nix env
# Pins 2026-02-02 (same as project root to reuse cache)
# debrief commit: ce2a45e3a5e8d6e609fbb43ce8233ff4996acfab (HEAD as of 2026-06-30)
library(rix)

rix(
  date = "2026-02-02",
  project_path = ".",
  overwrite = TRUE,
  r_pkgs = c("profvis"),
  git_pkgs = list(
    list(
      package_name = "debrief",
      repo_url = "https://github.com/r-lib/debrief",
      commit = "ce2a45e3a5e8d6e609fbb43ce8233ff4996acfab"
    )
  ),
  system_pkgs = c("git"),
  ide = "none"
)
