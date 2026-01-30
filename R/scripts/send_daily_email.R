# send_daily_email.R
# Send daily LLM usage report via Gmail
# Called from GitHub Actions workflow: .github/workflows/daily-llm-report.yaml

library(blastula)
library(dplyr)
library(tibble)
library(jsonlite)
library(purrr)
library(lubridate)
library(DBI)
library(duckdb)

# Load cached ccusage data from inst/extdata/
load_cached <- function(type) {
  path <- sprintf("inst/extdata/ccusage_%s_all.json", type)
  if (!file.exists(path)) {
    message(sprintf("Cache file not found: %s", path))
    return(NULL)
  }
  tryCatch({
    fromJSON(path)
  }, error = function(e) {
    message(sprintf("Failed to parse %s: %s", path, e$message))
    NULL
  })
}

daily_raw <- load_cached("daily")
session_raw <- load_cached("session")
blocks_raw <- load_cached("blocks")

has_data <- !is.null(daily_raw) || !is.null(session_raw)

# Helper: normalize to character vector (handles NULL, list, character)
normalize_to_char_vec <- function(x) {
  switch(class(x)[1],
    "NULL" = character(0),
    "list" = as.character(unlist(x)),
    as.character(x)
  ) |> (\(v) if (length(v) == 0) character(0) else v)()
}

# Parse daily data
parse_daily <- function(json) {
  if (is.null(json$projects)) return(NULL)
  names(json$projects) |>
    map_dfr(\(p) {
      d <- json$projects[[p]]
      if (is.null(d) || length(d) == 0) return(NULL)
      as_tibble(d) |>
        mutate(
          project = p,
          across(any_of("modelsUsed"), ~ map(.x, normalize_to_char_vec))
        )
    })
}

daily_data <- parse_daily(daily_raw)
session_data <- if (!is.null(session_raw$sessions)) {
  as_tibble(session_raw$sessions)
} else NULL

today <- Sys.Date()

# Helper for safe date conversion
safe_date <- function(x) {
  if (is.null(x) || length(x) == 0 || all(is.na(x))) return(NA)
  tryCatch(as.Date(x), error = function(e) NA)
}

# Helper for formatting
dollar <- function(x) {
  if (is.na(x) || is.null(x) || is.nan(x)) return("-")
  sprintf("$%.2f", x)
}
comma <- function(x) {
  if (is.na(x) || is.null(x) || is.nan(x)) return("-")
  format(x, big.mark = ",", scientific = FALSE)
}
millions <- function(x) {
  if (is.na(x) || is.null(x) || is.nan(x)) return("-")
  sprintf("%.1fM", x / 1e6)
}
format_hhmm <- function(mins) sprintf("%02d:%02d", as.integer(mins %/% 60), as.integer(mins %% 60))

# Dark mode color palette
dark_bg <- "#1a1a2e"
dark_card <- "#16213e"
dark_row_alt <- "#0f3460"
dark_text <- "#e8e8e8"
dark_muted <- "#a0a0a0"
dark_border <- "#2a2a4a"
accent_green <- "#00d26a"
accent_blue <- "#4fc3f7"
accent_purple <- "#bb86fc"
accent_orange <- "#ff9800"

# Get cache timestamp
cache_time <- if (!is.null(session_raw$generatedAt)) {
  session_raw$generatedAt
} else if (file.exists("inst/extdata/ccusage_session_all.json")) {
  format(file.info("inst/extdata/ccusage_session_all.json")$mtime, "%Y-%m-%d %H:%M:%S")
} else {
  "Unknown"
}

if (!has_data) {
  email_body <- sprintf('\n<div style="background-color: %s; color: %s; padding: 20px; font-family: -apple-system, BlinkMacSystemFont, sans-serif;">
<h2 style="color: %s; margin-bottom: 5px;">LLM Usage Report - %s</h2>
<div style="background-color: #3d2c00; border: 1px solid #ffc107; padding: 15px; border-radius: 5px; color: #ffd54f;">
  <strong>No cached data available</strong>
  <p>Run locally: <code style="background-color: %s; padding: 2px 6px; border-radius: 3px;">Rscript R/scripts/refresh_ccusage_cache.R</code></p>
</div>
</div>
', dark_bg, dark_text, accent_orange, today, dark_card)
} else {
  # Calculate weekly stats (1-4 weeks back)
    calc_weekly <- function(weeks_back) {
      if (is.null(daily_data) || nrow(daily_data) == 0 || !"date" %in% names(daily_data)) {
        return(list(cost = 0, tokens = 0))
      }
      end_date <- today - (weeks_back - 1) * 7
      start_date <- end_date - 6
      weekly <- daily_data |>
        filter(safe_date(.data$date) >= start_date, safe_date(.data$date) <= end_date)
      list(
        cost = sum(weekly$totalCost, na.rm = TRUE),
        tokens = sum(weekly$totalTokens, na.rm = TRUE)
      )
    }

  week1 <- calc_weekly(1)
  week2 <- calc_weekly(2)
  week3 <- calc_weekly(3)
  week4 <- calc_weekly(4)

  # --- 1. Calculate ccusage stats ---
  total_cost <- if (!is.null(daily_data)) sum(daily_data$totalCost, na.rm = TRUE) else 0
  total_tokens <- if (!is.null(daily_data)) sum(daily_data$totalTokens, na.rm = TRUE) else 0
  n_sessions <- if (!is.null(session_data)) nrow(session_data) else 0
  
  cc_start <- if (!is.null(daily_data) && nrow(daily_data) > 0) min(safe_date(daily_data$date), na.rm=TRUE) else NA
  cc_end <- if (!is.null(daily_data) && nrow(daily_data) > 0) max(safe_date(daily_data$date), na.rm=TRUE) else NA
  cc_days <- if (!is.na(cc_start) && !is.na(cc_end)) as.numeric(cc_end - cc_start) + 1 else 0
  cc_entries <- if (!is.null(blocks_raw$blocks)) nrow(blocks_raw$blocks) else NA
  
  cc_cost_day <- if (cc_days > 0) total_cost / cc_days else 0
  cc_tok_day <- if (cc_days > 0) total_tokens / cc_days else 0

  # --- 2. Calculate cmonitor stats ---
  cm_cost <- NA; cm_tokens <- NA; cm_entries <- NA; cm_days <- NA; cm_start <- NA; cm_end <- NA
  cm_cost_day <- NA; cm_tok_day <- NA
  
  cmonitor_path <- "inst/extdata/cmonitor_daily.txt"
  if (file.exists(cmonitor_path)) {
    lines <- readLines(cmonitor_path, warn = FALSE)
    lines <- lines[!grepl("Setup complete|Terminal wrapper|RSTUDIO_TERM_EXEC|unpacking", lines)]
    lines <- gsub("\033\\[[0-9;]*[a-zA-Z]", "", lines)
    full_text <- paste(lines, collapse = "\n")
    
    extract <- function(pattern, text) {
      m <- regexec(pattern, text)
      if (m[[1]][1] == -1) return(NULL)
      regmatches(text, m)[[1]][2]
    }
    
    cost_val <- extract("Total Cost:\\s*\\$([0-9,.]+)", full_text)
    tokens_val <- extract("Total Tokens:\\s*([0-9,]+)", full_text)
    entries_val <- extract("Entries:\\s*([0-9,]+)", full_text)
    period_val <- extract("Daily Usage Summary\\s*-\\s*([0-9-]+\\s*to\\s*[0-9-]+)", full_text)
    
    if (!is.null(cost_val)) cm_cost <- as.numeric(gsub("[$,]", "", cost_val))
    if (!is.null(tokens_val)) cm_tokens <- as.numeric(gsub("[,]", "", tokens_val))
    if (!is.null(entries_val)) cm_entries <- as.numeric(gsub("[,]", "", entries_val))
      if (!is.null(period_val)) {
        dates <- strsplit(period_val, " to ")[[1]]
        if (length(dates) >= 2) {
          cm_start <- safe_date(dates[1])
          cm_end <- safe_date(dates[2])
          if (!is.na(cm_start) && !is.na(cm_end)) {
            cm_days <- as.numeric(cm_end - cm_start) + 1
            if (cm_days > 0) {
              cm_cost_day <- cm_cost / cm_days
              cm_tok_day <- cm_tokens / cm_days
            }
          }
        }
      }
  }

  # --- 3. Calculate Gemini stats ---
  gm_cost <- NA; gm_tokens <- NA; gm_entries <- NA; gm_days <- NA; gm_start <- NA; gm_end <- NA
  gm_cost_day <- NA; gm_tok_day <- NA
  gm_sessions_count <- 0
  
  gm_db_path <- "inst/extdata/gemini_usage.duckdb"
  if (file.exists(gm_db_path)) {
    gm_con <- dbConnect(duckdb(), dbdir = gm_db_path, read_only = TRUE)
    gm_stats <- dbGetQuery(gm_con, "
      SELECT 
        SUM(total_cost) as cost, 
        SUM(total_tokens) as tokens, 
        SUM(message_count) as entries,
        MIN(date) as start_date,
        MAX(date) as end_date
      FROM daily_usage
    ")
    
          if (!is.null(gm_stats$cost)) {
            gm_cost <- gm_stats$cost
            gm_tokens <- gm_stats$tokens
            gm_entries <- gm_stats$entries
            gm_start <- safe_date(gm_stats$start_date)
            gm_end <- safe_date(gm_stats$end_date)
            
            if (!is.na(gm_start) && !is.na(gm_end)) {
              gm_days <- as.numeric(gm_end - gm_start) + 1
              if (gm_days > 0) {
                gm_cost_day <- gm_cost / gm_days
                gm_tok_day <- gm_tokens / gm_days
              }
            }
          }    
    # Get recent Gemini sessions
    gm_sessions <- dbGetQuery(gm_con, "
      SELECT sessionId, total_cost, total_tokens, start_time 
      FROM sessions_summary 
      ORDER BY last_updated DESC LIMIT 5
    ")
    gm_sessions_count <- dbGetQuery(gm_con, "SELECT COUNT(*) FROM sessions_summary")[[1]]
    dbDisconnect(gm_con, shutdown = TRUE)
  }

  # Build email - Dark mode with Merged Summary Table
  # Break into chunks to avoid sprintf 100-argument limit
  
  email_header <- sprintf('\n<div style="background-color: %s; color: %s; padding: 20px; font-family: -apple-system, BlinkMacSystemFont, sans-serif;">
<h2 style="color: %s; margin-bottom: 5px;">LLM Usage Report - %s</h2>
<p style="color: %s; font-size: 12px; margin-top: 0;">Data cached: %s</p>

<h3 style="color: %s;">Summary</h3>
<table style="border-collapse: collapse; width: 100%%; font-size: 11px;">
  <tr style="background-color: %s; color: white;">
    <th style="padding: 6px; border: 1px solid %s;">Source</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">Cost<sup>1</sup></th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">$/Day</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">Tokens</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">Tok/Day</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">Days<sup>2</sup></th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">Sessions<sup>3</sup></th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">Entries<sup>4</sup></th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">Start Date</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right;">End Date</th>
  </tr>',
  dark_bg, dark_text, accent_orange, today, dark_muted, cache_time, accent_green,
  dark_row_alt, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border)

  row_ccusage <- sprintf('
  <!-- ccusage Row -->
  <tr style="background-color: %s;">
    <td style="padding: 6px; border: 1px solid %s; color: %s;"><strong>ccusage</strong></td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>',
  dark_card, dark_border, dark_text,
  dark_border, accent_green, dollar(total_cost),
  dark_border, dark_text, dollar(cc_cost_day),
  dark_border, accent_blue, millions(total_tokens),
  dark_border, dark_text, millions(cc_tok_day),
  dark_border, dark_text, cc_days,
  dark_border, dark_text, n_sessions,
  dark_border, dark_text, ifelse(is.na(cc_entries), "-", comma(cc_entries)),
  dark_border, dark_muted, as.character(cc_start),
  dark_border, dark_muted, as.character(cc_end))

  row_gemini <- sprintf('
  <!-- Gemini Row -->
  <tr style="background-color: %s;">
    <td style="padding: 6px; border: 1px solid %s; color: %s;"><strong>Gemini</strong></td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>',
  dark_row_alt, dark_border, dark_text,
  dark_border, accent_green, dollar(gm_cost),
  dark_border, dark_text, dollar(gm_cost_day),
  dark_border, accent_blue, millions(gm_tokens),
  dark_border, dark_text, millions(gm_tok_day),
  dark_border, dark_text, gm_days,
  dark_border, dark_text, ifelse(gm_sessions_count == 0, "-", gm_sessions_count),
  dark_border, dark_text, comma(gm_entries),
  dark_border, dark_muted, as.character(gm_start),
  dark_border, dark_muted, as.character(gm_end))

  row_cmonitor <- sprintf('
  <!-- cmonitor Row -->
  <tr style="background-color: %s;">
    <td style="padding: 6px; border: 1px solid %s; color: %s;"><strong>cmonitor</strong></td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">-</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
</table>',
  dark_card, dark_border, dark_text,
  dark_border, accent_green, dollar(cm_cost),
  dark_border, dark_text, dollar(cm_cost_day),
  dark_border, accent_blue, millions(cm_tokens),
  dark_border, dark_text, millions(cm_tok_day),
  dark_border, dark_text, cm_days,
  dark_border, dark_text, # Sessions (2 placeholders for style, value is hardcoded '-')
  dark_border, dark_text, comma(cm_entries),
  dark_border, dark_muted, as.character(cm_start),
  dark_border, dark_muted, as.character(cm_end))

  email_body <- paste0(email_header, row_ccusage, row_gemini, row_cmonitor)

  # Weekly Cost
  email_body <- paste0(email_body, sprintf('\n<h3 style="color: %s;">Weekly Cost (Claude)</h3>
<table style="border-collapse: collapse; max-width: 400px;">
  <tr style="background-color: %s;">
    <th style="padding: 8px; border: 1px solid %s; color: white;">Period</th>
    <th style="padding: 8px; border: 1px solid %s; text-align: right; color: white;">Cost</th>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 1 (current)</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 2</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 3</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 4</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
</table>
',
     accent_green, accent_green, dark_border, dark_border,
     dark_card, dark_border, dark_text, dark_border, accent_green, dollar(week1$cost),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, dollar(week2$cost),
     dark_card, dark_border, dark_text, dark_border, dark_text, dollar(week3$cost),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, dollar(week4$cost)))

  # Weekly Tokens
  email_body <- paste0(email_body, sprintf('\n<h3 style="color: %s;">Weekly Tokens (Claude)</h3>
<table style="border-collapse: collapse; max-width: 400px;">
  <tr style="background-color: %s;">
    <th style="padding: 8px; border: 1px solid %s; color: white;">Period</th>
    <th style="padding: 8px; border: 1px solid %s; text-align: right; color: white;">Tokens</th>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 1 (current)</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 2</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 3</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
  <tr style="background-color: %s;">
    <td style="padding: 8px; border: 1px solid %s; color: %s;">Week 4</td>
    <td style="padding: 8px; border: 1px solid %s; text-align: right; color: %s;">%s</td>
  </tr>
</table>
',
     accent_blue, accent_blue, dark_border, dark_border,
     dark_card, dark_border, dark_text, dark_border, accent_blue, millions(week1$tokens),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, millions(week2$tokens),
     dark_card, dark_border, dark_text, dark_border, dark_text, millions(week3$tokens),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, millions(week4$tokens)))

  # Time Block Activity Table (last 5 non-empty days)
  if (!is.null(blocks_raw) && !is.null(blocks_raw$blocks)) {
    blocks_df <- as_tibble(blocks_raw$blocks) |>
      mutate(
        start = ymd_hms(startTime),
        end = ymd_hms(actualEndTime),
        duration_mins = as.numeric(difftime(end, start, units = "mins")),
        duration_hrs = duration_mins / 60,
        date = as.Date(start),
        cost_per_hr = ifelse(duration_hrs > 0, costUSD / duration_hrs, 0),
        tokens_per_hr = ifelse(duration_hrs > 0, totalTokens / duration_hrs, 0)
      ) |>
      filter(!is.na(end), costUSD > 0) |>
      select(id, date, start, end, duration_mins, duration_hrs, costUSD, totalTokens, cost_per_hr, tokens_per_hr)

    recent_days <- blocks_df |>
      group_by(date) |>
      summarise(n = n(), .groups = "drop") |>
      arrange(desc(date)) |>
      head(5) |>
      pull(date)

    if (length(recent_days) > 0) {
      activity_df <- blocks_df |>
        filter(date %in% recent_days) |>
        arrange(desc(end))

      if (nrow(activity_df) > 0) {
        email_body <- paste0(email_body, sprintf('\n<h3 style="color: %s;">Time Block Activity (Last 5 Days)</h3>
<table style="border-collapse: collapse; width: 100%%;">
  <tr style="background-color: %s;">
    <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">Start</th>
    <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">End</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Duration</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Cost</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">$/hr</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Tokens</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Tok/hr</th>
  </tr>', accent_orange, "#607D8B",
            dark_border, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border))

        for (i in seq_len(nrow(activity_df))) {
          bg <- if (i %% 2 == 0) dark_row_alt else dark_card
          email_body <- paste0(email_body, sprintf('\n  <tr style="background-color: %s;">
    <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
  </tr>', 
            bg,
            dark_border, dark_muted, format(activity_df$start[i], "%Y-%m-%d %H:%M"),
            dark_border, dark_muted, format(activity_df$end[i], "%Y-%m-%d %H:%M"),
            dark_border, dark_text, format_hhmm(activity_df$duration_mins[i]),
            dark_border, accent_green, dollar(activity_df$costUSD[i]),
            dark_border, dark_text, dollar(activity_df$cost_per_hr[i]),
            dark_border, accent_blue, comma(activity_df$totalTokens[i]),
            dark_border, dark_text, comma(round(activity_df$tokens_per_hr[i]))
          ))
        }
        email_body <- paste0(email_body, "</table>")
      }
    }
  }

  # Gemini Recent Sessions
  if (exists("gm_sessions") && !is.null(gm_sessions) && nrow(gm_sessions) > 0) {
    email_body <- paste0(email_body, sprintf('\n<h3 style="color: %s; margin-top: 20px;">Gemini Recent Sessions</h3>
<table style="border-collapse: collapse; width: 100%%;">
  <tr style="background-color: %s;">
    <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">Session ID</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Cost</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Tokens</th>
    <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">Started</th>
  </tr>', accent_blue, accent_blue, dark_border, dark_border, dark_border, dark_border))

    for (i in seq_len(nrow(gm_sessions))) {
      bg <- if (i %% 2 == 0) dark_row_alt else dark_card
      email_body <- paste0(email_body, sprintf('\n  <tr style="background-color: %s;">
    <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
  </tr>', 
        bg,
        dark_border, dark_text, gm_sessions$sessionId[i],
        dark_border, accent_green, dollar(gm_sessions$total_cost[i]),
        dark_border, accent_blue, millions(gm_sessions$total_tokens[i]),
        dark_border, dark_muted, format(gm_sessions$start_time[i], "%Y-%m-%d %H:%M")
      ))
    }
    email_body <- paste0(email_body, "</table>")
  }

  # Top Claude Sessions by Cost - NOW AT THE END
  if (!is.null(session_data) && nrow(session_data) > 0) {
    top_sessions <- session_data |>
      arrange(desc(totalCost)) |>
      head(5)

    email_body <- paste0(email_body, sprintf('\n<h3 style="color: %s; margin-top: 20px;">Top Claude Sessions by Cost</h3>
<table style="border-collapse: collapse; width: 100%%;">
  <tr style="background-color: %s;">
    <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">Session</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Cost</th>
    <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Tokens</th>
    <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">Last Active</th>
  </tr>', accent_purple, accent_purple, dark_border, dark_border, dark_border, dark_border))

    for (i in seq_len(nrow(top_sessions))) {
      bg <- if (i %% 2 == 0) dark_row_alt else dark_card
      last_active <- top_sessions$lastActivity[i]
      # Clean up session name: remove leading dashes and path separators, show last 2 components
      session_name <- top_sessions$sessionId[i]
      session_parts <- strsplit(gsub("^-", "", session_name), "-")[[1]]
      if (length(session_parts) > 2) {
        session_name <- paste(tail(session_parts, 2), collapse = "/")
      }
      email_body <- paste0(email_body, sprintf('\n  <tr style="background-color: %s;">
    <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
  </tr>', 
        bg,
        dark_border, dark_text, session_name,
        dark_border, accent_green, dollar(top_sessions$totalCost[i]),
        dark_border, accent_blue, millions(top_sessions$totalTokens[i]),
        dark_border, dark_muted, last_active
      ))
    }
    email_body <- paste0(email_body, "</table>")
  }

  email_body <- paste0(email_body, sprintf('\n<hr style="margin-top: 20px; border-color: %s;">
<p style="color: %s; font-size: 12px;">
  <a href="https://github.com/JohnGavin/llm" style="color: %s;">llm project</a> |
  <a href="https://johngavin.github.io/llm/vignettes/telemetry.html" style="color: %s;">Dashboard</a> |
  Refresh: <code style="background-color: %s; padding: 2px 6px; border-radius: 3px; color: %s;">Rscript R/scripts/refresh_ccusage_cache.R</code>
</p>

<!-- Footnotes -->
<div style="margin-top: 30px; border-top: 1px solid %s; padding-top: 10px; color: %s; font-size: 10px;">
  <strong>Definitions:</strong><br>
  <sup>1</sup> <strong>Cost:</strong> Total cost in USD.<br>
  <sup>2</sup> <strong>Days:</strong> Number of days in the reporting period.<br>
  <sup>3</sup> <strong>Sessions:</strong> Number of distinct interactive sessions recorded.<br>
  <sup>4</sup> <strong>Entries:</strong> Total number of logged interactions/blocks.<br>
  <strong>Source:</strong> <em>ccusage/Gemini</em> (this R package) vs <em>cmonitor</em> (Rust-based system monitor).
</div>
</div>
', dark_border, dark_muted, accent_blue, accent_blue, dark_card, dark_text, dark_border, dark_muted))
}

# Create and send email
london_time <- format(Sys.time(), tz = "Europe/London", "%Y-%m-%d %H:%M")
email <- compose_email(
  body = md(email_body),
  footer = md(sprintf("<span style='color: %s;'>Report generated: %s (London)</span>", dark_muted, london_time))
)

smtp_creds <- creds_envvar(
  user = Sys.getenv("GMAIL_USERNAME"),
  pass_envvar = "GMAIL_APP_PASSWORD",
  host = "smtp.gmail.com",
  port = 465,
  use_ssl = TRUE
)

tryCatch({
  smtp_send(
    email = email,
    to = Sys.getenv("GMAIL_USERNAME"),
    from = Sys.getenv("GMAIL_USERNAME"),
    subject = sprintf("LLM Usage Report - %s", today),
    credentials = smtp_creds
  )
  message("Email sent successfully!")
}, error = function(e) {
  message("Failed to send email: ", e$message)
  quit(status = 1)
})