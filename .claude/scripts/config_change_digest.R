#!/usr/bin/env Rscript
# config_change_digest.R — Aggregate git changes to meta-config categories into a
# structured markdown digest.
#
# Usage:
#   Rscript .claude/scripts/config_change_digest.R \
#     [--since YYYY-MM-DDTHH:MM:SS] [--out PATH] [--dry-run]
#
# Defaults:
#   --since   24 hours ago (ISO8601)
#   --out     /tmp/config_change_digest_<date>.md
#   --dry-run print digest to stdout only
#
# Category paths (relative to repo root):
#   Skills    .claude/skills/**
#   Agents    .claude/agents/**
#   Rules     .claude/rules/**
#   Memory    .claude/memory/**
#   Hooks     .claude/hooks/**
#   Scripts   .claude/scripts/**
#   Templates .claude/templates/**
#   Commands  .claude/commands/**
#
# Output: a structured markdown file consumed by send_config_digest_email.R.
#
# Tracked in llm#297, enriched in llm#444.

# ── Argument parsing ──────────────────────────────────────────────────────────

args <- commandArgs(trailingOnly = TRUE)

parse_args <- function(args) {
  out <- list(
    since   = format(Sys.time() - 86400, "%Y-%m-%dT%H:%M:%S"),
    out     = file.path(tempdir(), sprintf("config_change_digest_%s.md", format(Sys.Date()))),
    dry_run = FALSE
  )
  i <- 1L
  while (i <= length(args)) {
    if (args[i] == "--since" && i + 1L <= length(args)) {
      out$since <- args[i + 1L]; i <- i + 2L
    } else if (args[i] == "--out" && i + 1L <= length(args)) {
      out$out <- args[i + 1L]; i <- i + 2L
    } else if (args[i] == "--dry-run") {
      out$dry_run <- TRUE; i <- i + 1L
    } else {
      i <- i + 1L
    }
  }
  out
}

cfg <- parse_args(args)

# ── Locate repo root ──────────────────────────────────────────────────────────

find_repo_root <- function() {
  # Env override: allows tests to point at a synthetic fixture repo.
  env_root <- Sys.getenv("LLM_REPO_ROOT", unset = "")
  if (nzchar(env_root) && file.exists(file.path(env_root, ".git"))) {
    return(normalizePath(env_root))
  }
  # Walk up from script location or working directory
  start <- tryCatch(
    dirname(normalizePath(sys.frame(0)$ofile, mustWork = FALSE)),
    error = function(e) getwd()
  )
  path <- start
  for (i in seq_len(10L)) {
    if (file.exists(file.path(path, ".git"))) return(path)
    parent <- dirname(path)
    if (parent == path) break
    path <- parent
  }
  # Final fallback: cwd
  getwd()
}

REPO_ROOT <- find_repo_root()

# ── Repo slug and link helpers ────────────────────────────────────────────────

REPO_SLUG <- "JohnGavin/llm"

link_hash <- function(short_hash) {
  # Render a 7-char commit hash as a markdown hyperlink.
  sprintf("[`%s`](https://github.com/%s/commit/%s)", short_hash, REPO_SLUG, short_hash)
}

linkify_issues <- function(text) {
  # Replace #NNN references with markdown issue links.
  gsub("#([0-9]+)",
       sprintf("[#\\1](https://github.com/%s/issues/\\1)", REPO_SLUG),
       text, perl = TRUE)
}

# ── Category definitions ──────────────────────────────────────────────────────

CATEGORIES <- list(
  list(name = "Skills",    path = ".claude/skills",    exclude = c(".system", "generated")),
  list(name = "Agents",    path = ".claude/agents",    exclude = character(0)),
  list(name = "Rules",     path = ".claude/rules",     exclude = character(0)),
  list(name = "Memory",    path = ".claude/memory",    exclude = character(0)),
  list(name = "Hooks",     path = ".claude/hooks",     exclude = character(0)),
  list(name = "Scripts",   path = ".claude/scripts",   exclude = character(0)),
  list(name = "Templates", path = ".claude/templates", exclude = character(0)),
  list(name = "Commands",  path = ".claude/commands",  exclude = character(0))
)

# ── Git helpers ───────────────────────────────────────────────────────────────

run_git <- function(...) {
  result <- system2("git", args = c("-C", REPO_ROOT, ...),
                    stdout = TRUE, stderr = FALSE)
  result
}

git_log_numstat <- function(since, path_prefix) {
  # Returns character vector of lines from git log --numstat.
  # Use --pretty=tformat: to avoid system2 shell-interpolation of % tokens.
  # Separator is UNIT SEPARATOR (ASCII 31) converted to | in post-process.
  fmt <- paste0("COMMIT:", "%H", "\x1f", "%s", "\x1f", "%ae", "\x1f", "%ad")
  run_git("log", "--numstat",
          paste0("--pretty=tformat:", fmt),
          "--date=iso-strict",
          paste0("--since=", since),
          "--", path_prefix)
}

git_log_commits <- function(since) {
  # Returns all commits in window: hash\x1fsubject
  fmt <- paste0("%H", "\x1f", "%s")
  lines <- run_git("log",
                   paste0("--pretty=tformat:", fmt),
                   "--no-merges",
                   paste0("--since=", since))
  lines
}

parse_conv_scope <- function(subject) {
  # Extract scope from conventional commit: "type(scope): msg" -> "scope"
  m <- regmatches(subject, regexpr("\\(([^)]+)\\)", subject))
  if (length(m) == 0L || !nzchar(m)) return(NA_character_)
  gsub("[()]", "", m)
}

parse_conv_type <- function(subject) {
  m <- regmatches(subject, regexpr("^([a-z]+)(?:\\([^)]*\\))?:", subject, perl = TRUE))
  if (length(m) == 0L || !nzchar(m)) return(NA_character_)
  gsub(":.*$", "", gsub("\\([^)]*\\)", "", m))
}

# ── Per-category stats ────────────────────────────────────────────────────────

compute_category_stats <- function(cat_def, since) {
  path  <- cat_def$path
  excl  <- cat_def$exclude

  lines <- git_log_numstat(since, path)
  if (length(lines) == 0L) {
    return(list(
      name = cat_def$name, path = path,
      n_commits = 0L, n_added = 0L, n_deleted = 0L,
      files_changed = character(0), commits = list(),
      file_stats = list(), top_files = list()
    ))
  }

  # Parse numstat output
  # Format alternates: COMMIT:<hash>|<subject>|<author>|<date>
  #                    <added>\t<deleted>\t<file>
  current_commit <- NULL
  commits <- list()
  files_changed <- character(0)
  total_added <- 0L
  total_deleted <- 0L
  # Per-file accumulator: named list of list(added=N, deleted=N)
  file_stats <- list()

  for (line in lines) {
    if (startsWith(line, "COMMIT:")) {
      parts <- strsplit(sub("^COMMIT:", "", line), "\x1f", fixed = TRUE)[[1]]
      current_commit <- list(
        hash    = if (length(parts) >= 1L) parts[[1L]] else "",
        subject = if (length(parts) >= 2L) parts[[2L]] else "",
        author  = if (length(parts) >= 3L) parts[[3L]] else "",
        date    = if (length(parts) >= 4L) parts[[4L]] else ""
      )
      commits[[length(commits) + 1L]] <- current_commit
    } else if (grepl("^\t", line) || grepl("^[0-9-]", line)) {
      # numstat line: added\tdeleted\tfile
      parts <- strsplit(trimws(line), "\t")[[1]]
      if (length(parts) < 3L) next
      # Filter excluded subdirectories
      file_path <- parts[[3L]]
      if (length(excl) > 0L) {
        skip <- any(sapply(excl, function(ex) grepl(ex, file_path, fixed = TRUE)))
        if (skip) next
      }
      added   <- suppressWarnings(as.integer(parts[[1L]]))
      deleted <- suppressWarnings(as.integer(parts[[2L]]))
      if (!is.na(added))   total_added   <- total_added   + added
      if (!is.na(deleted)) total_deleted <- total_deleted + deleted
      files_changed <- unique(c(files_changed, file_path))
      # Accumulate per-file stats
      if (!is.null(file_stats[[file_path]])) {
        file_stats[[file_path]]$added   <- file_stats[[file_path]]$added   + if (!is.na(added))   added   else 0L
        file_stats[[file_path]]$deleted <- file_stats[[file_path]]$deleted + if (!is.na(deleted)) deleted else 0L
      } else {
        file_stats[[file_path]] <- list(
          added   = if (!is.na(added))   added   else 0L,
          deleted = if (!is.na(deleted)) deleted else 0L
        )
      }
    }
  }

  # Compute top_files: top 3 by (added + deleted), sorted descending
  top_files <- list()
  if (length(file_stats) > 0L) {
    totals <- sapply(file_stats, function(fs) fs$added + fs$deleted)
    ord    <- order(totals, decreasing = TRUE)
    top_n  <- min(3L, length(ord))
    for (j in seq_len(top_n)) {
      fp <- names(file_stats)[ord[j]]
      top_files[[j]] <- list(
        path    = fp,
        added   = file_stats[[fp]]$added,
        deleted = file_stats[[fp]]$deleted
      )
    }
  }

  list(
    name          = cat_def$name,
    path          = path,
    n_commits     = length(commits),
    n_added       = total_added,
    n_deleted     = total_deleted,
    files_changed = files_changed,
    commits       = commits,
    file_stats    = file_stats,
    top_files     = top_files
  )
}

# ── Filetype subtotals ────────────────────────────────────────────────────────

compute_filetype_stats <- function(cat_stats) {
  # Walk all categories and re-bucket file_stats by extension.
  # Returns a list sorted by total (added+deleted) desc, each entry:
  #   list(ext=".R", n_files=N, added=N, deleted=N)
  ext_map <- list()  # keyed by extension string

  for (s in cat_stats) {
    if (length(s$file_stats) == 0L) next
    for (fp in names(s$file_stats)) {
      ext <- tools::file_ext(fp)
      if (!nzchar(ext)) ext <- "(no ext)"
      ext_key <- paste0(".", ext)
      fs  <- s$file_stats[[fp]]
      if (!is.null(ext_map[[ext_key]])) {
        ext_map[[ext_key]]$n_files <- ext_map[[ext_key]]$n_files + 1L
        ext_map[[ext_key]]$added   <- ext_map[[ext_key]]$added   + fs$added
        ext_map[[ext_key]]$deleted <- ext_map[[ext_key]]$deleted + fs$deleted
      } else {
        ext_map[[ext_key]] <- list(
          ext     = ext_key,
          n_files = 1L,
          added   = fs$added,
          deleted = fs$deleted
        )
      }
    }
  }

  if (length(ext_map) == 0L) return(list())

  totals <- sapply(ext_map, function(e) e$added + e$deleted)
  ord    <- order(totals, decreasing = TRUE)
  ext_map[ord]
}

# ── Theme clustering ──────────────────────────────────────────────────────────

cluster_themes <- function(commit_lines, top_n = 5L) {
  # commit_lines: "hash|subject" format from git_log_commits()
  # Returns: list with $top (top_n themes) and $all_counts (named int vector, sorted desc)
  if (length(commit_lines) == 0L) return(list(top = list(), all_counts = integer(0)))

  parsed <- lapply(commit_lines, function(l) {
    parts   <- strsplit(l, "\x1f", fixed = TRUE)[[1L]]
    hash    <- if (length(parts) >= 1L) parts[[1L]] else ""
    subject <- if (length(parts) >= 2L) paste(parts[-1L], collapse = " ") else ""
    scope   <- parse_conv_scope(subject)
    type    <- parse_conv_type(subject)
    list(hash = hash, subject = subject, scope = scope, type = type)
  })

  # Group by scope (fall back to type if no scope)
  theme_key <- function(p) {
    if (!is.na(p$scope) && nzchar(p$scope)) return(p$scope)
    if (!is.na(p$type)  && nzchar(p$type))  return(p$type)
    "other"
  }

  themes <- list()
  for (p in parsed) {
    k <- theme_key(p)
    if (is.null(themes[[k]])) themes[[k]] <- list(commits = list(), n = 0L)
    themes[[k]]$commits <- c(themes[[k]]$commits, list(p))
    themes[[k]]$n       <- themes[[k]]$n + 1L
  }

  # Sort by count descending
  counts        <- sapply(themes, function(t) t$n)
  themes_sorted <- themes[order(counts, decreasing = TRUE)]
  counts_sorted <- counts[order(counts, decreasing = TRUE)]

  # all_counts: named integer vector for breakdown QA marker
  all_counts <- setNames(as.integer(counts_sorted), names(themes_sorted))

  list(top = head(themes_sorted, top_n), all_counts = all_counts)
}

# ── Lessons-learnt extraction ─────────────────────────────────────────────────

extract_lessons <- function(since, changelog_path = NULL) {
  lessons <- list()

  # 1. fix:/revert: commits
  fix_fmt     <- paste0("%H", "\x1f", "%s")
  fix_commits <- run_git("log",
    paste0("--pretty=tformat:", fix_fmt),
    "--no-merges",
    paste0("--since=", since))

  for (line in fix_commits) {
    parts   <- strsplit(line, "\x1f", fixed = TRUE)[[1L]]
    subject <- if (length(parts) >= 2L) paste(parts[-1L], collapse = " ") else ""
    type    <- parse_conv_type(subject)
    if (!is.na(type) && type %in% c("fix", "revert")) {
      short_hash <- if (length(parts) >= 1L) substr(parts[[1L]], 1L, 7L) else ""
      lessons[[length(lessons) + 1L]] <- list(
        type    = type,
        subject = subject,
        hash    = short_hash,
        source  = "commit"
      )
    }
  }

  # 2. CHANGELOG.md "Failed approaches" section within window
  if (is.null(changelog_path)) {
    changelog_path <- file.path(REPO_ROOT, "CHANGELOG.md")
  }
  if (file.exists(changelog_path)) {
    cl_lines <- readLines(changelog_path, warn = FALSE)
    # Find sections matching the since window: look for ## <date> headings
    since_date <- tryCatch(
      as.Date(substr(since, 1L, 10L)),
      error = function(e) Sys.Date() - 1L
    )
    in_window_section  <- FALSE
    in_failed_section  <- FALSE
    failed_bullets     <- character(0)

    for (l in cl_lines) {
      # Check for date heading
      if (grepl("^## \\d{4}-\\d{2}-\\d{2}", l)) {
        date_str <- regmatches(l, regexpr("\\d{4}-\\d{2}-\\d{2}", l))
        if (length(date_str) > 0L) {
          section_date <- tryCatch(as.Date(date_str), error = function(e) NA)
          if (!is.na(section_date) && section_date >= since_date) {
            in_window_section <- TRUE
          } else {
            in_window_section <- FALSE
          }
        }
        in_failed_section <- FALSE
      } else if (in_window_section && grepl("^###.*[Ff]ailed", l)) {
        in_failed_section <- TRUE
      } else if (in_window_section && grepl("^###", l)) {
        in_failed_section <- FALSE
      } else if (in_failed_section && grepl("^-", l)) {
        failed_bullets <- c(failed_bullets, trimws(sub("^-+\\s*", "", l)))
      }
    }

    if (length(failed_bullets) > 0L) {
      for (b in head(failed_bullets, 5L)) {
        lessons[[length(lessons) + 1L]] <- list(
          type    = "changelog-failed",
          subject = b,
          hash    = "",
          source  = "CHANGELOG"
        )
      }
    }
  }

  # Compute type breakdown (named int vector, sorted desc) for QA marker
  if (length(lessons) > 0L) {
    type_vec  <- sapply(lessons, function(l) toupper(l$type))
    type_tbl  <- sort(table(type_vec), decreasing = TRUE)
    lessons_breakdown <- setNames(as.integer(type_tbl), names(type_tbl))
  } else {
    lessons_breakdown <- integer(0)
  }

  # Return list with $lessons (records) and $breakdown (named int vector)
  list(lessons = lessons, breakdown = lessons_breakdown)
}

# ── Markdown rendering ────────────────────────────────────────────────────────

render_markdown <- function(cat_stats, themes_result, lessons_result, since, generated_at) {
  # themes_result: list(top=..., all_counts=...)  from cluster_themes()
  # lessons_result: list(lessons=..., breakdown=...) from extract_lessons()
  themes          <- themes_result$top
  themes_counts   <- themes_result$all_counts
  lessons         <- lessons_result$lessons
  lessons_brkdown <- lessons_result$breakdown

  lines <- character(0)
  emit  <- function(...) lines <<- c(lines, sprintf(...))

  emit("# Config-Change Digest — %s", format(as.Date(substr(since, 1L, 10L)) + 1L))
  emit("")
  emit("**Window:** since `%s` | **Generated:** `%s` UTC", since, generated_at)
  emit("")

  # ── Enhancement 1: Filetype subtotals line ─────────────────────────────────
  ft_stats <- compute_filetype_stats(cat_stats)
  if (length(ft_stats) > 0L) {
    top3_ft <- head(ft_stats, 3L)
    others  <- max(0L, length(ft_stats) - 3L)
    ft_parts <- sapply(top3_ft, function(ft) {
      sprintf("%d `%s` (+%d -%d)", ft$n_files, ft$ext, ft$added, ft$deleted)
    })
    others_str <- if (others > 0L) sprintf(", +%d others", others) else ""
    emit("**By filetype:** %s%s", paste(ft_parts, collapse = " · "), others_str)
    emit("")
  }

  emit("---")
  emit("")

  # ── Section 1: Category summary table (with Top files column) ──────────────
  emit("## Changes by Category")
  emit("")
  emit("| Category | Files changed | Lines added | Lines deleted | Top files |")
  emit("|----------|:-------------:|:-----------:|:-------------:|-----------|")

  total_files   <- 0L
  total_added   <- 0L
  total_deleted <- 0L

  for (s in cat_stats) {
    n_files <- length(s$files_changed)
    total_files   <- total_files   + n_files
    total_added   <- total_added   + s$n_added
    total_deleted <- total_deleted + s$n_deleted
    if (n_files == 0L && s$n_added == 0L && s$n_deleted == 0L) next

    # ── Enhancement 5: Top-3 files drilldown ─────────────────────────────────
    if (length(s$top_files) > 0L) {
      file_parts <- sapply(s$top_files, function(tf) {
        bn  <- basename(tf$path)
        url <- sprintf("https://github.com/%s/blob/main/%s", REPO_SLUG, tf$path)
        sprintf("[`%s`](%s) (+%d -%d)", bn, url, tf$added, tf$deleted)
      })
      n_extra    <- max(0L, n_files - length(s$top_files))
      others_str <- if (n_extra > 0L) sprintf(" · +%d others", n_extra) else ""
      top_files_cell <- paste0(paste(file_parts, collapse = " · "), others_str)
    } else {
      top_files_cell <- "—"
    }

    emit("| %s | %d | +%d | -%d | %s |",
         s$name, n_files, s$n_added, s$n_deleted, top_files_cell)
  }

  emit("| **Total** | **%d** | **+%d** | **-%d** | |",
       total_files, total_added, total_deleted)
  emit("")

  # ── Section 2: Themes today ────────────────────────────────────────────────
  emit("## Themes Today")
  emit("")

  if (length(themes) == 0L) {
    emit("_No commits in window._")
  } else {
    for (theme_name in names(themes)) {
      t <- themes[[theme_name]]
      emit("### `%s` (%d commit%s)", theme_name, t$n, if (t$n == 1L) "" else "s")
      emit("")
      for (c in head(t$commits, 3L)) {
        short_hash <- substr(c$hash, 1L, 7L)
        # ── Enhancement 4: Embedded links ─────────────────────────────────────
        emit("- %s %s", link_hash(short_hash), linkify_issues(c$subject))
      }
      if (t$n > 3L) emit("- _(+%d more)_", t$n - 3L)
      emit("")
    }
  }

  emit("---")
  emit("")

  # ── Section 3: Lessons learnt ──────────────────────────────────────────────
  emit("## Lessons Learnt")
  emit("")

  fix_lessons <- Filter(function(l) l$source == "commit", lessons)
  cl_lessons  <- Filter(function(l) l$source == "CHANGELOG", lessons)

  if (length(fix_lessons) == 0L && length(cl_lessons) == 0L) {
    emit("_No fix/revert commits or CHANGELOG failed-approach entries in window._")
  } else {
    if (length(fix_lessons) > 0L) {
      emit("### From fix/revert commits")
      emit("")
      for (l in fix_lessons) {
        # ── Enhancement 4: Embedded links ───────────────────────────────────
        hash_part <- if (nzchar(l$hash)) sprintf(" %s", link_hash(l$hash)) else ""
        emit("- **[%s]**%s %s", toupper(l$type), hash_part, linkify_issues(l$subject))
      }
      emit("")
    }
    if (length(cl_lessons) > 0L) {
      emit("### From CHANGELOG (failed approaches)")
      emit("")
      for (l in cl_lessons) {
        emit("- %s", linkify_issues(l$subject))
      }
      emit("")
    }
  }

  emit("---")
  emit("")

  # ── QA markers ────────────────────────────────────────────────────────────
  emit("<!-- QA:config_digest_generated=%s -->"  , generated_at)
  emit("<!-- QA:config_digest_since=%s -->"       , since)
  emit("<!-- QA:config_digest_total_files=%d -->" , total_files)
  emit("<!-- QA:config_digest_total_added=%d -->" , total_added)
  emit("<!-- QA:config_digest_total_deleted=%d -->", total_deleted)
  emit("<!-- QA:config_digest_n_themes=%d -->"    , length(themes_counts))
  emit("<!-- QA:config_digest_n_lessons=%d -->"   , length(lessons))

  # ── Enhancement 2+3: Breakdown QA markers ─────────────────────────────────
  if (length(themes_counts) > 0L) {
    top3_t  <- head(themes_counts, 3L)
    others  <- max(0L, length(themes_counts) - 3L)
    parts   <- paste(names(top3_t), top3_t, sep = ":")
    if (others > 0L) parts <- c(parts, sprintf("+%d", others))
    emit("<!-- QA:config_digest_themes_breakdown=%s -->", paste(parts, collapse = ","))
  }
  if (length(lessons_brkdown) > 0L) {
    top3_l  <- head(lessons_brkdown, 3L)
    others  <- max(0L, length(lessons_brkdown) - 3L)
    parts   <- paste(names(top3_l), top3_l, sep = ":")
    if (others > 0L) parts <- c(parts, sprintf("+%d", others))
    emit("<!-- QA:config_digest_lessons_breakdown=%s -->", paste(parts, collapse = ","))
  }

  paste(lines, collapse = "\n")
}

# ── Main ──────────────────────────────────────────────────────────────────────

main <- function() {
  since        <- cfg$since
  out_path     <- cfg$out
  dry_run      <- cfg$dry_run
  generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  message(sprintf("config_change_digest.R: repo=%s since=%s", REPO_ROOT, since))

  # Per-category stats
  cat_stats <- lapply(CATEGORIES, compute_category_stats, since = since)

  # Theme clustering (all commits in window, not scoped to category)
  commit_lines   <- git_log_commits(since)
  themes_result  <- cluster_themes(commit_lines, top_n = 5L)

  # Lessons learnt
  lessons_result <- extract_lessons(since)

  # Render
  digest <- render_markdown(cat_stats, themes_result, lessons_result, since, generated_at)

  # Summary to stderr for callers
  total_files   <- sum(sapply(cat_stats, function(s) length(s$files_changed)))
  total_added   <- sum(sapply(cat_stats, function(s) s$n_added))
  total_deleted <- sum(sapply(cat_stats, function(s) s$n_deleted))
  n_themes  <- length(themes_result$all_counts)
  n_lessons <- length(lessons_result$lessons)
  message(sprintf(
    "config_change_digest.R: %d files changed | +%d/-%d lines | %d themes | %d lessons",
    total_files, total_added, total_deleted, n_themes, n_lessons
  ))

  if (dry_run) {
    message("config_change_digest.R: --dry-run — printing to stdout")
    cat(digest, "\n")
    message("config_change_digest.R: dry-run complete")
    return(invisible(NULL))
  }

  dir.create(dirname(out_path), showWarnings = FALSE, recursive = TRUE)
  writeLines(digest, out_path)
  message(sprintf("config_change_digest.R: written to %s", out_path))
  invisible(out_path)
}

main()
