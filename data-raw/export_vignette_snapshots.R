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
refused <- character()

for (nm in vig) {
  obj <- tryCatch(
    targets::tar_read_raw(nm, store = store),
    error = function(e) {
      cli::cli_warn("Could not read target {.val {nm}}: {conditionMessage(e)}")
      NULL
    }
  )

  rds <- file.path(snapdir, paste0(nm, ".rds"))

  ## NULL guard -- the reason this script exists rather than a bare saveRDS
  ## loop. Decision delegated to vig_snapshot_action() (R/vig_snapshot.R) so
  ## it is unit-testable independently of a real _targets store.
  ##
  ## A partial build (only the vig_* targets) or a machine missing an
  ## upstream input -- e.g. `inst/extdata/ccusage_blocks_all.json`, which
  ## every session-efficiency target depends on -- yields NULL for those
  ## targets. Writing that NULL over a committed snapshot that still holds
  ## real data would silently blank a plot on the deployed site, so a NULL
  ## build never overwrites an existing non-NULL snapshot -- it is reported
  ## as skipped instead.
  ##
  ## A brand-new target with no prior snapshot that builds NULL is NEVER
  ## written either, even though that was #879's original relaxation (to
  ## stop check_rds_freshness() reporting "built target with no snapshot"
  ## forever). That relaxation shipped a real defect: the first NULL build of
  ## `vig_codexbar_project_cost_plot` -- caught while its upstream JSON
  ## source was mid-toggle to an empty placeholder, see #877 -- was committed
  ## as-is and rendered a blank chart on the deployed site. The `qa_no_nulls`
  ## gate (`R/tar_plans/plan_qa_gates.R`, #881) now treats ANY NULL vig_*
  ## value, in the store or in a snapshot, as a P0 build-aborting failure --
  ## so there is no longer a legitimate NULL state for this exporter to
  ## accommodate. A NULL build with no protective snapshot is now a refusal:
  ## the script does not write it, and reports it loudly so the missing
  ## upstream input gets fixed instead of silently masked.
  action <- vig_snapshot_action(obj, rds)

  switch(action,
    write = {
      if (!file.exists(rds)) created <- c(created, nm)
      saveRDS(obj, rds)
      written <- c(written, nm)
    },
    skip = {
      skipped <- c(skipped, nm)
    },
    refuse = {
      refused <- c(refused, nm)
    }
  )
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

if (length(refused)) {
  cli::cli_alert_danger(
    "Refused to write {length(refused)} NULL snapshot{?s} -- no protective \\
     non-NULL snapshot exists for {?this target/these targets}."
  )
  cli::cli_ul(refused)
  cli::cli_alert_info(
    "The upstream input for {?this target/these targets} is missing or \\
     empty. Fix the input, re-run tar_make(), then re-run this script."
  )
  cli::cli_abort(c(
    "x" = "{length(refused)} vig_* target{?s} built NULL with no snapshot to protect.",
    "i" = "A NULL snapshot would trip the qa_no_nulls P0 gate (#881).",
    "i" = "Fix the upstream input for: {paste(refused, collapse = ', ')}"
  ))
}
