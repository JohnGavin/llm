# R/tar_plans/plan_vignette_outputs.R
# Targets for telemetry vignette outputs
# Every plot, table, and summary displayed in the vignette is a target here.

library(targets)

# Shared black-background / white-ink ggplot theme for every telemetry plot
# (accessibility: dark-mode-completeness rule — black #000000, white #ffffff,
# never dark blue/grey placeholders). Defined here (not exported) so it is
# available inside every tar_target() expression across the telemetry plans,
# since all R/ files compile into one package namespace.
theme_dashboard <- function(base_size = 14) {
  ggplot2::theme_minimal(base_size = base_size) +
    ggplot2::theme(
      plot.background    = ggplot2::element_rect(fill = "#000000", color = NA),
      panel.background   = ggplot2::element_rect(fill = "#000000", color = NA),
      legend.background  = ggplot2::element_rect(fill = "#000000", color = NA),
      strip.background   = ggplot2::element_rect(fill = "#000000", color = "#ffffff"),
      panel.grid.major   = ggplot2::element_line(color = "#ffffff", linewidth = 0.3),
      panel.grid.minor   = ggplot2::element_line(color = "#ffffff", linewidth = 0.15),
      text          = ggplot2::element_text(color = "#ffffff"),
      axis.text     = ggplot2::element_text(color = "#ffffff"),
      axis.title    = ggplot2::element_text(color = "#ffffff"),
      plot.title    = ggplot2::element_text(color = "#ffffff", face = "bold"),
      plot.subtitle = ggplot2::element_text(color = "#ffffff"),
      strip.text    = ggplot2::element_text(color = "#ffffff"),
      legend.text   = ggplot2::element_text(color = "#ffffff"),
      legend.title  = ggplot2::element_text(color = "#ffffff"),
      legend.position = "bottom"
    )
}

# Shared named palette for the LLM Usage/GitHub Activity telemetry pages
# (narrative-colour-persistence rule: same entity -> same colour everywhere).
# All hex values are >=4.5:1 contrast on #000000.
TELEMETRY_PALETTE <- c(
  "accent"      = "#4ea8de", # single-series lines/points (cost, commits, gemini, model-cost dots)
  "trend"       = "#f08080", # LOESS/trend overlay lines
  "Input"       = "#69d4a0", # token-type breakdown
  "Output"      = "#4ea8de",
  "Cache"       = "#ffd93d",
  "Last Week"   = "#69d4a0", # session-recency period
  "Older"       = "#c084fc"
)

# Fixed-size accessible qualitative palette used to colour dynamic, unbounded
# category sets (e.g. project names) that cannot be enumerated in a fixed
# named vector ahead of time. Recycled and named per-plot via setNames().
ACCESSIBLE_QUALITATIVE_COLORS <- c(
  "#4ea8de", "#69d4a0", "#ffd93d", "#f08080",
  "#c084fc", "#f4a261", "#2dd4bf", "#fb7185"
)

# Ratio/rate labeller (e.g. $/min): at most signif(x, 3) to avoid spurious
# precision on computed rates (visualization number-formatting rule).
label_dollar_signif <- function(x) paste0("$", signif(x, 3))

#' Vignette Output Targets
#'
#' All computation for vignettes/telemetry.qmd lives here.
#' The vignette itself contains only `safe_tar_read("vig_*")` calls.
#'
#' @return A list of target objects
#' @export
plan_vignette_outputs <- function() {
  list(
    # === Shared data targets ===
    tar_target(
      vig_daily_data,
      llm::load_cached_ccusage("daily", project_filter = NULL)
    ),

    # `vig_session_data` (`load_cached_ccusage("session", ...)`) was retired
    # here (JohnGavin/llm#877). It read this package's own bundled
    # `ccusage_session_all.json`, which is frozen at 2026-05-09 and has no
    # mechanism to refresh (the resolver deliberately keeps `session` reading
    # the local copy rather than falling back to llmtelemetry -- see
    # `ccusage_cache_file()` in R/ccusage.R). It is also structurally
    # unusable even if refreshed: `sessionId` holds a raw project path
    # rather than a unique identifier, and `projectPath` is a literal
    # placeholder (see #870). Nothing in this package or the vignettes ever
    # consumed the target -- confirmed via a full-repo grep before removal --
    # so retiring it drops dead weight rather than a working feature.
    # `vig_session_metrics` below is unaffected: it is built from
    # `vig_blocks_data` (ccusage Max5 blocks), a *different* file that
    # llmtelemetry refreshes daily and which is NOT frozen (#860/#869).
    # Do not reintroduce a target that reads `ccusage_session_all.json`
    # without first fixing its underlying freshness.

    # Resolved via llm:::ccusage_cache_dir() rather than here::here() -- the
    # blocks cache lives in llmtelemetry (#32) and was never restored to this
    # package, so the hardcoded path always missed and every downstream
    # session-efficiency target returned NULL (#860).
    tar_target(
      vig_blocks_data,
      tryCatch(
        {
          f <- llm:::ccusage_cache_file("blocks")
          if (is.null(f)) {
            cli::cli_warn("ccusage_blocks_all.json not found in package or llmtelemetry")
            NULL
          } else {
            jsonlite::fromJSON(f)
          }
        },
        error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL }
      )
    ),

    # === LLM Usage & Costs section ===

    # Dashboard status summary table
    tar_target(
      vig_usage_summary,
      {
        if (is.null(vig_daily_data) || nrow(vig_daily_data) == 0) return(NULL)
        summary_stats <- as.data.frame(llm::summarize_llm_usage(vig_daily_data))
        if (nrow(summary_stats) == 0) return(NULL)
        DT::datatable(
          summary_stats,
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            sprintf(
              "This table summarises the current Claude usage status across %d day(s) of cached ccusage data. Values are computed by llm::summarize_llm_usage() directly from the daily usage records ingested into inst/extdata. Use it to check whether spend, token usage, or session counts have drifted from recent norms before drilling into the trend charts below.",
              length(unique(vig_daily_data$date))
            )
          ),
          extensions = "Buttons",
          rownames = FALSE,
          options = list(
            dom = "Bfrtip",
            buttons = c("copy", "csv", "excel", "pdf", "print"),
            pageLength = 10,
            autoWidth = TRUE,
            scrollX = TRUE
          )
        )
      },
      packages = c("DT", "htmltools")
    ),

    # Daily cost trend plot
    tar_target(
      vig_cost_trend_plot,
      {
        if (is.null(vig_daily_data) || nrow(vig_daily_data) == 0) return(NULL)
        vig_daily_data |>
          dplyr::mutate(date = as.Date(as.character(date))) |>
          dplyr::group_by(date) |>
          dplyr::summarise(daily_cost = sum(totalCost, na.rm = TRUE), .groups = "drop") |>
          ggplot2::ggplot(ggplot2::aes(x = date, y = daily_cost)) +
          ggplot2::geom_line(color = TELEMETRY_PALETTE[["accent"]], linewidth = 0.8) +
          ggplot2::geom_point(color = TELEMETRY_PALETTE[["accent"]], size = 1.5) +
          ggplot2::geom_smooth(method = "loess", se = FALSE, color = TELEMETRY_PALETTE[["trend"]]) +
          ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
          ggplot2::labs(title = "Daily Costs", x = "Date", y = "Cost (USD)") +
          theme_dashboard()
      },
      packages = c("ggplot2", "dplyr", "scales")
    ),

    # Cumulative cost plot
    tar_target(
      vig_cumulative_cost_plot,
      {
        if (is.null(vig_daily_data) || nrow(vig_daily_data) == 0) return(NULL)
        vig_daily_data |>
          dplyr::mutate(date = as.Date(as.character(date))) |>
          dplyr::group_by(date) |>
          dplyr::summarise(daily_cost = sum(totalCost, na.rm = TRUE), .groups = "drop") |>
          dplyr::arrange(date) |>
          dplyr::mutate(cumulative_cost = cumsum(daily_cost)) |>
          ggplot2::ggplot(ggplot2::aes(x = date, y = cumulative_cost)) +
          ggplot2::geom_area(fill = TELEMETRY_PALETTE[["accent"]], alpha = 0.3) +
          ggplot2::geom_line(color = TELEMETRY_PALETTE[["accent"]]) +
          ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
          ggplot2::labs(title = "Cumulative Spending", x = "Date", y = "Cumulative Cost (USD)") +
          theme_dashboard()
      },
      packages = c("ggplot2", "dplyr", "scales")
    ),

    # Combined breakdowns plot (model costs + token usage)
    tar_target(
      vig_breakdowns_plot,
      {
        if (is.null(vig_daily_data) || nrow(vig_daily_data) == 0) return(NULL)

        model_stats <- llm::get_model_breakdown(vig_daily_data)
        if (!is.null(model_stats) && nrow(model_stats) > 0 && "modelName" %in% names(model_stats)) {
          p1 <- ggplot2::ggplot(
            model_stats,
            ggplot2::aes(x = total_cost, y = reorder(modelName, total_cost))
          ) +
            ggplot2::geom_segment(
              ggplot2::aes(x = 0, xend = total_cost, yend = reorder(modelName, total_cost)),
              color = TELEMETRY_PALETTE[["accent"]]
            ) +
            ggplot2::geom_point(color = TELEMETRY_PALETTE[["accent"]], size = 4) +
            ggplot2::geom_text(
              ggplot2::aes(label = scales::dollar(total_cost)),
              hjust = -0.3, color = "#ffffff", size = 3.2
            ) +
            ggplot2::scale_x_continuous(
              labels = scales::dollar_format(),
              expand = ggplot2::expansion(mult = c(0, 0.15))
            ) +
            ggplot2::labs(title = "Cost by Model", x = "USD", y = NULL) +
            theme_dashboard()
        } else {
          p1 <- ggplot2::ggplot() +
            ggplot2::labs(title = "No model breakdown data available") +
            ggplot2::theme_void() +
            ggplot2::theme(
              plot.background = ggplot2::element_rect(fill = "#000000", color = NA),
              text = ggplot2::element_text(color = "#ffffff")
            )
        }

        # Aggregate token usage by type across the full tracked period, so
        # the "breakdown" reads as a categorical comparison (input vs output
        # vs cache) rather than an undifferentiated stacked-bar wall of dates.
        token_data <- vig_daily_data |>
          dplyr::summarise(
            Input = sum(inputTokens, na.rm = TRUE),
            Output = sum(outputTokens, na.rm = TRUE),
            Cache = sum(cacheCreationTokens + cacheReadTokens, na.rm = TRUE)
          ) |>
          tidyr::pivot_longer(dplyr::everything(), names_to = "type", values_to = "tokens")

        p2 <- ggplot2::ggplot(
          token_data,
          ggplot2::aes(x = tokens / 1e6, y = reorder(type, tokens), color = type)
        ) +
          ggplot2::geom_segment(
            ggplot2::aes(x = 0, xend = tokens / 1e6, yend = reorder(type, tokens)),
            linewidth = 1
          ) +
          ggplot2::geom_point(size = 4) +
          ggplot2::geom_text(
            ggplot2::aes(label = scales::comma(tokens, scale = 1e-6, suffix = "M", accuracy = 0.1)),
            hjust = -0.3, color = "#ffffff", size = 3.2
          ) +
          ggplot2::scale_color_manual(values = TELEMETRY_PALETTE) +
          ggplot2::scale_x_continuous(
            labels = scales::label_comma(suffix = "M"),
            expand = ggplot2::expansion(mult = c(0, 0.2))
          ) +
          ggplot2::labs(title = "Total Token Usage by Type", x = "Millions", y = NULL) +
          theme_dashboard() +
          ggplot2::theme(legend.position = "none")

        gridExtra::grid.arrange(p1, p2, ncol = 1)
      },
      packages = c("ggplot2", "dplyr", "tidyr", "scales", "gridExtra")
    ),

    # Gemini daily cost plot
    tar_target(
      vig_gemini_plot,
      {
        # Resolved rather than hardcoded: #32 moved this DB to llmtelemetry and
        # left the here::here() path behind, so this target had been silently
        # returning NULL ever since (#860).
        gm_db_path <- llm:::llm_extdata_file("gemini_usage.duckdb")
        if (is.null(gm_db_path) || !file.exists(gm_db_path)) return(NULL)
        tryCatch({
          con <- DBI::dbConnect(duckdb::duckdb(), dbdir = gm_db_path, read_only = TRUE)
          on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
          gm_daily <- dplyr::tbl(con, "daily_usage") |>
            dplyr::arrange(date) |>
            dplyr::collect()
          if (nrow(gm_daily) == 0) return(NULL)
          gm_daily <- gm_daily |> dplyr::mutate(date = as.Date(date))
          ggplot2::ggplot(
            gm_daily,
            ggplot2::aes(x = total_cost, y = reorder(as.character(date), total_cost))
          ) +
            ggplot2::geom_segment(
              ggplot2::aes(x = 0, xend = total_cost, yend = reorder(as.character(date), total_cost)),
              color = TELEMETRY_PALETTE[["accent"]]
            ) +
            ggplot2::geom_point(color = TELEMETRY_PALETTE[["accent"]], size = 4) +
            ggplot2::geom_text(
              ggplot2::aes(label = scales::dollar(total_cost)),
              hjust = -0.3, color = "#ffffff", size = 3
            ) +
            ggplot2::scale_x_continuous(
              labels = scales::dollar_format(),
              expand = ggplot2::expansion(mult = c(0, 0.15))
            ) +
            ggplot2::labs(title = "Gemini Daily Costs", x = "USD", y = "Date") +
            theme_dashboard()
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("ggplot2", "dplyr", "DBI", "duckdb", "scales")
    ),

    # === Session Efficiency section ===

    # Processed session metrics
    tar_target(
      vig_session_metrics,
      {
        if (is.null(vig_blocks_data) || is.null(vig_blocks_data$blocks) || length(vig_blocks_data$blocks) == 0) return(NULL)
        tryCatch({
          tibble::as_tibble(vig_blocks_data$blocks) |>
            dplyr::mutate(
              start = lubridate::ymd_hms(startTime),
              end = lubridate::ymd_hms(actualEndTime),
              duration_mins = as.numeric(difftime(end, start, units = "mins")),
              date = as.Date(start),
              cost_per_min = ifelse(duration_mins > 0, costUSD / duration_mins, 0),
              period = dplyr::case_when(
                difftime(Sys.Date(), date, units = "weeks") <= 1 ~ "Last Week",
                TRUE ~ "Older"
              )
            ) |>
            dplyr::filter(duration_mins > 0)
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("dplyr", "lubridate", "tibble")
    ),

    # Duration trend plot
    tar_target(
      vig_duration_trend_plot,
      {
        if (is.null(vig_session_metrics) || nrow(vig_session_metrics) == 0) return(NULL)
        vig_session_metrics |>
          dplyr::group_by(date, period) |>
          dplyr::summarise(avg_dur = mean(duration_mins), .groups = "drop") |>
          ggplot2::ggplot(ggplot2::aes(x = date, y = avg_dur)) +
          ggplot2::geom_point(ggplot2::aes(color = period), size = 2) +
          ggplot2::geom_smooth(method = "loess", se = FALSE, color = TELEMETRY_PALETTE[["trend"]]) +
          ggplot2::scale_color_manual(values = TELEMETRY_PALETTE) +
          ggplot2::labs(title = "Avg Session Duration", y = "Minutes", color = "Period") +
          theme_dashboard()
      },
      packages = c("ggplot2", "dplyr")
    ),

    # Cost efficiency plot
    tar_target(
      vig_cost_efficiency_plot,
      {
        if (is.null(vig_session_metrics) || nrow(vig_session_metrics) == 0) return(NULL)
        vig_session_metrics |>
          dplyr::group_by(date, period) |>
          dplyr::summarise(avg_cost = mean(cost_per_min), .groups = "drop") |>
          ggplot2::ggplot(ggplot2::aes(x = date, y = avg_cost)) +
          ggplot2::geom_point(ggplot2::aes(color = period), size = 2) +
          ggplot2::geom_smooth(method = "loess", se = FALSE, color = TELEMETRY_PALETTE[["trend"]]) +
          ggplot2::scale_color_manual(values = TELEMETRY_PALETTE) +
          ggplot2::scale_y_continuous(labels = label_dollar_signif) +
          ggplot2::labs(title = "Cost per Minute", y = "$/min", color = "Period") +
          theme_dashboard()
      },
      packages = c("ggplot2", "dplyr", "scales")
    ),

    # Cost vs duration scatter
    tar_target(
      vig_cost_duration_plot,
      {
        if (is.null(vig_session_metrics) || nrow(vig_session_metrics) == 0) return(NULL)
        ggplot2::ggplot(vig_session_metrics, ggplot2::aes(x = duration_mins, y = cost_per_min)) +
          ggplot2::geom_point(ggplot2::aes(color = period), alpha = 0.6) +
          ggplot2::geom_smooth(method = "loess", color = TELEMETRY_PALETTE[["trend"]]) +
          ggplot2::scale_color_manual(values = TELEMETRY_PALETTE) +
          ggplot2::scale_y_continuous(labels = label_dollar_signif) +
          ggplot2::labs(
            title = "Cost Intensity vs Duration",
            subtitle = "Are longer sessions more cost efficient?",
            x = "Duration (mins)",
            y = "Cost/Min ($)",
            color = "Period"
          ) +
          theme_dashboard()
      },
      packages = c("ggplot2", "scales")
    ),

    # Model breakdown by session plot
    tar_target(
      vig_model_session_plot,
      {
        if (is.null(vig_session_metrics) || nrow(vig_session_metrics) == 0) return(NULL)
        if (!"models" %in% names(vig_session_metrics)) return(NULL)
        tryCatch({
          model_usage <- vig_session_metrics |>
            dplyr::select(date, duration_mins, cost_per_min, models) |>
            tidyr::unnest(models) |>
            dplyr::mutate(model_clean = gsub("claude-", "", models, fixed = TRUE))

          ggplot2::ggplot(model_usage, ggplot2::aes(x = date, y = cost_per_min)) +
            ggplot2::geom_point(alpha = 0.4, color = TELEMETRY_PALETTE[["accent"]]) +
            ggplot2::geom_smooth(method = "loess", se = FALSE, color = TELEMETRY_PALETTE[["trend"]]) +
            ggplot2::facet_wrap(~model_clean, scales = "free_y", ncol = 2) +
            ggplot2::scale_y_continuous(labels = label_dollar_signif) +
            ggplot2::labs(title = "Cost Efficiency by Model", y = "Cost/Min ($)") +
            theme_dashboard()
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("ggplot2", "dplyr", "tidyr", "scales")
    ),

    # Max5 blocks table
    tar_target(
      vig_max5_table,
      {
        if (is.null(vig_session_metrics) || nrow(vig_session_metrics) == 0) return(NULL)
        tbl_data <- vig_session_metrics |>
          dplyr::arrange(dplyr::desc(start)) |>
          dplyr::mutate(
            Duration = sprintf("%02d:%02d", as.integer(duration_mins %/% 60), as.integer(duration_mins %% 60)),
            Cost = scales::dollar(costUSD),
            Tokens = scales::comma(totalTokens)
          ) |>
          dplyr::select(Start = start, Duration, Cost, Tokens)

        DT::datatable(
          tbl_data,
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            sprintf(
              "This table lists the %d most recent Max5 usage blocks, each block representing one continuous Claude session window. Duration is shown as HH:MM, cost in USD, and tokens as a comma-formatted count. Rows are sorted by session start time, most recent first, so you can spot unusually long or expensive sessions quickly.",
              nrow(tbl_data)
            )
          ),
          extensions = "Buttons",
          rownames = FALSE,
          options = list(
            dom = "Bfrtip",
            buttons = c("copy", "csv", "excel", "pdf", "print"),
            pageLength = 10,
            autoWidth = TRUE,
            scrollX = TRUE
          )
        )
      },
      packages = c("DT", "dplyr", "scales", "htmltools")
    ),

    # CodexBar per-project cost (day/project grain, JohnGavin/llm#877).
    # This is a separate, forward-looking cost source from `vig_blocks_data`
    # above: CodexBar has no session-grain export at all (confirmed against
    # the raw CLI -- see R/ccusage.R::load_codexbar_project_cost() roxygen),
    # so the finest honest grain it can offer is project-per-day. It is also
    # an ESTIMATE, apportioned from CodexBar's day-level cost total via
    # session-duration weighting -- not measured per project. The exporter
    # (llmtelemetry) has been observed to emit an empty `[]` placeholder on
    # some runs; NULL-safe throughout, same pattern as every other target in
    # this file.
    tar_target(
      vig_codexbar_project_cost_data,
      llm::load_codexbar_project_cost()
    ),

    tar_target(
      vig_codexbar_project_cost_summary,
      llm::summarise_codexbar_project_cost(vig_codexbar_project_cost_data)
    ),

    tar_target(
      vig_codexbar_project_cost_plot,
      {
        if (is.null(vig_codexbar_project_cost_summary) ||
            nrow(vig_codexbar_project_cost_summary) == 0) {
          return(NULL)
        }
        d <- vig_codexbar_project_cost_summary
        window_lo <- min(d$date_min, na.rm = TRUE)
        window_hi <- max(d$date_max, na.rm = TRUE)
        ggplot2::ggplot(
          d,
          ggplot2::aes(x = total_est_cost, y = reorder(canonical_project, total_est_cost))
        ) +
          ggplot2::geom_segment(
            ggplot2::aes(
              x = 0, xend = total_est_cost,
              yend = reorder(canonical_project, total_est_cost)
            ),
            color = TELEMETRY_PALETTE[["accent"]]
          ) +
          ggplot2::geom_point(color = TELEMETRY_PALETTE[["accent"]], size = 3.5) +
          ggplot2::geom_text(
            ggplot2::aes(label = scales::dollar(total_est_cost)),
            hjust = -0.3, color = "#ffffff", size = 3
          ) +
          ggplot2::scale_x_continuous(
            labels = scales::dollar_format(),
            expand = ggplot2::expansion(mult = c(0, 0.18))
          ) +
          ggplot2::labs(
            title = sprintf("CodexBar Cost by Project (estimate, %s to %s)", window_lo, window_hi),
            subtitle = "Day x project grain -- apportioned from CodexBar's daily total by session-duration share, not measured per project",
            x = "Estimated cost (USD)",
            y = NULL
          ) +
          theme_dashboard()
      },
      packages = c("ggplot2", "scales")
    ),

    # === CI & Git Stats section ===

    # Workflow runs data
    tar_target(
      vig_workflow_runs,
      {
        tryCatch({
          owner <- "JohnGavin"
          repo <- "llm"
          runs <- gh::gh("/repos/{owner}/{repo}/actions/runs", owner = owner, repo = repo, per_page = 50)
          if (is.null(runs$workflow_runs) || length(runs$workflow_runs) == 0) return(NULL)
          tibble::tibble(
            name = sapply(runs$workflow_runs, `[[`, "name"),
            conclusion = sapply(runs$workflow_runs, function(x) x$conclusion %||% NA),
            start = lubridate::ymd_hms(sapply(runs$workflow_runs, `[[`, "run_started_at")),
            end = lubridate::ymd_hms(sapply(runs$workflow_runs, `[[`, "updated_at"))
          ) |>
            dplyr::mutate(duration_mins = as.numeric(difftime(end, start, units = "mins")))
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("gh", "lubridate", "dplyr", "tibble"),
      cue = tar_cue(mode = "always")
    ),

    # Workflow runtimes boxplot
    tar_target(
      vig_workflow_plot,
      {
        if (is.null(vig_workflow_runs) || nrow(vig_workflow_runs) == 0) return(NULL)
        vig_workflow_runs |>
          dplyr::filter(conclusion == "success", !is.na(duration_mins)) |>
          ggplot2::ggplot(ggplot2::aes(x = reorder(name, duration_mins), y = duration_mins)) +
          ggplot2::geom_boxplot(fill = TELEMETRY_PALETTE[["accent"]], alpha = 0.7, color = "#ffffff") +
          ggplot2::coord_flip() +
          ggplot2::labs(title = "Workflow Runtimes", x = NULL, y = "Minutes") +
          theme_dashboard()
      },
      packages = c("ggplot2", "dplyr")
    ),

    # Git commit history plot
    tar_target(
      vig_git_history_plot,
      {
        tryCatch({
          git_log <- gert::git_log(max = 100)
          if (is.null(git_log) || nrow(git_log) == 0) return(NULL)
          git_log |>
            dplyr::mutate(date = as.Date(time)) |>
            dplyr::count(date) |>
            ggplot2::ggplot(ggplot2::aes(x = n, y = reorder(as.character(date), n))) +
            ggplot2::geom_segment(
              ggplot2::aes(x = 0, xend = n, yend = reorder(as.character(date), n)),
              color = TELEMETRY_PALETTE[["accent"]]
            ) +
            ggplot2::geom_point(color = TELEMETRY_PALETTE[["accent"]], size = 4) +
            ggplot2::geom_text(
              ggplot2::aes(label = n),
              hjust = -0.3, color = "#ffffff", size = 3
            ) +
            ggplot2::scale_x_continuous(
              labels = scales::comma,
              expand = ggplot2::expansion(mult = c(0, 0.15))
            ) +
            ggplot2::labs(title = "Recent Commits", x = "Count", y = "Date") +
            theme_dashboard()
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("ggplot2", "dplyr", "gert", "scales"),
      cue = tar_cue(mode = "always")
    ),

    # === Project Structure section ===

    # File type counts table
    tar_target(
      vig_file_counts_table,
      {
        tryCatch({
          files <- fs::dir_ls(recurse = TRUE, type = "file")
          files <- files[!grepl("(\\.git|_targets|renv)", files)]
          if (length(files) == 0) return(NULL)
          tbl_data <- tibble::tibble(path = as.character(files)) |>
            dplyr::mutate(ext = tools::file_ext(path)) |>
            dplyr::count(ext, sort = TRUE)
          DT::datatable(
            tbl_data,
            caption = htmltools::tags$caption(
              style = "caption-side: bottom; text-align: left;",
              sprintf(
                "This table counts every tracked file in the repository by extension, excluding .git, _targets, and renv directories. It covers %s files across %d distinct extensions and is recomputed on every pipeline run. Use it to sanity-check that the repository's file mix (R source, vignettes, config, data) matches expectations.",
                scales::comma(sum(tbl_data$n)), nrow(tbl_data)
              )
            ),
            extensions = "Buttons",
            rownames = FALSE,
            options = list(
              dom = "Bfrtip",
              buttons = c("copy", "csv", "excel", "pdf", "print"),
              pageLength = 15,
              autoWidth = TRUE,
              scrollX = TRUE
            )
          )
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("DT", "dplyr", "tibble", "fs", "htmltools", "scales")
    ),

    # === Pipeline Metrics section ===

    # Pipeline summary: plans, target counts, top by size/time
    tar_target(
      vig_pipeline_summary,
      {
        tryCatch({
          # tar_meta() cannot be called inside tar_make() — use callr subprocess
          meta <- callr::r(function() {
            setwd(here::here())
            targets::tar_meta()
          }, error = "error")
          if (is.null(meta) || nrow(meta) == 0) return(NULL)

          # Plan files
          plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$", full.names = TRUE)
          plan_counts <- lapply(plan_files, function(f) {
            code <- readLines(f, warn = FALSE)
            n <- sum(grepl("tar_target\\(|tar_quarto\\(", code))
            tibble::tibble(plan = basename(f), targets = n)
          })
          plan_tbl <- dplyr::bind_rows(plan_counts) |>
            dplyr::arrange(dplyr::desc(targets))

          # Top by size
          top_size <- meta |>
            dplyr::filter(!is.na(bytes), bytes > 0) |>
            dplyr::arrange(dplyr::desc(bytes)) |>
            dplyr::slice_head(n = 5) |>
            dplyr::transmute(
              target = name,
              size = dplyr::case_when(
                bytes >= 1e9 ~ sprintf("%.1f GB", bytes / 1e9),
                bytes >= 1e6 ~ sprintf("%.1f MB", bytes / 1e6),
                bytes >= 1e3 ~ sprintf("%.1f KB", bytes / 1e3),
                TRUE ~ paste0(bytes, " B")
              ),
              bytes
            )

          # Top by time
          top_time <- meta |>
            dplyr::filter(!is.na(seconds), seconds > 0) |>
            dplyr::arrange(dplyr::desc(seconds)) |>
            dplyr::slice_head(n = 5) |>
            dplyr::transmute(
              target = name,
              time = dplyr::case_when(
                seconds >= 60 ~ sprintf("%.1f min", seconds / 60),
                TRUE ~ sprintf("%.1f s", seconds)
              ),
              seconds
            )

          list(
            plan_tbl = plan_tbl,
            total_plans = nrow(plan_tbl),
            total_targets = sum(plan_tbl$targets),
            top_size = top_size,
            top_time = top_time
          )
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("dplyr", "tibble", "targets", "callr"),
      cue = tar_cue(mode = "always")
    ),

    # Pipeline summary as DT tables
    tar_target(
      vig_pipeline_plans_table,
      {
        if (is.null(vig_pipeline_summary)) return(NULL)
        DT::datatable(
          vig_pipeline_summary$plan_tbl,
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            sprintf(
              "This table lists every targets plan file under R/tar_plans and how many tar_target()/tar_quarto() calls each one defines. The pipeline currently has %d plans with %d total targets, sorted by target count descending. Use it to spot which plan files are growing large enough to warrant splitting.",
              vig_pipeline_summary$total_plans,
              vig_pipeline_summary$total_targets
            )
          ),
          rownames = FALSE,
          options = list(dom = "t", pageLength = 20, order = list(list(1, "desc")))
        )
      },
      packages = c("DT", "htmltools")
    ),

    tar_target(
      vig_pipeline_top_size_table,
      {
        if (is.null(vig_pipeline_summary)) return(NULL)
        DT::datatable(
          vig_pipeline_summary$top_size |> dplyr::select(target, size),
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            "This table ranks the five largest targets currently stored in the _targets cache by their serialized size on disk. Size is reported in the most readable unit (KB, MB, or GB) depending on magnitude. Large targets here are the best candidates for storage-format optimisation (e.g. switching to qs or parquet) if the pipeline's disk footprint becomes a concern."
          ),
          rownames = FALSE,
          options = list(dom = "t", pageLength = 5)
        )
      },
      packages = c("DT", "dplyr", "htmltools")
    ),

    tar_target(
      vig_pipeline_top_time_table,
      {
        if (is.null(vig_pipeline_summary)) return(NULL)
        DT::datatable(
          vig_pipeline_summary$top_time |> dplyr::select(target, time),
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            "This table ranks the five slowest targets in the most recent pipeline run by wall-clock compute time, shown in minutes or seconds depending on magnitude. Compute time is read from targets::tar_meta() metadata captured after tar_make() completes. Targets appearing here repeatedly are the best candidates for caching, parallelisation via crew, or algorithmic optimisation."
          ),
          rownames = FALSE,
          options = list(dom = "t", pageLength = 5)
        )
      },
      packages = c("DT", "dplyr", "htmltools")
    ),

    # === GitHub Activity section ===

    # Commit velocity: weekly commit counts with highlights
    tar_target(
      vig_commit_velocity,
      {
        tryCatch({
          git_log <- gert::git_log(max = 500)
          if (is.null(git_log) || nrow(git_log) == 0) return(NULL)

          started <- min(as.Date(git_log$time))
          latest <- max(as.Date(git_log$time))
          age_days <- as.integer(difftime(latest, started, units = "days"))

          weekly <- git_log |>
            dplyr::mutate(
              date = as.Date(time),
              week = lubridate::floor_date(date, "week")
            ) |>
            dplyr::group_by(week) |>
            dplyr::summarise(
              commits = dplyr::n(),
              .groups = "drop"
            ) |>
            dplyr::arrange(week) |>
            dplyr::mutate(
              week_label = format(week, "W%V (%b %d)")
            )

          list(
            started = started,
            latest = latest,
            age_days = age_days,
            total_commits = nrow(git_log),
            weekly = weekly
          )
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("gert", "dplyr", "lubridate"),
      cue = tar_cue(mode = "always")
    ),

    tar_target(
      vig_commit_velocity_table,
      {
        if (is.null(vig_commit_velocity)) return(NULL)
        tbl <- vig_commit_velocity$weekly |>
          dplyr::select(Week = week_label, Commits = commits)
        DT::datatable(
          tbl,
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            sprintf(
              "This table shows weekly commit counts for the repository since it was created. Across %d days (started %s) the project has accumulated %d total commits, giving a sense of overall development velocity. Use it alongside the pipeline metrics table to see whether commit activity and pipeline growth are moving together.",
              vig_commit_velocity$age_days,
              vig_commit_velocity$started,
              vig_commit_velocity$total_commits
            )
          ),
          rownames = FALSE,
          options = list(dom = "t", pageLength = 20, order = list(list(1, "desc")))
        )
      },
      packages = c("DT", "dplyr", "htmltools")
    ),

    # GitHub issues and PRs summary
    tar_target(
      vig_github_activity,
      {
        tryCatch({
          owner <- "JohnGavin"
          repo <- "llm"

          # Issues
          issues_open <- gh::gh("/repos/{owner}/{repo}/issues",
            owner = owner, repo = repo, state = "open", per_page = 100)
          issues_closed <- gh::gh("/repos/{owner}/{repo}/issues",
            owner = owner, repo = repo, state = "closed", per_page = 100)
          # Filter out PRs (issues endpoint includes PRs)
          issues_open <- Filter(function(x) is.null(x$pull_request), issues_open)
          issues_closed <- Filter(function(x) is.null(x$pull_request), issues_closed)

          open_issues <- tibble::tibble(
            number = sapply(issues_open, `[[`, "number"),
            title = sapply(issues_open, `[[`, "title")
          )

          # PRs
          prs_open <- gh::gh("/repos/{owner}/{repo}/pulls",
            owner = owner, repo = repo, state = "open", per_page = 100)
          prs_closed <- gh::gh("/repos/{owner}/{repo}/pulls",
            owner = owner, repo = repo, state = "closed", per_page = 100)

          # Workflows
          workflows <- gh::gh("/repos/{owner}/{repo}/actions/workflows",
            owner = owner, repo = repo)
          active_workflows <- Filter(function(w) w$state == "active", workflows$workflows)

          list(
            issues_open = length(issues_open),
            issues_closed = length(issues_closed),
            issues_total = length(issues_open) + length(issues_closed),
            open_issue_list = open_issues,
            prs_open = length(prs_open),
            prs_merged = sum(sapply(prs_closed, function(x) !is.null(x$merged_at))),
            prs_total = length(prs_open) + length(prs_closed),
            workflows_active = length(active_workflows),
            workflow_names = sapply(active_workflows, `[[`, "name")
          )
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("gh", "tibble"),
      cue = tar_cue(mode = "always")
    ),

    tar_target(
      vig_github_activity_table,
      {
        if (is.null(vig_github_activity)) return(NULL)
        ga <- vig_github_activity
        tbl <- tibble::tibble(
          Metric = c("Issues (open/closed/total)",
                     "Pull Requests (open/merged/total)",
                     "Active CI Workflows"),
          Value = c(
            sprintf("%d / %d / %d", ga$issues_open, ga$issues_closed, ga$issues_total),
            sprintf("%d / %d / %d", ga$prs_open, ga$prs_merged, ga$prs_total),
            sprintf("%d (%s)", ga$workflows_active,
                    paste(ga$workflow_names, collapse = ", "))
          )
        )
        DT::datatable(
          tbl,
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            sprintf(
              "This table summarises the repository's GitHub issue, pull request, and CI workflow activity as of the last pipeline run. There are currently %d open and %d closed issues (%d total), %d open and %d merged pull requests (%d total), and %d active CI workflow(s). Use it as a quick health check before diving into the individual issue and PR lists.",
              ga$issues_open, ga$issues_closed, ga$issues_total,
              ga$prs_open, ga$prs_merged, ga$prs_total,
              ga$workflows_active
            )
          ),
          rownames = FALSE,
          options = list(dom = "t", pageLength = 5)
        )
      },
      packages = c("DT", "tibble", "htmltools")
    ),

    # Codebase metrics
    tar_target(
      vig_codebase_metrics,
      {
        tryCatch({
          r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
          r_files <- r_files[!grepl("R/dev/", r_files, fixed = TRUE)]
          test_files <- list.files("tests/testthat", pattern = "^test-.*\\.R$")
          vignette_files <- list.files("vignettes", pattern = "\\.(qmd|Rmd)$")
          plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$")

          # Count lines of R code
          lines_of_code <- sum(sapply(r_files, function(f) {
            code <- readLines(f, warn = FALSE)
            sum(nchar(trimws(code)) > 0 & !grepl("^\\s*#", code))
          }))

          # Count exported functions from NAMESPACE
          ns_file <- "NAMESPACE"
          exports <- if (file.exists(ns_file)) {
            ns <- readLines(ns_file, warn = FALSE)
            sum(grepl("^export\\(", ns))
          } else {
            NA_integer_
          }

          # Package version
          desc <- read.dcf("DESCRIPTION", fields = c("Version", "Package"))
          version <- desc[1, "Version"]
          pkg_name <- desc[1, "Package"]

          tbl <- tibble::tibble(
            Metric = c("R source files", "Test files", "Vignettes",
                       "Targets plans", "Exported functions",
                       "Lines of R code", "Version"),
            Count = c(length(r_files), length(test_files), length(vignette_files),
                      length(plan_files), exports,
                      format(lines_of_code, big.mark = ","), version)
          )

          DT::datatable(
            tbl,
            caption = htmltools::tags$caption(
              style = "caption-side: bottom; text-align: left;",
              sprintf(
                "This table reports structural metrics for the %s package (version %s): counts of R source files, test files, vignettes, targets plan files, and exported functions, plus total non-comment lines of R code. Metrics are recomputed directly from the repository tree and NAMESPACE on every pipeline run, so they always reflect the current checkout. Use it to track codebase growth over time alongside the commit velocity and pipeline metrics tables.",
                pkg_name, version
              )
            ),
            rownames = FALSE,
            options = list(dom = "t", pageLength = 10)
          )
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("DT", "tibble", "htmltools")
    ),

    # GitHub stats table
    tar_target(
      vig_github_stats_table,
      {
        tryCatch({
          owner <- "JohnGavin"
          repo <- "llm"
          info <- gh::gh("/repos/{owner}/{repo}", owner = owner, repo = repo)
          branches <- gh::gh("/repos/{owner}/{repo}/branches", owner = owner, repo = repo)
          commits <- gh::gh("/repos/{owner}/{repo}/commits", owner = owner, repo = repo, per_page = 1)

          stats_data <- tibble::tibble(
            Metric = c("Stars", "Forks", "Open Issues", "Branches", "Last Commit"),
            Value = c(
              as.character(info$stargazers_count %||% 0),
              as.character(info$forks_count %||% 0),
              as.character(info$open_issues_count %||% 0),
              as.character(length(branches)),
              as.character(as.Date(lubridate::ymd_hms(commits[[1]]$commit$committer$date)))
            )
          )
          DT::datatable(
            stats_data,
            caption = htmltools::tags$caption(
              style = "caption-side: bottom; text-align: left;",
              "This table shows top-level GitHub repository statistics: star and fork counts, the number of open issues, the number of branches, and the date of the most recent commit. Values are fetched live from the GitHub API on every pipeline run, so they reflect the repository's current state rather than a cached snapshot. Use it as a quick external-visibility check alongside the internal codebase and pipeline metrics tables."
            ),
            extensions = "Buttons",
            rownames = FALSE,
            options = list(
              dom = "Bfrtip",
              buttons = c("copy", "csv", "excel", "pdf", "print"),
              pageLength = 10,
              autoWidth = TRUE,
              scrollX = TRUE
            )
          )
        }, error = function(e) { cli::cli_warn("Target failed: {conditionMessage(e)}"); NULL })
      },
      packages = c("DT", "gh", "lubridate", "tibble", "htmltools"),
      cue = tar_cue(mode = "always")
    )
  )
}
