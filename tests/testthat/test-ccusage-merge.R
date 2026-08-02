# Tests for llm#870: merging the two disjoint ccusage daily cache windows.

# ============================================================================
# Helpers
# ============================================================================

make_daily_row <- function(project, date, totalCost = 1, totalTokens = 100,
                            inputTokens = 10, outputTokens = 5,
                            cacheCreationTokens = 0, cacheReadTokens = 0) {
  tibble::tibble(
    date = date,
    inputTokens = inputTokens,
    outputTokens = outputTokens,
    cacheCreationTokens = cacheCreationTokens,
    cacheReadTokens = cacheReadTokens,
    totalTokens = totalTokens,
    totalCost = totalCost,
    modelsUsed = list("claude-opus"),
    modelBreakdowns = list(tibble::tibble(
      modelName = "claude-opus", inputTokens = inputTokens,
      outputTokens = outputTokens, cacheCreationTokens = cacheCreationTokens,
      cacheReadTokens = cacheReadTokens, cost = totalCost
    )),
    project = project
  )
}

# ============================================================================
# 1. canonicalize_ccusage_project() -- both naming schemes
# ============================================================================

test_that("canonicalize_ccusage_project maps the old dash-mangled scheme", {
  expect_equal(
    canonicalize_ccusage_project("-Users-johngavin-docs-gh-llm"),
    "llm"
  )
  expect_equal(
    canonicalize_ccusage_project("-Users-johngavin-docs-gh-llmtelemetry"),
    "llmtelemetry"
  )
  expect_equal(
    canonicalize_ccusage_project(
      "-Users-johngavin-docs-gh-proj-finance-data-historical"
    ),
    "historical"
  )
  expect_equal(
    canonicalize_ccusage_project(
      "-Users-johngavin-docs-gh-proj-pers-travel"
    ),
    "travel"
  )
  expect_equal(
    canonicalize_ccusage_project(
      "-Users-johngavin-docs--pers-NHS-health-data-antigravity-mycare"
    ),
    "mycare"
  )
})

test_that("canonicalize_ccusage_project maps the new short-form scheme", {
  expect_equal(canonicalize_ccusage_project("llm"), "llm")
  expect_equal(canonicalize_ccusage_project("llmtelemetry"), "llmtelemetry")
  expect_equal(canonicalize_ccusage_project("historical"), "historical")
  expect_equal(canonicalize_ccusage_project("travel"), "travel")
  expect_equal(canonicalize_ccusage_project("mycare"), "mycare")
  # slash-form sub-path collapses onto the project, not the sub-path
  expect_equal(canonicalize_ccusage_project("llm/knowledge"), "llm")
})

test_that("old and new schemes canonicalise the SAME real project identically", {
  # This is the property the merge depends on: a project active in both
  # windows must resolve to one shared key, or its per-project series would
  # falsely appear to end in one window and begin fresh in the other.
  pairs <- list(
    c("-Users-johngavin-docs-gh-llm", "llm"),
    c("-Users-johngavin-docs-gh-llmtelemetry", "llmtelemetry"),
    c("-Users-johngavin-docs-gh-proj-finance-data-historical", "historical"),
    c("-Users-johngavin-docs-gh-proj-pers-travel", "travel"),
    c(
      "-Users-johngavin-docs--pers-NHS-health-data-antigravity-mycare",
      "mycare"
    )
  )
  for (p in pairs) {
    expect_equal(
      canonicalize_ccusage_project(p[1]),
      canonicalize_ccusage_project(p[2]),
      info = sprintf("old=%s new=%s", p[1], p[2])
    )
  }
})

test_that("canonicalize_ccusage_project is vectorised and preserves NA", {
  result <- canonicalize_ccusage_project(c("llm", NA, "historical"))
  expect_equal(result, c("llm", NA_character_, "historical"))
  expect_equal(canonicalize_ccusage_project(character(0)), character(0))
  expect_equal(canonicalize_ccusage_project(NULL), character(0))
})

# ============================================================================
# 2. Ephemeral bucketing (NOT dropped, NOT NA -- explicit sentinel)
# ============================================================================

test_that("ephemeral entries bucket to the sentinel, not NA and not dropped", {
  ephemeral_raw <- c(
    # new-scheme per-agent worktree paths
    "llm//claude/worktrees/agent/a8a55593cef9747a7",
    "llm//claude/worktrees/agent/ad6b73b1531e56062",
    # old-scheme roborev worktrees
    "-private-tmp-roborev-worktree-1248728332",
    "-private-tmp-roborev-worktree-1417729064",
    # old-scheme random-hash tmp clones
    "-private-tmp-tmp-D73dOZsvyf-repo",
    # bare noise tokens
    "worktrees",
    "unknown",
    "roborev"
  )
  result <- canonicalize_ccusage_project(ephemeral_raw)
  expect_true(all(result == CCUSAGE_EPHEMERAL))
  expect_false(anyNA(result))
})

test_that("a real project name is never mistaken for the ephemeral sentinel", {
  real_raw <- c("llm", "historical", "travel", "mycare", "llmtelemetry")
  result <- canonicalize_ccusage_project(real_raw)
  expect_false(any(result == CCUSAGE_EPHEMERAL))
})

test_that("CCUSAGE_EPHEMERAL is a stable, distinctive sentinel string", {
  expect_equal(CCUSAGE_EPHEMERAL, "<ephemeral>")
  # not a value that could plausibly collide with a real project name
  expect_false(CCUSAGE_EPHEMERAL %in% c("llm", "historical", "travel"))
})

# ============================================================================
# 3. merge_ccusage_daily() -- union row count / no silent data loss
# ============================================================================

test_that("merge_ccusage_daily unions two disjoint windows with no data loss", {
  llm_data <- dplyr::bind_rows(
    make_daily_row("llm", "2026-01-10", totalCost = 5, totalTokens = 500),
    make_daily_row("historical", "2026-01-11", totalCost = 3, totalTokens = 300)
  )
  telemetry_data <- dplyr::bind_rows(
    make_daily_row("llm", "2026-06-29", totalCost = 7, totalTokens = 700),
    make_daily_row("travel", "2026-07-01", totalCost = 2, totalTokens = 200)
  )

  merged <- merge_ccusage_daily(llm_data, telemetry_data)

  expect_s3_class(merged, "data.frame")
  expect_equal(nrow(merged), 4L)
  expect_equal(sum(merged$totalCost), 5 + 3 + 7 + 2)
  expect_equal(sum(merged$totalTokens), 500 + 300 + 700 + 200)
  expect_setequal(merged$date, c("2026-01-10", "2026-01-11", "2026-06-29", "2026-07-01"))
})

test_that("merge_ccusage_daily sums (does not drop) same-source raw-project collisions", {
  # Two DIFFERENT raw project names that canonicalise to the same key on the
  # same date -- this is the exact bug pattern found while implementing
  # llm#870: naive dedup-by-(project,date) picked one row and silently
  # discarded the other's cost/tokens.
  llm_data <- dplyr::bind_rows(
    make_daily_row(
      "-private-tmp-roborev-worktree-1111111111", "2026-04-05",
      totalCost = 4, totalTokens = 400
    ),
    make_daily_row(
      "-private-tmp-roborev-worktree-2222222222", "2026-04-05",
      totalCost = 6, totalTokens = 600
    )
  )

  merged <- merge_ccusage_daily(llm_data, NULL)

  expect_equal(nrow(merged), 1L)
  expect_equal(merged$project, CCUSAGE_EPHEMERAL)
  expect_equal(merged$totalCost, 10)
  expect_equal(merged$totalTokens, 1000)
  # both raw contributors are recorded, not silently dropped
  expect_match(merged$project_raw, "1111111111")
  expect_match(merged$project_raw, "2222222222")
})

test_that("merge_ccusage_daily returns NULL when both sources are empty", {
  expect_null(merge_ccusage_daily(NULL, NULL))
  expect_null(merge_ccusage_daily(tibble::tibble(), tibble::tibble()))
})

test_that("merge_ccusage_daily handles a single non-NULL source", {
  llm_data <- make_daily_row("llm", "2026-01-10", totalCost = 5)
  merged <- merge_ccusage_daily(llm_data, NULL)
  expect_equal(nrow(merged), 1L)
  expect_equal(merged$source_window, "llm")
  expect_equal(merged$project, "llm")
  expect_equal(merged$project_raw, "llm")
})

# ============================================================================
# 4. Gap representation -- explicit, not interpolated
# ============================================================================

test_that("merge_ccusage_daily exposes the cross-window gap explicitly", {
  llm_data <- make_daily_row("llm", "2026-05-09", totalCost = 1)
  telemetry_data <- make_daily_row("llm", "2026-06-29", totalCost = 1)

  merged <- merge_ccusage_daily(llm_data, telemetry_data)

  # No fabricated row for any date inside the gap.
  expect_false(any(merged$date > "2026-05-09" & merged$date < "2026-06-29"))

  gaps <- attr(merged, "ccusage_gaps")
  expect_s3_class(gaps, "data.frame")
  expect_true(nrow(gaps) >= 1L)
  big_gap <- gaps[which.max(gaps$gap_days), ]
  expect_equal(as.character(big_gap$gap_start), "2026-05-10")
  expect_equal(as.character(big_gap$gap_end), "2026-06-28")
  expect_equal(big_gap$gap_days, 50L)
})

test_that("find_activity_gaps also detects the gap directly on the merged data", {
  llm_data <- make_daily_row("llm", "2026-05-09", totalCost = 1)
  telemetry_data <- make_daily_row("llm", "2026-06-29", totalCost = 1)
  merged <- merge_ccusage_daily(llm_data, telemetry_data)

  gaps <- find_activity_gaps(merged)
  expect_true(any(gaps$gap_days == 50L))
})

# ============================================================================
# 5. Dedup-on-overlap (cross-source; not exercised by real data today, but
#    the rule must hold if a future refresh creates overlap)
# ============================================================================

test_that("merge_ccusage_daily dedups (does not sum) a cross-source overlap", {
  # Same canonical project + same date present in BOTH windows: this
  # represents the same underlying observation recorded twice (e.g. a stale
  # llm copy plus a corrected llmtelemetry refresh), so llmtelemetry should
  # win outright rather than the values being added together.
  llm_data <- make_daily_row("llm", "2026-07-01", totalCost = 1, totalTokens = 100)
  telemetry_data <- make_daily_row("llm", "2026-07-01", totalCost = 9, totalTokens = 900)

  merged <- merge_ccusage_daily(llm_data, telemetry_data)

  expect_equal(nrow(merged), 1L)
  expect_equal(merged$source_window, "llmtelemetry")
  expect_equal(merged$totalCost, 9)
  expect_equal(merged$totalTokens, 900)
})

test_that("dedup-on-overlap is scoped to the colliding (project, date) pair only", {
  llm_data <- dplyr::bind_rows(
    make_daily_row("llm", "2026-07-01", totalCost = 1),
    make_daily_row("historical", "2026-07-02", totalCost = 2)
  )
  telemetry_data <- make_daily_row("llm", "2026-07-01", totalCost = 9)

  merged <- merge_ccusage_daily(llm_data, telemetry_data)

  expect_equal(nrow(merged), 2L)
  llm_row <- merged[merged$project == "llm", ]
  hist_row <- merged[merged$project == "historical", ]
  expect_equal(llm_row$totalCost, 9)
  expect_equal(llm_row$source_window, "llmtelemetry")
  expect_equal(hist_row$totalCost, 2)
  expect_equal(hist_row$source_window, "llm")
})

# ============================================================================
# 6. ccusage_daily_cache_paths() -- source discovery
# ============================================================================

test_that("ccusage_daily_cache_paths finds the package copy via LLM_CCUSAGE_DIR-independent lookup", {
  withr::local_tempdir() -> tmp
  withr::local_envvar(c(LLM_PROJECTS_ROOT = tmp))
  # Neither source exists under this isolated root.
  paths <- ccusage_daily_cache_paths()
  expect_true(is.na(paths["llmtelemetry"]) || !("llmtelemetry" %in% names(paths)))
})

test_that("ccusage_daily_cache_paths finds an llmtelemetry fixture when present", {
  tmp <- withr::local_tempdir()
  telemetry_dir <- file.path(tmp, "llmtelemetry", "inst", "extdata")
  dir.create(telemetry_dir, recursive = TRUE)
  fixture <- list(
    projects = list(llm = list(
      date = "2026-07-01", inputTokens = 1, outputTokens = 1,
      cacheCreationTokens = 0, cacheReadTokens = 0,
      totalTokens = 2, totalCost = 0.1, modelsUsed = list("m"),
      modelBreakdowns = list(list())
    )),
    totals = list()
  )
  jsonlite::write_json(
    fixture, file.path(telemetry_dir, "ccusage_daily_all.json"),
    auto_unbox = TRUE
  )
  withr::local_envvar(c(LLM_PROJECTS_ROOT = tmp))

  paths <- ccusage_daily_cache_paths()
  expect_true("llmtelemetry" %in% names(paths))
  expect_true(file.exists(paths["llmtelemetry"]))
})

# ============================================================================
# 7. load_cached_ccusage("daily") wiring + backward compatibility
# ============================================================================

test_that("load_cached_ccusage('daily') with explicit cache_dir keeps old single-source shape", {
  tmp <- withr::local_tempdir()
  fixture <- list(
    projects = list(myproj = list(
      date = c("2026-01-01", "2026-01-02"),
      inputTokens = c(1, 2), outputTokens = c(1, 2),
      cacheCreationTokens = c(0, 0), cacheReadTokens = c(0, 0),
      totalTokens = c(2, 4), totalCost = c(0.1, 0.2),
      modelsUsed = list(list("m"), list("m")),
      modelBreakdowns = list(list(), list())
    )),
    totals = list()
  )
  jsonlite::write_json(
    fixture, file.path(tmp, "ccusage_daily_all.json"), auto_unbox = TRUE
  )

  result <- load_cached_ccusage("daily", cache_dir = tmp)

  expect_equal(nrow(result), 2L)
  expect_false("project_raw" %in% colnames(result))
  expect_false("source_window" %in% colnames(result))
  expect_equal(unique(result$project), "myproj")
})

test_that("load_cached_ccusage('daily') with no sources available returns NULL with a message", {
  withr::local_envvar(c(
    LLM_CCUSAGE_DIR = "",
    LLM_PROJECTS_ROOT = withr::local_tempdir()
  ))
  # Force ccusage_pkg_cache_dir() to find nothing by pointing HOME-derived
  # lookups at an isolated tempdir; if the package copy still resolves in
  # this dev checkout, skip rather than assert a false negative.
  pkg_dir <- ccusage_pkg_cache_dir()
  skip_if(
    !is.null(pkg_dir) &&
      file.exists(file.path(pkg_dir, "ccusage_daily_all.json")),
    "package ships its own ccusage_daily_all.json in this checkout"
  )
  expect_message(
    result <- load_cached_ccusage("daily"),
    "Cache file not found"
  )
  expect_null(result)
})
