#' Targets Plan: Package Context (pkgctx) Cache Management
#'
#' Detects stale and missing .ctx.yaml files for all DESCRIPTION dependencies.
#' Regenerates via `nix run github:b-rodrigues/pkgctx` when needed.
#'
#' Central cache: ~/docs_gh/proj/data/llm/content/inst/ctx/external/
#' See ctx-yaml-cache rule and llm-package-context skill.

# ── Constants ─────────────────────────────────────────────────────────
CTX_CACHE <- file.path(
  Sys.getenv("HOME"),
  "docs_gh/proj/data/llm/content/inst/ctx/external"
)
CTX_MAX_AGE_DAYS <- 30
# Base R packages — never generate ctx for these
BASE_PKGS <- c(
  "base", "compiler", "datasets", "graphics", "grDevices", "grid",
  "methods", "parallel", "splines", "stats", "stats4", "tcltk",
  "tools", "utils"
)

# ── Helper functions ──────────────────────────────────────────────────

#' Extract Imports + Suggests from DESCRIPTION
extract_deps <- function(desc_path = "DESCRIPTION") {
  if (!file.exists(desc_path)) return(character(0))
  desc <- read.dcf(desc_path, fields = c("Imports", "Suggests", "Depends"))
  raw <- paste(na.omit(as.character(desc)), collapse = ",")
  pkgs <- trimws(unlist(strsplit(raw, ",")))
  pkgs <- sub("\\s*\\(.*", "", pkgs)  # Remove version constraints
  pkgs <- pkgs[nzchar(pkgs)]
  pkgs <- setdiff(pkgs, c(BASE_PKGS, "R"))
  sort(unique(pkgs))
}

#' Check ctx cache status for a package
#' Returns: list(pkg, status, ctx_path, ctx_version, installed_version, age_days)
check_ctx_status <- function(pkg, cache_dir = CTX_CACHE) {
  ctx_file <- file.path(cache_dir, paste0(pkg, ".ctx.yaml"))

  if (!file.exists(ctx_file)) {
    return(list(
      pkg = pkg, status = "MISSING", ctx_path = ctx_file,
      ctx_version = NA, installed_version = NA, age_days = NA
    ))
  }

  # Age check
  mtime <- file.mtime(ctx_file)
  age_days <- as.numeric(difftime(Sys.time(), mtime, units = "days"))

  # Version check
  ctx_lines <- readLines(ctx_file, n = 10, warn = FALSE)
  ctx_ver_line <- grep("^version:", ctx_lines, value = TRUE)
  ctx_version <- if (length(ctx_ver_line) > 0) {
    trimws(sub("^version:\\s*", "", ctx_ver_line[1]))
  } else {
    "unknown"
  }

  inst_version <- tryCatch(
    as.character(utils::packageVersion(pkg)),
    error = function(e) "not installed"
  )

  stale <- age_days > CTX_MAX_AGE_DAYS
  version_mismatch <- inst_version != "not installed" &&
    ctx_version != "unknown" &&
    ctx_version != inst_version

  status <- if (version_mismatch) {
    "VERSION_MISMATCH"
  } else if (stale) {
    "STALE"
  } else {
    "OK"
  }

  list(
    pkg = pkg, status = status, ctx_path = ctx_file,
    ctx_version = ctx_version, installed_version = inst_version,
    age_days = round(age_days, 1)
  )
}

#' Generate ctx.yaml for a package using nix run pkgctx
generate_ctx <- function(pkg, cache_dir = CTX_CACHE) {
  out_file <- file.path(cache_dir, paste0(pkg, ".ctx.yaml"))
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)

  # Determine source prefix for special packages
  source <- if (pkg %in% c(
    "TCGAbiolinks", "GenomicDataCommons", "SummarizedExperiment",
    "DESeq2", "edgeR", "limma", "fgsea", "apeglm",
    "S4Vectors", "SingleCellExperiment", "AnnotationDbi",
    "org.Hs.eg.db", "GenomicRanges", "msigdbr", "anndataR"
  )) {
    paste0("bioc:", pkg)
  } else if (pkg %in% c("rix")) {
    "github:ropensci/rix"
  } else {
    pkg
  }

  cmd <- sprintf(
    'nix run github:b-rodrigues/pkgctx -- r %s --compact > "%s" 2>/dev/null',
    source, out_file
  )

  cli::cli_alert_info("Generating ctx for {pkg}...")
  exit_code <- system(cmd, timeout = 120)

  if (exit_code != 0 || !file.exists(out_file) || file.size(out_file) < 10) {
    # Clean up failed generation
    unlink(out_file)
    cli::cli_alert_warning("Failed to generate ctx for {pkg}")
    return(list(pkg = pkg, status = "FAILED", file = out_file))
  }

  cli::cli_alert_success("Generated {basename(out_file)} ({round(file.size(out_file)/1024, 1)} KB)")
  list(pkg = pkg, status = "GENERATED", file = out_file)
}

# ── Targets plan ──────────────────────────────────────────────────────

plan_pkgctx <- function() {
  list(
    # 1. Extract all dependencies from DESCRIPTION
    targets::tar_target(
      pkgctx_deps,
      extract_deps("DESCRIPTION"),
      cue = targets::tar_cue(mode = "always")
    ),

    # 2. Audit cache: check status of every dependency
    targets::tar_target(
      pkgctx_audit,
      {
        statuses <- lapply(pkgctx_deps, check_ctx_status, cache_dir = CTX_CACHE)
        df <- do.call(rbind, lapply(statuses, function(s) {
          data.frame(
            package = s$pkg,
            status = s$status,
            ctx_version = as.character(s$ctx_version %||% NA),
            installed_version = as.character(s$installed_version %||% NA),
            age_days = s$age_days %||% NA_real_,
            stringsAsFactors = FALSE
          )
        }))

        n_ok <- sum(df$status == "OK")
        n_stale <- sum(df$status == "STALE")
        n_mismatch <- sum(df$status == "VERSION_MISMATCH")
        n_missing <- sum(df$status == "MISSING")

        cli::cli_h2("pkgctx Cache Audit")
        cli::cli_alert_success("{n_ok} up-to-date")
        if (n_stale > 0) cli::cli_alert_warning("{n_stale} stale (>{CTX_MAX_AGE_DAYS} days)")
        if (n_mismatch > 0) cli::cli_alert_danger("{n_mismatch} version mismatch")
        if (n_missing > 0) cli::cli_alert_warning("{n_missing} missing")

        df
      },
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    ),

    # 3. Regenerate stale/mismatched ctx files (not missing — those need explicit approval)
    targets::tar_target(
      pkgctx_refresh_stale,
      {
        needs_refresh <- pkgctx_audit[
          pkgctx_audit$status %in% c("STALE", "VERSION_MISMATCH"), , drop = FALSE
        ]
        if (nrow(needs_refresh) == 0) {
          cli::cli_alert_success("No stale ctx files to refresh")
          return(data.frame(
            package = character(0), result = character(0),
            stringsAsFactors = FALSE
          ))
        }

        cli::cli_alert_info("Refreshing {nrow(needs_refresh)} stale ctx file(s)...")
        results <- lapply(needs_refresh$package, function(pkg) {
          res <- generate_ctx(pkg, cache_dir = CTX_CACHE)
          data.frame(package = pkg, result = res$status, stringsAsFactors = FALSE)
        })
        do.call(rbind, results)
      },
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    ),

    # 4. Report missing packages (informational — does NOT auto-generate)
    targets::tar_target(
      pkgctx_missing_report,
      {
        missing <- pkgctx_audit[pkgctx_audit$status == "MISSING", , drop = FALSE]
        if (nrow(missing) == 0) {
          cli::cli_alert_success("All dependencies have ctx files")
          return(character(0))
        }

        cli::cli_alert_warning(
          "Missing ctx for {nrow(missing)} package(s): {paste(missing$package, collapse = ', ')}"
        )
        cli::cli_alert_info(
          "Generate with: targets::tar_make(names = 'pkgctx_generate_missing')"
        )
        missing$package
      },
      packages = c("cli"),
      cue = targets::tar_cue(mode = "always")
    ),

    # 5. Generate missing ctx files (opt-in — run explicitly when ready)
    targets::tar_target(
      pkgctx_generate_missing,
      {
        missing_pkgs <- pkgctx_missing_report
        if (length(missing_pkgs) == 0) {
          cli::cli_alert_success("Nothing to generate")
          return(data.frame(
            package = character(0), result = character(0),
            stringsAsFactors = FALSE
          ))
        }

        cli::cli_alert_info("Generating ctx for {length(missing_pkgs)} missing package(s)...")
        cli::cli_alert_info("This may take 30-60s per package (nix build).")

        results <- lapply(missing_pkgs, function(pkg) {
          res <- generate_ctx(pkg, cache_dir = CTX_CACHE)
          data.frame(package = pkg, result = res$status, stringsAsFactors = FALSE)
        })
        do.call(rbind, results)
      },
      packages = c("cli"),
      # Never runs automatically — must be explicitly requested
      cue = targets::tar_cue(mode = "never")
    )
  )
}
