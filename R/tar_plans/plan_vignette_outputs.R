# R/tar_plans/plan_vignette_outputs.R
# Targets for telemetry vignette outputs
# Every plot, table, and summary displayed in the vignette is a target here.

library(targets)

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

    tar_target(
      vig_session_data,
      llm::load_cached_ccusage("session", project_filter = NULL)
    ),

    tar_target(
      vig_blocks_data,
      tryCatch(
        jsonlite::fromJSON(here::here("inst/extdata/ccusage_blocks_all.json")),
        error = function(e) NULL
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
          caption = "Current Usage Status",
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
      packages = c("DT")
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
          ggplot2::geom_col(fill = "steelblue", alpha = 0.7) +
          ggplot2::geom_smooth(method = "loess", se = FALSE, color = "darkred") +
          ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
          ggplot2::labs(title = "Daily Costs", x = "Date", y = "Cost (USD)") +
          ggplot2::theme_minimal()
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
          ggplot2::geom_area(fill = "steelblue", alpha = 0.3) +
          ggplot2::geom_line(color = "steelblue") +
          ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
          ggplot2::labs(title = "Cumulative Spending", x = "Date", y = "Cumulative Cost (USD)") +
          ggplot2::theme_minimal()
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
          p1 <- ggplot2::ggplot(model_stats, ggplot2::aes(x = reorder(modelName, total_cost), y = total_cost)) +
            ggplot2::geom_col(fill = "steelblue") +
            ggplot2::coord_flip() +
            ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
            ggplot2::labs(title = "Cost by Model", x = NULL, y = "USD") +
            ggplot2::theme_minimal()
        } else {
          p1 <- ggplot2::ggplot() + ggplot2::labs(title = "No model breakdown data available") + ggplot2::theme_void()
        }

        token_data <- vig_daily_data |>
          dplyr::mutate(date = as.Date(as.character(date))) |>
          dplyr::group_by(date) |>
          dplyr::summarise(
            Input = sum(inputTokens, na.rm = TRUE),
            Output = sum(outputTokens, na.rm = TRUE),
            Cache = sum(cacheCreationTokens + cacheReadTokens, na.rm = TRUE),
            .groups = "drop"
          ) |>
          tidyr::pivot_longer(-date, names_to = "type", values_to = "tokens")

        p2 <- ggplot2::ggplot(token_data, ggplot2::aes(x = date, y = tokens / 1e6, fill = type)) +
          ggplot2::geom_col() +
          ggplot2::scale_y_continuous(labels = scales::label_comma(suffix = "M")) +
          ggplot2::labs(title = "Token Usage", y = "Millions") +
          ggplot2::theme_minimal()

        gridExtra::grid.arrange(p1, p2, ncol = 1)
      },
      packages = c("ggplot2", "dplyr", "tidyr", "scales", "gridExtra")
    ),

    # Gemini daily cost plot
    tar_target(
      vig_gemini_plot,
      {
        gm_db_path <- here::here("inst/extdata/gemini_usage.duckdb")
        if (!file.exists(gm_db_path)) return(NULL)
        tryCatch({
          con <- DBI::dbConnect(duckdb::duckdb(), dbdir = gm_db_path, read_only = TRUE)
          on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
          gm_daily <- dplyr::tbl(con, "daily_usage") |>
            dplyr::arrange(date) |>
            dplyr::collect()
          if (nrow(gm_daily) == 0) return(NULL)
          ggplot2::ggplot(gm_daily, ggplot2::aes(x = as.Date(date), y = total_cost)) +
            ggplot2::geom_col(fill = "#4fc3f7") +
            ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
            ggplot2::labs(title = "Gemini Daily Costs", x = "Date", y = "USD") +
            ggplot2::theme_minimal()
        }, error = function(e) NULL)
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
        }, error = function(e) NULL)
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
          ggplot2::geom_point(ggplot2::aes(color = period)) +
          ggplot2::geom_smooth(method = "loess", se = FALSE) +
          ggplot2::labs(title = "Avg Session Duration", y = "Minutes") +
          ggplot2::theme_minimal()
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
          ggplot2::geom_point(ggplot2::aes(color = period)) +
          ggplot2::geom_smooth(method = "loess", se = FALSE) +
          ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
          ggplot2::labs(title = "Cost per Minute", y = "$/min") +
          ggplot2::theme_minimal()
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
          ggplot2::geom_smooth(method = "loess", color = "red") +
          ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
          ggplot2::labs(
            title = "Cost Intensity vs Duration",
            subtitle = "Are longer sessions more cost efficient?",
            x = "Duration (mins)",
            y = "Cost/Min ($)"
          ) +
          ggplot2::theme_minimal()
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
            dplyr::mutate(model_clean = gsub("claude-", "", models))

          ggplot2::ggplot(model_usage, ggplot2::aes(x = date, y = cost_per_min)) +
            ggplot2::geom_point(alpha = 0.4, color = "steelblue") +
            ggplot2::geom_smooth(method = "loess", se = FALSE, color = "darkred") +
            ggplot2::facet_wrap(~model_clean, scales = "free_y", ncol = 2) +
            ggplot2::scale_y_continuous(labels = scales::dollar_format()) +
            ggplot2::labs(title = "Cost Efficiency by Model", y = "Cost/Min ($)") +
            ggplot2::theme_minimal()
        }, error = function(e) NULL)
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
          caption = "Max5 Usage Blocks",
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
      packages = c("DT", "dplyr", "scales")
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
        }, error = function(e) NULL)
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
          ggplot2::geom_boxplot(fill = "steelblue", alpha = 0.7) +
          ggplot2::coord_flip() +
          ggplot2::labs(title = "Workflow Runtimes", x = NULL, y = "Minutes") +
          ggplot2::theme_minimal()
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
            ggplot2::ggplot(ggplot2::aes(x = date, y = n)) +
            ggplot2::geom_col(fill = "steelblue") +
            ggplot2::labs(title = "Recent Commits", y = "Count") +
            ggplot2::theme_minimal()
        }, error = function(e) NULL)
      },
      packages = c("ggplot2", "dplyr", "gert"),
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
            caption = "File Types",
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
        }, error = function(e) NULL)
      },
      packages = c("DT", "dplyr", "tibble", "fs")
    ),

    # === Pipeline Metrics section ===

    # Pipeline summary: plans, target counts, top by size/time
    tar_target(
      vig_pipeline_summary,
      {
        tryCatch({
          meta <- targets::tar_meta()
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
        }, error = function(e) NULL)
      },
      packages = c("dplyr", "tibble", "targets"),
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
            sprintf("Pipeline has %d plans with %d total targets.",
                    vig_pipeline_summary$total_plans,
                    vig_pipeline_summary$total_targets)
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
          caption = "Top 5 targets by stored size.",
          rownames = FALSE,
          options = list(dom = "t", pageLength = 5)
        )
      },
      packages = c("DT", "dplyr")
    ),

    tar_target(
      vig_pipeline_top_time_table,
      {
        if (is.null(vig_pipeline_summary)) return(NULL)
        DT::datatable(
          vig_pipeline_summary$top_time |> dplyr::select(target, time),
          caption = "Top 5 targets by compute time.",
          rownames = FALSE,
          options = list(dom = "t", pageLength = 5)
        )
      },
      packages = c("DT", "dplyr")
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
        }, error = function(e) NULL)
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
            sprintf("Total: %d commits over %d days (started %s).",
                    vig_commit_velocity$total_commits,
                    vig_commit_velocity$age_days,
                    vig_commit_velocity$started)
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
        }, error = function(e) NULL)
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
          caption = "GitHub issues, pull requests, and CI workflows.",
          rownames = FALSE,
          options = list(dom = "t", pageLength = 5)
        )
      },
      packages = c("DT", "tibble")
    ),

    # Codebase metrics
    tar_target(
      vig_codebase_metrics,
      {
        tryCatch({
          r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
          r_files <- r_files[!grepl("R/dev/", r_files)]
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
            caption = sprintf("%s codebase metrics.", pkg_name),
            rownames = FALSE,
            options = list(dom = "t", pageLength = 10)
          )
        }, error = function(e) NULL)
      },
      packages = c("DT", "tibble")
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
            caption = "GitHub Stats",
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
        }, error = function(e) NULL)
      },
      packages = c("DT", "gh", "lubridate", "tibble"),
      cue = tar_cue(mode = "always")
    )
  )
}
