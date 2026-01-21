# LLM Usage Tracking Functions
# Functions for fetching, storing, and analyzing Claude Code usage data

#' Fetch ccusage data from command line
#'
#' @param type One of "daily", "weekly", "session", "blocks"
#' @param project_filter Project name to filter (NULL for all)
#' @return tibble of usage data
#' @export
fetch_ccusage <- function(type = c("daily", "weekly", "session", "blocks"),
                          project_filter = NULL) {
  type <- match.arg(type)

  # Build command
  cmd <- sprintf("npx ccusage %s --json --instances", type)
  if (type == "blocks") {
    cmd <- paste(cmd, "--breakdown")
  }

  # Execute command
  result <- tryCatch({
    output <- system(cmd, intern = TRUE, ignore.stderr = TRUE)
    jsonlite::fromJSON(paste(output, collapse = "\n"))
  }, error = function(e) {
    message("ccusage command not available: ", e$message)
    NULL
  })

  if (is.null(result)) return(NULL)

  # Parse projects data
  parse_ccusage_json(result, project_filter)
}

#' Normalize a value to character vector (helper for modelsUsed)
#'
#' Handles the inconsistent JSON types: NULL, empty array, single string, or array
#' @param x A value that may be NULL, empty, list, or character
#' @return character vector
normalize_to_char_vec <- function(x) {
  switch(
    class(x)[1],
    "NULL" = character(0),
    "list" = as.character(unlist(x)),
    as.character(x)
  ) |>
    (\(v) if (length(v) == 0) character(0) else v)()
}

#' Parse ccusage JSON output
#'
#' @param json_data Parsed JSON from ccusage
#' @param project_filter Project name to filter
#' @return tibble of usage data
parse_ccusage_json <- function(json_data, project_filter = NULL) {
  if (is.null(json_data$projects)) return(NULL)

  projects <- names(json_data$projects) |>
    purrr::keep(~ is.null(project_filter) || grepl(project_filter, .x, fixed = TRUE))

  if (length(projects) == 0) return(NULL)

  # Combine all project data
  # Note: modelsUsed can be string, array, or empty - normalize to list for bind_rows
  purrr::map_dfr(projects, \(proj) {
    proj_data <- json_data$projects[[proj]]
    if (is.null(proj_data) || length(proj_data) == 0) return(NULL)

    tibble::as_tibble(proj_data) |>
      dplyr::mutate(
        project = proj,
        dplyr::across(
          dplyr::any_of("modelsUsed"),
          ~ purrr::map(.x, normalize_to_char_vec)
        )
      )
  })
}

#' Load cached ccusage data from JSON files
#'
#' @param type One of "daily", "session", "blocks"
#' @param project_filter Project name pattern to filter (NULL for all projects)
#' @param cache_dir Directory containing cached JSON files
#' @return tibble of usage data
#' @export
load_cached_ccusage <- function(type = c("daily", "session", "blocks"),
                                 project_filter = NULL,
                                 cache_dir = NULL) {
  type <- match.arg(type)

  # Find cache directory (handle being called from vignettes)
  if (is.null(cache_dir)) {
    # Try multiple locations
    candidates <- c(
      "inst/extdata",
      "../inst/extdata",
      here::here("inst/extdata")
    )
    cache_dir <- Find(dir.exists, candidates)
    if (is.null(cache_dir)) {
      message("Could not find cache directory")
      return(NULL)
    }
  }

  # Find cache file
  cache_file <- file.path(cache_dir, sprintf("ccusage_%s_all.json", type))

  if (!file.exists(cache_file)) {
    message("Cache file not found: ", cache_file)
    return(NULL)
  }

  json_data <- jsonlite::fromJSON(cache_file)

  # Handle session data structure differently
  if (type == "session" && !is.null(json_data$sessions)) {
    result <- tibble::as_tibble(json_data$sessions)
    return(result)
  }

  parse_ccusage_json(json_data, project_filter)
}

#' Get summary statistics for LLM usage
#'
#' @param daily_data Daily usage tibble
#' @return tibble with summary stats
#' @export
summarize_llm_usage <- function(daily_data) {
  if (is.null(daily_data) || nrow(daily_data) == 0) {
    return(tibble::tibble(
      metric = character(),
      value = character()
    ))
  }

  tibble::tibble(
    metric = c(
      "Total Cost (USD)",
      "Total Tokens",
      "Days Active",
      "Date Range",
      "Avg Cost/Day",
      "Avg Tokens/Day"
    ),
    value = c(
      sprintf("$%.2f", sum(daily_data$totalCost, na.rm = TRUE)),
      scales::comma(sum(daily_data$totalTokens, na.rm = TRUE)),
      as.character(dplyr::n_distinct(daily_data$date)),
      sprintf("%s to %s", min(daily_data$date), max(daily_data$date)),
      sprintf("$%.2f", mean(daily_data$totalCost, na.rm = TRUE)),
      scales::comma(round(mean(daily_data$totalTokens, na.rm = TRUE)))
    )
  )
}

#' Get cost breakdown by model
#'
#' @param daily_data Daily usage tibble with modelBreakdowns
#' @return tibble with model costs
#' @export
get_model_breakdown <- function(daily_data) {
  if (is.null(daily_data) || nrow(daily_data) == 0) {
    return(NULL)
  }

  # Extract model breakdowns
  if (!"modelBreakdowns" %in% names(daily_data)) {
    return(NULL)
  }

  purrr::map_dfr(seq_len(nrow(daily_data)), function(i) {
    breakdowns <- daily_data$modelBreakdowns[[i]]
    if (is.null(breakdowns) || length(breakdowns) == 0) return(NULL)

    tibble::as_tibble(breakdowns) |>
      dplyr::mutate(date = daily_data$date[i])
  }) |>
    dplyr::group_by(modelName) |>
    dplyr::summarise(
      total_cost = sum(cost, na.rm = TRUE),
      total_input = sum(inputTokens, na.rm = TRUE),
      total_output = sum(outputTokens, na.rm = TRUE),
      total_cache_creation = sum(cacheCreationTokens, na.rm = TRUE),
      total_cache_read = sum(cacheReadTokens, na.rm = TRUE),
      days_used = dplyr::n_distinct(date),
      .groups = "drop"
    ) |>
    dplyr::arrange(dplyr::desc(total_cost))
}

#' Identify gaps in activity
#'
#' @param daily_data Daily usage tibble
#' @return tibble with gap information
#' @export
find_activity_gaps <- function(daily_data) {
  if (is.null(daily_data) || nrow(daily_data) == 0) {
    return(NULL)
  }

  dates <- sort(unique(as.Date(daily_data$date)))

  if (length(dates) < 2) return(NULL)

  # Find all dates in range
  all_dates <- seq(min(dates), max(dates), by = "day")
  missing_dates <- all_dates[!all_dates %in% dates]

  if (length(missing_dates) == 0) {
    return(tibble::tibble(
      gap_start = as.Date(character()),
      gap_end = as.Date(character()),
      gap_days = integer()
    ))
  }

  # Group consecutive missing dates into gaps
  gaps <- tibble::tibble(date = missing_dates) |>
    dplyr::mutate(
      diff = c(1, diff(date)),
      group = cumsum(diff != 1)
    ) |>
    dplyr::group_by(group) |>
    dplyr::summarise(
      gap_start = min(date),
      gap_end = max(date),
      gap_days = as.integer(gap_end - gap_start + 1),
      .groups = "drop"
    ) |>
    dplyr::select(-group) |>
    dplyr::filter(gap_days >= 1) |>
    dplyr::arrange(dplyr::desc(gap_start))

  gaps
}

#' Append usage data to DuckDB
#'
#' @param data Usage data tibble
#' @param db_path Path to DuckDB file
#' @param table_name Table name
#' @export
append_to_duckdb <- function(data, db_path = "inst/extdata/llm_usage.duckdb",
                              table_name = "daily_usage") {
  if (is.null(data) || nrow(data) == 0) {
    message("No data to append")
    return(invisible(NULL))
  }

  # Ensure directory exists
  dir.create(dirname(db_path), recursive = TRUE, showWarnings = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Add fetch timestamp
  data <- data |>
    dplyr::mutate(fetch_timestamp = Sys.time())

  # Create table if not exists
  if (!DBI::dbExistsTable(con, table_name)) {
    DBI::dbWriteTable(con, table_name, data)
  } else {
    DBI::dbAppendTable(con, table_name, data)
  }

  message(sprintf("Appended %d rows to %s", nrow(data), table_name))
  invisible(data)
}

#' Query latest usage data from DuckDB
#'
#' @param db_path Path to DuckDB file
#' @param table_name Table name
#' @return tibble of latest data
#' @export
query_latest_usage <- function(db_path = "inst/extdata/llm_usage.duckdb",
                                table_name = "daily_usage") {
  if (!file.exists(db_path)) {
    message("Database not found: ", db_path)
    return(NULL)
  }

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  dplyr::tbl(con, table_name) |>
    dplyr::filter(fetch_timestamp == max(fetch_timestamp, na.rm = TRUE)) |>
    dplyr::collect()
}
