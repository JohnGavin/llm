#' Targets Plan: HTML Error Detection for pkgdown Site
#'
#' Scans all HTML files in docs/ for error patterns before deployment.
#' Implements #139: catch broken references and error messages before
#' GitHub Pages deploy.
#'
#' Pattern groups:
#'   - Unresolved references (*not found*, MISSING EVIDENCE, not available)
#'   - R errors / warnings leaked into HTML (Error in, Error:, Warning:)
#'   - Raw R output (#&gt; — code block prefix when prose leaks into output)
#'   - Unrendered markdown (^####)
#'   - Placeholder content (TODO, FIXME)
#'   - NULL / NaN literals in rendered output (table cells, captions)
#'
#' Returns a tidy tibble of files with detected error patterns.
#' Calls cli::cli_abort() if any errors found — fails the pipeline.

# Single source of truth — keep in sync with the inline patterns in
# .github/workflows/quarto-publish.yaml "Validate rendered HTML" step.
#
# Patterns are tightened to anchor on rendering-error context, not bare
# keyword occurrence — prose mentions of "MISSING EVIDENCE" in CHANGELOG
# or "<td>NULL</td>" in function-reference default-arg tables must NOT
# trip the gate.
QA_HTML_ERROR_PATTERNS <- c(
  # #139 vignette error stubs (the #140-class case)
  #   raw markdown form: *Rules directory not found*
  #   rendered form:     <em>Rules directory not found</em>
  "\\*[^*\\n]*\\b(directory|target|memory|file) not found\\b[^*\\n]*\\*",
  "<em>[^<]*\\b(directory|target|memory|file) not found\\b[^<]*</em>",
  # Unrendered markdown headings (line start, with following space)
  "(^|\\n)####\\s",
  # Placeholders surfaced in rendered content (require colon marker so
  # prose mentions don't trip)
  "(^|>|\\s)TODO:\\s",
  "(^|>|\\s)FIXME:\\s",
  # Vignette evidence-gate placeholder — only when in literal brackets
  "\\[MISSING EVIDENCE\\]",
  # R errors / warnings leaked into HTML code blocks
  "<code>Error[: ]",
  "<code>Warning[: ]",
  "Error in [a-zA-Z_.][a-zA-Z0-9_.]*\\(",
  # Raw R output prefix #> followed by NULL or NaN (real computation
  # error, not "x = NULL" default-arg display)
  "#&gt;\\s*(NULL|NaN)\\b",
  # gt table sourcenotes that came out NULL
  "class=\"gt_sourcenote\">NULL<"
)

#' Scan a directory of rendered HTML files for error patterns
#'
#' Used by both the `qa_html_no_errors` target and the
#' "Validate rendered HTML" step in `.github/workflows/quarto-publish.yaml`,
#' so the same patterns gate the local build AND the deploy.
#'
#' @param html_dir Path to the pkgdown output (default "docs").
#' @param skip_basenames Basenames excluded from scan (changelog, news).
#' @param skip_paths Substring excluded from scan (matched on full path).
#' @return Invisibly returns a tibble of (file, url, patterns) for files
#'   with detected errors, or NULL when clean. Calls `cli::cli_abort()`
#'   on detection so callers (target body, Rscript -e from CI) exit
#'   non-zero on failure.
scan_html_for_errors <- function(html_dir       = "docs",
                                 skip_basenames = c("CHANGELOG.html",
                                                    "NEWS.html",
                                                    "news.html"),
                                 skip_paths     = "/news/") {
  html_files <- list.files(
    html_dir,
    pattern    = "\\.html$",
    recursive  = TRUE,
    full.names = TRUE
  )

  html_files <- html_files[
    !basename(html_files) %in% skip_basenames &
    !grepl(skip_paths, html_files, fixed = TRUE)
  ]

  if (length(html_files) == 0) {
    cli::cli_alert_warning(
      "No HTML files found in {.path {html_dir}} — run pkgdown first"
    )
    return(invisible(NULL))
  }

  results <- purrr::map_dfr(html_files, function(f) {
    content <- paste(readLines(f, warn = FALSE), collapse = "\n")
    matches <- Filter(
      function(p) grepl(p, content, perl = TRUE),
      QA_HTML_ERROR_PATTERNS
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
  invisible(results)
}

plan_qa_gates <- function() {
  list(
    targets::tar_target(
      qa_html_no_errors,
      scan_html_for_errors(),
      packages = c("purrr", "tibble", "cli")
    )
  )
}
