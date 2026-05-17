# R/tar_plans/plan_kb_stats.R
# Pre-computes aggregate knowledge-base stats for the knowledge-evolution vignette.
# knowledge/ is gitignored (wiki-storage-policy), so CI cannot read it directly.
# This target exports aggregates only — no raw page content — to inst/extdata/vignettes/.

plan_kb_stats <- function() {
  list(
    tar_target(
      vig_kb_stats,
      {
        # Locate knowledge/ — probe repo-relative path first (works in CI when
        # knowledge/ were ever present), then fall back to absolute home path.
        .kb_candidates <- c(
          here::here("knowledge"),
          path.expand("~/docs_gh/llm/knowledge")
        )
        kb_path <- Find(dir.exists, .kb_candidates)

        wiki_dir <- if (!is.null(kb_path)) file.path(kb_path, "wiki") else NULL
        raw_dir  <- if (!is.null(kb_path)) file.path(kb_path, "raw")  else NULL

        if (is.null(kb_path) || !dir.exists(wiki_dir)) {
          # CI / no knowledge/ available — return zero-value stub
          return(list(
            n_pages           = 0L,
            n_sources         = 0L,
            with_sources      = 0L,
            provenance_pct    = 0,
            ai_inferred_markers = 0L,
            page_words        = setNames(numeric(0), character(0)),
            snapshot_date     = Sys.Date(),
            note = paste0(
              "knowledge/ unavailable in this build environment (gitignored). ",
              "Run tar_make(vig_kb_stats) locally and commit the RDS."
            )
          ))
        }

        # --- Wiki stats ---------------------------------------------------------
        wiki_files <- list.files(wiki_dir, pattern = "\\.md$", full.names = TRUE)
        n_pages    <- length(wiki_files)

        if (n_pages == 0L) {
          page_words_raw   <- numeric(0)
          with_sources_raw <- 0L
          ai_markers_raw   <- 0L
        } else {
          read_lines_safe <- function(f) {
            tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
          }

          page_words_raw <- vapply(wiki_files, function(f) {
            content <- paste(read_lines_safe(f), collapse = " ")
            length(strsplit(trimws(content), "\\s+")[[1L]])
          }, integer(1L))

          with_sources_raw <- sum(vapply(wiki_files, function(f) {
            any(grepl("^## Sources", read_lines_safe(f)))
          }, logical(1L)))

          ai_markers_raw <- sum(vapply(wiki_files, function(f) {
            sum(grepl("AI-inferred", read_lines_safe(f), fixed = TRUE))
          }, integer(1L)))
        }

        # Anonymize page keys: sort by word count desc, name page_001, page_002 …
        if (n_pages > 0L) {
          sorted_idx  <- order(page_words_raw, decreasing = TRUE)
          sorted_wc   <- page_words_raw[sorted_idx]
          anon_names  <- sprintf("page_%03d", seq_along(sorted_wc))
          page_words  <- setNames(as.numeric(sorted_wc), anon_names)
        } else {
          page_words <- setNames(numeric(0), character(0))
        }

        # --- Raw sources --------------------------------------------------------
        n_sources <- if (!is.null(raw_dir) && dir.exists(raw_dir)) {
          length(list.files(raw_dir, recursive = TRUE, all.files = FALSE))
        } else {
          0L
        }

        result <- list(
          n_pages             = as.integer(n_pages),
          n_sources           = as.integer(n_sources),
          with_sources        = as.integer(with_sources_raw),
          provenance_pct      = if (n_pages > 0L) {
            round(with_sources_raw / n_pages * 100, 1)
          } else {
            0
          },
          ai_inferred_markers = as.integer(ai_markers_raw),
          page_words          = page_words,
          snapshot_date       = Sys.Date(),
          note                = NA_character_
        )

        # Write RDS so the vignette can load it in CI (knowledge/ is gitignored).
        # Commit inst/extdata/vignettes/vig_kb_stats.rds after running tar_make().
        rds_out <- here::here("inst/extdata/vignettes/vig_kb_stats.rds")
        saveRDS(result, rds_out)

        result
      },
      packages = c("here"),
      cue = tar_cue(mode = "always")
    )
  )
}
