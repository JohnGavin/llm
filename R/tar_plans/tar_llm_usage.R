# Targets plan for LLM Usage Tracking
# Uses DuckDB for point-in-time storage of ccusage data

library(targets)
library(tarchetypes)

#' LLM Usage Tracking Targets
#'
#' Creates targets for fetching, storing, and analyzing LLM usage data.
#'
#' @return A list of target objects
#' @export
tar_llm_usage <- function() {
  list(
    # Fetch current usage data from ccusage CLI
    tar_target(
      llm_daily_raw,
      fetch_ccusage_data("daily"),
      cue = tar_cue(mode = "always")
    ),

    tar_target(
      llm_session_raw,
      fetch_ccusage_data("session"),
      cue = tar_cue(mode = "always")
    ),

    tar_target(
      llm_blocks_raw,
      fetch_ccusage_data("blocks"),
      cue = tar_cue(mode = "always")
    ),

    # Store to DuckDB with point-in-time tracking
    tar_target(
      llm_daily_stored,
      store_llm_data(llm_daily_raw, "daily_usage"),
      cue = tar_cue(mode = "always")
    ),

    tar_target(
      llm_session_stored,
      store_llm_data(llm_session_raw, "session_usage"),
      cue = tar_cue(mode = "always")
    ),

    # Generate summary for email
    tar_target(
      llm_daily_summary,
      generate_daily_summary(llm_daily_raw, llm_session_raw)
    )
  )
}

#' Fetch ccusage data from CLI
#'
#' @param type One of "daily", "session", "blocks"
#' @return tibble with usage data
fetch_ccusage_data <- function(type = c("daily", "session", "blocks")) {
  type <- match.arg(type)

  cmd <- sprintf("npx ccusage %s --json --instances", type)
  if (type == "blocks") {
    cmd <- paste(cmd, "--breakdown")
  }

  result <- tryCatch({
    output <- system(cmd, intern = TRUE, ignore.stderr = TRUE)
    jsonlite::fromJSON(paste(output, collapse = "\n"))
  }, error = function(e) {
    message("ccusage command failed: ", e$message)
    NULL
  })

  if (is.null(result)) return(NULL)

  # Parse the data based on type
  if (type == "session") {
    parse_session_data(result)
  } else if (!is.null(result$projects)) {
    parse_projects_data(result)
  } else {
    NULL
  }
}

#' Parse session data from ccusage
parse_session_data <- function(json_data) {
  if (is.null(json_data$sessions)) return(NULL)

  tibble::as_tibble(json_data$sessions) |>
    dplyr::mutate(fetch_timestamp = Sys.time())
}

#' Helper: normalize to character vector (handles NULL, list, character)
normalize_to_char_vec <- function(x) {
  switch(class(x)[1],
    "NULL" = character(0),
    "list" = as.character(unlist(x)),
    as.character(x)
  ) |> (\(v) if (length(v) == 0) character(0) else v)()
}

#' Parse projects data from ccusage
parse_projects_data <- function(json_data) {
  if (is.null(json_data$projects)) return(NULL)

  names(json_data$projects) |>
    purrr::map_dfr(\(proj) {
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
    }) |>
    dplyr::mutate(fetch_timestamp = Sys.time())
}

#' Store LLM data to DuckDB with point-in-time tracking
#'
#' @param data Tibble of usage data
#' @param table_name Name of the DuckDB table
#' @param db_path Path to DuckDB file
#' @return Number of rows appended
store_llm_data <- function(data,
                           table_name,
                           db_path = "inst/extdata/llm_usage.duckdb") {
  if (is.null(data) || nrow(data) == 0) {
    message("No data to store")
    return(0L)
  }

  # Ensure directory exists
  dir.create(dirname(db_path), recursive = TRUE, showWarnings = FALSE)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Flatten list columns for storage
  data_flat <- flatten_list_columns(data)

  # Create or append to table
  if (!DBI::dbExistsTable(con, table_name)) {
    DBI::dbWriteTable(con, table_name, data_flat)
    message(sprintf("Created table '%s' with %d rows", table_name, nrow(data_flat)))
  } else {
    # Check for duplicates before appending
    existing <- DBI::dbGetQuery(
      con,
      sprintf("SELECT DISTINCT date, project FROM %s", table_name)
    )

    if ("date" %in% names(data_flat) && "project" %in% names(data_flat)) {
      new_data <- data_flat |>
        dplyr::anti_join(existing, by = c("date", "project"))

      if (nrow(new_data) > 0) {
        DBI::dbAppendTable(con, table_name, new_data)
        message(sprintf("Appended %d new rows to '%s'", nrow(new_data), table_name))
      } else {
        message(sprintf("No new data to append to '%s'", table_name))
      }
    } else {
      # For session data, always append (use fetch_timestamp for dedup)
      DBI::dbAppendTable(con, table_name, data_flat)
      message(sprintf("Appended %d rows to '%s'", nrow(data_flat), table_name))
    }
  }

  nrow(data_flat)
}

#' Flatten list columns for DuckDB storage
flatten_list_columns <- function(data) {
  list_cols <- names(data)[sapply(data, is.list)]

  for (col in list_cols) {
    if (col == "modelBreakdowns") {
      # Convert model breakdowns to JSON string
      data[[col]] <- sapply(data[[col]], function(x) {
        if (is.null(x) || length(x) == 0) return(NA_character_)
        jsonlite::toJSON(x, auto_unbox = TRUE)
      })
    } else if (col == "modelsUsed") {
      # Convert to comma-separated string
      data[[col]] <- sapply(data[[col]], function(x) {
        if (is.null(x) || length(x) == 0) return(NA_character_)
        paste(x, collapse = ",")
      })
    } else {
      # Default: convert to JSON
      data[[col]] <- sapply(data[[col]], function(x) {
        if (is.null(x) || length(x) == 0) return(NA_character_)
        jsonlite::toJSON(x, auto_unbox = TRUE)
      })
    }
  }

  data
}

#' Generate daily summary for email report
#'
#' @param daily_data Daily usage data
#' @param session_data Session usage data
#' @return List with summary statistics
generate_daily_summary <- function(daily_data, session_data) {
  list(
    date = Sys.Date(),
    daily_stats = if (!is.null(daily_data) && nrow(daily_data) > 0) {
      list(
        total_cost = sum(daily_data$totalCost, na.rm = TRUE),
        total_tokens = sum(daily_data$totalTokens, na.rm = TRUE),
        n_projects = dplyr::n_distinct(daily_data$project),
        date_range = c(min(daily_data$date), max(daily_data$date))
      )
    },
    session_stats = if (!is.null(session_data) && nrow(session_data) > 0) {
      list(
        n_sessions = nrow(session_data),
        total_cost = sum(session_data$totalCost, na.rm = TRUE),
        most_active = session_data |>
          dplyr::arrange(dplyr::desc(totalCost)) |>
          dplyr::slice_head(n = 3) |>
          dplyr::pull(sessionId)
      )
    }
  )
}

#' Query LLM usage from DuckDB
#'
#' @param table_name Table to query
#' @param db_path Path to DuckDB file
#' @param latest_only Return only the most recent fetch
#' @return tibble of usage data
query_llm_usage <- function(table_name = "daily_usage",
                            db_path = "inst/extdata/llm_usage.duckdb",
                            latest_only = FALSE) {
  if (!file.exists(db_path)) {
    message("Database not found: ", db_path)
    return(NULL)
  }

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  if (latest_only) {
    dplyr::tbl(con, table_name) |>
      dplyr::filter(fetch_timestamp == max(fetch_timestamp, na.rm = TRUE)) |>
      dplyr::collect()
  } else {
    dplyr::tbl(con, table_name) |>
      dplyr::collect()
  }
}
