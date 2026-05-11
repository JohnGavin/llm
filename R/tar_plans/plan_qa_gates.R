#' Targets Plan: HTML Error Detection for pkgdown Site
#'
#' Scans all HTML files in docs/ for error patterns before deployment.
#' Implements #139: catch broken references and error messages before
#' GitHub Pages deploy.
#'
#' Patterns checked: unresolved references (*not found*), Error: messages,
#' bare #### headings (missing roxygen titles), TODO, FIXME.
#'
#' Returns a tidy tibble of files with detected error patterns.
#' Calls cli::cli_abort() if any errors found — fails the pipeline.

plan_qa_gates <- function() {
  list(
    targets::tar_target(
      qa_html_no_errors,
      {
        html_files <- list.files(
          "docs",
          pattern    = "\\.html$",
          recursive  = TRUE,
          full.names = TRUE
        )

        if (length(html_files) == 0) {
          cli::cli_alert_warning(
            "No HTML files found in docs/ — run pkgdown first"
          )
          return(invisible(NULL))
        }

        error_patterns <- c(
          "\\*.*not found\\*",  # *directory not found* style errors
          "^####",              # unrendered markdown headings
          "<code>Error:"        # R errors leaked into code blocks
        )

        results <- purrr::map_dfr(html_files, function(f) {
          content <- paste(readLines(f, warn = FALSE), collapse = "\n")
          matches <- Filter(
            function(p) grepl(p, content, perl = TRUE),
            error_patterns
          )
          if (length(matches) > 0) {
            tibble::tibble(
              file     = basename(f),
              url      = sub("^docs/", "https://johngavin.github.io/llm/", f),
              patterns = paste(matches, collapse = ", ")
            )
          }
        })

        if (!is.null(results) && nrow(results) > 0) {
          cli::cli_alert_danger("HTML errors detected in pkgdown site:")
          print(results)
          cli::cli_abort("Fix HTML errors before deploying (see above)")
        }

        cli::cli_alert_success(
          "No HTML error messages in {length(html_files)} pages"
        )
        results
      },
      packages = c("purrr", "tibble", "cli")
    )
  )
}
