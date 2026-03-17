# R/tar_plans/plan_predictions.R
# Cross-project prediction calibration targets
# Scans ~/.claude/predictions/*.jsonl for global calibration view

library(targets)

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
              mean(outcome[!is.na(outcome)] == TRUE)
            } else {
              NA_real_
            },
            brier_score = if (sum(!is.na(outcome)) > 0) {
              resolved <- dplyr::cur_data() |> dplyr::filter(!is.na(outcome))
              outcome_bin <- dplyr::if_else(resolved$outcome == TRUE, 1, 0)
              mean((resolved$p_success - outcome_bin)^2)
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
            outcome_binary = dplyr::if_else(outcome == TRUE, 1, 0)
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
          caption = "Prediction calibration by project.",
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
      packages = c("DT", "dplyr")
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
          caption = sprintf(
            "Global calibration (Brier: %.3f, n=%d resolved).",
            cal$brier_score, cal$n_resolved
          ),
          rownames = FALSE,
          options = list(dom = "t", pageLength = 10)
        )
      },
      packages = c("DT", "dplyr")
    ),

    # === Vignette plots ===

    tar_target(
      vig_pred_global_brier_plot,
      {
        if (is.null(pred_global_rolling_brier) ||
            nrow(pred_global_rolling_brier) == 0) return(NULL)

        ggplot2::ggplot(
          pred_global_rolling_brier,
          ggplot2::aes(x = prediction_num, y = cumulative_brier,
                       color = project_name)
        ) +
          ggplot2::geom_line() +
          ggplot2::geom_hline(yintercept = 0.25, linetype = "dashed",
                              color = "red", alpha = 0.5) +
          ggplot2::annotate("text", x = 1, y = 0.26,
                            label = "Uninformative baseline",
                            hjust = 0, size = 3, color = "red") +
          ggplot2::scale_y_continuous(limits = c(0, 0.5)) +
          ggplot2::labs(
            title = "Cross-Project Rolling Brier Score",
            subtitle = "Cumulative calibration over time (lower is better)",
            x = "Prediction Number (chronological)",
            y = "Cumulative Brier Score",
            color = "Project"
          ) +
          ggplot2::theme_minimal()
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
          dplyr::mutate(outcome_binary = dplyr::if_else(outcome == TRUE, 1, 0)) |>
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

        ggplot2::ggplot(
          plot_data,
          ggplot2::aes(x = project_name, y = rate, fill = metric)
        ) +
          ggplot2::geom_col(position = "dodge") +
          ggplot2::scale_y_continuous(labels = scales::percent_format()) +
          ggplot2::scale_fill_manual(
            values = c("Mean Predicted" = "steelblue", "Actual Success" = "coral")
          ) +
          ggplot2::coord_flip() +
          ggplot2::labs(
            title = "Predicted vs Actual Success Rate by Project",
            x = NULL, y = "Rate", fill = NULL
          ) +
          ggplot2::theme_minimal()
      },
      packages = c("ggplot2", "dplyr", "tidyr", "scales")
    )
  )
}
