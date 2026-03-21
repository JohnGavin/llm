#' Targets Plan: Package Context (pkgctx) Cache Management
#'
#' Reusable functions + targets for ctx.yaml cache management.
#' Central cache: ~/docs_gh/proj/data/llm/content/inst/ctx/external/
#'
#' Architecture:
#'   - Functions (extract_deps, check_ctx_status, generate_ctx, ctx_audit,
#'     ctx_sync) are reusable from ANY project via source()
#'   - Targets (plan_pkgctx) run in the llm project for its own DESCRIPTION
#'   - Other projects call ctx_sync("path/to/DESCRIPTION") directly
#'
#' pkgctx: https://github.com/b-rodrigues/pkgctx
#'   nix run github:b-rodrigues/pkgctx -- r <pkg> --compact > pkg.ctx.yaml
#'   No installation needed. Downloads and parses source on demand.

# ── Constants ─────────────────────────────────────────────────────────
CTX_CACHE <- file.path(
  Sys.getenv("HOME"),
  "docs_gh/proj/data/llm/content/inst/ctx/external"
)
CTX_MAX_AGE_DAYS <- 30

BASE_PKGS <- c(
  "base", "compiler", "datasets", "graphics", "grDevices", "grid",
  "methods", "parallel", "splines", "stats", "stats4", "tcltk",
  "tools", "utils"
)

# Known Bioconductor packages (use bioc: prefix)
BIOC_PKGS <- c(
  "AnnotationDbi", "apeglm", "anndataR", "BiocGenerics",
  "DESeq2", "edgeR", "fgsea", "GenomicDataCommons", "GenomicRanges",
  "IRanges", "limma", "msigdbr", "org.Hs.eg.db",
  "S4Vectors", "SingleCellExperiment", "SummarizedExperiment",
  "TCGAbiolinks"
)

# Known GitHub packages (use github: prefix)
GITHUB_PKGS <- c(rix = "github:ropensci/rix")

# ── Reusable functions (callable from any project) ────────────────────

#' Extract Imports + Suggests + Depends from a DESCRIPTION file
#' @param desc_path Path to DESCRIPTION file
#' @return Character vector of package names (excluding base R)
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

#' Check ctx cache status for a single package
#' @return list with pkg, status, ctx_version, installed_version, age_days
check_ctx_status <- function(pkg, cache_dir = CTX_CACHE) {
  ctx_file <- file.path(cache_dir, paste0(pkg, ".ctx.yaml"))

  if (!file.exists(ctx_file)) {
    return(list(
      pkg = pkg, status = "MISSING", ctx_path = ctx_file,
      ctx_version = NA_character_, installed_version = NA_character_,
      age_days = NA_real_
    ))
  }

  mtime <- file.mtime(ctx_file)
  age_days <- as.numeric(difftime(Sys.time(), mtime, units = "days"))

  ctx_lines <- readLines(ctx_file, n = 10, warn = FALSE)
  ctx_ver_line <- grep("^version:", ctx_lines, value = TRUE)
  ctx_version <- if (length(ctx_ver_line) > 0) {
    trimws(sub("^version:\\s*", "", ctx_ver_line[1]))
  } else "unknown"

  inst_version <- tryCatch(
    as.character(utils::packageVersion(pkg)),
    error = function(e) "not_installed"
  )

  version_mismatch <- inst_version != "not_installed" &&
    ctx_version != "unknown" && ctx_version != inst_version
  stale <- age_days > CTX_MAX_AGE_DAYS

  status <- if (version_mismatch) "VERSION_MISMATCH"
    else if (stale) "STALE"
    else "OK"

  list(
    pkg = pkg, status = status, ctx_path = ctx_file,
    ctx_version = ctx_version, installed_version = inst_version,
    age_days = round(age_days, 1)
  )
}

#' Generate ctx.yaml for a package
#' @param pkg Package name
#' @param cache_dir Central cache directory
#' @return list with pkg, status, file
generate_ctx <- function(pkg, cache_dir = CTX_CACHE) {
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  out_file <- file.path(cache_dir, paste0(pkg, ".ctx.yaml"))

  # Determine source prefix
  source <- if (pkg %in% BIOC_PKGS) {
    paste0("bioc:", pkg)
  } else if (pkg %in% names(GITHUB_PKGS)) {
    GITHUB_PKGS[[pkg]]
  } else {
    pkg
  }

  cmd <- sprintf(
    'nix run github:b-rodrigues/pkgctx -- r %s --compact > "%s" 2>/dev/null',
    source, out_file
  )

  cli::cli_alert_info("Generating ctx for {.pkg {pkg}}...")
  exit_code <- system(cmd, timeout = 300)

  if (exit_code != 0 || !file.exists(out_file) || file.size(out_file) < 10) {
    unlink(out_file)
    cli::cli_alert_warning("Failed to generate ctx for {.pkg {pkg}}")
    return(list(pkg = pkg, status = "FAILED", file = out_file))
  }

  size_kb <- round(file.size(out_file) / 1024, 1)
  cli::cli_alert_success("Generated {.file {basename(out_file)}} ({size_kb} KB)")
  list(pkg = pkg, status = "GENERATED", file = out_file)
}

#' Audit ctx cache for a DESCRIPTION file — report only
#' @param desc_path Path to DESCRIPTION
#' @return data.frame with package, status, ctx_version, installed_version, age_days
ctx_audit <- function(desc_path = "DESCRIPTION", cache_dir = CTX_CACHE) {
  deps <- extract_deps(desc_path)
  if (length(deps) == 0) return(data.frame())

  statuses <- lapply(deps, check_ctx_status, cache_dir = cache_dir)
  df <- do.call(rbind, lapply(statuses, function(s) {
    data.frame(
      package = s$pkg, status = s$status,
      ctx_version = s$ctx_version %||% NA_character_,
      installed_version = s$installed_version %||% NA_character_,
      age_days = s$age_days %||% NA_real_,
      stringsAsFactors = FALSE
    )
  }))

  n_ok <- sum(df$status == "OK")
  n_stale <- sum(df$status == "STALE")
  n_mismatch <- sum(df$status == "VERSION_MISMATCH")
  n_missing <- sum(df$status == "MISSING")

  cli::cli_h3("ctx audit: {basename(dirname(desc_path))}")
  cli::cli_alert_success("{n_ok} OK")
  if (n_stale > 0) cli::cli_alert_warning("{n_stale} stale (>{CTX_MAX_AGE_DAYS} days)")
  if (n_mismatch > 0) cli::cli_alert_danger("{n_mismatch} version mismatch")
  if (n_missing > 0) cli::cli_alert_warning("{n_missing} missing: {paste(df$package[df$status == 'MISSING'], collapse = ', ')}")
  df
}

#' Sync ctx cache for a DESCRIPTION file — audit + regenerate stale + create missing
#' @param desc_path Path to DESCRIPTION
#' @param fix_missing If TRUE, generate ctx for missing packages (default TRUE)
#' @param fix_stale If TRUE, regenerate stale/mismatched ctx (default TRUE)
#' @return data.frame with package, action, result
ctx_sync <- function(desc_path = "DESCRIPTION", cache_dir = CTX_CACHE,
                     fix_missing = TRUE, fix_stale = TRUE) {
  audit <- ctx_audit(desc_path, cache_dir)
  if (nrow(audit) == 0) return(data.frame())

  needs_work <- audit[audit$status != "OK", , drop = FALSE]
  if (nrow(needs_work) == 0) {
    cli::cli_alert_success("All ctx files up-to-date for {basename(dirname(desc_path))}")
    return(data.frame(package = character(0), action = character(0),
                      result = character(0), stringsAsFactors = FALSE))
  }

  results <- list()

  # Fix stale/mismatched
  if (fix_stale) {
    stale <- needs_work[needs_work$status %in% c("STALE", "VERSION_MISMATCH"), , drop = FALSE]
    for (pkg in stale$package) {
      res <- generate_ctx(pkg, cache_dir)
      results <- c(results, list(data.frame(
        package = pkg, action = "refresh", result = res$status,
        stringsAsFactors = FALSE
      )))
    }
  }

  # Fix missing
  if (fix_missing) {
    missing <- needs_work[needs_work$status == "MISSING", , drop = FALSE]
    for (pkg in missing$package) {
      res <- generate_ctx(pkg, cache_dir)
      results <- c(results, list(data.frame(
        package = pkg, action = "create", result = res$status,
        stringsAsFactors = FALSE
      )))
    }
  }

  if (length(results) > 0) do.call(rbind, results)
  else data.frame(package = character(0), action = character(0),
                  result = character(0), stringsAsFactors = FALSE)
}

# ── Targets plan (for llm project) ───────────────────────────────────

plan_pkgctx <- function() {
  list(
    # Audit: fast, always runs, reports status
    targets::tar_target(
      pkgctx_audit,
      ctx_audit("DESCRIPTION", CTX_CACHE),
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    ),

    # Sync: regenerate stale + create missing — runs automatically
    targets::tar_target(
      pkgctx_sync,
      {
        needs_work <- pkgctx_audit[pkgctx_audit$status != "OK", , drop = FALSE]
        if (nrow(needs_work) == 0) {
          cli::cli_alert_success("All ctx files up-to-date")
          return(data.frame(package = character(0), action = character(0),
                            result = character(0), stringsAsFactors = FALSE))
        }
        ctx_sync("DESCRIPTION", CTX_CACHE, fix_missing = TRUE, fix_stale = TRUE)
      },
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    )
  )
}
