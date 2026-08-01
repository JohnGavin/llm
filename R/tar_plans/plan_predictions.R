# R/tar_plans/plan_predictions.R
# Cross-project prediction calibration targets
# Scans ~/.claude/predictions/*.jsonl for global calibration view

library(targets)

# Named palette for the two fixed metric series compared on this page
# (narrative-colour-persistence rule). Contrast >=4.5:1 on #000000, shared
# hues with TELEMETRY_PALETTE (see plan_vignette_outputs.R) for consistency
# across telemetry pages. theme_dashboard() and ACCESSIBLE_QUALITATIVE_COLORS
# are also defined in plan_vignette_outputs.R and are available here since
# both files compile into the same package namespace.
PRED_PALETTE <- c(
  "Mean Predicted" = "#4ea8de",
  "Actual Success" = "#f08080"
)

#' Prediction Calibration Targets
#'
#' Cross-project prediction tracking with Brier scores,
#' reliability diagrams, and per-project summaries.
#'
#' @return A list of target objects
#' @export
plan_predictions <- function() {
  list(
    # === Raw data ===

    tar_target(
      pred_all_raw,
      llm::load_all_predictions(),
      cue = tar_cue(mode = "always")
    ),

    # === DuckDB persistence ===

    tar_target(
      pred_stored,
      {
        db_path <- here::here("inst/extdata/llm_usage_history.duckdb")
        store_cross_project_predictions(pred_all_raw, db_path)
      }
    ),

    # === Per-project summary ===

    tar_target(
      pred_by_project,
      {
        if (is.null(pred_all_raw) || nrow(pred_all_raw) == 0) {
          return(tibble::tibble(
            project_name = character(),
            n_predictions = integer(),
            n_resolved = integer(),
            success_rate = double(),
            brier_score = double()
          ))
        }

        pred_all_raw |>
          dplyr::group_by(project_name) |>
          dplyr::summarise(
            n_predictions = dplyr::n(),
            n_resolved = sum(!is.na(outcome)),
            success_rate = if (sum(!is.na(outcome)) > 0) {
              mean(outcome[!is.na(outcome)])
            } else {
              NA_real_
            },
            brier_score = if (sum(!is.na(outcome)) > 0) {
              outcome_bin <- as.integer(outcome[!is.na(outcome)])
              p_sub <- p_success[!is.na(outcome)]
              mean((p_sub - outcome_bin)^2)
            } else {
              NA_real_
            },
            .groups = "drop"
          )
      },
      packages = c("dplyr", "tibble")
    ),

    # === Global calibration ===

    tar_target(
      pred_global_calibration,
      compute_calibration_metrics(pred_all_raw)
    ),

    # === Rolling Brier with project colors ===

    tar_target(
      pred_global_rolling_brier,
      {
        if (is.null(pred_all_raw) || nrow(pred_all_raw) == 0) return(NULL)
        resolved <- pred_all_raw |> dplyr::filter(!is.na(outcome))
        if (nrow(resolved) == 0) return(NULL)

        resolved |>
          dplyr::mutate(
            outcome_binary = dplyr::if_else(outcome, 1, 0)
          ) |>
          dplyr::arrange(recorded_at) |>
          dplyr::mutate(
            sq_error = (p_success - outcome_binary)^2,
            cumulative_brier = cumsum(sq_error) / dplyr::row_number(),
            prediction_num = dplyr::row_number()
          )
      },
      packages = c("dplyr")
    ),

    # === Vignette tables ===

    tar_target(
      vig_pred_by_project_table,
      {
        if (nrow(pred_by_project) == 0) return(NULL)
        display <- pred_by_project |>
          dplyr::mutate(
            success_rate = ifelse(is.na(success_rate), "N/A",
                                  sprintf("%.0f%%", success_rate * 100)),
            brier_score = ifelse(is.na(brier_score), "N/A",
                                 sprintf("%.3f", brier_score))
          )
        DT::datatable(
          display,
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            sprintf(
              "This table breaks down cross-project prediction calibration by project name, covering %d project(s). For each project it reports the number of predictions logged, how many have resolved to a known outcome, the observed success rate among resolved predictions, and the Brier score (lower is better, 0 is perfect). Projects with few resolved predictions show 'N/A' for rate and score until more outcomes are recorded.",
              nrow(display)
            )
          ),
          extensions = "Buttons",
          rownames = FALSE,
          options = list(
            dom = "Bfrtip",
            buttons = c("copy", "csv", "excel", "pdf", "print"),
            pageLength = 20,
            scrollX = TRUE
          )
        )
      },
      packages = c("DT", "dplyr", "htmltools")
    ),

    tar_target(
      vig_pred_global_calibration_table,
      {
        cal <- pred_global_calibration
        if (nrow(cal$calibration_by_bucket) == 0) return(NULL)
        display <- cal$calibration_by_bucket |>
          dplyr::mutate(
            mean_predicted = sprintf("%.1f%%", mean_predicted * 100),
            mean_observed = sprintf("%.1f%%", mean_observed * 100),
            gap = sprintf("%+.1f pp", gap * 100)
          )
        DT::datatable(
          display,
          caption = htmltools::tags$caption(
            style = "caption-side: bottom; text-align: left;",
            sprintf(
              "This table groups all resolved cross-project predictions into probability buckets and compares the mean predicted probability against the mean observed outcome in each bucket. A well-calibrated forecaster should show a gap near zero in every row; large positive gaps mean predictions were too confident, large negative gaps mean predictions were under-confident. Across all %d resolved predictions, the overall Brier score is %.3f (0 is perfect, 0.25 is the uninformative baseline).",
              cal$n_resolved, cal$brier_score
            )
          ),
          rownames = FALSE,
          options = list(dom = "t", pageLength = 10)
        )
      },
      packages = c("DT", "dplyr", "htmltools")
    ),

    # === Vignette plots ===

    tar_target(
      vig_pred_global_brier_plot,
      {
        if (is.null(pred_global_rolling_brier) ||
            nrow(pred_global_rolling_brier) == 0) return(NULL)

        # project_name is a dynamic, unbounded set (new projects appear over
        # time), so it cannot be enumerated in a fixed named PALETTE ahead of
        # time. Build a scale_color_manual() vector at plot-build time from
        # the shared accessible qualitative colours instead of viridis.
        projects <- sort(unique(pred_global_rolling_brier$project_name))
        proj_palette <- stats::setNames(
          rep_len(ACCESSIBLE_QUALITATIVE_COLORS, length(projects)),
          projects
        )

        ggplot2::ggplot(
          pred_global_rolling_brier,
          ggplot2::aes(x = prediction_num, y = cumulative_brier,
                       color = project_name)
        ) +
          ggplot2::geom_line() +
          ggplot2::geom_hline(yintercept = 0.25, linetype = "dashed",
                              color = "#ffd93d", alpha = 0.7) +
          ggplot2::annotate("text", x = 1, y = 0.26,
                            label = "Uninformative baseline",
                            hjust = 0, size = 3, color = "#ffd93d") +
          ggplot2::scale_y_continuous(limits = c(0, 0.5)) +
          ggplot2::scale_color_manual(values = proj_palette) +
          ggplot2::labs(
            title = "Cross-Project Rolling Brier Score",
            subtitle = "Cumulative calibration over time (lower is better)",
            x = "Prediction Number (chronological)",
            y = "Cumulative Brier Score",
            color = "Project"
          ) +
          theme_dashboard()
      },
      packages = c("ggplot2")
    ),

    tar_target(
      vig_pred_success_rate_plot,
      {
        if (nrow(pred_by_project) == 0) return(NULL)
        resolved <- pred_by_project |>
          dplyr::filter(!is.na(success_rate))
        if (nrow(resolved) == 0) return(NULL)

        # Create long format for actual vs predicted comparison
        plot_data <- pred_all_raw |>
          dplyr::filter(!is.na(outcome)) |>
          dplyr::mutate(outcome_binary = dplyr::if_else(outcome, 1, 0)) |>
          dplyr::group_by(project_name) |>
          dplyr::summarise(
            `Mean Predicted` = mean(p_success),
            `Actual Success` = mean(outcome_binary),
            .groups = "drop"
          ) |>
          tidyr::pivot_longer(
            cols = c(`Mean Predicted`, `Actual Success`),
            names_to = "metric",
            values_to = "rate"
          )

        # Order projects by their actual success rate so the grouped dot
        # plot reads top-to-bottom from best to worst observed outcome.
        order_basis <- plot_data |>
          dplyr::filter(metric == "Actual Success") |>
          dplyr::arrange(rate) |>
          dplyr::pull(project_name)
        plot_data <- plot_data |>
          dplyr::mutate(project_name = factor(project_name, levels = order_basis))

        ggplot2::ggplot(
          plot_data,
          ggplot2::aes(x = rate, y = project_name, color = metric)
        ) +
          ggplot2::geom_line(
            ggplot2::aes(group = project_name), color = "#ffffff", linewidth = 0.4
          ) +
          ggplot2::geom_point(size = 4) +
          ggplot2::scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
          ggplot2::scale_color_manual(values = PRED_PALETTE) +
          ggplot2::labs(
            title = "Predicted vs Actual Success Rate by Project",
            x = "Rate", y = NULL, color = NULL
          ) +
          theme_dashboard()
      },
      packages = c("ggplot2", "dplyr", "tidyr", "scales")
    )
  )
}
