#' Check the irishbuoys pipeline-walkthrough plan-file list against reality
#'
#' @description
#' `vig_cr_pipeline_walkthrough` in `plan_vignette_closeread.R` hand-types a
#' `plan` column listing irishbuoys' `R/tar_plans/*.R` files, alongside
#' curated `layer`/`software`/`description` documentation prose that cannot
#' be purely parsed from those files. This function validates the
#' mechanically-derivable `plan` column against what actually exists in a
#' real irishbuoys checkout today, so a plan file renamed, added, or removed
#' there is caught instead of the documentation silently drifting out of
#' sync (llm#793 item 1, llm#792 F1 — bounded: only the `plan` column is
#' checked; `layer`/`software`/`description` remain a curated lookup, the
#' same pattern as the cited `maps/gadm_name_fixes.R` exemplar in llm#792).
#'
#' Per the `checks-must-distinguish-unknown` rule, an absent
#' `irishbuoys_plans_dir` (a worktree need not have every sibling project
#' checked out) returns `"INDETERMINATE"` rather than silently reporting a
#' match — an unperformed comparison is not a passed comparison.
#'
#' @param documented_plans Character vector of documented plan file base
#'   names (no `.R` extension), e.g. `vig_cr_pipeline_walkthrough$plan`.
#' @param irishbuoys_plans_dir Path to irishbuoys' `R/tar_plans` directory.
#'
#' @return A list with:
#'   - `status`: one of `"MATCHED"`, `"DRIFTED"`, `"INDETERMINATE"`
#'   - `checked_dir`: the directory that was (or would have been) scanned
#'   - `reason`: `NA_character_` unless `status == "INDETERMINATE"`
#'   - `missing_from_doc`: plan files that exist in irishbuoys but are not
#'     documented here (character(0) unless `status == "DRIFTED"`)
#'   - `stale_in_doc`: documented plan files no longer present in irishbuoys
#'     (character(0) unless `status == "DRIFTED"`)
#'
#' @keywords internal
check_pipeline_walkthrough_drift <- function(documented_plans, irishbuoys_plans_dir) {
  checkmate::assert_character(documented_plans, min.len = 1L, any.missing = FALSE)
  checkmate::assert_string(irishbuoys_plans_dir)

  if (!dir.exists(irishbuoys_plans_dir)) {
    return(list(
      status = "INDETERMINATE",
      checked_dir = irishbuoys_plans_dir,
      reason = "irishbuoys checkout not found — comparison not performed",
      missing_from_doc = character(0L),
      stale_in_doc = character(0L)
    ))
  }

  real_files <- tools::file_path_sans_ext(
    list.files(irishbuoys_plans_dir, pattern = "\\.R$")
  )

  missing_from_doc <- sort(setdiff(real_files, documented_plans))
  stale_in_doc <- sort(setdiff(documented_plans, real_files))

  status <- if (length(missing_from_doc) == 0L && length(stale_in_doc) == 0L) {
    "MATCHED"
  } else {
    "DRIFTED"
  }

  list(
    status = status,
    checked_dir = irishbuoys_plans_dir,
    reason = NA_character_,
    missing_from_doc = missing_from_doc,
    stale_in_doc = stale_in_doc
  )
}

#' Turn a pipeline-walkthrough drift result into loud failure or a quiet note
#'
#' @param drift_result Output of [check_pipeline_walkthrough_drift()].
#'
#' @return Invisibly, `drift_result`, unchanged. Called for its side effect:
#'   `cli::cli_abort()` on `"DRIFTED"` (breaks the build loudly), a single
#'   `cli::cli_inform()` on `"INDETERMINATE"`, nothing on `"MATCHED"`.
#'
#' @keywords internal
abort_on_pipeline_walkthrough_drift <- function(drift_result) {
  checkmate::assert_list(drift_result, names = "named")
  checkmate::assert_choice(drift_result$status, c("MATCHED", "DRIFTED", "INDETERMINATE"))

  if (identical(drift_result$status, "INDETERMINATE")) {
    cli::cli_inform(
      "vig_cr_pipeline_walkthrough drift check: INDETERMINATE — {drift_result$reason} ({drift_result$checked_dir})."
    )
    return(invisible(drift_result))
  }

  if (identical(drift_result$status, "DRIFTED")) {
    cli::cli_abort(c(
      "x" = "vig_cr_pipeline_walkthrough's hardcoded `plan` column has drifted from irishbuoys/R/tar_plans/ (llm#793 item 1).",
      if (length(drift_result$missing_from_doc) > 0L) {
        c("i" = paste0(
          "Present in irishbuoys but not documented here: ",
          paste(drift_result$missing_from_doc, collapse = ", ")
        ))
      },
      if (length(drift_result$stale_in_doc) > 0L) {
        c("i" = paste0(
          "Documented here but no longer present in irishbuoys: ",
          paste(drift_result$stale_in_doc, collapse = ", ")
        ))
      },
      "i" = "Update the plan/layer/software/description vectors in plan_vignette_closeread.R target 6 to match."
    ))
  }

  invisible(drift_result)
}
