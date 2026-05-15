# R/tar_plans/plan_scrolly_config.R
# Targets for scrolly-config-evolution vignette
# Scans .claude/ files and builds a per-file tibble with metadata

plan_scrolly_config <- function() {
  list(
    tar_target(
      vig_scrolly_config,
      {
        claude_dir <- here::here(".claude")

        # File patterns to scan per category
        scan_specs <- list(
          rules    = list(
            path    = file.path(claude_dir, "rules"),
            pattern = "\\.md$",
            recurse = TRUE
          ),
          skills   = list(
            path    = file.path(claude_dir, "skills"),
            pattern = "SKILL\\.md$",
            recurse = TRUE
          ),
          agents   = list(
            path    = file.path(claude_dir, "agents"),
            pattern = "\\.md$",
            recurse = FALSE
          ),
          hooks    = list(
            path    = file.path(claude_dir, "hooks"),
            pattern = "\\.sh$",
            recurse = FALSE
          ),
          memory   = list(
            path    = file.path(claude_dir, "memory"),
            pattern = "\\.md$",
            recurse = FALSE
          ),
          commands = list(
            path    = file.path(claude_dir, "commands"),
            pattern = "\\.md$",
            recurse = FALSE
          ),
          scripts  = list(
            path    = file.path(claude_dir, "scripts"),
            pattern = "\\.sh$",
            recurse = FALSE
          )
        )

        # Collect files per category
        rows <- lapply(names(scan_specs), function(cat) {
          spec  <- scan_specs[[cat]]
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
          category     = factor(category,
                                levels = c("rules", "skills", "agents", "hooks",
                                           "memory", "commands", "scripts")),
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
