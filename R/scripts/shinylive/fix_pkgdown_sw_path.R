# Fix pkgdown Shinylive Service Worker Path Mismatch
#
# CANONICAL LOCATION: /Users/johngavin/docs_gh/llm/scripts/shinylive/fix_pkgdown_sw_path.R
#
# PURPOSE:
# Fixes Issue #15 pattern where pkgdown renders articles to docs/articles/
# but Quarto shinylive extension meta tag points to parent directory (..)
#
# USAGE:
# 1. Symlink this file into your project:
#    ln -s /Users/johngavin/docs_gh/llm/scripts/shinylive/fix_pkgdown_sw_path.R R/dev/
#
# 2. After pkgdown::build_site():
#    source("R/dev/fix_pkgdown_sw_path.R")
#    copy_shinylive_sw_to_root()
#
# ISSUE: https://github.com/posit-dev/shinylive/issues/133
# DOCUMENTED: /Users/johngavin/docs_gh/llm/WIKI_CONTENT/WIKI_SHINYLIVE_LESSONS_LEARNED.md

#' Copy Shinylive Service Worker to site root
#'
#' Fixes pkgdown path mismatch where meta tag points to root
#' but file only exists in articles/ directory
#'
#' @param docs_dir Path to docs directory (default: "docs")
#' @param verbose Print status messages (default: TRUE)
#' @return TRUE if successful, FALSE otherwise
copy_shinylive_sw_to_root <- function(docs_dir = "docs", verbose = TRUE) {
  source_path <- file.path(docs_dir, "articles", "shinylive-sw.js")
  dest_path <- file.path(docs_dir, "shinylive-sw.js")

  # Check if source file exists
  if (!file.exists(source_path)) {
    if (verbose) {
      message("⚠️  Source file not found: ", source_path)
      message("    This is expected if vignettes haven't been built yet.")
    }
    return(FALSE)
  }

  # Copy file
  success <- file.copy(
    from = source_path,
    to = dest_path,
    overwrite = TRUE
  )

  if (success && verbose) {
    message("✅ Copied shinylive-sw.js to site root")
    message("   From: ", source_path)
    message("   To:   ", dest_path)

    # Show file sizes
    source_size <- file.size(source_path)
    dest_size <- file.size(dest_path)
    message("   Size: ", format(source_size, big.mark = ","), " bytes")

    # Verify they match
    if (source_size != dest_size) {
      warning("⚠️  File sizes don't match! Copy may have failed.")
      return(FALSE)
    }
  } else if (!success && verbose) {
    message("❌ Failed to copy shinylive-sw.js")
  }

  return(success)
}

# Don't auto-run when sourced
# Users should explicitly call copy_shinylive_sw_to_root()
