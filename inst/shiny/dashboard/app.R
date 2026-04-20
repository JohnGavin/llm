# Personal Productivity Dashboard
# Reads from ~/.claude/logs/unified.duckdb
# Stack: shiny + bslib + plotly + DT + duckdb

# ---- helpers ----------------------------------------------------------------

db_path <- path.expand("~/.claude/logs/unified.duckdb")

# Open-close per query: avoids holding a persistent read-only lock on DuckDB.
# Even read_only = TRUE blocks writers in DuckDB; releasing immediately is safer.
query_db <- function(sql, fallback = data.frame()) {
  con <- NULL
  tryCatch({
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = TRUE)
    result <- DBI::dbGetQuery(con, sql)
    DBI::dbDisconnect(con, shutdown = TRUE)
    result
  }, error = function(e) {
    if (!is.null(con)) {
      tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e2) NULL)
    }
    fallback
  })
}

# Compact metric table (2-col) replacing value_box
metric_table_ui <- function(metrics) {
  rows <- lapply(seq_len(nrow(metrics)), function(i) {
    shiny::tags$tr(
      shiny::tags$td(
        style = "color:#aaa; padding:4px 12px 4px 4px; font-size:0.85rem;",
        metrics$metric[i]
      ),
      shiny::tags$td(
        style = "color:#fff; padding:4px; font-weight:600; font-size:0.95rem;",
        metrics$value[i]
      )
    )
  })
  shiny::tags$table(
    style = "border-collapse:collapse; margin-bottom:8px;",
    shiny::tags$tbody(rows)
  )
}

plotly_dark_layout <- function(p, title = NULL) {
  plotly::layout(
    p,
    title         = if (!is.null(title)) list(text = title, font = list(color = "#fff")) else NULL,
    paper_bgcolor = "#000000",
    plot_bgcolor  = "#000000",
    font          = list(color = "#ffffff"),
    xaxis         = list(gridcolor = "#333", zerolinecolor = "#333", color = "#fff"),
    yaxis         = list(gridcolor = "#333", zerolinecolor = "#333", color = "#fff"),
    legend        = list(
      orientation = "h", xanchor = "center", x = 0.5,
      yanchor = "top", y = -0.15,
      bgcolor = "#000000", bordercolor = "#444", borderwidth = 1,
      font = list(color = "#ffffff", size = 12)
    ),
    margin        = list(t = 40, r = 20, b = 70, l = 50)
  ) |> plotly::config(scrollZoom = TRUE)
}

# ---- roborev helpers --------------------------------------------------------

roborev_data <- function() {
  tryCatch({
    json_text <- system2(
      "/usr/local/bin/roborev", c("list", "--json"),
      stdout = TRUE, stderr = FALSE
    )
    jsonlite::fromJSON(paste(json_text, collapse = "\n"))
  }, error = function(e) data.frame())
}

roborev_summary <- function() {
  tryCatch({
    json_text <- system2(
      "/usr/local/bin/roborev", c("summary", "--json"),
      stdout = TRUE, stderr = FALSE
    )
    jsonlite::fromJSON(paste(json_text, collapse = "\n"))
  }, error = function(e) list())
}

roborev_status <- function() {
  tryCatch({
    text <- system2(
      "/usr/local/bin/roborev", c("status"),
      stdout = TRUE, stderr = FALSE
    )
    paste(text, collapse = "\n")
  }, error = function(e) "roborev not available")
}

# ---- UI ---------------------------------------------------------------------

ui <- bslib::page_sidebar(
  title = "Productivity Dashboard",
  theme = bslib::bs_theme(bootswatch = "darkly"),

  # Force black backgrounds on plotly containers — overrides darkly card bleed
  shiny::tags$style("
    .plotly .main-svg { background: #000000 !important; }
    .js-plotly-plot .plotly .modebar { background: transparent !important; }
    .card-body { background-color: #1a1a2e !important; }
  "),

  # --- sidebar ---
  sidebar = bslib::sidebar(
    shiny::dateRangeInput(
      "date_range",
      "Date range",
      start = Sys.Date() - 90,
      end   = Sys.Date()
    ),
    shiny::uiOutput("project_filter_ui"),
    shiny::actionButton(
      "refresh",
      "Refresh",
      icon  = shiny::icon("rotate"),
      class = "btn-sm btn-secondary w-100 mt-2"
    )
  ),

  # --- main tabs ---
  bslib::navset_card_tab(

    # Tab 1: Overview --------------------------------------------------------
    bslib::nav_panel(
      "Overview",

      shiny::fluidRow(
        shiny::column(12, shiny::uiOutput("overview_metrics"))
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Daily cost by model", style = "color:#aaa; margin-top:16px;"),
          plotly::plotlyOutput("daily_cost_bar", height = "280px")
        )
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Daily sessions by project", style = "color:#aaa; margin-top:16px;"),
          plotly::plotlyOutput("daily_sessions_project", height = "260px")
        )
      )
    ),

    # Tab 2: Costs -----------------------------------------------------------
    bslib::nav_panel(
      "Costs",

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Cumulative cost vs $500 cap", style = "color:#aaa; margin-top:8px;"),
          plotly::plotlyOutput("cumulative_cost_line", height = "260px")
        )
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Model mix over time", style = "color:#aaa; margin-top:16px;"),
          plotly::plotlyOutput("model_mix_area", height = "240px")
        )
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Costs by day", style = "color:#aaa; margin-top:16px;"),
          DT::dataTableOutput("costs_tbl")
        )
      )
    ),

    # Tab 3: Budget ----------------------------------------------------------
    bslib::nav_panel(
      "Budget",

      shiny::uiOutput("budget_alert"),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Weekly budget status", style = "color:#aaa; margin-top:8px;"),
          shiny::uiOutput("budget_metrics")
        )
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Week spend vs cap", style = "color:#aaa; margin-top:16px;"),
          shiny::uiOutput("budget_progress_bar")
        )
      )
    ),

    # Tab 4: Time ------------------------------------------------------------
    bslib::nav_panel(
      "Time",

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Daily session time by project (last 10 days)", style = "color:#aaa; margin-top:8px;"),
          plotly::plotlyOutput("daily_time_project", height = "280px")
        )
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Recent sessions", style = "color:#aaa; margin-top:16px;"),
          DT::dataTableOutput("recent_sessions_tbl")
        )
      )
    ),

    # Tab 5: Reviews ---------------------------------------------------------
    bslib::nav_panel(
      "Reviews",

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("roborev status", style = "color:#aaa; margin-top:8px;"),
          shiny::uiOutput("roborev_status_ui")
        )
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Review metrics", style = "color:#aaa; margin-top:16px;"),
          shiny::uiOutput("roborev_metrics_ui")
        )
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Recent reviews", style = "color:#aaa; margin-top:16px;"),
          DT::dataTableOutput("roborev_tbl")
        )
      )
    ),

    # Tab 6: Errors ----------------------------------------------------------
    bslib::nav_panel(
      "Errors",

      shiny::fluidRow(
        shiny::column(12, shiny::uiOutput("error_metrics"))
      ),

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("All errors (newest first)", style = "color:#aaa; margin-top:16px;"),
          DT::dataTableOutput("errors_tbl")
        )
      )
    ),

    # Tab 7: Brain Dumps -----------------------------------------------------
    bslib::nav_panel(
      "Brain Dumps",

      shiny::fluidRow(
        shiny::column(
          12,
          shiny::h6("Brain dumps (newest first)", style = "color:#aaa; margin-top:8px;"),
          DT::dataTableOutput("braindumps_tbl")
        )
      )
    )
  )
)

# ---- Server -----------------------------------------------------------------

server <- function(input, output, session) {

  # Auto-refresh every 30 s
  shiny::observe({
    shiny::invalidateLater(30000, session)
    input$refresh  # also trigger on manual refresh
  })

  # Reactive: filter bounds
  start_dt <- shiny::reactive(as.character(input$date_range[1]))
  end_dt   <- shiny::reactive(as.character(input$date_range[2]))

  # Project choices --------------------------------------------------------
  projects_df <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      "SELECT DISTINCT project FROM sessions WHERE project IS NOT NULL ORDER BY project",
      data.frame(project = character(0))
    )
  })

  output$project_filter_ui <- shiny::renderUI({
    choices <- c("All", projects_df()$project)
    shiny::selectInput(
      "project_filter", "Project",
      choices   = choices,
      selected  = "All",
      selectize = FALSE
    )
  })

  project_clause <- shiny::reactive({
    req <- input$project_filter
    if (is.null(req) || req == "All") "" else paste0(" AND project = '", req, "'")
  })

  # ---- Overview tab --------------------------------------------------------

  sessions_today <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      paste0(
        "SELECT COUNT(*) AS n FROM sessions ",
        "WHERE CAST(started_at AS DATE) = CAST(current_date AS DATE)",
        project_clause()
      ),
      data.frame(n = 0L)
    )$n
  })

  cost_this_week <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      "SELECT COALESCE(SUM(total_cost), 0) AS total FROM costs WHERE date >= CAST(current_date - INTERVAL '6 days' AS DATE)",
      data.frame(total = 0)
    )$total
  })

  output$overview_metrics <- shiny::renderUI({
    metrics <- data.frame(
      metric = c("Sessions today", "Cost this week"),
      value  = c(
        as.character(sessions_today()),
        sprintf("$%.2f", cost_this_week())
      )
    )
    metric_table_ui(metrics)
  })

  # Daily cost bar chart by model
  daily_cost_data <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      paste0(
        "SELECT date, opus_cost, sonnet_cost, haiku_cost FROM costs ",
        "WHERE date BETWEEN '", start_dt(), "' AND '", end_dt(), "' ",
        "ORDER BY date"
      ),
      data.frame(
        date        = as.Date(character(0)),
        opus_cost   = numeric(0),
        sonnet_cost = numeric(0),
        haiku_cost  = numeric(0)
      )
    )
  })

  output$daily_cost_bar <- plotly::renderPlotly({
    df <- daily_cost_data()
    if (nrow(df) == 0) {
      p <- plotly::plot_ly(type = "bar") |>
        plotly::add_annotations(
          text = "No cost data for selected range",
          x = 0.5, y = 0.5, xref = "paper", yref = "paper",
          showarrow = FALSE, font = list(color = "#aaa", size = 14)
        )
      return(plotly_dark_layout(p))
    }
    p <- plotly::plot_ly(df, x = ~date) |>
      plotly::add_bars(y = ~opus_cost,   name = "Opus",   marker = list(color = "#e74c3c")) |>
      plotly::add_bars(y = ~sonnet_cost, name = "Sonnet", marker = list(color = "#3498db")) |>
      plotly::add_bars(y = ~haiku_cost,  name = "Haiku",  marker = list(color = "#2ecc71")) |>
      plotly::layout(barmode = "stack", yaxis = list(title = "USD"))
    plotly_dark_layout(p)
  })

  # Daily sessions by project (stacked bar)
  daily_sessions_proj_data <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      paste0(
        "SELECT CAST(started_at AS DATE) AS date, ",
        "COALESCE(project, 'unknown') AS project, ",
        "COUNT(*) AS n_sessions ",
        "FROM sessions ",
        "WHERE CAST(started_at AS DATE) BETWEEN '", start_dt(), "' AND '", end_dt(), "'",
        project_clause(),
        " GROUP BY date, project ORDER BY date"
      ),
      data.frame(
        date       = as.Date(character(0)),
        project    = character(0),
        n_sessions = integer(0)
      )
    )
  })

  output$daily_sessions_project <- plotly::renderPlotly({
    df <- daily_sessions_proj_data()
    if (nrow(df) == 0) {
      p <- plotly::plot_ly(type = "bar") |>
        plotly::add_annotations(
          text = "No session data for selected range",
          x = 0.5, y = 0.5, xref = "paper", yref = "paper",
          showarrow = FALSE, font = list(color = "#aaa", size = 14)
        )
      return(plotly_dark_layout(p))
    }
    projects <- unique(df$project)
    p <- plotly::plot_ly()
    for (proj in projects) {
      sub <- df[df$project == proj, ]
      p <- plotly::add_bars(p, x = sub$date, y = sub$n_sessions, name = proj)
    }
    p <- plotly::layout(p, barmode = "stack", yaxis = list(title = "Sessions"))
    plotly_dark_layout(p)
  })

  # ---- Costs tab -----------------------------------------------------------

  costs_all <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      paste0(
        "SELECT date, total_cost, opus_cost, sonnet_cost, haiku_cost, ",
        "opus_pct, sonnet_pct, haiku_pct FROM costs ",
        "WHERE date BETWEEN '", start_dt(), "' AND '", end_dt(), "' ",
        "ORDER BY date"
      ),
      data.frame(
        date        = as.Date(character(0)),
        total_cost  = numeric(0),
        opus_cost   = numeric(0), sonnet_cost = numeric(0), haiku_cost = numeric(0),
        opus_pct    = numeric(0), sonnet_pct  = numeric(0), haiku_pct  = numeric(0)
      )
    )
  })

  output$cumulative_cost_line <- plotly::renderPlotly({
    df <- costs_all()
    if (nrow(df) == 0) {
      p <- plotly::plot_ly(type = "scatter", mode = "lines") |>
        plotly::add_annotations(
          text = "No cost data for selected range",
          x = 0.5, y = 0.5, xref = "paper", yref = "paper",
          showarrow = FALSE, font = list(color = "#aaa", size = 14)
        )
      return(plotly_dark_layout(p))
    }
    df$cumcost <- cumsum(df$total_cost)
    cap <- 500
    p <- plotly::plot_ly(df, x = ~date) |>
      plotly::add_lines(
        y = ~cumcost, name = "Cumulative cost",
        line = list(color = "#3498db", width = 2)
      ) |>
      plotly::add_lines(
        x = range(df$date), y = c(cap, cap), name = "$500 cap",
        line = list(color = "#e74c3c", dash = "dash", width = 1.5)
      ) |>
      plotly::layout(yaxis = list(title = "USD"))
    plotly_dark_layout(p, "Cumulative cost vs $500 cap")
  })

  output$model_mix_area <- plotly::renderPlotly({
    df <- costs_all()
    if (nrow(df) == 0) {
      p <- plotly::plot_ly(type = "scatter", mode = "lines") |>
        plotly::add_annotations(
          text = "No cost data for selected range",
          x = 0.5, y = 0.5, xref = "paper", yref = "paper",
          showarrow = FALSE, font = list(color = "#aaa", size = 14)
        )
      return(plotly_dark_layout(p))
    }
    p <- plotly::plot_ly(df, x = ~date) |>
      plotly::add_lines(
        y = ~opus_pct, name = "Opus %",
        stackgroup = "one", fillcolor = "rgba(231,76,60,0.5)",
        line = list(color = "#e74c3c")
      ) |>
      plotly::add_lines(
        y = ~sonnet_pct, name = "Sonnet %",
        stackgroup = "one", fillcolor = "rgba(52,152,219,0.5)",
        line = list(color = "#3498db")
      ) |>
      plotly::add_lines(
        y = ~haiku_pct, name = "Haiku %",
        stackgroup = "one", fillcolor = "rgba(46,204,113,0.5)",
        line = list(color = "#2ecc71")
      ) |>
      plotly::layout(yaxis = list(title = "%", range = c(0, 100)))
    plotly_dark_layout(p, "Model mix (%)")
  })

  output$costs_tbl <- DT::renderDataTable({
    df <- costs_all()
    if (nrow(df) == 0) {
      df <- data.frame(message = "No cost data found")
    } else {
      df <- df[order(df$date, decreasing = TRUE), ]
      numeric_cols <- c("total_cost", "opus_cost", "sonnet_cost", "haiku_cost",
                        "opus_pct", "sonnet_pct", "haiku_pct")
      for (col in intersect(numeric_cols, names(df))) {
        df[[col]] <- round(df[[col]], 4)
      }
    }
    DT::datatable(
      df,
      caption  = "Daily costs",
      rownames = FALSE,
      options  = list(pageLength = 15, dom = "tp", scrollX = TRUE)
    )
  })

  # ---- Budget tab ----------------------------------------------------------

  # Tuesday-start week: days since last Tuesday
  week_start_date <- shiny::reactive({
    today <- Sys.Date()
    # DOW: 0=Sun,1=Mon,2=Tue,...,6=Sat. Tuesday=2.
    # Days since last Tuesday: (dow - 2 + 7) %% 7
    dow <- as.integer(format(today, "%w"))
    days_back <- (dow - 2L + 7L) %% 7L
    today - days_back
  })

  budget_cap <- shiny::reactive({
    cap_env <- Sys.getenv("CLAUDE_WEEKLY_CAP_USD", unset = "500")
    val <- suppressWarnings(as.numeric(cap_env))
    if (is.na(val) || val <= 0) 500 else val
  })

  week_spend_data <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    ws <- as.character(week_start_date())
    query_db(
      paste0(
        "SELECT COALESCE(SUM(total_cost), 0) AS week_total FROM costs ",
        "WHERE date >= '", ws, "'"
      ),
      data.frame(week_total = 0)
    )
  })

  week_spend <- shiny::reactive({
    week_spend_data()$week_total
  })

  budget_projection <- shiny::reactive({
    ws   <- week_start_date()
    days_elapsed <- as.numeric(Sys.Date() - ws) + 1
    spend <- week_spend()
    daily_rate  <- if (days_elapsed > 0) spend / days_elapsed else 0
    projected   <- daily_rate * 7
    days_remaining <- 7 - days_elapsed
    list(
      spend          = spend,
      cap            = budget_cap(),
      pct_used       = if (budget_cap() > 0) spend / budget_cap() * 100 else 0,
      projected      = projected,
      days_elapsed   = days_elapsed,
      days_remaining = max(0, days_remaining),
      week_start     = ws
    )
  })

  output$budget_alert <- shiny::renderUI({
    b <- budget_projection()
    if (b$projected > b$cap) {
      shiny::div(
        style = paste0(
          "background:#e74c3c; color:white; padding:8px 16px; ",
          "border-radius:4px; margin-bottom:12px;"
        ),
        paste0(
          "\u26a0 BUDGET ALERT: Projected $", round(b$projected, 0),
          " exceeds $", b$cap, " weekly cap"
        )
      )
    }
  })

  output$budget_metrics <- shiny::renderUI({
    b <- budget_projection()
    pct_color <- if (b$pct_used >= 80) "#e74c3c" else if (b$pct_used >= 60) "#f39c12" else "#2ecc71"
    metrics <- data.frame(
      metric = c(
        "Weekly spend", "Weekly cap", "% used",
        "Projected week-end", "Days remaining in week"
      ),
      value = c(
        sprintf("$%.2f", b$spend),
        sprintf("$%.0f", b$cap),
        paste0(round(b$pct_used, 1), "%"),
        sprintf("$%.2f", b$projected),
        as.character(b$days_remaining)
      ),
      stringsAsFactors = FALSE
    )
    rows <- lapply(seq_len(nrow(metrics)), function(i) {
      val_color <- if (metrics$metric[i] == "% used") pct_color else "#fff"
      shiny::tags$tr(
        shiny::tags$td(
          style = "color:#aaa; padding:4px 12px 4px 4px; font-size:0.85rem;",
          metrics$metric[i]
        ),
        shiny::tags$td(
          style = paste0("color:", val_color, "; padding:4px; font-weight:600; font-size:0.95rem;"),
          metrics$value[i]
        )
      )
    })
    shiny::tags$table(
      style = "border-collapse:collapse; margin-bottom:8px;",
      shiny::tags$tbody(rows)
    )
  })

  output$budget_progress_bar <- shiny::renderUI({
    b   <- budget_projection()
    pct <- min(100, b$pct_used)
    bar_color <- if (pct >= 80) "#e74c3c" else if (pct >= 60) "#f39c12" else "#2ecc71"
    shiny::div(
      style = "margin: 8px 0 16px 0;",
      shiny::div(
        style = paste0(
          "background:#333; border-radius:4px; height:24px; ",
          "width:100%; position:relative;"
        ),
        shiny::div(
          style = paste0(
            "background:", bar_color, "; border-radius:4px; height:24px; ",
            "width:", round(pct, 1), "%; position:absolute; top:0; left:0;"
          )
        ),
        shiny::div(
          style = paste0(
            "position:absolute; top:0; left:0; width:100%; height:24px; ",
            "display:flex; align-items:center; justify-content:center; ",
            "color:#fff; font-size:0.85rem; font-weight:600;"
          ),
          paste0(round(pct, 1), "% of $", round(b$cap, 0), " cap")
        )
      )
    )
  })

  # ---- Time tab ------------------------------------------------------------

  # Daily session time by project (last 10 days)
  daily_time_proj_data <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    cutoff <- as.character(Sys.Date() - 10)
    query_db(
      paste0(
        "SELECT CAST(started_at AS DATE) AS date, ",
        "COALESCE(project, 'unknown') AS project, ",
        "ROUND(SUM(COALESCE(duration_min, 0)), 1) AS total_min ",
        "FROM sessions ",
        "WHERE CAST(started_at AS DATE) >= '", cutoff, "'",
        project_clause(),
        " GROUP BY date, project ORDER BY date DESC"
      ),
      data.frame(
        date      = as.Date(character(0)),
        project   = character(0),
        total_min = numeric(0)
      )
    )
  })

  output$daily_time_project <- plotly::renderPlotly({
    df <- daily_time_proj_data()
    if (nrow(df) == 0) {
      p <- plotly::plot_ly(type = "bar") |>
        plotly::add_annotations(
          text = "No session time data for last 10 days",
          x = 0.5, y = 0.5, xref = "paper", yref = "paper",
          showarrow = FALSE, font = list(color = "#aaa", size = 14)
        )
      return(plotly_dark_layout(p))
    }
    projects <- unique(df$project)
    p <- plotly::plot_ly()
    for (proj in projects) {
      sub <- df[df$project == proj, ]
      p <- plotly::add_bars(p, x = sub$date, y = sub$total_min, name = proj)
    }
    p <- plotly::layout(p, barmode = "stack", yaxis = list(title = "Minutes"))
    plotly_dark_layout(p)
  })

  # Recent sessions table
  recent_sessions_data <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      paste0(
        "SELECT project, started_at, ROUND(duration_min, 1) AS duration_min, COALESCE(summary, '') AS summary ",
        "FROM sessions WHERE started_at IS NOT NULL",
        project_clause(),
        " ORDER BY started_at DESC LIMIT 30"
      ),
      data.frame(
        project      = character(0), started_at = character(0),
        duration_min = numeric(0),   summary    = character(0)
      )
    )
  })

  output$recent_sessions_tbl <- DT::renderDataTable({
    df <- recent_sessions_data()
    if (nrow(df) == 0) df <- data.frame(message = "No sessions found")
    DT::datatable(
      df,
      caption   = "Recent sessions",
      rownames  = FALSE,
      options   = list(
        pageLength = 10, dom = "t", scrollX = TRUE,
        initComplete = DT::JS(
          "function(settings, json) { $(this.api().table().node()).css('font-size', '0.82rem'); }"
        )
      )
    )
  })

  # ---- Reviews tab ---------------------------------------------------------

  # Cache roborev calls for 60 seconds
  roborev_cache <- shiny::reactiveValues(
    data       = NULL,
    summary    = NULL,
    status_txt = NULL,
    last_fetch = NULL
  )

  roborev_refresh <- shiny::reactive({
    shiny::invalidateLater(60000, session)
    input$refresh
    now <- Sys.time()
    needs_fetch <- is.null(roborev_cache$last_fetch) ||
      as.numeric(difftime(now, roborev_cache$last_fetch, units = "secs")) > 60
    if (needs_fetch) {
      roborev_cache$data       <- roborev_data()
      roborev_cache$summary    <- roborev_summary()
      roborev_cache$status_txt <- roborev_status()
      roborev_cache$last_fetch <- now
    }
    roborev_cache$last_fetch
  })

  output$roborev_status_ui <- shiny::renderUI({
    roborev_refresh()
    txt <- roborev_cache$status_txt
    if (is.null(txt)) txt <- "roborev not available"
    shiny::tags$pre(
      style = paste0(
        "background:#111; color:#ccc; padding:10px 14px; ",
        "border-radius:4px; font-size:0.82rem; white-space:pre-wrap; ",
        "max-height:140px; overflow-y:auto;"
      ),
      txt
    )
  })

  output$roborev_metrics_ui <- shiny::renderUI({
    roborev_refresh()
    df  <- roborev_cache$data
    if (is.null(df) || !is.data.frame(df) || nrow(df) == 0) {
      return(shiny::p(
        style = "color:#aaa; font-size:0.85rem;",
        "roborev is not installed or returned no data."
      ))
    }
    total   <- nrow(df)
    passed  <- if ("status" %in% names(df)) sum(df$status == "passed",  na.rm = TRUE) else NA
    failed  <- if ("status" %in% names(df)) sum(df$status == "failed",  na.rm = TRUE) else NA
    pending <- if ("status" %in% names(df)) sum(df$status == "pending", na.rm = TRUE) else NA
    metrics <- data.frame(
      metric = c("Total reviews", "Passed", "Failed", "Pending"),
      value  = c(
        as.character(total),
        if (is.na(passed))  "n/a" else as.character(passed),
        if (is.na(failed))  "n/a" else as.character(failed),
        if (is.na(pending)) "n/a" else as.character(pending)
      ),
      stringsAsFactors = FALSE
    )
    metric_table_ui(metrics)
  })

  output$roborev_tbl <- DT::renderDataTable({
    roborev_refresh()
    df <- roborev_cache$data
    if (is.null(df) || !is.data.frame(df) || nrow(df) == 0) {
      df <- data.frame(message = "roborev is not installed or returned no data")
    } else {
      keep <- intersect(c("commit", "repo", "status", "agent", "created_at"), names(df))
      if (length(keep) > 0) df <- df[, keep, drop = FALSE]
    }
    DT::datatable(
      df,
      caption  = "Recent reviews",
      rownames = FALSE,
      options  = list(pageLength = 20, dom = "tp", scrollX = TRUE)
    )
  })

  # ---- Errors tab ----------------------------------------------------------

  errors_data <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      paste0(
        "SELECT logged_at, source, ",
        "SUBSTRING(error_text, 1, 100) AS error_text ",
        "FROM errors ",
        "WHERE logged_at BETWEEN '", start_dt(), "' AND '",
        end_dt(), " 23:59:59' ",
        "ORDER BY logged_at DESC"
      ),
      data.frame(logged_at = character(0), source = character(0), error_text = character(0))
    )
  })

  errors_today_n <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      "SELECT COUNT(*) AS n FROM errors WHERE CAST(logged_at AS DATE) = CAST(current_date AS DATE)",
      data.frame(n = 0L)
    )$n
  })

  errors_week_n <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      "SELECT COUNT(*) AS n FROM errors WHERE logged_at >= current_date - INTERVAL '6 days'",
      data.frame(n = 0L)
    )$n
  })

  output$error_metrics <- shiny::renderUI({
    metrics <- data.frame(
      metric = c("Errors today", "Errors this week"),
      value  = c(
        as.character(errors_today_n()),
        as.character(errors_week_n())
      )
    )
    metric_table_ui(metrics)
  })

  output$errors_tbl <- DT::renderDataTable({
    df <- errors_data()
    if (nrow(df) == 0) df <- data.frame(message = "No errors in selected range")
    DT::datatable(
      df,
      caption  = "Errors",
      rownames = FALSE,
      options  = list(pageLength = 20, dom = "tp", scrollX = TRUE)
    )
  })

  # ---- Brain Dumps tab -----------------------------------------------------

  braindumps_data <- shiny::reactive({
    shiny::invalidateLater(30000, session)
    input$refresh
    query_db(
      paste0(
        "SELECT id, captured_at, source, ",
        "SUBSTRING(raw_text, 1, 200) AS raw_text ",
        "FROM braindumps ",
        "WHERE captured_at BETWEEN '", start_dt(), "' AND '",
        end_dt(), " 23:59:59' ",
        "ORDER BY captured_at DESC"
      ),
      data.frame(
        id = integer(0), captured_at = character(0),
        source = character(0), raw_text = character(0)
      )
    )
  })

  output$braindumps_tbl <- DT::renderDataTable({
    df <- braindumps_data()
    if (nrow(df) == 0) {
      df <- data.frame(message = "No brain dumps in selected range")
    }
    DT::datatable(
      df,
      caption   = "Brain dumps",
      rownames  = FALSE,
      options   = list(pageLength = 15, dom = "tp", scrollX = TRUE)
    )
  })
}

# ---- Run --------------------------------------------------------------------

shiny::shinyApp(ui, server)
