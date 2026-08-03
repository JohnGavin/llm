#' Decide what `export_vignette_snapshots.R` should do with a `vig_*` value
#'
#' Extracted from `data-raw/export_vignette_snapshots.R` so the exporter's
#' write/skip/refuse decision can be unit-tested independently of a real
#' `_targets` store.
#'
#' The decision matters because the deployed vignettes read the committed
#' `inst/extdata/vignettes/vig_*.rds` snapshots (via `safe_tar_read()`), not
#' the live pipeline. Writing `NULL` into a snapshot silently blanks a chart
#' on the deployed site, and the new `qa_no_nulls` gate
#' (`R/tar_plans/plan_qa_gates.R`, `check_no_nulls()`) treats ANY `NULL`
#' `vig_*` value — in the `_targets` store or in a committed snapshot — as a
#' P0 build-aborting failure. That gate is what makes `"refuse"` the correct
#' default below.
#'
#' History: #879 relaxed the exporter's original guard so a brand-new
#' target with no prior snapshot would still get a first snapshot written,
#' even when that first build was `NULL` — the justification being that
#' `check_rds_freshness()` would otherwise report "built target with no
#' snapshot" forever, with no way to clear it. That relaxation shipped a
#' real defect: `vig_codexbar_project_cost_plot.rds` was committed as
#' `NULL` because the exporter happened to run during an empty moment in its
#' upstream JSON source, and that chart rendered blank on the deployed site
#' (#877). Once `qa_no_nulls` exists (#881), a `NULL` `vig_*` value is no
#' longer a state the pipeline may pass through silently — it is always a
#' P0 failure to be fixed at the source, never accommodated by writing a
#' placeholder snapshot. This function therefore never returns an action
#' that results in a `NULL` snapshot being written, under any circumstance.
#'
#' @param obj The target's freshly-built value, as read via
#'   `targets::tar_read_raw()`. May be `NULL`.
#' @param rds_path Character(1). Path to the target's committed `.rds`
#'   snapshot file (whether or not it currently exists).
#' @return A character scalar, one of:
#'   - `"write"` — `obj` is non-`NULL`. The caller should `saveRDS(obj,
#'     rds_path)`.
#'   - `"skip"` — `obj` is `NULL`, but a snapshot already exists at
#'     `rds_path` and holds a non-`NULL` value. The existing committed data
#'     is protected from being overwritten by this machine's incomplete
#'     build; the caller should report the target as skipped, not write.
#'   - `"refuse"` — `obj` is `NULL`, and either no snapshot exists yet at
#'     `rds_path`, or the existing snapshot is itself `NULL`. There is no
#'     non-`NULL` value anywhere to protect or to write. The caller MUST
#'     NOT write `NULL` to `rds_path`; this is a pipeline defect (a missing
#'     or empty upstream input) that must be fixed at the source and
#'     re-exported once the target builds a real value.
#' @keywords internal
vig_snapshot_action <- function(obj, rds_path) {
  if (!is.null(obj)) {
    return("write")
  }

  if (file.exists(rds_path) && !is.null(readRDS(rds_path))) {
    return("skip")
  }

  "refuse"
}

#' Repair absolute nix-store paths in a htmlwidget's `html_dependency` list
#'
#' `DT::datatable()` (and other htmlwidgets) record their JS/CSS assets as an
#' **absolute** filesystem path in each `htmltools::htmlDependency()`'s
#' `src$file`. `saveRDS()` preserves that path verbatim into the committed
#' `inst/extdata/vignettes/*.rds` snapshot, so the path baked in is whichever
#' machine last ran `export_vignette_snapshots.R` — typically a
#' `/nix/store/<hash>-r-<pkg>-<version>/library/<PKG>/...` path on the
#' snapshot author's laptop. CI installs the same package fresh from Posit
#' Package Manager at a different path, so `quarto render` fails with
#' `path for html_dependency not found` (#883).
#'
#' Regenerating the snapshot does not fix this — it only re-acquires
#' whichever path the exporting machine happens to have. Instead, repair the
#' path at *read* time: for each dependency whose recorded `src$file` does
#' not exist on the current machine, re-resolve it via [system.file()] using
#' the trailing `library/<PKG>/<rest>` portion of the recorded path. This
#' makes the object portable across machines without ever touching the
#' committed `.rds` file.
#'
#' @param obj Any R object. Non-htmlwidgets (or htmlwidgets with no
#'   `dependencies`) are returned unchanged.
#' @return `obj`, with any resolvable absolute dependency paths repaired.
#'   Dependencies that already resolve on this machine — including
#'   package-relative ones (`dep$package` set) — are left untouched, so this
#'   is a no-op on the machine that exported the snapshot. A dependency whose
#'   package cannot be resolved via `system.file()` is left at its original
#'   (broken) path, so the failure stays visible rather than becoming a
#'   silently-missing widget asset.
#' @keywords internal
#' @export
repair_widget_deps <- function(obj) {
  if (!inherits(obj, "htmlwidget") || is.null(obj$dependencies)) {
    return(obj)
  }

  obj$dependencies <- lapply(obj$dependencies, function(dep) {
    if (!is.null(dep$package)) return(dep)

    file <- dep$src$file
    if (is.null(file) || !nzchar(file)) return(dep)
    if (file.exists(file) || dir.exists(file)) return(dep)

    m <- regmatches(file, regexec("/library/([^/]+)/(.*)$", file))[[1]]
    if (length(m) != 3L) return(dep)

    pkg <- m[2]
    rest <- m[3]
    resolved <- system.file(rest, package = pkg)
    if (nzchar(resolved)) {
      dep$src$file <- resolved
    }
    dep
  })

  obj
}
