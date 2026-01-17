# send_daily_email.R
# Send daily LLM usage report via Gmail
# Called from GitHub Actions workflow: .github/workflows/daily-llm-report.yaml

library(blastula)
library(dplyr)
library(tibble)
library(jsonlite)
library(purrr)

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

has_data <- !is.null(daily_raw) || !is.null(session_raw)

# Parse daily data
parse_daily <- function(json) {
  if (is.null(json$projects)) return(NULL)
  projects <- names(json$projects)
  map_dfr(projects, function(p) {
    d <- json$projects[[p]]
    if (is.null(d) || length(d) == 0) return(NULL)
    as_tibble(d) |> mutate(project = p)
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
  <h2>LLM Usage Report - %s</h2>
  <div style="background-color: #fff3cd; border: 1px solid #ffc107; padding: 15px; border-radius: 5px;">
    <strong>No cached data available</strong>
    <p>Run locally: <code>Rscript R/scripts/refresh_ccusage_cache.R</code></p>
  </div>
  ', today)
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

  # Build email
  email_body <- sprintf('
  <h2>LLM Usage Report - %s</h2>
  <p style="color: #666; font-size: 12px;">Data cached: %s</p>

  <h3>Summary</h3>
  <table style="border-collapse: collapse; max-width: 400px;">
    <tr style="background-color: #f2f2f2;">
      <td style="padding: 8px; border: 1px solid #ddd;"><strong>Total Cost</strong></td>
      <td style="padding: 8px; border: 1px solid #ddd;">%s</td>
    </tr>
    <tr>
      <td style="padding: 8px; border: 1px solid #ddd;"><strong>Total Tokens</strong></td>
      <td style="padding: 8px; border: 1px solid #ddd;">%s</td>
    </tr>
    <tr style="background-color: #f2f2f2;">
      <td style="padding: 8px; border: 1px solid #ddd;"><strong>Sessions</strong></td>
      <td style="padding: 8px; border: 1px solid #ddd;">%d</td>
    </tr>
  </table>

  <h3>Weekly Cost</h3>
  <table style="border-collapse: collapse; max-width: 400px;">
    <tr style="background-color: #4CAF50; color: white;">
      <th style="padding: 8px; border: 1px solid #ddd;">Period</th>
      <th style="padding: 8px; border: 1px solid #ddd; text-align: right;">Cost</th>
    </tr>
    <tr>
      <td style="padding: 8px; border: 1px solid #ddd;">Week 1 (current)</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
    <tr style="background-color: #f2f2f2;">
      <td style="padding: 8px; border: 1px solid #ddd;">Week 2</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
    <tr>
      <td style="padding: 8px; border: 1px solid #ddd;">Week 3</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
    <tr style="background-color: #f2f2f2;">
      <td style="padding: 8px; border: 1px solid #ddd;">Week 4</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
  </table>

  <h3>Weekly Tokens</h3>
  <table style="border-collapse: collapse; max-width: 400px;">
    <tr style="background-color: #2196F3; color: white;">
      <th style="padding: 8px; border: 1px solid #ddd;">Period</th>
      <th style="padding: 8px; border: 1px solid #ddd; text-align: right;">Tokens</th>
    </tr>
    <tr>
      <td style="padding: 8px; border: 1px solid #ddd;">Week 1 (current)</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
    <tr style="background-color: #f2f2f2;">
      <td style="padding: 8px; border: 1px solid #ddd;">Week 2</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
    <tr>
      <td style="padding: 8px; border: 1px solid #ddd;">Week 3</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
    <tr style="background-color: #f2f2f2;">
      <td style="padding: 8px; border: 1px solid #ddd;">Week 4</td>
      <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
    </tr>
  </table>

  <h3>Top Sessions by Cost</h3>
  ', today, cache_time,
     dollar(total_cost), millions(total_tokens), n_sessions,
     dollar(week1$cost), dollar(week2$cost), dollar(week3$cost), dollar(week4$cost),
     millions(week1$tokens), millions(week2$tokens), millions(week3$tokens), millions(week4$tokens))

  if (!is.null(session_data) && nrow(session_data) > 0) {
    top_sessions <- session_data |>
      arrange(desc(totalCost)) |>
      head(5)

    session_table <- '<table style="border-collapse: collapse; width: 100%;">
      <tr style="background-color: #9C27B0; color: white;">
        <th style="padding: 8px; border: 1px solid #ddd;">Session</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: right;">Cost</th>
        <th style="padding: 8px; border: 1px solid #ddd; text-align: right;">Tokens</th>
        <th style="padding: 8px; border: 1px solid #ddd;">Last Active</th>
      </tr>'

    for (i in seq_len(nrow(top_sessions))) {
      bg <- if (i %% 2 == 0) "background-color: #f2f2f2;" else ""
      session_table <- paste0(session_table, sprintf('
        <tr style="%s">
          <td style="padding: 8px; border: 1px solid #ddd;">%s</td>
          <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
          <td style="padding: 8px; border: 1px solid #ddd; text-align: right;">%s</td>
          <td style="padding: 8px; border: 1px solid #ddd;">%s</td>
        </tr>',
        bg,
        substr(top_sessions$sessionId[i], 1, 40),
        dollar(top_sessions$totalCost[i]),
        millions(top_sessions$totalTokens[i]),
        top_sessions$lastActivity[i]
      ))
    }
    session_table <- paste0(session_table, "</table>")
    email_body <- paste0(email_body, session_table)
  }

  email_body <- paste0(email_body, '
  <hr style="margin-top: 20px;">
  <p style="color: #666; font-size: 12px;">
    <a href="https://github.com/JohnGavin/llm">llm project</a> |
    <a href="https://johngavin.github.io/llm/articles/telemetry.html">Dashboard</a> |
    Refresh: <code>Rscript R/scripts/refresh_ccusage_cache.R</code>
  </p>
  ')
}

# Create and send email
london_time <- format(Sys.time(), tz = "Europe/London", "%Y-%m-%d %H:%M")
email <- compose_email(
  body = md(email_body),
  footer = md(sprintf("Report generated: %s (London)", london_time))
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
