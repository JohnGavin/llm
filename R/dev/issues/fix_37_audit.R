# fix_37_audit.R
# Cross-project audit for missing data handling anti-patterns
# Issue: https://github.com/johngavin/llm/issues/37
#
# Usage: Rscript R/dev/issues/fix_37_audit.R
# Scans ~/docs_gh/*/R/ for:
#   1. suppressWarnings(as.*) — silent type coercion
#   2. read.csv() without na.strings
#   3. Bare NA in tibble/data.frame construction (should use typed NA_*)

library(tibble)

base_dir <- path.expand("~/docs_gh")

# Get all sibling project directories that have R/ folders
project_dirs <- list.dirs(base_dir, recursive = FALSE)
r_dirs <- file.path(project_dirs, "R")
r_dirs <- r_dirs[dir.exists(r_dirs)]

cat("Scanning", length(r_dirs), "project R/ directories\n\n")

scan_files <- function(dirs) {
  unlist(lapply(dirs, function(d) {
    list.files(d, pattern = "\\.R$", recursive = TRUE, full.names = TRUE)
  }))
}

r_files <- scan_files(r_dirs)
cat("Found", length(r_files), "R files\n\n")

# --- Pattern 1: suppressWarnings(as.*) ---
find_suppress_as <- function(files) {
  results <- lapply(files, function(f) {
    lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    hits <- grep("suppressWarnings\\(as\\.", lines)
    if (length(hits) > 0L) {
      tibble(
        file = f,
        line = hits,
        code = trimws(lines[hits]),
        pattern = "suppressWarnings(as.*)"
      )
    }
  })
  do.call(rbind, Filter(Negate(is.null), results))
}

# --- Pattern 2: read.csv() without na.strings ---
find_bare_read_csv <- function(files) {
  results <- lapply(files, function(f) {
    lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    csv_hits <- grep("read\\.csv\\(", lines)
    if (length(csv_hits) > 0L) {
      # Keep only lines without na.strings or na =
      bare <- csv_hits[!grepl("na\\.strings|na\\s*=", lines[csv_hits])]
      if (length(bare) > 0L) {
        tibble(
          file = f,
          line = bare,
          code = trimws(lines[bare]),
          pattern = "read.csv() without na.strings"
        )
      }
    }
  })
  do.call(rbind, Filter(Negate(is.null), results))
}

# --- Pattern 3: Bare NA in tibble/data.frame construction ---
find_bare_na <- function(files) {
  results <- lapply(files, function(f) {
    lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    # Lines with tibble( or data.frame( context AND bare NA
    # Look for c(..., NA, ...) where NA is not NA_integer_ etc.
    context_lines <- grep("(tibble|data\\.frame|tribble)\\(", lines)
    if (length(context_lines) == 0L) return(NULL)

    # Check surrounding lines (within 10 lines of construction)
    check_range <- unique(unlist(lapply(context_lines, function(l) {
      seq(max(1L, l), min(length(lines), l + 10L))
    })))

    # Find bare NA (not NA_integer_, NA_real_, NA_character_, NA_complex_)
    bare_na_pattern <- "\\bNA\\b(?!_integer_|_real_|_character_|_complex_|_Date_)"
    hits <- check_range[grepl(bare_na_pattern, lines[check_range], perl = TRUE)]

    # Filter out comment-only lines and is.na() calls
    if (length(hits) > 0L) {
      hits <- hits[!grepl("^\\s*#", lines[hits])]
      hits <- hits[!grepl("is\\.na\\(|na\\.rm|na\\.strings|na\\s*=", lines[hits])]
    }

    if (length(hits) > 0L) {
      tibble(
        file = f,
        line = hits,
        code = trimws(lines[hits]),
        pattern = "bare NA in data construction"
      )
    }
  })
  do.call(rbind, Filter(Negate(is.null), results))
}

# Run all checks
cat("=== Pattern 1: suppressWarnings(as.*) ===\n")
p1 <- find_suppress_as(r_files)
if (is.null(p1) || nrow(p1) == 0L) {
  cat("No hits found.\n\n")
  p1 <- tibble(file = character(), line = integer(), code = character(), pattern = character())
} else {
  p1$file <- sub(base_dir, "~", p1$file, fixed = TRUE)
  print(p1, n = Inf)
  cat("\n")
}

cat("=== Pattern 2: read.csv() without na.strings ===\n")
p2 <- find_bare_read_csv(r_files)
if (is.null(p2) || nrow(p2) == 0L) {
  cat("No hits found.\n\n")
  p2 <- tibble(file = character(), line = integer(), code = character(), pattern = character())
} else {
  p2$file <- sub(base_dir, "~", p2$file, fixed = TRUE)
  print(p2, n = Inf)
  cat("\n")
}

cat("=== Pattern 3: Bare NA in data construction ===\n")
p3 <- find_bare_na(r_files)
if (is.null(p3) || nrow(p3) == 0L) {
  cat("No hits found.\n\n")
  p3 <- tibble(file = character(), line = integer(), code = character(), pattern = character())
} else {
  p3$file <- sub(base_dir, "~", p3$file, fixed = TRUE)
  print(p3, n = Inf)
  cat("\n")
}

# Combined summary
all_findings <- rbind(p1, p2, p3)
cat("=== Summary ===\n")
cat("Total findings:", nrow(all_findings), "\n")
if (nrow(all_findings) > 0L) {
  cat("\nBy pattern:\n")
  print(table(all_findings$pattern))
  cat("\nBy project:\n")
  projects <- sub("^(~/[^/]+/[^/]+)/.*", "\\1", all_findings$file)
  print(table(projects))
}
