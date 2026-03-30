#' Targets Plan: Package Context (pkgctx) Cache Management
#'
#' Reusable functions + targets for ctx.yaml cache management.
#' Central cache: ~/docs_gh/proj/data/llm/content/inst/ctx/external/
#'
#' VERSION-STAMPED: Files are named {pkg}@{version}.ctx.yaml so different
#' projects using different nix shells (different package versions) don't
#' overwrite each other's ctx files.
#'
#' Architecture:
#'   - Functions are reusable from ANY project via source()
#'   - Each project resolves versions from its own nix shell
#'   - Targets (plan_pkgctx) run in the llm project for its own DESCRIPTION
#'
#' pkgctx: https://github.com/b-rodrigues/pkgctx
#'   nix run github:b-rodrigues/pkgctx -- r <pkg> --compact > pkg.ctx.yaml
#'   Source-based: downloads and parses source on demand. No installation needed.

# ── Constants ─────────────────────────────────────────────────────────
CTX_CACHE <- file.path(
  Sys.getenv("HOME"),
  "docs_gh/proj/data/llm/content/inst/ctx/external"
)
CTX_MAX_AGE_DAYS <- 30
CTX_CLEANUP_DAYS <- 90  # Delete untouched ctx files older than this

BASE_PKGS <- c(
  "base", "compiler", "datasets", "graphics", "grDevices", "grid",
  "methods", "parallel", "splines", "stats", "stats4", "tcltk",
  "tools", "utils"
)

BIOC_PKGS <- c(
  "AnnotationDbi", "apeglm", "anndataR", "BiocGenerics",
  "DESeq2", "edgeR", "fgsea", "GenomicDataCommons", "GenomicRanges",
  "IRanges", "limma", "msigdbr", "org.Hs.eg.db",
  "S4Vectors", "SingleCellExperiment", "SummarizedExperiment",
  "TCGAbiolinks"
)

GITHUB_PKGS <- c(rix = "github:ropensci/rix")

# ── Naming convention ─────────────────────────────────────────────────

#' Build version-stamped ctx filename
#' @param pkg Package name
#' @param version Package version string
#' @return Filename like "dplyr@1.1.4.ctx.yaml"
ctx_filename <- function(pkg, version) {
  paste0(pkg, "@", version, ".ctx.yaml")
}

#' Get the installed version of a package in this nix shell
#' @return Version string or "unknown" if not installed
get_installed_version <- function(pkg) {
  tryCatch(
    as.character(utils::packageVersion(pkg)),
    error = function(e) "unknown"
  )
}

#' Find any existing ctx file for a package (any version)
#' @return Character vector of matching file paths
find_ctx_files <- function(pkg, cache_dir = CTX_CACHE) {
  pattern <- paste0("^", gsub("\\.", "\\\\.", pkg), "@.*\\.ctx\\.yaml$")
  list.files(cache_dir, pattern = pattern, full.names = TRUE)
}

# ── Reusable functions (callable from any project) ────────────────────

#' Extract Imports + Suggests + Depends from a DESCRIPTION file
extract_deps <- function(desc_path = "DESCRIPTION") {
  if (!file.exists(desc_path)) {
    cli::cli_alert_warning("DESCRIPTION not found: {desc_path}")
    return(character(0))
  }
  desc <- read.dcf(desc_path, fields = c("Imports", "Suggests", "Depends"))
  raw <- paste(na.omit(as.character(desc)), collapse = ",")
  pkgs <- trimws(unlist(strsplit(raw, ",")))
  pkgs <- sub("\\s*\\(.*", "", pkgs)
  pkgs <- pkgs[nzchar(pkgs)]
  pkgs <- setdiff(pkgs, c(BASE_PKGS, "R"))
  sort(unique(pkgs))
}

#' Check ctx cache status for a single package (version-aware)
#' Looks for {pkg}@{installed_version}.ctx.yaml in the cache.
#' @return list with pkg, version, status, ctx_path, age_days
check_ctx_status <- function(pkg, cache_dir = CTX_CACHE) {
  version <- get_installed_version(pkg)

  # If not installed, look for any version in cache
  if (version == "unknown") {
    existing <- find_ctx_files(pkg, cache_dir)
    if (length(existing) > 0) {
      # Use the newest file
      newest <- existing[which.max(file.mtime(existing))]
      age <- as.numeric(difftime(Sys.time(), file.mtime(newest), units = "days"))
      return(list(
        pkg = pkg, version = version, status = "OK_UNVERSIONED",
        ctx_path = newest, age_days = round(age, 1)
      ))
    }
    return(list(
      pkg = pkg, version = version, status = "MISSING",
      ctx_path = NA_character_, age_days = NA_real_
    ))
  }

  # Look for exact version match
  ctx_file <- file.path(cache_dir, ctx_filename(pkg, version))

  if (file.exists(ctx_file)) {
    age <- as.numeric(difftime(Sys.time(), file.mtime(ctx_file), units = "days"))
    stale <- age > CTX_MAX_AGE_DAYS
    return(list(
      pkg = pkg, version = version,
      status = if (stale) "STALE" else "OK",
      ctx_path = ctx_file, age_days = round(age, 1)
    ))
  }

  # No exact match — check for other versions (usable but not exact)
  other_versions <- find_ctx_files(pkg, cache_dir)
  if (length(other_versions) > 0) {
    newest <- other_versions[which.max(file.mtime(other_versions))]
    age <- as.numeric(difftime(Sys.time(), file.mtime(newest), units = "days"))
    return(list(
      pkg = pkg, version = version, status = "OTHER_VERSION",
      ctx_path = newest, age_days = round(age, 1)
    ))
  }

  list(
    pkg = pkg, version = version, status = "MISSING",
    ctx_path = NA_character_, age_days = NA_real_
  )
}

#' Generate version-stamped ctx.yaml for a package
#' pkgctx fetches latest CRAN source, so we generate to a temp file first,
#' read the version from the output, then rename to {pkg}@{version}.ctx.yaml.
#' This way the version stamp always matches the actual ctx content.
#' @param pkg Package name
#' @param version Hint version (used for skip check only; actual version comes from pkgctx output)
#' @return list with pkg, version, status, file
generate_ctx <- function(pkg, version = NULL, cache_dir = CTX_CACHE) {
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)

  # If we know the version, check if it already exists
  if (!is.null(version) && version != "unknown") {
    existing <- file.path(cache_dir, ctx_filename(pkg, version))
    if (file.exists(existing)) {
      age <- as.numeric(difftime(Sys.time(), file.mtime(existing), units = "days"))
      if (age < CTX_MAX_AGE_DAYS) {
        return(list(pkg = pkg, version = version, status = "SKIPPED", file = existing))
      }
    }
  }

  # Determine source prefix
  source <- if (pkg %in% BIOC_PKGS) {
    paste0("bioc:", pkg)
  } else if (pkg %in% names(GITHUB_PKGS)) {
    GITHUB_PKGS[[pkg]]
  } else {
    pkg
  }

  # Generate to temp file first
  tmp_file <- tempfile(fileext = ".ctx.yaml")
  cmd <- sprintf(
    'nix run github:b-rodrigues/pkgctx -- r %s --compact > "%s" 2>/dev/null',
    source, tmp_file
  )

  cli::cli_alert_info("Generating ctx for {.pkg {pkg}}...")
  exit_code <- system(cmd, timeout = 300)

  if (exit_code != 0 || !file.exists(tmp_file) || file.size(tmp_file) < 10) {
    unlink(tmp_file)
    cli::cli_alert_warning("Failed to generate ctx for {.pkg {pkg}}")
    return(list(pkg = pkg, version = version %||% "unknown", status = "FAILED",
                file = NA_character_))
  }

  # Read actual version from pkgctx output
  lines <- readLines(tmp_file, n = 10, warn = FALSE)
  ver_line <- grep("^version:", lines, value = TRUE)
  actual_version <- if (length(ver_line) > 0) {
    trimws(sub("^version:\\s*", "", ver_line[1]))
  } else "unknown"

  # Rename to version-stamped final location
  out_file <- file.path(cache_dir, ctx_filename(pkg, actual_version))
  file.copy(tmp_file, out_file, overwrite = TRUE)
  unlink(tmp_file)

  size_kb <- round(file.size(out_file) / 1024, 1)
  cli::cli_alert_success("Generated {.file {basename(out_file)}} ({size_kb} KB)")
  list(pkg = pkg, version = actual_version, status = "GENERATED", file = out_file)
}

#' Audit ctx cache for a DESCRIPTION file — report only
ctx_audit <- function(desc_path = "DESCRIPTION", cache_dir = CTX_CACHE) {
  deps <- extract_deps(desc_path)
  if (length(deps) == 0) return(tibble::tibble())

  statuses <- lapply(deps, check_ctx_status, cache_dir = cache_dir)
  df <- do.call(rbind, lapply(statuses, function(s) {
    tibble::tibble(
      package = s$pkg, version = s$version, status = s$status,
      ctx_path = s$ctx_path %||% NA_character_,
      age_days = s$age_days %||% NA_real_    )
  }))

  n_ok <- sum(df$status %in% c("OK", "OK_UNVERSIONED"))
  n_other <- sum(df$status == "OTHER_VERSION")
  n_stale <- sum(df$status == "STALE")
  n_missing <- sum(df$status == "MISSING")

  proj_name <- basename(dirname(normalizePath(desc_path, mustWork = FALSE)))
  cli::cli_h3("ctx audit: {proj_name}")
  cli::cli_alert_success("{n_ok} OK")
  if (n_other > 0) cli::cli_alert_info("{n_other} other-version (usable, not exact)")
  if (n_stale > 0) cli::cli_alert_warning("{n_stale} stale (>{CTX_MAX_AGE_DAYS} days)")
  if (n_missing > 0) {
    missing_pkgs <- df$package[df$status == "MISSING"]
    cli::cli_alert_warning("{n_missing} missing: {paste(missing_pkgs, collapse = ', ')}")
  }
  df
}

#' Sync ctx cache — audit + regenerate stale + create missing
ctx_sync <- function(desc_path = "DESCRIPTION", cache_dir = CTX_CACHE,
                     fix_missing = TRUE, fix_stale = TRUE) {
  audit <- ctx_audit(desc_path, cache_dir)
  if (nrow(audit) == 0) return(tibble::tibble())

  needs_work <- audit[!audit$status %in% c("OK", "OK_UNVERSIONED"), , drop = FALSE]
  if (nrow(needs_work) == 0) {
    proj <- basename(dirname(normalizePath(desc_path, mustWork = FALSE)))
    cli::cli_alert_success("All ctx files up-to-date for {proj}")
    return(tibble::tibble(package = character(0), action = character(0),
                      result = character(0)))
  }

  results <- list()

  if (fix_stale) {
    stale <- needs_work[needs_work$status == "STALE", , drop = FALSE]
    for (i in seq_len(nrow(stale))) {
      res <- generate_ctx(stale$package[i], stale$version[i], cache_dir)
      results <- c(results, list(tibble::tibble(
        package = stale$package[i], action = "refresh", result = res$status      )))
    }
  }

  if (fix_missing) {
    missing <- needs_work[needs_work$status == "MISSING", , drop = FALSE]
    for (i in seq_len(nrow(missing))) {
      res <- generate_ctx(missing$package[i], missing$version[i], cache_dir)
      results <- c(results, list(tibble::tibble(
        package = missing$package[i], action = "create", result = res$status      )))
    }
  }

  if (length(results) > 0) do.call(rbind, results)
  else tibble::tibble(package = character(0), action = character(0),
                  result = character(0))
}

#' Clean up old ctx files not touched in CTX_CLEANUP_DAYS
ctx_cleanup <- function(cache_dir = CTX_CACHE, max_age_days = CTX_CLEANUP_DAYS) {
  all_ctx <- list.files(cache_dir, pattern = "\\.ctx\\.yaml$", full.names = TRUE)
  old <- all_ctx[
    as.numeric(difftime(Sys.time(), file.mtime(all_ctx), units = "days")) > max_age_days
  ]
  if (length(old) > 0) {
    cli::cli_alert_info("Cleaning up {length(old)} ctx files older than {max_age_days} days")
    unlink(old)
  }
  invisible(length(old))
}

# ── Targets plan (for llm project) ───────────────────────────────────

plan_pkgctx <- function() {
  list(
    targets::tar_target(
      pkgctx_audit,
      ctx_audit("DESCRIPTION", CTX_CACHE),
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    ),

    targets::tar_target(
      pkgctx_sync,
      {
        needs_work <- pkgctx_audit[
          !pkgctx_audit$status %in% c("OK", "OK_UNVERSIONED"), , drop = FALSE
        ]
        if (nrow(needs_work) == 0) {
          cli::cli_alert_success("All ctx files up-to-date")
          return(tibble::tibble(package = character(0), action = character(0),
                            result = character(0)))
        }
        ctx_sync("DESCRIPTION", CTX_CACHE, fix_missing = TRUE, fix_stale = TRUE)
      },
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    )
  )
}
