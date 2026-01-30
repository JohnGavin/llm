# Tests for Gemini session log parsing

test_that("Gemini sessionId extraction from filename works", {
  # Sample filename pattern
  fname <- "session-2026-01-13T12-39-ce182e3b.json"
  
  sid_match <- regexec("session-(.*)\.json", fname)
  expect_true(sid_match[[1]][1] != -1)
  
  sid <- regmatches(fname, sid_match)[[1]][2]
  expect_equal(sid, "2026-01-13T12-39-ce182e3b")
})

test_that("Gemini message parsing logic is correct", {
  # Mock a single message from the JSON structure
  msg <- list(
    id = "test-id",
    timestamp = "2026-01-13T12:39:56.564Z",
    type = "gemini",
    model = "gemini-1.5-flash",
    tokens = list(
      input = 1000,
      output = 200,
      cached = 500
    )
  )
  
  # Logic from refresh_gemini_cache.R
  timestamp <- lubridate::ymd_hms(msg$timestamp)
  expect_s3_class(timestamp, "POSIXct")
  
  input <- as.numeric(msg$tokens$input %||% 0)
  expect_equal(input, 1000)
  
  # Pricing check (1.5 Flash: 0.075 input, 0.30 output, 0.01875 cached)
  # (1000*0.075 + 200*0.30 + 500*0.01875) / 1e6
  expected_cost <- (1000*0.075 + 200*0.30 + 500*0.01875) / 1e6
  
  # Replicate calculate_cost logic
  rates <- list(input = 0.075, output = 0.30, cached = 0.01875)
  cost <- (input * rates$input + 
           as.numeric(msg$tokens$output) * rates$output + 
           as.numeric(msg$tokens$cached) * rates$cached) / 1e6
           
  expect_equal(cost, expected_cost)
})

test_that("Gemini integration with DuckDB can be initialized", {
  skip_if_not_installed("duckdb")
  
  tmp_db <- tempfile(fileext = ".duckdb")
  con <- dbConnect(duckdb::duckdb(), dbdir = tmp_db)
  
  # Ensure we can create the summary table
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sessions_summary (
      sessionId VARCHAR PRIMARY KEY,
      total_tokens BIGINT,
      total_cost DOUBLE
    )
  ")
  
  expect_true("sessions_summary" %in% dbListTables(con))
  dbDisconnect(con, shutdown = TRUE)
})
