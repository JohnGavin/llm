#' Data acquisition plan — follows targets-pipeline-spec convention
#' Target prefix: raw_*
plan_data <- function() {
  list(
    targets::tar_target(
      raw_data,
      {
        set.seed(42)
        data.frame(
          x = 1:100,
          y = rnorm(100, mean = 5, sd = 2),
          group = rep(c("A", "B"), 50)
        )
      }
    )
  )
}
