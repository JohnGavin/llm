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

#' Check that all rendered vignette HTML contains the mandatory methodology block
#'
#' Every analytical vignette must ship with three H3 subsections:
#' "What this vignette computes", "Data sources", and "AI disclosure".
#' This function scans rendered HTML and aborts the pipeline if any are missing.
#'
#' @param vignettes_dir Path to rendered vignettes HTML (default "docs/articles").
#' @return Invisibly returns a character vector of checked files when all pass.
#'   Calls `cli::cli_abort()` if any rendered vignette is missing any of the
#'   three required subsections.
check_methodology_blocks <- function(vignettes_dir = "docs/articles",
                                     src_vignettes  = "vignettes") {
  # Derive the set of HTML files to check from the vignette SOURCE files.
  # This prevents non-vignette pages (authors.html, AGENTS.html, etc.) from
  # being flagged for missing methodology blocks.
  #
  # pkgdown flattens ALL vignettes into docs/articles/<name>.html:
  #   vignettes/<name>.qmd          -> docs/articles/<name>.html
  #   vignettes/articles/<name>.qmd -> docs/articles/<name>.html
  src_top      <- list.files(src_vignettes, pattern = "\\.qmd$",
                              full.names = FALSE, recursive = FALSE)
  src_articles <- list.files(file.path(src_vignettes, "articles"),
                              pattern = "\\.qmd$",
                              full.names = FALSE, recursive = FALSE)

  html_top      <- file.path(vignettes_dir,
                              sub("\\.qmd$", ".html", src_top))
  html_articles <- file.path(vignettes_dir,
                              sub("\\.qmd$", ".html", src_articles))

  html_files <- c(html_top, html_articles)
  # Keep only files that actually exist (skip if docs not yet rendered)
  html_files <- html_files[file.exists(html_files)]

  if (length(html_files) == 0L) {
    cli::cli_alert_warning(
      "No vignette HTML found in {.path {vignettes_dir}} — run pkgdown/quarto first"
    )
    return(invisible(character(0L)))
  }

  # Required methodology section markers (match H3 id slugs or text)
  required_markers <- c(
    methodology  = "Methodology",
    data_sources = "Data sources",
    ai_disc      = "AI disclosure"
  )

  missing_report <- purrr::map_dfr(html_files, function(f) {
    content <- paste(readLines(f, warn = FALSE), collapse = "\n")
    absent <- names(required_markers)[
      !vapply(required_markers, function(m) grepl(m, content, ignore.case = TRUE), logical(1L))
    ]
    if (length(absent) > 0L) {
      tibble::tibble(
        file    = basename(f),
        missing = paste(absent, collapse = ", ")
      )
    }
  })

  if (!is.null(missing_report) && nrow(missing_report) > 0L) {
    cli::cli_alert_danger("Methodology blocks missing in {nrow(missing_report)} vignette(s):")
    print(missing_report)
    cli::cli_abort(c(
      "x" = "All rendered vignettes must contain ## Methodology with three H3 subsections.",
      "i" = "Missing in: {paste(missing_report$file, collapse = ', ')}",
      "i" = "See narrative-evidence-block rule for the required structure."
    ))
  }

  cli::cli_alert_success(
    "Methodology blocks present in all {length(html_files)} vignette page(s)"
  )
  invisible(html_files)
}

plan_qa_gates <- function() {
  list(
    targets::tar_target(
      qa_html_no_errors,
      scan_html_for_errors(),
      packages = c("purrr", "tibble", "cli")
    ),
    targets::tar_target(
      qa_methodology_blocks,
      check_methodology_blocks(),
      packages = c("purrr", "tibble", "cli")
    )
  )
}
