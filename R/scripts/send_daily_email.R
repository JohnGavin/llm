# send_daily_email.R
# Send daily LLM usage report via Gmail
# Called from GitHub Actions workflow: .github/workflows/daily-llm-report.yaml

library(blastula)
library(dplyr)
library(tibble)
library(jsonlite)
library(purrr)
library(lubridate)

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

# Helper for formatting
dollar <- function(x) sprintf("$%.2f", x)
comma <- function(x) format(x, big.mark = ",", scientific = FALSE)
millions <- function(x) sprintf("%.1fM", x / 1e6)
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
  email_body <- sprintf('
  <div style="background-color: %s; color: %s; padding: 20px; font-family: -apple-system, BlinkMacSystemFont, sans-serif;">
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
    if (is.null(daily_data)) return(list(cost = 0, tokens = 0))
    end_date <- today - (weeks_back - 1) * 7
    start_date <- end_date - 6
    weekly <- daily_data |>
      filter(as.Date(date) >= start_date, as.Date(date) <= end_date)
    list(
      cost = sum(weekly$totalCost, na.rm = TRUE),
      tokens = sum(weekly$totalTokens, na.rm = TRUE)
    )
  }

  week1 <- calc_weekly(1)
  week2 <- calc_weekly(2)
  week3 <- calc_weekly(3)
  week4 <- calc_weekly(4)

  total_cost <- if (!is.null(daily_data)) sum(daily_data$totalCost, na.rm = TRUE) else 0
  total_tokens <- if (!is.null(daily_data)) sum(daily_data$totalTokens, na.rm = TRUE) else 0
  n_sessions <- if (!is.null(session_data)) nrow(session_data) else 0

  # Build email - Dark mode with Summary and Weekly tables first
  email_body <- sprintf('
  <div style="background-color: %s; color: %s; padding: 20px; font-family: -apple-system, BlinkMacSystemFont, sans-serif;">
  <h2 style="color: %s; margin-bottom: 5px;">LLM Usage Report - %s</h2>
  <p style="color: %s; font-size: 12px; margin-top: 0;">Data cached: %s</p>

  <h3 style="color: %s;">Summary</h3>
  <table style="border-collapse: collapse; max-width: 400px;">
    <tr style="background-color: %s;">
      <td style="padding: 8px; border: 1px solid %s; color: %s;"><strong>Total Cost</strong></td>
      <td style="padding: 8px; border: 1px solid %s; color: %s;">%s</td>
    </tr>
    <tr style="background-color: %s;">
      <td style="padding: 8px; border: 1px solid %s; color: %s;"><strong>Total Tokens</strong></td>
      <td style="padding: 8px; border: 1px solid %s; color: %s;">%s</td>
    </tr>
    <tr style="background-color: %s;">
      <td style="padding: 8px; border: 1px solid %s; color: %s;"><strong>Sessions</strong></td>
      <td style="padding: 8px; border: 1px solid %s; color: %s;">%d</td>
    </tr>
  </table>

  <h3 style="color: %s;">Weekly Cost</h3>
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

  <h3 style="color: %s;">Weekly Tokens</h3>
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
     dark_bg, dark_text, accent_orange, today, dark_muted, cache_time,
     accent_green,
     dark_row_alt, dark_border, dark_text, dark_border, accent_green, dollar(total_cost),
     dark_card, dark_border, dark_text, dark_border, dark_text, millions(total_tokens),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, n_sessions,
     accent_green, accent_green, dark_border, dark_border,
     dark_card, dark_border, dark_text, dark_border, accent_green, dollar(week1$cost),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, dollar(week2$cost),
     dark_card, dark_border, dark_text, dark_border, dark_text, dollar(week3$cost),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, dollar(week4$cost),
     accent_blue, accent_blue, dark_border, dark_border,
     dark_card, dark_border, dark_text, dark_border, accent_blue, millions(week1$tokens),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, millions(week2$tokens),
     dark_card, dark_border, dark_text, dark_border, dark_text, millions(week3$tokens),
     dark_row_alt, dark_border, dark_text, dark_border, dark_text, millions(week4$tokens))

  # Time Block Activity Table (last 3 non-empty days) - BEFORE Top Sessions
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

    # Get last 3 non-empty days
    recent_days <- blocks_df |>
      group_by(date) |>
      summarise(n = n(), .groups = "drop") |>
      arrange(desc(date)) |>
      head(3) |>
      pull(date)

    if (length(recent_days) > 0) {
      activity_df <- blocks_df |>
        filter(date %in% recent_days) |>
        arrange(desc(end))

      if (nrow(activity_df) > 0) {
        email_body <- paste0(email_body, sprintf('
  <h3 style="color: %s;">Time Block Activity (Last 3 Days)</h3>
  <table style="border-collapse: collapse; width: 100%%;">
    <tr style="background-color: %s;">
      <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">Time Block</th>
      <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">Start</th>
      <th style="padding: 6px; border: 1px solid %s; font-size: 11px; color: white;">End</th>
      <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Duration</th>
      <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Cost</th>
      <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">$/hr</th>
      <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Tokens</th>
      <th style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: white;">Tok/hr</th>
    </tr>', accent_orange, "#607D8B",
            dark_border, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border, dark_border))

        for (i in seq_len(nrow(activity_df))) {
          bg <- if (i %% 2 == 0) dark_row_alt else dark_card
          # Format time block as readable range (e.g., "Jan 16 10:00-15:00")
          time_block <- sprintf("%s %s-%s",
            format(activity_df$start[i], "%b %d"),
            format(activity_df$start[i], "%H:%M"),
            format(activity_df$end[i], "%H:%M"))
          email_body <- paste0(email_body, sprintf('
    <tr style="background-color: %s;">
      <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
      <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
      <td style="padding: 6px; border: 1px solid %s; font-size: 11px; color: %s;">%s</td>
      <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
      <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
      <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
      <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
      <td style="padding: 6px; border: 1px solid %s; text-align: right; font-size: 11px; color: %s;">%s</td>
    </tr>',
            bg,
            dark_border, dark_text, time_block,
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

  # Top Sessions by Cost - NOW AT THE END
  if (!is.null(session_data) && nrow(session_data) > 0) {
    top_sessions <- session_data |>
      arrange(desc(totalCost)) |>
      head(5)

    email_body <- paste0(email_body, sprintf('
  <h3 style="color: %s;">Top Sessions by Cost</h3>
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
      email_body <- paste0(email_body, sprintf('
    <tr style="background-color: %s;">
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

  email_body <- paste0(email_body, sprintf('
  <hr style="margin-top: 20px; border-color: %s;">
  <p style="color: %s; font-size: 12px;">
    <a href="https://github.com/JohnGavin/llm" style="color: %s;">llm project</a> |
    <a href="https://johngavin.github.io/llm/vignettes/telemetry.html" style="color: %s;">Dashboard</a> |
    Refresh: <code style="background-color: %s; padding: 2px 6px; border-radius: 3px; color: %s;">Rscript R/scripts/refresh_ccusage_cache.R</code>
  </p>
  </div>
  ', dark_border, dark_muted, accent_blue, accent_blue, dark_card, dark_text))
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
