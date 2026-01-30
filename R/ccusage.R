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

#' Display progress bar for LLM usage
#'
#' @title Display Terminal Progress Bar for LLM Usage
#'
#' @description
#' Shows a terminal progress bar with current usage vs limits. The bar includes
#' a visual indicator using Unicode box characters, percentage completion, and
#' formatted values. Colors change based on usage thresholds (green < 75%, yellow
#' 75-89%, red >= 90%).
#'
#' @param current Current usage value (typically cost in USD)
#' @param limit Maximum limit value (upper bound for the progress bar)
#' @param label Character string label for the progress bar (default: "Usage")
#' @param show_tokens Logical whether to show token count on a second line (default: FALSE)
#' @param tokens_current Current token count (required if show_tokens = TRUE)
#' @param tokens_limit Token limit (required if show_tokens = TRUE)
#'
#' @return Invisibly returns the percentage used (numeric 0-100)
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Show basic cost progress bar
#' show_usage_progress(15, 30, label = "Daily Cost")
#'
#' # Show cost and token usage
#' show_usage_progress(
#'   current = 25,
#'   limit = 30,
#'   label = "Daily Usage",
#'   show_tokens = TRUE,
#'   tokens_current = 450000,
#'   tokens_limit = 500000
#' )
#' }
#'
#' @seealso
#' - [show_daily_progress()] for today's complete usage summary
#' - [show_weekly_progress()] for weekly usage tracking
#' - [show_usage_dashboard()] for combined daily/weekly dashboard
#'
#' @keywords internal
show_usage_progress <- function(current, limit, label = "Usage",
                                 show_tokens = FALSE,
                                 tokens_current = NULL,
                                 tokens_limit = NULL) {
  if (!requireNamespace("cli", quietly = TRUE)) {
    message("cli package required for progress bars")
    return(invisible(NULL))
  }

  # Validate inputs
  checkmate::assert_number(current, lower = 0, finite = TRUE)
  checkmate::assert_number(limit, lower = 0.00001, finite = TRUE) # limit must be > 0
  checkmate::assert_string(label)
  checkmate::assert_flag(show_tokens)
  
  if (show_tokens) {
    checkmate::assert_number(tokens_current, lower = 0, finite = TRUE, null.ok = TRUE)
    checkmate::assert_number(tokens_limit, lower = 1, finite = TRUE, null.ok = TRUE)
  }

  # Calculate percentage
  pct <- min(100, round((current / limit) * 100))

  # Determine color based on percentage
  color <- if (pct >= 90) "red" else if (pct >= 75) "yellow" else "green"

  # Create progress bar
  bar_width <- 40
  filled <- round(bar_width * pct / 100)
  empty <- bar_width - filled

  bar <- paste0(
    strrep("\U00002588", filled),  # full block
    strrep("\U00002591", empty)     # light shade
  )

  # Format output with color
  cli::cli_div(theme = list(
    ".pbar" = list(color = color),
    ".label" = list("font-weight" = "bold")
  ))

  cli::cli_text(
    "{.label {label}} {.pbar [{bar}]} {pct}% (${format(current, nsmall=2)} / ${format(limit, nsmall=2)})"
  )

  # Show tokens if requested
  if (show_tokens && !is.null(tokens_current) && !is.null(tokens_limit)) {
    token_pct <- min(100, round((tokens_current / tokens_limit) * 100))
    token_filled <- round(bar_width * token_pct / 100)
    token_empty <- bar_width - token_filled
    token_bar <- paste0(
      strrep("\U00002588", token_filled),  # full block
      strrep("\U00002591", token_empty)     # light shade
    )

    cli::cli_text(
      "Tokens:       [{token_bar}] {token_pct}% ({scales::comma(tokens_current)} / {scales::comma(tokens_limit)})"
    )
  }

  cli::cli_end()

  invisible(pct)
}

#' Display daily usage progress bars
#'
#' @title Show Today's LLM Usage Progress
#'
#' @description
#' Displays progress bars for today's LLM usage against configured daily limits.
#' Shows both cost and token consumption with visual progress bars and color coding.
#' Fetches data from cached ccusage files and calculates statistics for the current day.
#'
#' @param daily_limit Daily cost limit in USD. If NULL, reads from environment variable
#'   `LLM_DAILY_LIMIT` or defaults to 30.
#' @param token_limit Daily token limit. If NULL, reads from environment variable
#'   `LLM_DAILY_TOKEN_LIMIT` or defaults to 500000.
#' @param cache_dir Directory containing cached JSON files. If NULL, searches standard
#'   package cache locations.
#'
#' @return Invisibly returns a list with elements:
#'   - `cost`: Numeric, current daily cost
#'   - `tokens`: Numeric, current daily token usage
#'   - `cost_pct`: Integer, percentage of daily cost limit used
#'   - `token_pct`: Integer, percentage of daily token limit used
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Show today's usage with defaults
#' show_daily_progress()
#'
#' # Show today's usage with custom limits
#' show_daily_progress(daily_limit = 50, token_limit = 750000)
#' }
#'
#' @seealso
#' - [show_usage_progress()] for low-level progress bar display
#' - [show_weekly_progress()] for weekly usage tracking
#' - [show_usage_dashboard()] for combined daily/weekly view
#' - [load_cached_ccusage()] to load underlying data
#'
#' @keywords internal
show_daily_progress <- function(daily_limit = NULL,
                                 token_limit = NULL,
                                 cache_dir = NULL) {
  # Validate inputs
  checkmate::assert_number(daily_limit, lower = 0, null.ok = TRUE)
  checkmate::assert_number(token_limit, lower = 0, null.ok = TRUE)
  if (!is.null(cache_dir)) checkmate::assert_directory_exists(cache_dir)

  # Get limits from environment or defaults
  if (is.null(daily_limit)) {
    daily_limit <- as.numeric(Sys.getenv("LLM_DAILY_LIMIT", "30"))
  }
  if (is.null(token_limit)) {
    token_limit <- as.numeric(Sys.getenv("LLM_DAILY_TOKEN_LIMIT", "500000"))
  }

  # Load today's data
  daily_data <- load_cached_ccusage("daily", cache_dir = cache_dir)

  if (is.null(daily_data) || nrow(daily_data) == 0) {
    cli::cli_alert_warning("No usage data available")
    return(invisible(NULL))
  }

  # Filter to today
  today <- Sys.Date()
  today_data <- daily_data |>
    dplyr::filter(as.Date(date) == today)

  if (nrow(today_data) == 0) {
    # No data for today, show zero usage
    current_cost <- 0
    current_tokens <- 0
  } else {
    current_cost <- sum(today_data$totalCost, na.rm = TRUE)
    current_tokens <- sum(today_data$totalTokens, na.rm = TRUE)
  }

  cli::cli_h2("Today's Usage")

  show_usage_progress(
    current = current_cost,
    limit = daily_limit,
    label = "Today's Usage",
    show_tokens = TRUE,
    tokens_current = current_tokens,
    tokens_limit = token_limit
  )

  invisible(list(
    cost = current_cost,
    tokens = current_tokens,
    cost_pct = round((current_cost / daily_limit) * 100),
    token_pct = round((current_tokens / token_limit) * 100)
  ))
}

#' Display weekly usage progress bar
#'
#' @title Show 7-Day LLM Usage Progress
#'
#' @description
#' Displays a progress bar for the last 7 days of LLM usage against a configured
#' weekly cost limit. Aggregates daily usage data from the past 7 days and shows
#' the cumulative cost with visual progress indication.
#'
#' @param weekly_limit Weekly cost limit in USD. If NULL, reads from environment
#'   variable `LLM_WEEKLY_LIMIT` or defaults to 120.
#' @param cache_dir Directory containing cached JSON files. If NULL, searches standard
#'   package cache locations.
#'
#' @return Invisibly returns a list with elements:
#'   - `cost`: Numeric, total cost for the last 7 days
#'   - `cost_pct`: Integer, percentage of weekly limit used
#'   - `days_with_usage`: Integer, number of days with recorded usage
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Show this week's usage with defaults
#' show_weekly_progress()
#'
#' # Show this week's usage with custom limit
#' show_weekly_progress(weekly_limit = 200)
#' }
#'
#' @seealso
#' - [show_usage_progress()] for low-level progress bar display
#' - [show_daily_progress()] for daily usage tracking
#' - [show_usage_dashboard()] for combined daily/weekly view
#' - [load_cached_ccusage()] to load underlying data
#'
#' @keywords internal
show_weekly_progress <- function(weekly_limit = NULL,
                                  cache_dir = NULL) {
  # Validate inputs
  checkmate::assert_number(weekly_limit, lower = 0, null.ok = TRUE)
  if (!is.null(cache_dir)) checkmate::assert_directory_exists(cache_dir)

  # Get limit from environment or default
  if (is.null(weekly_limit)) {
    weekly_limit <- as.numeric(Sys.getenv("LLM_WEEKLY_LIMIT", "120"))
  }

  # Load daily data
  daily_data <- load_cached_ccusage("daily", cache_dir = cache_dir)

  if (is.null(daily_data) || nrow(daily_data) == 0) {
    cli::cli_alert_warning("No usage data available")
    return(invisible(NULL))
  }

  # Filter to last 7 days
  week_start <- Sys.Date() - 6
  week_data <- daily_data |>
    dplyr::filter(as.Date(date) >= week_start)

  if (nrow(week_data) == 0) {
    current_cost <- 0
  } else {
    current_cost <- sum(week_data$totalCost, na.rm = TRUE)
  }

  cli::cli_h2("This Week")

  show_usage_progress(
    current = current_cost,
    limit = weekly_limit,
    label = "This Week",
    show_tokens = FALSE
  )

  invisible(list(
    cost = current_cost,
    cost_pct = round((current_cost / weekly_limit) * 100),
    days_with_usage = dplyr::n_distinct(week_data$date)
  ))
}

#' Display combined usage dashboard
#'
#' @title Show Complete LLM Usage Dashboard
#'
#' @description
#' Displays a comprehensive usage dashboard combining daily and weekly progress bars,
#' token usage, and Max5 block status (if applicable). Includes automated warnings
#' when approaching cost limits. This is the main entry point for monitoring LLM usage
#' across different time horizons.
#'
#' @param daily_limit Daily cost limit in USD. If NULL, reads from `LLM_DAILY_LIMIT`
#'   environment variable or defaults to 30.
#' @param weekly_limit Weekly cost limit in USD. If NULL, reads from `LLM_WEEKLY_LIMIT`
#'   environment variable or defaults to 120.
#' @param token_limit Daily token limit. If NULL, reads from `LLM_DAILY_TOKEN_LIMIT`
#'   environment variable or defaults to 500000.
#' @param cache_dir Directory containing cached JSON files. If NULL, searches standard
#'   package cache locations.
#' @param show_max5 Logical whether to show Max5 5-hour block status when the
#'   `LLM_PLAN` environment variable is set to "max5". Default: TRUE.
#'
#' @return Invisibly returns a list containing:
#'   - `daily`: List from [show_daily_progress()]
#'   - `weekly`: List from [show_weekly_progress()]
#'   - `max5`: List from [show_max5_block_status()] if applicable, otherwise NULL
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Show complete dashboard with default settings
#' show_usage_dashboard()
#'
#' # Show dashboard with custom limits
#' show_usage_dashboard(
#'   daily_limit = 50,
#'   weekly_limit = 200,
#'   token_limit = 750000
#' )
#'
#' # Show dashboard without Max5 status
#' show_usage_dashboard(show_max5 = FALSE)
#' }
#'
#' @seealso
#' - [show_daily_progress()] for daily breakdown
#' - [show_weekly_progress()] for weekly breakdown
#' - [show_max5_block_status()] for Max5 plan block tracking
#' - [show_usage_progress()] for individual progress bars
#'
#' @keywords internal
show_usage_dashboard <- function(daily_limit = NULL,
                                  weekly_limit = NULL,
                                  token_limit = NULL,
                                  cache_dir = NULL,
                                  show_max5 = TRUE) {
  # Validate inputs
  checkmate::assert_number(daily_limit, lower = 0, null.ok = TRUE)
  checkmate::assert_number(weekly_limit, lower = 0, null.ok = TRUE)
  checkmate::assert_number(token_limit, lower = 0, null.ok = TRUE)
  if (!is.null(cache_dir)) checkmate::assert_directory_exists(cache_dir)
  checkmate::assert_flag(show_max5)

  cli::cli_h1("LLM Usage Dashboard")

  # Show daily progress
  daily_stats <- show_daily_progress(daily_limit, token_limit, cache_dir)

  cli::cli_text("")

  # Show weekly progress
  weekly_stats <- show_weekly_progress(weekly_limit, cache_dir)

  # Show Max5 block status if enabled
  if (show_max5 && tolower(Sys.getenv("LLM_PLAN", "")) == "max5") {
    cli::cli_text("")
    max5_stats <- show_max5_block_status(cache_dir = cache_dir)
  }

  # Add warnings if approaching limits
  if (!is.null(daily_stats)) {
    if (daily_stats$cost_pct >= 90) {
      cli::cli_alert_danger("Daily cost limit nearly reached!")
    } else if (daily_stats$cost_pct >= 75) {
      cli::cli_alert_warning("Approaching daily cost limit")
    }
  }

  if (!is.null(weekly_stats)) {
    if (weekly_stats$cost_pct >= 90) {
      cli::cli_alert_danger("Weekly cost limit nearly reached!")
    } else if (weekly_stats$cost_pct >= 75) {
      cli::cli_alert_warning("Approaching weekly cost limit")
    }
  }

  invisible(list(
    daily = daily_stats,
    weekly = weekly_stats,
    max5 = if (exists("max5_stats")) max5_stats else NULL
  ))
}

#' Get current Max5 5-hour block window
#'
#' @title Determine Current 5-Hour Block Window
#'
#' @description
#' Calculates which 5-hour block the current time falls into for Max5 plan users.
#' The day is divided into blocks starting at hours 0, 5, 10, 15, and 20 (UTC or local
#' timezone). Each block has a 5-hour duration and independent token usage limits.
#'
#' @param current_time Current time to calculate block for. Accepts POSIXct or can be
#'   converted to POSIXct. Defaults to [Sys.time()].
#'
#' @return List containing:
#'   - `block_start`: POSIXct, start time of the current block
#'   - `block_end`: POSIXct, end time of the current block (5 hours later)
#'   - `time_remaining`: difftime object, time remaining in the current block
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Get current block window
#' current_window <- get_current_block_window()
#' print(current_window$time_remaining)
#'
#' # Get block window for a specific time
#' get_current_block_window(as.POSIXct("2025-01-22 12:30:00"))
#' }
#'
#' @seealso
#' - [calculate_block_usage()] to calculate usage within a block window
#' - [show_max5_block_status()] to display block status
#' - [get_block_history()] to view historical block usage
#'
#' @keywords internal
get_current_block_window <- function(current_time = Sys.time()) {
  # Validate input
  # checkmate doesn't have a direct assert_posixct but we can check class or use testDate
  if (!inherits(current_time, c("POSIXct", "POSIXlt", "Date", "character"))) {
    stop("current_time must be a POSIXct, Date, or character string")
  }

  # Try to convert to POSIXct
  tryCatch({
    current_time <- as.POSIXct(current_time)
  }, error = function(e) {
    stop("current_time must be convertible to POSIXct (a valid date/time)")
  })

  if (is.na(current_time)) {
    stop("current_time is NA - must be a valid date/time")
  }

  # Get hour of day (0-23)
  hour <- as.integer(format(current_time, "%H"))

  # Calculate block start hour (0, 5, 10, 15, 20)
  block_start_hour <- floor(hour / 5) * 5

  # Create block start time (same day, block start hour, 0 minutes)
  block_start <- as.POSIXct(
    paste0(format(current_time, "%Y-%m-%d "),
           sprintf("%02d:00:00", block_start_hour)),
    tz = Sys.timezone()
  )

  # Block ends 5 hours later
  block_end <- block_start + 5 * 3600

  list(
    block_start = block_start,
    block_end = block_end,
    time_remaining = difftime(block_end, current_time, units = "mins")
  )
}

#' Calculate Max5 block usage from blocks data
#'
#' @title Calculate Token Usage for 5-Hour Block
#'
#' @description
#' Calculates token usage statistics for the current 5-hour block. Filters the blocks
#' data to entries within the specified block window and aggregates token counts.
#' Returns usage metrics and percentage of the 88,000-token block limit.
#'
#' @param blocks_data Blocks data tibble from [load_cached_ccusage()] with
#'   "blocks" type. Must contain `timestamp` and `totalTokens` columns.
#' @param current_window List from [get_current_block_window()] containing
#'   `block_start`, `block_end`, and `time_remaining` fields.
#'
#' @return List containing:
#'   - `tokens_used`: Numeric, tokens used in the current block
#'   - `tokens_limit`: Numeric, token limit per block (default 88000)
#'   - `usage_pct`: Integer, percentage of block limit used (0-100)
#'   - `time_remaining`: difftime object, time remaining in the block
#'   - `block_start`: POSIXct, block start time
#'   - `block_end`: POSIXct, block end time
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Get current block window
#' window <- get_current_block_window()
#'
#' # Load blocks data
#' blocks <- load_cached_ccusage("blocks")
#'
#' # Calculate usage
#' usage <- calculate_block_usage(blocks, window)
#' print(usage$usage_pct)
#' }
#'
#' @seealso
#' - [get_current_block_window()] to get the block window
#' - [show_max5_block_status()] to display formatted block status
#' - [get_block_history()] to view historical blocks
#'
#' @keywords internal
calculate_block_usage <- function(blocks_data, current_window) {
  # Validate inputs
  checkmate::assert_data_frame(blocks_data, null.ok = TRUE)
  checkmate::assert_list(current_window, names = "named")
  checkmate::assert_names(names(current_window), must.include = c("block_start", "block_end", "time_remaining"))

  if (is.null(blocks_data) || nrow(blocks_data) == 0) {
    return(list(
      tokens_used = 0,
      tokens_limit = 88000,
      usage_pct = 0,
      time_remaining = current_window$time_remaining,
      block_start = current_window$block_start,
      block_end = current_window$block_end
    ))
  }

  # Filter to current block
  current_block <- blocks_data |>
    dplyr::filter(
      timestamp >= current_window$block_start,
      timestamp < current_window$block_end
    )

  if (nrow(current_block) == 0) {
    tokens_used <- 0
  } else {
    tokens_used <- sum(current_block$totalTokens, na.rm = TRUE)
  }

  # Max5 limit per 5-hour block
  tokens_limit <- as.numeric(Sys.getenv("LLM_BLOCK_LIMIT_TOKENS", "88000"))

  list(
    tokens_used = tokens_used,
    tokens_limit = tokens_limit,
    usage_pct = round((tokens_used / tokens_limit) * 100),
    time_remaining = current_window$time_remaining,
    block_start = current_window$block_start,
    block_end = current_window$block_end
  )
}

#' Show Max5 5-hour block status
#'
#' @title Display Max5 5-Hour Block Status
#'
#' @description
#' Displays the current token usage for the active 5-hour block with a progress bar,
#' remaining time indicator, and threshold-based warnings. Designed for users on the
#' Max5 plan which has per-block token limits. Automatically loads cached block data
#' and calculates the current block window.
#'
#' @param cache_dir Directory containing cached JSON files. If NULL, searches standard
#'   package cache locations.
#'
#' @return Invisibly returns a list from [calculate_block_usage()] containing:
#'   - `tokens_used`: Numeric, tokens consumed in current block
#'   - `tokens_limit`: Numeric, token limit per block
#'   - `usage_pct`: Integer, percentage of limit used
#'   - `time_remaining`: difftime object, time until block ends
#'   - `block_start`: POSIXct, when the block started
#'   - `block_end`: POSIXct, when the block ends
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Show current Max5 block status
#' show_max5_block_status()
#'
#' # Show block status for specific cache directory
#' show_max5_block_status(cache_dir = "/path/to/cache")
#' }
#'
#' @details
#' This function is most useful when called from [show_usage_dashboard()] with
#' `LLM_PLAN=max5` environment variable set. It automatically applies warning
#' thresholds based on:
#' - `LLM_WARN_THRESHOLD` (default 0.75): Yellow warning
#' - `LLM_CRITICAL_THRESHOLD` (default 0.90): Red critical alert
#'
#' @seealso
#' - [get_current_block_window()] to determine the active block
#' - [calculate_block_usage()] for the underlying calculation
#' - [get_block_history()] to view historical block usage
#' - [show_usage_dashboard()] for integration with daily/weekly views
#'
#' @keywords internal
show_max5_block_status <- function(cache_dir = NULL) {
  # Validate input
  if (!is.null(cache_dir)) checkmate::assert_directory_exists(cache_dir)

  cli::cli_h2("Max5 5-Hour Block Status")

  # Load blocks data
  blocks_data <- load_cached_ccusage("blocks", cache_dir = cache_dir)

  # Get current block window
  current_window <- get_current_block_window()

  # Calculate usage
  block_stats <- calculate_block_usage(blocks_data, current_window)

  # Format time remaining
  time_remaining <- as.numeric(block_stats$time_remaining)  # Convert to minutes
  if (time_remaining > 60) {
    hours <- floor(time_remaining / 60)
    mins <- round(time_remaining - (hours * 60))
    time_str <- sprintf("%dh %dm", hours, mins)
  } else {
    time_str <- sprintf("%dm", round(time_remaining))
  }

  cli::cli_text("{.dim Block: {format(block_stats$block_start, '%H:%M')} - {format(block_stats$block_end, '%H:%M')} | Remaining: {time_str}}")

  # Show progress bar
  pct <- block_stats$usage_pct
  color <- if (pct >= 90) "red" else if (pct >= 75) "yellow" else "green"

  bar_width <- 40
  filled <- round(bar_width * pct / 100)
  empty <- bar_width - filled
  bar <- paste0(strrep("\U00002588", filled), strrep("\U00002591", empty))  # full block and light shade

  cli::cli_div(theme = list(
    ".pbar" = list(color = color),
    ".label" = list("font-weight" = "bold")
  ))

  cli::cli_text(
    "{.label Tokens} {.pbar [{bar}]} {pct}% ({scales::comma(block_stats$tokens_used)} / {scales::comma(block_stats$tokens_limit)})"
  )

  cli::cli_end()

  # Add warnings based on thresholds
  warn_threshold <- as.numeric(Sys.getenv("LLM_WARN_THRESHOLD", "0.75"))
  critical_threshold <- as.numeric(Sys.getenv("LLM_CRITICAL_THRESHOLD", "0.90"))

  if (pct >= critical_threshold * 100) {
    cli::cli_alert_danger("CRITICAL: {pct}% of 5-hour block limit reached - consider pausing")
  } else if (pct >= warn_threshold * 100) {
    cli::cli_alert_warning("WARNING: {pct}% of 5-hour block limit used")
  }

  invisible(block_stats)
}

#' Get Max5 block history
#'
#' @title Display Recent 5-Hour Block History
#'
#' @description
#' Displays historical usage for recent 5-hour blocks with status indicators and
#' completion percentages. Groups block data by date and block hour, showing up to
#' the last 10 blocks from the requested time period. Each block is tagged with a
#' status emoji (white = low, green = moderate, yellow = warning, red = critical).
#'
#' @param days Number of days of history to show (default 3). Retrieves all blocks
#'   from the past N days.
#' @param cache_dir Directory containing cached JSON files. If NULL, searches standard
#'   package cache locations.
#'
#' @return Invisibly returns a tibble with columns:
#'   - `block_id`: Character, unique identifier (date_hour format)
#'   - `block_date`: Date, date of the block
#'   - `block_hour`: Integer, starting hour of the block (0, 5, 10, 15, 20)
#'   - `total_tokens`: Numeric, tokens consumed in the block
#'   - `usage_pct`: Integer, percentage of 88000-token limit
#'   - `status`: Character, emoji status indicator
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Show last 3 days of block history
#' history <- get_block_history()
#'
#' # Show last 7 days of block history
#' get_block_history(days = 7)
#' }
#'
#' @details
#' Block status indicators:
#' - White circle = 0-49% of limit used (light usage)
#' - Green circle = 50-74% of limit used (normal usage)
#' - Yellow circle = 75-89% of limit used (warning)
#' - Red circle = 90%+ of limit used (critical)
#'
#' @seealso
#' - [show_max5_block_status()] to see current block status
#' - [get_current_block_window()] to get the active block window
#' - [calculate_block_usage()] for individual block calculations
#'
#' @keywords internal
get_block_history <- function(days = 3, cache_dir = NULL) {
  # Validate inputs
  checkmate::assert_count(days, positive = TRUE)
  if (!is.null(cache_dir)) checkmate::assert_directory_exists(cache_dir)

  # Load blocks data
  blocks_data <- load_cached_ccusage("blocks", cache_dir = cache_dir)

  if (is.null(blocks_data) || nrow(blocks_data) == 0) {
    cli::cli_alert_warning("No block history available")
    return(NULL)
  }

  # Get cutoff time
  cutoff <- Sys.time() - days * 24 * 3600

  # Filter to recent data
  recent_blocks <- blocks_data |>
    dplyr::filter(timestamp >= cutoff) |>
    dplyr::mutate(
      # Calculate which 5-hour block each entry belongs to
      block_hour = floor(as.integer(format(timestamp, "%H")) / 5) * 5,
      block_date = as.Date(timestamp),
      block_id = paste0(block_date, "_", sprintf("%02d", block_hour))
    ) |>
    dplyr::group_by(block_id, block_date, block_hour) |>
    dplyr::summarise(
      total_tokens = sum(totalTokens, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      usage_pct = round((total_tokens / 88000) * 100),
      status = dplyr::case_when(
        usage_pct >= 90 ~ "\U0001F534",  # red circle
        usage_pct >= 75 ~ "\U0001F7E1",  # yellow circle
        usage_pct >= 50 ~ "\U0001F7E2",  # green circle
        TRUE ~ "\U000026AA"  # white circle
      )
    ) |>
    dplyr::arrange(desc(block_date), desc(block_hour))

  if (nrow(recent_blocks) > 0) {
    cli::cli_h3("Recent Block History")

    # Display as a simple table
    for (i in seq_len(min(10, nrow(recent_blocks)))) {
      row <- recent_blocks[i, ]
      cli::cli_text(
        "{row$status} {row$block_date} {sprintf('%02d:00', row$block_hour)}-{sprintf('%02d:00', (row$block_hour + 5) %% 24)}: {row$usage_pct}% ({scales::comma(row$total_tokens)} tokens)"
      )
    }
  }

  invisible(recent_blocks)
}
