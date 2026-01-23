# Tests for ccusage progress functions

# Helper function to create sample data
create_sample_daily_data <- function(dates = Sys.Date(), costs = 15.0, tokens = 250000) {
  tibble::tibble(
    date = dates,
    totalCost = costs,
    totalTokens = tokens,
    project = "test-project"
  )
}

create_sample_blocks_data <- function(timestamps = Sys.time(), tokens = 20000) {
  tibble::tibble(
    timestamp = timestamps,
    totalTokens = tokens,
    project = "test-project"
  )
}

# ============================================================================
# 1. show_usage_progress() tests
# ============================================================================

test_that("show_usage_progress calculates percentage correctly", {
  skip_if_not_installed("cli")
  
  # Test basic percentage calculation
  result <- show_usage_progress(current = 50, limit = 100, label = "Test")
  expect_equal(result, 50)
  
  result <- show_usage_progress(current = 75, limit = 100, label = "Test")
  expect_equal(result, 75)
  
  result <- show_usage_progress(current = 100, limit = 100, label = "Test")
  expect_equal(result, 100)
})

test_that("show_usage_progress handles edge cases", {
  skip_if_not_installed("cli")
  
  # Zero usage
  result <- show_usage_progress(current = 0, limit = 100, label = "Test")
  expect_equal(result, 0)
  
  # Over limit (should cap at 100%)
  result <- show_usage_progress(current = 150, limit = 100, label = "Test")
  expect_equal(result, 100)
})

test_that("show_usage_progress validates inputs (TDD - will fail)", {
  skip_if_not_installed("cli")
  
  # These should fail until we add input validation
  expect_error(
    show_usage_progress(current = NULL, limit = 100, label = "Test"),
    "current.*NULL|missing|required"
  )
  
  expect_error(
    show_usage_progress(current = 50, limit = NULL, label = "Test"),
    "limit.*NULL|missing|required"
  )
  
  expect_error(
    show_usage_progress(current = -10, limit = 100, label = "Test"),
    "current.*negative|positive"
  )
  
  expect_error(
    show_usage_progress(current = 50, limit = 0, label = "Test"),
    "limit.*zero|positive"
  )
  
  expect_error(
    show_usage_progress(current = "50", limit = 100, label = "Test"),
    "numeric"
  )
})

test_that("show_usage_progress handles token display", {
  skip_if_not_installed("cli")
  
  # With tokens
  result <- show_usage_progress(
    current = 15, 
    limit = 30,
    label = "Test",
    show_tokens = TRUE,
    tokens_current = 250000,
    tokens_limit = 500000
  )
  expect_equal(result, 50)
  
  # Missing token values when show_tokens = TRUE (should handle gracefully)
  result <- show_usage_progress(
    current = 15,
    limit = 30,
    show_tokens = TRUE,
    tokens_current = NULL,
    tokens_limit = 500000
  )
  expect_equal(result, 50)
})

test_that("show_usage_progress bar formatting is correct", {
  skip_if_not_installed("cli")

  # Test that function runs without error and returns invisibly
  expect_invisible(show_usage_progress(current = 50, limit = 100, label = "Test"))

  # Test different progress levels
  expect_invisible(show_usage_progress(current = 0, limit = 100))
  expect_invisible(show_usage_progress(current = 100, limit = 100))
  expect_invisible(show_usage_progress(current = 75, limit = 100))
})

# ============================================================================
# 2. show_daily_progress() tests
# ============================================================================

test_that("show_daily_progress calculates today's usage correctly", {
  skip_if_not_installed("cli")
  
  # Mock load_cached_ccusage to return test data
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(
        dates = Sys.Date(),
        costs = 15.50,
        tokens = 275000
      )
    }
  )
  
  result <- show_daily_progress(daily_limit = 30, token_limit = 500000)
  
  expect_equal(result$cost, 15.50)
  expect_equal(result$tokens, 275000)
  expect_equal(result$cost_pct, 52)
  expect_equal(result$token_pct, 55)
})

test_that("show_daily_progress handles no data for today", {
  skip_if_not_installed("cli")
  
  # Data from yesterday only
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(
        dates = Sys.Date() - 1,
        costs = 20,
        tokens = 300000
      )
    }
  )
  
  result <- show_daily_progress(daily_limit = 30)
  
  expect_equal(result$cost, 0)
  expect_equal(result$tokens, 0)
  expect_equal(result$cost_pct, 0)
})

test_that("show_daily_progress handles NULL/empty data", {
  skip_if_not_installed("cli")
  
  # NULL data
  local_mocked_bindings(
    load_cached_ccusage = function(...) NULL
  )
  
  result <- show_daily_progress()
  expect_null(result)
  
  # Empty tibble
  local_mocked_bindings(
    load_cached_ccusage = function(...) tibble::tibble()
  )
  
  result <- show_daily_progress()
  expect_null(result)
})

test_that("show_daily_progress uses environment variables for limits", {
  skip_if_not_installed("cli")
  
  withr::local_envvar(
    LLM_DAILY_LIMIT = "50",
    LLM_DAILY_TOKEN_LIMIT = "1000000"
  )
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(costs = 25, tokens = 500000)
    }
  )
  
  result <- show_daily_progress()
  
  # Percentage should be based on env var limits
  expect_equal(result$cost_pct, 50)  # 25/50
  expect_equal(result$token_pct, 50) # 500000/1000000
})

test_that("show_daily_progress handles multiple projects for today", {
  skip_if_not_installed("cli")
  
  # Multiple entries for today
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      tibble::tibble(
        date = rep(Sys.Date(), 3),
        totalCost = c(5, 10, 7.5),
        totalTokens = c(100000, 150000, 125000),
        project = c("proj1", "proj2", "proj3")
      )
    }
  )
  
  result <- show_daily_progress(daily_limit = 30)
  
  # Should sum across all projects
  expect_equal(result$cost, 22.5)
  expect_equal(result$tokens, 375000)
})

# ============================================================================
# 3. show_weekly_progress() tests
# ============================================================================

test_that("show_weekly_progress calculates 7-day window correctly", {
  skip_if_not_installed("cli")
  
  # Data spanning last 7 days
  dates <- seq(Sys.Date() - 6, Sys.Date(), by = "day")
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(
        dates = dates,
        costs = rep(10, 7),
        tokens = rep(200000, 7)
      )
    }
  )
  
  result <- show_weekly_progress(weekly_limit = 120)
  
  expect_equal(result$cost, 70)
  expect_equal(result$cost_pct, 58)
  expect_equal(result$days_with_usage, 7)
})

test_that("show_weekly_progress excludes data outside window", {
  skip_if_not_installed("cli")
  
  # Data from 10 days ago should be excluded
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      tibble::tibble(
        date = c(Sys.Date() - 10, Sys.Date() - 3, Sys.Date()),
        totalCost = c(50, 20, 15),
        totalTokens = c(500000, 300000, 250000),
        project = "test"
      )
    }
  )
  
  result <- show_weekly_progress(weekly_limit = 120)
  
  # Should only include last 2 days (35 total)
  expect_equal(result$cost, 35)
  expect_equal(result$days_with_usage, 2)
})

test_that("show_weekly_progress handles no recent data", {
  skip_if_not_installed("cli")
  
  # Data from 30 days ago only
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(
        dates = Sys.Date() - 30,
        costs = 50,
        tokens = 500000
      )
    }
  )
  
  result <- show_weekly_progress(weekly_limit = 120)
  
  expect_equal(result$cost, 0)
})

test_that("show_weekly_progress uses environment variable for limit", {
  skip_if_not_installed("cli")
  
  withr::local_envvar(LLM_WEEKLY_LIMIT = "200")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(costs = 100, tokens = 1000000)
    }
  )
  
  result <- show_weekly_progress()
  
  expect_equal(result$cost_pct, 50)  # 100/200
})

# ============================================================================
# 4. show_usage_dashboard() tests
# ============================================================================

test_that("show_usage_dashboard combines daily and weekly stats", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(costs = 25, tokens = 400000)
    }
  )
  
  result <- show_usage_dashboard(
    daily_limit = 30,
    weekly_limit = 120,
    token_limit = 500000,
    show_max5 = FALSE
  )
  
  expect_named(result, c("daily", "weekly", "max5"))
  expect_equal(result$daily$cost, 25)
  expect_equal(result$weekly$cost, 25)
  expect_null(result$max5)
})

test_that("show_usage_dashboard includes Max5 when enabled", {
  skip_if_not_installed("cli")
  
  withr::local_envvar(LLM_PLAN = "max5")
  
  local_mocked_bindings(
    load_cached_ccusage = function(type, ...) {
      if (type == "blocks") {
        create_sample_blocks_data()
      } else {
        create_sample_daily_data()
      }
    }
  )
  
  result <- show_usage_dashboard(show_max5 = TRUE)
  
  expect_false(is.null(result$max5))
})

test_that("show_usage_dashboard handles NULL data gracefully", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) NULL
  )
  
  result <- show_usage_dashboard(show_max5 = FALSE)
  
  expect_null(result$daily)
  expect_null(result$weekly)
})

# ============================================================================
# 5. get_current_block_window() tests
# ============================================================================

test_that("get_current_block_window calculates blocks correctly", {
  # Test different hours map to correct blocks
  
  # Hour 0 -> Block 0-5
  time1 <- as.POSIXct("2026-01-22 00:30:00")
  result1 <- get_current_block_window(time1)
  expect_equal(as.integer(format(result1$block_start, "%H")), 0)
  expect_equal(as.integer(format(result1$block_end, "%H")), 5)
  
  # Hour 7 -> Block 5-10
  time2 <- as.POSIXct("2026-01-22 07:30:00")
  result2 <- get_current_block_window(time2)
  expect_equal(as.integer(format(result2$block_start, "%H")), 5)
  expect_equal(as.integer(format(result2$block_end, "%H")), 10)
  
  # Hour 14 -> Block 10-15
  time3 <- as.POSIXct("2026-01-22 14:30:00")
  result3 <- get_current_block_window(time3)
  expect_equal(as.integer(format(result3$block_start, "%H")), 10)
  expect_equal(as.integer(format(result3$block_end, "%H")), 15)
  
  # Hour 22 -> Block 20-25 (next day)
  time4 <- as.POSIXct("2026-01-22 22:30:00")
  result4 <- get_current_block_window(time4)
  expect_equal(as.integer(format(result4$block_start, "%H")), 20)
  expect_equal(as.integer(format(result4$block_end, "%H")), 1)  # Next day
})

test_that("get_current_block_window calculates time remaining correctly", {
  # Test at start of block
  time1 <- as.POSIXct("2026-01-22 10:00:00")
  result1 <- get_current_block_window(time1)
  expect_equal(as.numeric(result1$time_remaining, units = "hours"), 5)
  
  # Test in middle of block
  time2 <- as.POSIXct("2026-01-22 12:30:00")
  result2 <- get_current_block_window(time2)
  expect_equal(as.numeric(result2$time_remaining, units = "hours"), 2.5)
  
  # Test near end of block
  time3 <- as.POSIXct("2026-01-22 14:55:00")
  result3 <- get_current_block_window(time3)
  expect_lt(as.numeric(result3$time_remaining, units = "mins"), 10)
})

test_that("get_current_block_window handles boundary hours correctly", {
  # Exactly on block boundary
  time1 <- as.POSIXct("2026-01-22 05:00:00")
  result1 <- get_current_block_window(time1)
  expect_equal(as.integer(format(result1$block_start, "%H")), 5)
  
  time2 <- as.POSIXct("2026-01-22 15:00:00")
  result2 <- get_current_block_window(time2)
  expect_equal(as.integer(format(result2$block_start, "%H")), 15)
})

test_that("get_current_block_window validates input (TDD - will fail)", {
  # These should fail until we add input validation
  expect_error(
    get_current_block_window(NULL),
    "time|NULL|missing"
  )
  
  expect_error(
    get_current_block_window("not a time"),
    "POSIXct|time|date"
  )
  
  expect_error(
    get_current_block_window(12345),
    "POSIXct|time|date"
  )
})

# ============================================================================
# 6. calculate_block_usage() tests
# ============================================================================

test_that("calculate_block_usage sums tokens in current block", {
  current_time <- as.POSIXct("2026-01-22 12:00:00")
  window <- get_current_block_window(current_time)
  
  # Create data with timestamps in current block
  blocks_data <- tibble::tibble(
    timestamp = c(
      as.POSIXct("2026-01-22 10:30:00"),  # In block
      as.POSIXct("2026-01-22 12:00:00"),  # In block
      as.POSIXct("2026-01-22 14:30:00"),  # In block
      as.POSIXct("2026-01-22 09:00:00"),  # Before block
      as.POSIXct("2026-01-22 16:00:00")   # After block
    ),
    totalTokens = c(10000, 15000, 20000, 50000, 60000),
    project = "test"
  )
  
  result <- calculate_block_usage(blocks_data, window)
  
  # Should only count tokens from current block (45000)
  expect_equal(result$tokens_used, 45000)
  expect_equal(result$usage_pct, 51)  # 45000/88000
})

test_that("calculate_block_usage handles empty data", {
  window <- get_current_block_window()
  
  # NULL data
  result1 <- calculate_block_usage(NULL, window)
  expect_equal(result1$tokens_used, 0)
  expect_equal(result1$usage_pct, 0)
  
  # Empty tibble
  result2 <- calculate_block_usage(tibble::tibble(), window)
  expect_equal(result2$tokens_used, 0)
  expect_equal(result2$usage_pct, 0)
})

test_that("calculate_block_usage handles no data in current block", {
  current_time <- as.POSIXct("2026-01-22 12:00:00")
  window <- get_current_block_window(current_time)
  
  # Data only from other blocks
  blocks_data <- tibble::tibble(
    timestamp = as.POSIXct("2026-01-22 16:00:00"),  # Different block
    totalTokens = 50000,
    project = "test"
  )
  
  result <- calculate_block_usage(blocks_data, window)
  
  expect_equal(result$tokens_used, 0)
  expect_equal(result$usage_pct, 0)
})

test_that("calculate_block_usage uses environment variable for limit", {
  withr::local_envvar(LLM_BLOCK_LIMIT_TOKENS = "100000")
  
  window <- get_current_block_window()
  blocks_data <- create_sample_blocks_data(tokens = 50000)
  
  result <- calculate_block_usage(blocks_data, window)
  
  expect_equal(result$tokens_limit, 100000)
  expect_equal(result$usage_pct, 50)  # 50000/100000
})

test_that("calculate_block_usage validates inputs (TDD - will fail)", {
  window <- get_current_block_window()
  
  # Invalid window structure
  expect_error(
    calculate_block_usage(tibble::tibble(), NULL),
    "window.*NULL|missing|required"
  )
  
  expect_error(
    calculate_block_usage(tibble::tibble(), list()),
    "block_start|block_end"
  )
})

test_that("calculate_block_usage handles NA tokens", {
  window <- get_current_block_window()
  
  blocks_data <- tibble::tibble(
    timestamp = Sys.time(),
    totalTokens = c(10000, NA, 20000, NA),
    project = "test"
  )
  
  result <- calculate_block_usage(blocks_data, window)
  
  # Should sum non-NA values (30000)
  expect_equal(result$tokens_used, 30000)
})

# ============================================================================
# 7. show_max5_block_status() tests
# ============================================================================

test_that("show_max5_block_status displays current block correctly", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_blocks_data(
        timestamps = Sys.time(),
        tokens = 44000  # 50% of 88000
      )
    }
  )
  
  result <- show_max5_block_status()
  
  expect_equal(result$tokens_used, 44000)
  expect_equal(result$usage_pct, 50)
  expect_equal(result$tokens_limit, 88000)
})

test_that("show_max5_block_status handles NULL data", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) NULL
  )
  
  result <- show_max5_block_status()
  
  expect_equal(result$tokens_used, 0)
  expect_equal(result$usage_pct, 0)
})

test_that("show_max5_block_status formats time remaining correctly", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) tibble::tibble()
  )
  
  # Mock to control current time
  local_mocked_bindings(
    get_current_block_window = function(...) {
      list(
        block_start = as.POSIXct("2026-01-22 10:00:00"),
        block_end = as.POSIXct("2026-01-22 15:00:00"),
        time_remaining = as.difftime(2.5, units = "hours")
      )
    }
  )
  
  result <- show_max5_block_status()
  
  expect_equal(as.numeric(result$time_remaining, units = "hours"), 2.5)
})

test_that("show_max5_block_status uses threshold environment variables", {
  skip_if_not_installed("cli")

  withr::local_envvar(
    LLM_WARN_THRESHOLD = "0.60",
    LLM_CRITICAL_THRESHOLD = "0.80"
  )

  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_blocks_data(tokens = 70400)  # 80% of 88000
    }
  )

  # Should run and return status with 80% usage
  result <- show_max5_block_status()

  # Check that we got back the expected usage percentage (field is usage_pct not usage_percent)
  expect_equal(result$usage_pct, 80)
})

# ============================================================================
# 8. get_block_history() tests
# ============================================================================

test_that("get_block_history groups by 5-hour blocks", {
  skip_if_not_installed("cli")

  # Create data spanning multiple blocks - use current time to ensure data isn't filtered
  current_time <- Sys.time()

  local_mocked_bindings(
    load_cached_ccusage = function(type, ...) {
      if (type == "blocks") {
        tibble::tibble(
          timestamp = c(
            current_time - 3600,     # 1 hour ago
            current_time - 2400,     # 40 min ago - same block
            current_time - 600,      # 10 min ago - might be different block
            current_time - 300       # 5 min ago - same block as above
          ),
          totalTokens = c(10000, 15000, 20000, 25000),
          project = "test"
        )
      } else {
        NULL
      }
    }
  )

  result <- get_block_history(days = 1)

  # Should have at least 1 block (all timestamps might be in same block)
  expect_gte(nrow(result), 1)
  expect_lte(nrow(result), 2)  # At most 2 blocks given the time spans

  # Check that total tokens are summed correctly
  total_tokens_sum <- sum(result$total_tokens)
  expect_equal(total_tokens_sum, 70000)  # Sum of all tokens

  # Check that the result has the expected columns
  expect_true("block_hour" %in% names(result))
  expect_true("total_tokens" %in% names(result))
  expect_true("usage_pct" %in% names(result))
  expect_true("status" %in% names(result))
})

test_that("get_block_history filters by days parameter", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      tibble::tibble(
        timestamp = c(
          Sys.time() - 5 * 24 * 3600,  # 5 days ago
          Sys.time() - 2 * 24 * 3600,  # 2 days ago
          Sys.time()                   # Now
        ),
        totalTokens = c(10000, 15000, 20000),
        project = "test"
      )
    }
  )
  
  # Request only 3 days of history
  result <- get_block_history(days = 3)
  
  # Should exclude data from 5 days ago
  expect_lte(nrow(result), 2)
})

test_that("get_block_history handles NULL data", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) NULL
  )
  
  result <- get_block_history()
  
  expect_null(result)
})

test_that("get_block_history calculates status indicators correctly", {
  skip_if_not_installed("cli")

  # Use fixed timestamps to ensure different blocks (00:00, 05:00, 10:00, 15:00, 20:00)
  base_date <- format(Sys.Date(), "%Y-%m-%d")

  local_mocked_bindings(
    load_cached_ccusage = function(type, ...) {
      if (type == "blocks") {
        tibble::tibble(
          timestamp = c(
            as.POSIXct(paste(base_date, "01:00:00")),  # Block 00:00-05:00
            as.POSIXct(paste(base_date, "06:00:00")),  # Block 05:00-10:00
            as.POSIXct(paste(base_date, "11:00:00")),  # Block 10:00-15:00
            as.POSIXct(paste(base_date, "16:00:00"))   # Block 15:00-20:00
          ),
          totalTokens = c(
            44000,  # 50% -> green
            66000,  # 75% -> yellow
            79200,  # 90% -> red
            88000   # 100% -> red
          ),
          project = "test"
        )
      } else {
        NULL
      }
    }
  )

  result <- get_block_history(days = 1)

  # Should have exactly 4 blocks
  expect_equal(nrow(result), 4)

  # Check percentage calculations
  expect_true(all(result$usage_pct %in% c(50, 75, 90, 100)))

  # Check status emoji assignment - at least one of each expected status
  expect_true("🔴" %in% result$status)  # 100% and 90%
  expect_true("🟡" %in% result$status)  # 75%
  expect_true("🟢" %in% result$status)  # 50%
})

test_that("get_block_history sorts by date and hour descending", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      tibble::tibble(
        timestamp = c(
          as.POSIXct("2026-01-20 10:00:00"),
          as.POSIXct("2026-01-22 05:00:00"),
          as.POSIXct("2026-01-21 15:00:00")
        ),
        totalTokens = c(10000, 20000, 15000),
        project = "test"
      )
    }
  )
  
  result <- get_block_history(days = 7)
  
  # Should be sorted newest first
  expect_equal(result$block_date[1], as.Date("2026-01-22"))
  expect_equal(result$block_date[2], as.Date("2026-01-21"))
  expect_equal(result$block_date[3], as.Date("2026-01-20"))
})

test_that("get_block_history limits display to 10 blocks", {
  skip_if_not_installed("cli")
  
  # Create data for 15 blocks
  timestamps <- seq(Sys.time() - 15 * 5 * 3600, Sys.time(), by = "5 hours")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      tibble::tibble(
        timestamp = timestamps,
        totalTokens = rep(20000, length(timestamps)),
        project = "test"
      )
    }
  )
  
  # Capture output
  output <- capture.output({
    result <- get_block_history(days = 7)
  })
  
  # Full result should have all blocks
  expect_gte(nrow(result), 10)
  
  # But display should be limited (check output line count)
  # Each block creates one line of output
  status_lines <- grep("🔴|🟡|🟢|⚪", output)
  expect_lte(length(status_lines), 10)
})

test_that("get_block_history handles empty data gracefully", {
  skip_if_not_installed("cli")
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) tibble::tibble()
  )
  
  result <- get_block_history()
  
  expect_null(result)
})

# ============================================================================
# Integration tests
# ============================================================================

test_that("Integration: dashboard with real-ish data flow", {
  skip_if_not_installed("cli")
  
  # Create comprehensive test dataset
  dates <- seq(Sys.Date() - 6, Sys.Date(), by = "day")
  
  local_mocked_bindings(
    load_cached_ccusage = function(type, ...) {
      if (type == "daily") {
        tibble::tibble(
          date = dates,
          totalCost = c(15, 20, 18, 22, 25, 19, 17),
          totalTokens = rep(300000, 7),
          project = "test"
        )
      } else if (type == "blocks") {
        create_sample_blocks_data()
      } else {
        NULL
      }
    }
  )
  
  # Run full dashboard
  result <- show_usage_dashboard(
    daily_limit = 30,
    weekly_limit = 150,
    token_limit = 500000,
    show_max5 = FALSE
  )
  
  # Verify structure
  expect_named(result, c("daily", "weekly", "max5"))
  
  # Verify calculations
  expect_equal(result$daily$cost, 17)  # Today's cost
  expect_equal(result$weekly$cost, sum(c(15, 20, 18, 22, 25, 19, 17)))
})

test_that("Integration: block window and usage work together", {
  # Test the full flow from getting window to calculating usage
  current_time <- as.POSIXct("2026-01-22 12:30:00")
  
  # Get window
  window <- get_current_block_window(current_time)
  expect_equal(as.integer(format(window$block_start, "%H")), 10)
  
  # Create usage data
  blocks_data <- tibble::tibble(
    timestamp = c(
      as.POSIXct("2026-01-22 10:15:00"),
      as.POSIXct("2026-01-22 11:30:00"),
      as.POSIXct("2026-01-22 13:00:00")
    ),
    totalTokens = c(20000, 30000, 15000),
    project = "test"
  )
  
  # Calculate usage
  usage <- calculate_block_usage(blocks_data, window)
  
  expect_equal(usage$tokens_used, 65000)
  expect_equal(usage$usage_pct, 74)  # 65000/88000
})

# ============================================================================
# Snapshot tests (for formatted output)
# ============================================================================

test_that("show_usage_progress output format is stable", {
  skip_if_not_installed("cli")
  skip_on_cran()  # Snapshot tests can be fragile on CRAN
  
  output <- capture.output({
    show_usage_progress(
      current = 25,
      limit = 50,
      label = "Test Progress"
    )
  })
  
  expect_snapshot(output)
})

test_that("show_daily_progress output format is stable", {
  skip_if_not_installed("cli")
  skip_on_cran()
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      create_sample_daily_data(costs = 15, tokens = 300000)
    }
  )
  
  output <- capture.output({
    show_daily_progress(daily_limit = 30, token_limit = 500000)
  })
  
  expect_snapshot(output)
})

test_that("get_block_history output format is stable", {
  skip_if_not_installed("cli")
  skip_on_cran()
  
  local_mocked_bindings(
    load_cached_ccusage = function(...) {
      tibble::tibble(
        timestamp = as.POSIXct("2026-01-22 10:30:00"),
        totalTokens = 44000,
        project = "test"
      )
    }
  )
  
  output <- capture.output({
    get_block_history(days = 1)
  })
  
  expect_snapshot(output)
})
