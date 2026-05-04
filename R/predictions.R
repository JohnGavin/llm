#' Cross-Project Prediction Calibration
#'
#' @description
#' Functions for aggregating prediction JSONL files across all projects
#' in `~/.claude/predictions/`. Each project writes its own JSONL file;
#' this module reads them all for a global calibration view.

# ============================================================================
# DISCOVERY
# ============================================================================

#' Discover all project prediction JSONL files
#'
#' Scans `~/.claude/predictions/` for `.jsonl` files and returns
#' metadata about each.
#'
#' @param dir Directory to scan. Defaults to `~/.claude/predictions`.
#' @return Tibble with columns: project_slug, file_path, file_size, modified
#' @export
discover_project_predictions <- function(dir = "~/.claude/predictions") {
  dir <- path.expand(dir)
  if (!dir.exists(dir)) {
    return(tibble::tibble(
      project_slug = character(),
      file_path = character(),
      file_size = double(),
      modified = as.POSIXct(character())
    ))
  }

  files <- list.files(dir, pattern = "\\.jsonl$", full.names = TRUE)
  if (length(files) == 0) {
    return(tibble::tibble(
      project_slug = character(),
      file_path = character(),
      file_size = double(),
      modified = as.POSIXct(character())
    ))
  }

  info <- file.info(files)
  tibble::tibble(
    project_slug = tools::file_path_sans_ext(basename(files)),
    file_path = files,
    file_size = info$size,
    modified = info$mtime
  )
}

# ============================================================================
# LOADING
# ============================================================================

#' Load and reconcile all predictions across projects
#'
#' Reads every JSONL file in the predictions directory and returns
#' a single reconciled tibble.
#'
#' @param dir Directory to scan. Defaults to `~/.claude/predictions`.
#' @return Tibble of all predictions across all projects
#' @export
load_all_predictions <- function(dir = "~/.claude/predictions") {
  dir <- path.expand(dir)
  empty <- tibble::tibble(
    prediction_id = character(),
    recorded_at = character(),
    project_slug = character(),
    project_name = character(),
    task_type = character(),
    task_description = character(),
    approach_summary = character(),
    p_success = double(),
    confidence_bucket = character(),
    outcome = logical(),
    outcome_recorded_at = character(),
    outcome_notes = character()
  )

  if (!dir.exists(dir)) return(empty)

  files <- list.files(dir, pattern = "\\.jsonl$", full.names = TRUE)
  if (length(files) == 0) return(empty)

  all_preds <- lapply(files, function(f) {
    lines <- readLines(f, warn = FALSE)
    lines <- lines[nzchar(trimws(lines))]
    if (length(lines) == 0) return(empty)

    parsed <- lapply(lines, function(line) {
      tryCatch(jsonlite::fromJSON(line), error = function(e) NULL)
    })
    parsed <- Filter(Negate(is.null), parsed)
    if (length(parsed) == 0) return(empty)

    raw <- dplyr::bind_rows(parsed)

    # Ensure columns
    for (col in names(empty)) {
      if (!col %in% names(raw)) raw[[col]] <- NA
    }

    # Reconcile duplicates
    raw |>
      dplyr::arrange(recorded_at) |>
      dplyr::group_by(prediction_id) |>
      dplyr::summarise(
        recorded_at = dplyr::first(recorded_at),
        project_slug = dplyr::first(project_slug),
        project_name = dplyr::first(project_name),
        task_type = dplyr::first(task_type),
        task_description = dplyr::first(task_description),
        approach_summary = dplyr::first(approach_summary),
        p_success = dplyr::first(p_success),
        confidence_bucket = dplyr::first(confidence_bucket),
        outcome = dplyr::last(stats::na.omit(outcome)),
        outcome_recorded_at = dplyr::last(stats::na.omit(outcome_recorded_at)),
        outcome_notes = dplyr::last(stats::na.omit(outcome_notes)),
        .groups = "drop"
      )
  })

  dplyr::bind_rows(all_preds)
}

# ============================================================================
# DUCKDB STORAGE
# ============================================================================

#' Store cross-project predictions to DuckDB
#'
#' Full replace into `predictions_all_projects` table in the llm usage DB.
#'
#' @param predictions Tibble from `load_all_predictions()`
#' @param db_path Path to DuckDB file
#' @return Invisible row count
#' @noRd
# jarl-ignore unused_function: internal helper, wired in future calibration targets
store_cross_project_predictions <- function(predictions, db_path) {
  if (is.null(predictions) || nrow(predictions) == 0) return(invisible(0L))

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  if (DBI::dbExistsTable(con, "predictions_all_projects")) {
    DBI::dbRemoveTable(con, "predictions_all_projects")
  }
  DBI::dbWriteTable(con, "predictions_all_projects", predictions)

  invisible(nrow(predictions))
}

# ============================================================================
# CALIBRATION (reused from per-project pattern)
# ============================================================================

#' Compute calibration metrics
#'
#' Same algorithm as irishbuoys but available in the llm package
#' for cross-project aggregation.
#'
#' @param predictions Tibble with p_success and outcome columns
#' @return List with brier_score, accuracy, calibration_by_bucket,
#'   rolling_brier, n_total, n_resolved
#' @noRd
# jarl-ignore unused_function: internal helper, wired in future calibration targets
compute_calibration_metrics <- function(predictions) {
  empty_result <- list(
    brier_score = NA_real_,
    accuracy = NA_real_,
    calibration_by_bucket = tibble::tibble(
      confidence_bucket = character(),
      n = integer(),
      mean_predicted = double(),
      mean_observed = double(),
      gap = double()
    ),
    rolling_brier = tibble::tibble(
      prediction_id = character(),
      recorded_at = character(),
      cumulative_brier = double()
    ),
    n_total = 0L,
    n_resolved = 0L
  )

  if (is.null(predictions) || nrow(predictions) == 0) return(empty_result)

  n_total <- nrow(predictions)
  resolved <- predictions |> dplyr::filter(!is.na(outcome))
  n_resolved <- nrow(resolved)
  if (n_resolved == 0) {
    empty_result$n_total <- n_total
    return(empty_result)
  }

  resolved <- resolved |>
    dplyr::mutate(outcome_binary = dplyr::if_else(outcome, 1, 0))

  brier_score <- mean((resolved$p_success - resolved$outcome_binary)^2)
  accuracy <- mean((resolved$p_success >= 0.5) == (resolved$outcome_binary == 1))

  calibration_by_bucket <- resolved |>
    dplyr::mutate(
      confidence_bucket = dplyr::case_when(
        p_success < 0.40 ~ "low",
        p_success <= 0.70 ~ "medium",
        TRUE ~ "high"
      )
    ) |>
    dplyr::group_by(confidence_bucket) |>
    dplyr::summarise(
      n = dplyr::n(),
      mean_predicted = mean(p_success),
      mean_observed = mean(outcome_binary),
      gap = mean(p_success) - mean(outcome_binary),
      .groups = "drop"
    )

  rolling_brier <- resolved |>
    dplyr::arrange(recorded_at) |>
    dplyr::mutate(
      sq_error = (p_success - outcome_binary)^2,
      cumulative_brier = cumsum(sq_error) / dplyr::row_number()
    ) |>
    dplyr::select(prediction_id, recorded_at, cumulative_brier)

  list(
    brier_score = brier_score,
    accuracy = accuracy,
    calibration_by_bucket = calibration_by_bucket,
    rolling_brier = rolling_brier,
    n_total = n_total,
    n_resolved = n_resolved
  )
}
