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

#' Check rendered HTML pages for hover-popup compliance (Issue #246)
#'
#' Scans all rendered HTML pages in `html_dir` for three classes of problems:
#' 1. Pages with bare `<abbr title="…">` elements but no Tippy.js upgrade
#'    (i.e. no `.tt[data-tippy-content]` spans present on the same page).
#' 2. `.tt[data-tippy-content]` elements whose body contains fewer than 2
#'    sentences (insufficient contextual detail per the hover-popup standard).
#' 3. `.tt[data-tippy-content]` elements whose body contains no `<a href`
#'    anchor (every popup must link to at least one reference).
#'
#' Returns invisibly when all checks pass. Calls `cli::cli_abort()` — which
#' causes `tar_make()` to abort — when any violation is detected.
#'
#' @param html_dir Path to the directory of rendered HTML files to scan.
#'   Defaults to `"docs"` (pkgdown output root). Searched recursively.
#' @param skip_basenames Character vector of HTML basenames to exclude.
#' @return Invisibly returns a character vector of scanned file paths on
#'   success. Calls `cli::cli_abort()` on failure.
check_hover_popups <- function(html_dir       = "docs",
                               skip_basenames = c("CHANGELOG.html",
                                                   "NEWS.html",
                                                   "news.html")) {
  html_files <- list.files(
    html_dir,
    pattern    = "\\.html$",
    recursive  = TRUE,
    full.names = TRUE
  )
  html_files <- html_files[!basename(html_files) %in% skip_basenames]

  if (length(html_files) == 0L) {
    cli::cli_alert_warning(
      "No HTML files found in {.path {html_dir}} — run pkgdown/quarto first"
    )
    return(invisible(character(0L)))
  }

  issues <- character(0L)

  for (h in html_files) {
    content <- paste(readLines(h, warn = FALSE), collapse = "\n")

    # Check 1: bare <abbr title> without any Tippy upgrade on the page
    has_bare_abbr <- grepl('<abbr[^>]+title=', content, perl = TRUE)
    has_tippy     <- grepl('class="tt"[^>]*data-tippy-content=|data-tippy-content=', content, perl = TRUE)
    if (has_bare_abbr && !has_tippy) {
      issues <- c(issues, sprintf(
        "%s — bare <abbr title> found with no Tippy upgrade",
        basename(h)
      ))
    }

    # Check 2 & 3: per .tt element — body length and embedded link
    # Extract all data-tippy-content attribute values
    # Pattern: data-tippy-content="..." (double-quoted attribute)
    matches <- regmatches(
      content,
      gregexpr('data-tippy-content="[^"]*"', content, perl = TRUE)
    )[[1L]]

    for (m in matches) {
      # Strip the attribute name and surrounding quotes
      body <- sub('^data-tippy-content="', "", m)
      body <- sub('"$', "", body)
      # Unescape &quot; so sentence splitting works on punctuation
      body <- gsub("&quot;", '"', body, fixed = TRUE)

      # Sentence count: strip HTML tags first so URL dots (e.g. .com) are not
      # counted as sentence terminators, then split on terminal punctuation.
      body_text   <- gsub("<[^>]+>", "", body)
      parts       <- strsplit(body_text, "[.!?]+\\s*")[[1L]]
      n_sentences <- sum(nzchar(trimws(parts)))

      has_link <- grepl("<a[[:space:]]+href=", body, perl = TRUE)

      if (n_sentences < 2L) {
        issues <- c(issues, sprintf(
          "%s — tooltip '%s…' has %d sentence(s); need ≥2",
          basename(h),
          substr(body, 1L, 40L),
          n_sentences
        ))
      }
      if (!has_link) {
        issues <- c(issues, sprintf(
          "%s — tooltip '%s…' has no <a href> link",
          basename(h),
          substr(body, 1L, 40L)
        ))
      }
    }
  }

  if (length(issues) > 0L) {
    cli::cli_alert_danger("hover-popup QA failed in {length(issues)} case(s):")
    for (i in issues) cli::cli_alert_warning(i)
    cli::cli_abort(c(
      "x" = "hover-popup QA failed: {length(issues)} violation(s) detected.",
      "i" = "See .claude/rules/hover-popup-standard.md for authoring rules.",
      "i" = "Fix bare <abbr title>, add >=2 sentences, add >=1 <a href> per tooltip."
    ))
  }

  cli::cli_alert_success(
    "Hover-popup QA passed for {length(html_files)} page(s)"
  )
  invisible(html_files)
}

#' Check that all rendered vignette HTML contains the mandatory build-info block
#'
#' Every vignette must end with a `<div class="build-info">` block (from the
#' `_includes/build-info.qmd` partial). This function:
#'   1. Scans rendered HTML for the `class="build-info"` marker.
#'   2. Detects hardcoded literal dates matching `20[0-9]{2}-[0-9]{2}-[0-9]{2}`
#'      inside the block (a `dynamic-prose-values` violation).
#'
#' @param vignettes_dir Path to rendered vignettes HTML (default "docs/articles").
#' @param src_vignettes Path to vignette source directory (default "vignettes").
#' @return Invisibly returns a character vector of checked files when all pass.
#'   Calls `cli::cli_abort()` if any rendered vignette is missing the block or
#'   contains a hardcoded date.
check_build_info_blocks <- function(vignettes_dir = "docs/articles",
                                    src_vignettes  = "vignettes") {
  src_top      <- list.files(src_vignettes, pattern = "\\.qmd$",
                              full.names = FALSE, recursive = FALSE)
  src_articles <- list.files(file.path(src_vignettes, "articles"),
                              pattern = "\\.qmd$",
                              full.names = FALSE, recursive = FALSE)

  html_top      <- file.path(vignettes_dir, sub("\\.qmd$", ".html", src_top))
  html_articles <- file.path(vignettes_dir, sub("\\.qmd$", ".html", src_articles))

  html_files <- c(html_top, html_articles)
  html_files <- html_files[file.exists(html_files)]

  if (length(html_files) == 0L) {
    cli::cli_alert_warning(
      "No vignette HTML found in {.path {vignettes_dir}} — run pkgdown/quarto first"
    )
    return(invisible(character(0L)))
  }

  missing_block    <- character(0L)
  hardcoded_dates  <- character(0L)

  for (f in html_files) {
    content <- paste(readLines(f, warn = FALSE), collapse = "\n")

    if (!grepl('class="build-info"', content, fixed = TRUE)) {
      missing_block <- c(missing_block, basename(f))
    } else {
      # Extract the build-info div content and check for hardcoded dates
      # Pattern: <div class="build-info" ...> ... </div>
      block_match <- regmatches(
        content,
        regexpr('class="build-info"[^>]*>.*?</div>', content, perl = TRUE)
      )
      if (length(block_match) > 0L && nzchar(block_match)) {
        # A hardcoded date looks like 20YY-MM-DD appearing as plain text
        # (not inside an href URL, not inside a git SHA context)
        # We look for it outside of href attributes
        block_text <- gsub('<a[^>]*href="[^"]*"[^>]*>', "", block_match)
        if (grepl("20[0-9]{2}-[0-9]{2}-[0-9]{2}", block_text, perl = TRUE)) {
          hardcoded_dates <- c(hardcoded_dates, basename(f))
        }
      }
    }
  }

  if (length(missing_block) > 0L) {
    cli::cli_alert_danger(
      "Build-info block missing in {length(missing_block)} vignette(s):"
    )
    for (f in missing_block) cli::cli_alert_warning(f)
    cli::cli_abort(c(
      "x" = "All rendered vignettes must contain the build-info block.",
      "i" = "Missing in: {paste(missing_block, collapse = ', ')}",
      "i" = "Add {{< include /_includes/build-info.qmd >}} before the QR footer.",
      "i" = "See .claude/rules/vignette-build-info-block.md for placement rules."
    ))
  }

  if (length(hardcoded_dates) > 0L) {
    cli::cli_alert_danger(
      "Hardcoded dates detected in build-info block in {length(hardcoded_dates)} vignette(s):"
    )
    for (f in hardcoded_dates) cli::cli_alert_warning(f)
    cli::cli_abort(c(
      "x" = "Build-info block contains hardcoded literal dates (dynamic-prose-values violation).",
      "i" = "Affected: {paste(hardcoded_dates, collapse = ', ')}",
      "i" = "Date fields must be inline-R expressions, not hardcoded strings.",
      "i" = "See .claude/rules/dynamic-prose-values.md for the requirement."
    ))
  }

  cli::cli_alert_success(
    "Build-info blocks present and valid in all {length(html_files)} vignette(s)"
  )
  invisible(html_files)
}

#' Check committed vig_*.rds snapshots are not older than their targets
#'
#' The telemetry vignettes read via `safe_tar_read()`, which falls back to the
#' committed `inst/extdata/vignettes/vig_*.rds` snapshots when there is no
#' `_targets` store (i.e. on deploy). A pipeline-source fix therefore stays
#' invisible on the deployed site until the snapshots are re-exported.
#'
#' That is exactly what happened in #859/#860: the plots were fixed in source,
#' merged, and CI went green, but the deployed vignettes kept rendering the old
#' snapshots for weeks because nothing compared the two.
#'
#' This gate compares each `vig_` target's last build time in `tar_meta()`
#' against its snapshot's mtime and fails when the target is newer.
#'
#' @param store targets store to read metadata from.
#' @param snapshot_dir Directory holding the committed `.rds` snapshots.
#' @param tolerance_sec Grace period; a snapshot written moments before the
#'   target's recorded build time is not stale in any meaningful sense.
#' @return Invisibly, a tibble of target/snapshot times.
#' @keywords internal
check_rds_freshness <- function(store = targets::tar_config_get("store"),
                                 snapshot_dir = "inst/extdata/vignettes",
                                 tolerance_sec = 60) {
  if (!dir.exists(store)) {
    cli::cli_alert_info("No targets store at {.path {store}} — skipping snapshot-freshness gate.")
    return(invisible(NULL))
  }
  if (!dir.exists(snapshot_dir)) {
    cli::cli_alert_info("No snapshot dir at {.path {snapshot_dir}} — skipping snapshot-freshness gate.")
    return(invisible(NULL))
  }

  meta <- targets::tar_meta(store = store)
  meta <- meta[grepl("^vig_", meta$name) & !is.na(meta$time), c("name", "time")]
  if (nrow(meta) == 0) {
    cli::cli_alert_info("No built vig_* targets in {.path {store}} — skipping snapshot-freshness gate.")
    return(invisible(NULL))
  }

  meta$rds <- file.path(snapshot_dir, paste0(meta$name, ".rds"))
  meta$rds_mtime <- file.mtime(meta$rds)

  missing <- meta$name[is.na(meta$rds_mtime)]
  stale <- meta$name[
    !is.na(meta$rds_mtime) &
      as.numeric(difftime(meta$time, meta$rds_mtime, units = "secs")) > tolerance_sec
  ]

  if (length(missing) || length(stale)) {
    cli::cli_abort(c(
      "x" = "Committed vig_*.rds snapshots are out of date with the pipeline.",
      "i" = if (length(stale)) {
        "Target newer than snapshot ({length(stale)}): {paste(stale, collapse = ', ')}"
      },
      "i" = if (length(missing)) {
        "Built target with no snapshot ({length(missing)}): {paste(missing, collapse = ', ')}"
      },
      "i" = "The deployed vignettes read these snapshots, not the pipeline.",
      "i" = "Fix: Rscript data-raw/export_vignette_snapshots.R"
    ))
  }

  cli::cli_alert_success(
    "All {nrow(meta)} vig_* snapshot{?s} at least as new as their target{?s}."
  )
  invisible(meta)
}

#' Check that all built vig_* targets and their committed snapshots are non-NULL
#'
#' Implements the P0 gate mandated by `.claude/rules/qa-targets-pipeline.md`
#' ("All vig_* targets return non-NULL") and requested by #881: none of the
#' existing gates check the pipeline's inputs or its target *values* — they
#' only check the rendered HTML tail (`qa_html_no_errors`, `qa_methodology_blocks`,
#' `qa_hover_popups`, `qa_build_info_blocks`) or snapshot mtimes
#' (`qa_rds_freshness`, #872). None of them would catch the #869 failure mode:
#' an upstream input file goes missing, the target silently returns NULL, and
#' the committed `.rds` snapshot masks it from every downstream check.
#'
#' Checks two independent surfaces, because they have different causes and
#' different fixes:
#'   1. Every built `vig_*` target in the `_targets` store — a NULL here means
#'      the pipeline itself produced NULL on the last `tar_make()`.
#'   2. Every committed `inst/extdata/vignettes/vig_*.rds` snapshot — a NULL
#'      here means a NULL was exported and committed, independent of whether
#'      the current store still reproduces it.
#'
#' Ships strict with no allowlist (#881 Layer 1) by design: there is no
#' grandfathered exception carried in this function. If a `vig_*` target has
#' a legitimate reason to return NULL (e.g. an upstream export that is
#' sometimes empty by design, per #877), that decision belongs in the
#' target's own logic (a documented early-return) and its exported snapshot
#' must be refreshed once real data is available — never in an allowlist
#' here. Verification while writing this gate found exactly one pre-existing
#' violation of that discipline: the committed
#' `vig_codexbar_project_cost_plot.rds` snapshot is NULL (captured during a
#' run with no CodexBar data, #877/#879), while the target itself now builds
#' a real plot. This gate correctly flags that snapshot as stale/wrong; the
#' fix is a snapshot re-export (`Rscript data-raw/export_vignette_snapshots.R`),
#' out of scope for the commit that introduces this gate.
#'
#' @param store targets store to read metadata and target values from.
#' @param snapshot_dir Directory holding the committed `.rds` snapshots.
#' @return Invisibly, a character vector of checked target names when all
#'   pass. Calls `cli::cli_abort()` naming every offending target when any
#'   built target or committed snapshot is NULL.
#' @keywords internal
check_no_nulls <- function(store = targets::tar_config_get("store"),
                           snapshot_dir = "inst/extdata/vignettes") {
  if (!dir.exists(store)) {
    cli::cli_alert_info("No targets store at {.path {store}} — skipping no-nulls gate.")
    return(invisible(NULL))
  }

  meta <- targets::tar_meta(store = store)
  meta <- meta[grepl("^vig_", meta$name) & !is.na(meta$time), ]
  vig_names <- meta$name
  if (length(vig_names) == 0L) {
    cli::cli_alert_info("No built vig_* targets in {.path {store}} — skipping no-nulls gate.")
    return(invisible(NULL))
  }

  # Surface 1: the built target value in the _targets store.
  store_null <- vig_names[vapply(vig_names, function(nm) {
    is.null(targets::tar_read_raw(nm, store = store))
  }, logical(1L))]

  # Surface 2: the committed .rds snapshot the deployed vignettes actually
  # read via safe_tar_read(). Only checked when the snapshot exists — a
  # missing snapshot is qa_rds_freshness's concern, not this gate's.
  snapshot_null <- character(0L)
  if (dir.exists(snapshot_dir)) {
    for (nm in vig_names) {
      rds <- file.path(snapshot_dir, paste0(nm, ".rds"))
      if (file.exists(rds)) {
        val <- readRDS(rds)
        if (is.null(val)) snapshot_null <- c(snapshot_null, nm)
      }
    }
  }

  if (length(store_null) || length(snapshot_null)) {
    cli::cli_abort(c(
      "x" = "NULL vig_* target(s) detected — the pipeline is silently producing empty output.",
      "i" = if (length(store_null)) {
        "Built target is NULL in the _targets store ({length(store_null)}): {paste(store_null, collapse = ', ')}"
      },
      "i" = if (length(snapshot_null)) {
        "Committed snapshot is NULL ({length(snapshot_null)}): {paste(snapshot_null, collapse = ', ')}"
      },
      "i" = "A NULL vig_ target usually means an upstream input file went missing or stale.",
      "i" = "Check the target's input resolution via llm_extdata_file() / ccusage_cache_file().",
      "i" = "Fix the input, re-run tar_make(), then re-export: Rscript data-raw/export_vignette_snapshots.R"
    ))
  }

  cli::cli_alert_success(
    "All {length(vig_names)} vig_* target{?s} non-NULL in store and snapshot{?s}."
  )
  invisible(vig_names)
}

plan_qa_gates <- function() {
  list(
    targets::tar_target(
      qa_no_nulls,
      check_no_nulls(),
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    ),
    targets::tar_target(
      qa_rds_freshness,
      check_rds_freshness(),
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    ),
    targets::tar_target(
      qa_html_no_errors,
      scan_html_for_errors(),
      packages = c("purrr", "tibble", "cli")
    ),
    targets::tar_target(
      qa_methodology_blocks,
      check_methodology_blocks(),
      packages = c("purrr", "tibble", "cli")
    ),
    targets::tar_target(
      qa_hover_popups,
      check_hover_popups(),
      packages = c("cli")
    ),
    targets::tar_target(
      qa_build_info_blocks,
      check_build_info_blocks(),
      packages = c("cli")
    )
  )
}
