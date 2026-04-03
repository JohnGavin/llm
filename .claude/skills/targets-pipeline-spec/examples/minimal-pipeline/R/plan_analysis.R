#' Analysis plan — follows targets-pipeline-spec convention
#' Target prefix: result_*
plan_analysis <- function() {
  list(
    targets::tar_target(
      result_summary,
      {
        raw_data |>
          dplyr::group_by(group) |>
          dplyr::summarise(
            n = dplyr::n(),
            mean_y = mean(y),
            sd_y = sd(y),
            .groups = "drop"
          )
      },
      packages = c("dplyr")
    ),

    targets::tar_target(
      result_model,
      lm(y ~ x + group, data = raw_data)
    )
  )
}
