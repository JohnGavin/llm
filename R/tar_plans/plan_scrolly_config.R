# R/tar_plans/plan_scrolly_config.R
# Targets for scrolly-config-evolution vignette
# Scans a subset of .claude/ config artifacts and builds a per-file tibble
# with metadata. Coverage: rules (.md), skills (SKILL.md only), agents (.md),
# hooks (.sh), memory (.md), commands (.md), scripts (.sh).
# Other .claude/ paths (e.g. worktrees/, logs/) are intentionally excluded.

# Internal helper: derive human-readable scope text from scan_specs.
# scan_specs: named list of lists with fields $pattern and $recurse.
# n_files: integer — total files in vig_scrolly_config after exclusions.
# Returns a list with two character(1) elements:
#   $prose — for methodology section prose
#   $alt   — shorter string for fig-alt attributes
.build_scrolly_scope <- function(scan_specs, n_files) {
  cat_desc <- vapply(names(scan_specs), function(cat) {
    spec     <- scan_specs[[cat]]
    pat      <- spec$pattern
    rec      <- isTRUE(spec$recurse)
    pat_desc <- if (grepl("^SKILL\\.md\\$", pat, ignore.case = FALSE)) {
      "SKILL.md only"
    } else if (grepl("^\\.md\\$", pat)) {
      if (rec) "*.md (recursive)" else "*.md (top-level)"
    } else if (grepl("^\\.sh\\$", pat)) {
      if (rec) "*.sh (recursive)" else "*.sh (top-level)"
    } else {
      pat
    }
    paste0(cat, " (", pat_desc, ")")
  }, character(1L))

  cat_list <- paste(cat_desc, collapse = ", ")

  prose <- paste0(
    "Tracked files scanned from `.claude/` using per-category specs: ",
    cat_list,
    ". Paths under `archive/` and `worktrees/` subtrees are excluded. ",
    n_files, " files total."
  )

  alt <- paste0(
    "Config files from `.claude/` across ",
    length(scan_specs), " categories (",
    paste(names(scan_specs), collapse = ", "),
    "). Skills match SKILL.md only; rules use recursive *.md; all other categories ",
    "use top-level glob. archive/ and worktrees/ excluded."
  )

  list(prose = prose, alt = alt)
}

plan_scrolly_config <- function() {
  list(
    # scrolly_scan_specs: canonical per-category scan configuration.
    # Both vig_scrolly_config and scrolly_scope_text derive from this target
    # so prose and data stay in sync when specs change.
    tar_target(
      scrolly_scan_specs,
      list(
        rules    = list(pattern = "\\.md$",      recurse = TRUE),
        skills   = list(pattern = "SKILL\\.md$", recurse = TRUE),
        agents   = list(pattern = "\\.md$",      recurse = FALSE),
        hooks    = list(pattern = "\\.sh$",      recurse = FALSE),
        memory   = list(pattern = "\\.md$",      recurse = FALSE),
        commands = list(pattern = "\\.md$",      recurse = FALSE),
        scripts  = list(pattern = "\\.sh$",      recurse = FALSE)
      ),
      packages = character(0)
    ),
    # scrolly_scope_text: human-readable scope description derived from
    # scrolly_scan_specs. Referenced in vignette prose and fig-alt attributes
    # via safe_tar_read("scrolly_scope_text") — satisfies dynamic-prose-values rule.
    tar_target(
      scrolly_scope_text,
      .build_scrolly_scope(scrolly_scan_specs, nrow(vig_scrolly_config)),
      packages = character(0)
    ),
    tar_target(
      vig_scrolly_config,
      {
        claude_dir <- here::here(".claude")

        # Build full scan_specs (with path) from the canonical spec target
        full_specs <- lapply(names(scrolly_scan_specs), function(cat) {
          s <- scrolly_scan_specs[[cat]]
          s$path <- file.path(claude_dir, cat)
          s
        })
        names(full_specs) <- names(scrolly_scan_specs)

        # Collect files per category
        rows <- lapply(names(full_specs), function(cat) {
          spec  <- full_specs[[cat]]
          if (!dir.exists(spec$path)) return(tibble::tibble())
          files <- list.files(
            spec$path,
            pattern   = spec$pattern,
            recursive = spec$recurse,
            full.names = TRUE
          )
          # Skip archive/ and worktrees/ subtrees
          files <- files[!grepl("/(archive|worktrees)/", files, fixed = FALSE)]
          if (length(files) == 0L) return(tibble::tibble())

          tibble::tibble(
            abs_path = files,
            category = cat
          )
        })

        all_files <- dplyr::bind_rows(rows)
        if (nrow(all_files) == 0L) {
          return(tibble::tibble(
            path         = character(0),
            category     = factor(character(0)),
            n_lines      = integer(0),
            n_bytes      = integer(0),
            git_age_days = numeric(0)
          ))
        }

        # Line and byte counts
        count_lines <- function(p) {
          tryCatch(
            length(readLines(p, warn = FALSE)),
            error = function(e) 0L
          )
        }

        repo_root <- here::here()

        get_git_age <- function(p) {
          rel <- tryCatch(
            fs::path_rel(p, repo_root),
            error = function(e) p
          )
          # git log -1 --format=%ct returns Unix timestamp of last commit
          result <- tryCatch(
            system2(
              "git",
              args    = c("-C", repo_root, "log", "-1", "--format=%ct", "--", rel),
              stdout  = TRUE,
              stderr  = FALSE
            ),
            error = function(e) character(0)
          )
          if (length(result) == 0L || !nzchar(result[[1L]])) return(0)
          ts <- suppressWarnings(as.numeric(result[[1L]]))
          if (is.na(ts)) return(0)
          as.numeric(difftime(Sys.time(), as.POSIXct(ts, origin = "1970-01-01", tz = "UTC"),
                              units = "days"))
        }

        dplyr::mutate(
          all_files,
          path         = as.character(fs::path_rel(abs_path, repo_root)),
          category     = factor(category, levels = names(scrolly_scan_specs)),
          n_lines      = vapply(abs_path, count_lines, integer(1L)),
          n_bytes      = as.integer(file.info(abs_path)$size),
          git_age_days = vapply(abs_path, get_git_age, numeric(1L))
        ) |>
          dplyr::select(path, category, n_lines, n_bytes, git_age_days)
      },
      packages = c("dplyr", "tibble", "fs", "here"),
      cue = tar_cue(mode = "always")
    )
  )
}
