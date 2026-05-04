#' Targets Plan: pkgdown Site Build
#'
#' Tracks R/, man/, vignettes/, DESCRIPTION, _pkgdown.yml for changes.
#' Rebuilds site locally when inputs change. Stages docs/ for commit.
#' Does NOT push — user controls when to push.
#'
#' Reusable: copy to any R package project's R/tar_plans/.
#' Requires: pkgdown, gert, cli in DESCRIPTION Suggests.
#'
#' CI counterpart: lightweight deploy-pages.yml uploads pre-built docs/
#' to GitHub Pages (~30s, no nix, no R). See ci-strategy memory.

plan_pkgdown <- function() {
  list(
    # 1. Track all files that affect the site
    targets::tar_target(
      pkgdown_inputs,
      {
        inputs <- c(
          list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE),
          list.files("man", pattern = "\\.Rd$", full.names = TRUE),
          list.files("vignettes", pattern = "\\.(qmd|Rmd)$", full.names = TRUE),
          list.files("pkgdown", full.names = TRUE, recursive = TRUE),
          "DESCRIPTION", "NAMESPACE", "_pkgdown.yml"
        )
        inputs[file.exists(inputs)]
      },
      cue = targets::tar_cue(mode = "always")
    ),

    # 2. Build site when inputs change
    targets::tar_target(
      pkgdown_build,
      {
        force(pkgdown_inputs)
        cli::cli_alert_info("Building pkgdown site...")
        pkgdown::build_site(preview = FALSE)

        articles <- list.files("docs/articles", pattern = "\\.html$")
        all_files <- list.files("docs", recursive = TRUE, full.names = TRUE)
        size_mb <- round(sum(file.size(all_files)) / 1e6, 1)

        cli::cli_alert_success("pkgdown: {length(articles)} articles, {size_mb} MB total")
        list(
          built_at = Sys.time(),
          n_articles = length(articles),
          size_mb = size_mb
        )
      },
      packages = c("pkgdown", "cli")
    ),

    # 3. Stage docs/ for commit (does NOT push)
    targets::tar_target(
      pkgdown_staged,
      {
        force(pkgdown_build)
        gert::git_add("docs")
        staged <- gert::git_status()
        staged <- staged[staged$staged, , drop = FALSE]
        n <- nrow(staged)

        if (n > 0) {
          cli::cli_alert_success("pkgdown: {n} file(s) staged in docs/")
          cli::cli_alert_info("Commit: gert::git_commit('docs: rebuild pkgdown site')")
        } else {
          cli::cli_alert_info("pkgdown: docs/ unchanged, no commit needed")
        }

        list(n_staged = n, built_at = pkgdown_build$built_at)
      },
      packages = c("gert", "cli")
    )
  )
}
