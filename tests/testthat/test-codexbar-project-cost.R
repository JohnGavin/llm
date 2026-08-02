# Tests for JohnGavin/llm#877: day/project-grain CodexBar cost content,
# added in place of the session grain that neither CodexBar nor the frozen
# ccusage session cache can provide. See R/ccusage.R for the roxygen on
# load_codexbar_project_cost() / summarise_codexbar_project_cost() for the
# full investigation (raw CodexBar CLI has no session/project identifier;
# codexbar_cost_per_project.json is an estimate apportioned by
# session-duration weighting, not a native per-project export).

# ============================================================================
# summarise_codexbar_project_cost()
# ============================================================================

test_that("summarise_codexbar_project_cost aggregates to one row per project", {
  df <- tibble::tibble(
    date              = c("2026-07-01", "2026-07-02", "2026-07-01"),
    canonical_project = c("llm", "llm", "llmtelemetry"),
    est_cost          = c(1.5, 2.5, 3.0),
    duration_min      = c(10, 20, 30),
    share             = c(0.5, 0.5, 1)
  )

  out <- summarise_codexbar_project_cost(df)

  expect_equal(nrow(out), 2L)
  expect_setequal(out$canonical_project, c("llm", "llmtelemetry"))

  llm_row <- out[out$canonical_project == "llm", ]
  expect_equal(llm_row$total_est_cost, 4.0)
  expect_equal(llm_row$total_duration_min, 30)
  expect_equal(llm_row$n_days, 2L)
  expect_equal(llm_row$date_min, "2026-07-01")
  expect_equal(llm_row$date_max, "2026-07-02")

  # Sorted descending by total cost (largest project first): llm totals
  # 1.5 + 2.5 = 4.0, ahead of llmtelemetry's 3.0.
  expect_equal(out$canonical_project[1], "llm")
})

test_that("summarise_codexbar_project_cost drops NA and empty canonical_project rows", {
  df <- tibble::tibble(
    date              = c("2026-07-01", "2026-07-02", "2026-07-03"),
    canonical_project = c("llm", NA_character_, ""),
    est_cost          = c(1, 2, 3),
    duration_min      = c(10, 20, 30),
    share             = c(1, 1, 1)
  )

  out <- summarise_codexbar_project_cost(df)

  expect_equal(nrow(out), 1L)
  expect_equal(out$canonical_project, "llm")
})

test_that("summarise_codexbar_project_cost returns an empty tibble for NULL or empty input", {
  out_null  <- summarise_codexbar_project_cost(NULL)
  out_empty <- summarise_codexbar_project_cost(tibble::tibble())

  expect_equal(nrow(out_null), 0L)
  expect_equal(nrow(out_empty), 0L)
  expect_true(all(c("canonical_project", "total_est_cost", "total_duration_min",
                     "n_days", "date_min", "date_max") %in% names(out_null)))
})

test_that("summarise_codexbar_project_cost returns an empty tibble when required columns are missing", {
  df <- tibble::tibble(canonical_project = "llm", duration_min = 10)  # no est_cost, no date

  out <- summarise_codexbar_project_cost(df)

  expect_equal(nrow(out), 0L)
})

# ============================================================================
# load_codexbar_project_cost()
# ============================================================================

test_that("load_codexbar_project_cost returns an empty tibble when the file is absent", {
  out <- load_codexbar_project_cost(path = file.path(tempdir(), "does-not-exist.json"))

  expect_equal(nrow(out), 0L)
  expect_equal(
    names(out),
    c("date", "canonical_project", "est_cost", "duration_min", "share")
  )
})

test_that("load_codexbar_project_cost returns an empty tibble for an empty JSON array", {
  f <- withr::local_tempfile(fileext = ".json")
  writeLines("[]", f)

  out <- load_codexbar_project_cost(path = f)

  expect_equal(nrow(out), 0L)
})

test_that("load_codexbar_project_cost parses a populated day x project fixture", {
  f <- withr::local_tempfile(fileext = ".json")
  jsonlite::write_json(
    data.frame(
      date              = c("2026-07-01", "2026-07-01", "2026-07-02"),
      canonical_project = c("llm", "llmtelemetry", "llm"),
      est_cost          = c(1.23, 4.56, 2.34),
      duration_min      = c(15, 45, 20),
      share             = c(0.25, 0.75, 1),
      stringsAsFactors  = FALSE
    ),
    f,
    auto_unbox = TRUE
  )

  out <- load_codexbar_project_cost(path = f)

  expect_equal(nrow(out), 3L)
  expect_setequal(out$canonical_project, c("llm", "llmtelemetry"))
  expect_type(out$est_cost, "double")
  expect_equal(sum(out$est_cost), 1.23 + 4.56 + 2.34)
})

test_that("load_codexbar_project_cost tolerates a missing duration_min/share column", {
  f <- withr::local_tempfile(fileext = ".json")
  jsonlite::write_json(
    data.frame(
      date              = "2026-07-01",
      canonical_project = "llm",
      est_cost          = 1,
      stringsAsFactors  = FALSE
    ),
    f,
    auto_unbox = TRUE
  )

  out <- load_codexbar_project_cost(path = f)

  expect_equal(nrow(out), 1L)
  expect_true(all(is.na(out$duration_min)))
  expect_true(all(is.na(out$share)))
})

# ============================================================================
# End-to-end: load then summarise
# ============================================================================

test_that("load_codexbar_project_cost output feeds summarise_codexbar_project_cost cleanly", {
  f <- withr::local_tempfile(fileext = ".json")
  jsonlite::write_json(
    data.frame(
      date              = c("2026-07-01", "2026-07-02"),
      canonical_project = c("llm", "llm"),
      est_cost          = c(1, 2),
      duration_min      = c(10, 10),
      share             = c(1, 1),
      stringsAsFactors  = FALSE
    ),
    f,
    auto_unbox = TRUE
  )

  loaded  <- load_codexbar_project_cost(path = f)
  out     <- summarise_codexbar_project_cost(loaded)

  expect_equal(nrow(out), 1L)
  expect_equal(out$total_est_cost, 3)
})
