# Regression test for JohnGavin/llm#877: `vig_session_data` was retired
# (it read a frozen, structurally-unusable `ccusage_session_all.json` that
# nothing in the package ever consumed) and three new day/project-grain
# CodexBar targets were added in its place. `tar_target()` only captures the
# target expression -- it does not evaluate it -- so this test can inspect
# the plan's target names without any live data files, ccusage, or codexbar
# CLI being present.

# R/tar_plans/ is a subdirectory of R/, so it is NOT collated into the
# package namespace -- only tar_source() loads it at pipeline build time.
# Source it directly, as test-qa-rds-freshness.R and test-plan-qa-gates.R do.
source(file.path(pkgload::pkg_path(), "R", "tar_plans", "plan_vignette_outputs.R"))

test_that("vig_session_data is retired and not reintroduced", {
  targets_list <- plan_vignette_outputs()
  names <- vapply(targets_list, function(t) t$settings$name, character(1))

  expect_false(
    "vig_session_data" %in% names,
    info = paste(
      "vig_session_data reads ccusage_session_all.json, which is frozen at",
      "2026-05-09 with no refresh mechanism and a structurally broken",
      "sessionId/projectPath schema (see #877, #870). Do not reintroduce it",
      "without first fixing the underlying data source."
    )
  )
})

test_that("the new day/project-grain CodexBar targets are present", {
  targets_list <- plan_vignette_outputs()
  names <- vapply(targets_list, function(t) t$settings$name, character(1))

  expect_true(all(c(
    "vig_codexbar_project_cost_data",
    "vig_codexbar_project_cost_summary",
    "vig_codexbar_project_cost_plot"
  ) %in% names))
})

test_that("the working Max5-block session-efficiency targets are unchanged", {
  # These are sourced from vig_blocks_data (ccusage_blocks_all.json), which
  # llmtelemetry refreshes daily and is NOT the frozen file -- #877
  # deliberately leaves them in place rather than downgrading fresh,
  # measured block-grain data to a coarser CodexBar estimate.
  targets_list <- plan_vignette_outputs()
  names <- vapply(targets_list, function(t) t$settings$name, character(1))

  expect_true(all(c(
    "vig_blocks_data",
    "vig_session_metrics",
    "vig_duration_trend_plot",
    "vig_cost_efficiency_plot",
    "vig_cost_duration_plot",
    "vig_model_session_plot",
    "vig_max5_table"
  ) %in% names))
})
