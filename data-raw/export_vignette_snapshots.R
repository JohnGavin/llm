## export_vignette_snapshots.R -- reproducible exporter for vig_* RDS snapshots
##
## The telemetry vignettes read their plots/tables via `safe_tar_read()`, which
## on deploy (where there is no `_targets` store) falls back to the committed
## snapshots in `inst/extdata/vignettes/vig_*.rds`. Before this script those
## snapshots were hand-exported (#64) by an ad-hoc loop that lived in no file,
## so a pipeline-source fix (e.g. #859's dark dot-plots and captions) stayed
## invisible on the deployed site until someone remembered to redo it by hand.
##
## Usage, from the package root, inside the project nix shell:
##
##   nix-shell default.nix --run "Rscript data-raw/export_vignette_snapshots.R"
##
## Env vars:
##   VIG_STORE  targets store to read from (default "_targets")
##   VIG_BUILD  "1" to run tar_make() for the vig_* targets first (default "1")
##
## Related: #860 (this exporter), #64 (original hand export), #859 (plot fixes).

suppressMessages(pkgload::load_all(quiet = TRUE))

store   <- Sys.getenv("VIG_STORE", "_targets")
do_build <- !identical(Sys.getenv("VIG_BUILD", "1"), "0")
snapdir <- "inst/extdata/vignettes"

dir.create(snapdir, showWarnings = FALSE, recursive = TRUE)

if (do_build) {
  cli::cli_h1("Building vig_* targets")
  targets::tar_make(names = tidyselect::starts_with("vig_"), store = store)
}

vig <- sort(grep("^vig_", targets::tar_manifest()$name, value = TRUE))
cli::cli_h1("Exporting {length(vig)} vig_* target{?s} to {.path {snapdir}}")

written <- character()
skipped <- character()
created <- character()

for (nm in vig) {
  obj <- tryCatch(
    targets::tar_read_raw(nm, store = store),
    error = function(e) {
      cli::cli_warn("Could not read target {.val {nm}}: {conditionMessage(e)}")
      NULL
    }
  )

  rds <- file.path(snapdir, paste0(nm, ".rds"))

  ## NULL guard -- the reason this script exists rather than a bare saveRDS loop.
  ##
  ## A partial build (only the vig_* targets) or a machine missing an upstream
  ## input -- e.g. `inst/extdata/ccusage_blocks_all.json`, which every
  ## session-efficiency target depends on -- yields NULL for those targets.
  ## Writing that NULL over a committed snapshot that still holds real data
  ## silently blanks a plot on the deployed site. Never overwrite real data
  ## with NULL; report it instead so the missing input can be fixed.
  ##
  ## That protection only applies when a *prior* snapshot exists to protect.
  ## A brand-new target (no snapshot committed yet) that legitimately builds
  ## as NULL -- e.g. an upstream export whose source flips between populated
  ## and an empty `[]` placeholder across cron runs, see JohnGavin/llm#877 --
  ## must still get a snapshot written, or check_rds_freshness() reports it
  ## forever as "built target with no snapshot" with no way to clear.
  if (is.null(obj)) {
    if (file.exists(rds)) {
      if (!is.null(readRDS(rds))) skipped <- c(skipped, nm)
      next
    }
    created <- c(created, nm)
    saveRDS(obj, rds)
    written <- c(written, nm)
    next
  }

  if (!file.exists(rds)) created <- c(created, nm)
  saveRDS(obj, rds)
  written <- c(written, nm)
}

cli::cli_h2("Summary")
cli::cli_alert_success("Wrote {length(written)} snapshot{?s} ({length(created)} new).")

if (length(skipped)) {
  cli::cli_alert_warning(
    "Kept {length(skipped)} existing snapshot{?s}: target built as NULL here, \\
     but the committed snapshot still holds real data."
  )
  cli::cli_ul(skipped)
  cli::cli_alert_info(
    "This machine is missing an upstream input for those targets. Re-run on a \\
     full-data environment to refresh them."
  )
}
