#!/usr/bin/env Rscript
# check_vignette_targets.R — Pre-render check for required targets
#
# Usage:
#   Rscript check_vignette_targets.R [qmd_file]
#
# Scans a .qmd file for tar_read/safe_tar_read calls and verifies
# those targets exist in the store. Exits non-zero if any are missing.

args <- commandArgs(trailingOnly = TRUE)
qmd_file <- if (length(args) > 0) args[1] else NULL

# Find required targets from .qmd files
find_required_targets <- function(qmd_path) {

  if (!file.exists(qmd_path)) {
    message("File not found: ", qmd_path)
    return(character(0))
  }

  lines <- readLines(qmd_path, warn = FALSE)
  text <- paste(lines, collapse = "\n")

  # Match tar_read("name"), tar_read(name), safe_tar_read("name"), etc.
  patterns <- c(
    'tar_read\\s*\\(\\s*["\']([^"\']+)["\']',
    'tar_read\\s*\\(\\s*([a-zA-Z_][a-zA-Z0-9_]*)',
    'safe_tar_read\\s*\\(\\s*["\']([^"\']+)["\']',
    'tar_read_raw\\s*\\(\\s*["\']([^"\']+)["\']'
  )

  targets <- character(0)
  for (pat in patterns) {
    matches <- regmatches(text, gregexpr(pat, text, perl = TRUE))[[1]]
    if (length(matches) > 0) {
      extracted <- gsub(pat, "\\1", matches, perl = TRUE)
      targets <- c(targets, extracted)
    }
  }

  unique(targets)
}

# Check which targets exist
check_targets <- function(required, strict = FALSE) {

  if (length(required) == 0) {
    message("No targets referenced in file.")
    return(invisible(TRUE))
  }

  # Try to load targets - fail-closed in strict mode
  if (!requireNamespace("targets", quietly = TRUE)) {
    if (strict) {
      message("ERROR: targets package not available - cannot validate")
      return(invisible(FALSE))
    }
    message("WARN: targets package not available - skipping validation")
    return(invisible(TRUE))
  }

  # Get available targets
  available <- tryCatch({
    meta <- targets::tar_meta(fields = "name")
    if (!is.null(meta)) meta$name else character(0)
  }, error = function(e) character(0))

  missing <- setdiff(required, available)

  if (length(missing) > 0) {
    message("ERROR: Missing targets required for render:")
    for (t in missing) message("  - ", t)
    message("\nRun: tar_make(c('", paste(missing, collapse = "', '"), "'))")
    return(invisible(FALSE))
  }

  message("OK: All ", length(required), " required targets available:")
  for (t in required) message("  + ", t)
  invisible(TRUE)
}

# Main
if (!is.null(qmd_file)) {
  targets <- find_required_targets(qmd_file)
  ok <- check_targets(targets, strict = TRUE)
  if (!ok) quit(status = 1)
} else {
  # Check all .qmd files: prefer vignettes/, fall back to docs/, then repo root
  qmd_files <- list.files("vignettes", pattern = "\\.qmd$", full.names = TRUE)
  if (length(qmd_files) == 0) {
    qmd_files <- list.files("docs", pattern = "\\.qmd$", full.names = TRUE)
  }
  if (length(qmd_files) == 0) {
    qmd_files <- list.files(".", pattern = "\\.qmd$", full.names = TRUE)
  }

  if (length(qmd_files) == 0) {
    message("ERROR: No .qmd files found in vignettes/, docs/, or repo root")
    quit(status = 1)
  }

  message("Found ", length(qmd_files), " .qmd file(s) to check")

  all_ok <- TRUE
  for (f in qmd_files) {
    message("\n=== ", basename(f), " ===")
    targets <- find_required_targets(f)
    ok <- check_targets(targets, strict = TRUE)
    if (!ok) all_ok <- FALSE
  }

  if (!all_ok) quit(status = 1)
}

message("\nPre-render target check passed.")
