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
      bgcolor = "#000000", bordercolor = "#333", font = list(color = "#ffffff", size = 12)
    ),
    margin        = list(t = 40, r = 20, b = 70, l = 50)
  ) |> plotly::config(scrollZoom = TRUE)
}

# ---- UI ---------------------------------------------------------------------

ui <- bslib::page_sidebar(
  title = "Productivity Dashboard",
  theme = bslib::bs_theme(bootswatch = "darkly"),

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

    # Tab 3: Time ------------------------------------------------------------
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

    # Tab 4: Errors ----------------------------------------------------------
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

    # Tab 5: Brain Dumps -----------------------------------------------------
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

  # Recent sessions table (moved from Overview)
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
