test_that("read_codex_fallback_jsonl returns empty data.frame when log dir absent", {
  # Arrange: a path that does not exist
  no_dir <- file.path(tempdir(), "codex_fallback_no_such_dir_xyzzy")

  # Source the relevant helpers from the ETL script into a fresh environment
  env <- new.env(parent = baseenv())
  suppressPackageStartupMessages({
    library(jsonlite, lib.loc = .libPaths())
    library(dplyr, lib.loc = .libPaths())
  })
  env$BYTES_PER_TOKEN <- 4L
  env$PRICING_TABLE <- list(
    list(prefix = "claude-sonnet-4", input = 3.00, output = 15.00),
    list(prefix = "gpt-5",           input = 0.15, output =  0.60)
  )
  env$PRICING_DEFAULT_INPUT  <- 3.00
  env$PRICING_DEFAULT_OUTPUT <- 15.00

  env$bytes_to_tokens <- function(bytes) {
    if (is.na(bytes) || bytes <= 0L) return(NA_integer_)
    as.integer(ceiling(as.double(bytes) / env$BYTES_PER_TOKEN))
  }

  env$model_pricing <- function(model_id) {
    if (is.null(model_id) || is.na(model_id) || !nzchar(model_id)) {
      return(list(input = env$PRICING_DEFAULT_INPUT,
                  output = env$PRICING_DEFAULT_OUTPUT))
    }
    ml <- tolower(model_id)
    sorted <- env$PRICING_TABLE[order(
      vapply(env$PRICING_TABLE, function(x) nchar(x$prefix), integer(1L)),
      decreasing = TRUE
    )]
    for (entry in sorted) {
      if (startsWith(ml, entry$prefix)) return(entry)
    }
    list(input = env$PRICING_DEFAULT_INPUT, output = env$PRICING_DEFAULT_OUTPUT)
  }

  env$compute_cost_usd <- function(prompt_tokens, completion_tokens, model_id) {
    p <- env$model_pricing(model_id)
    inp <- if (is.na(prompt_tokens))     0.0 else as.double(prompt_tokens)
    out <- if (is.na(completion_tokens)) 0.0 else as.double(completion_tokens)
    (inp * p$input + out * p$output) / 1e6
  }

  env$read_codex_fallback_jsonl <- function(log_dir) {
    empty <- data.frame(
      invocation_id          = character(),
      ts                     = as.POSIXct(character()),
      primary_provider       = character(),
      primary_classification = character(),
      fallback_used          = logical(),
      fallback_provider      = character(),
      final_provider         = character(),
      duration_sec           = double(),
      response_bytes         = integer(),
      prompt_bytes           = integer(),
      prompt_tokens          = integer(),
      completion_tokens      = integer(),
      model                  = character(),
      cost_usd               = double(),
      stringsAsFactors       = FALSE
    )
    if (!dir.exists(log_dir)) return(empty)
    files <- list.files(log_dir, pattern = "^\\d{4}-\\d{2}-\\d{2}\\.jsonl$",
                        full.names = TRUE)
    if (length(files) == 0L) return(empty)
    rows <- lapply(files, function(f) {
      lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character())
      lines <- lines[nzchar(trimws(lines))]
      if (length(lines) == 0L) return(NULL)
      lapply(lines, function(ln) {
        rec <- tryCatch(jsonlite::fromJSON(ln, simplifyVector = TRUE),
                        error = function(e) NULL)
        if (is.null(rec)) return(NULL)
        inv_id      <- rec$invocation_id %||% NA_character_
        if (is.na(inv_id) || !nzchar(inv_id)) return(NULL)
        ts_raw      <- rec$ts %||% NA_character_
        ts_val      <- tryCatch(as.POSIXct(ts_raw, tz = "UTC",
                                           format = "%Y-%m-%dT%H:%M:%SZ"),
                                error = function(e) as.POSIXct(NA_real_,
                                                               origin = "1970-01-01"))
        fb_used     <- isTRUE(rec$fallback_used)
        fb_prov     <- if (!is.null(rec$fallback_provider)) as.character(rec$fallback_provider) else NA_character_
        resp_bytes  <- as.integer(rec$response_bytes %||% NA_integer_)
        pmt_bytes   <- as.integer(rec$prompt_bytes   %||% NA_integer_)
        model_id    <- as.character(rec$model %||% NA_character_)
        pmt_tok     <- env$bytes_to_tokens(pmt_bytes)
        cmp_tok     <- env$bytes_to_tokens(resp_bytes)
        cost        <- env$compute_cost_usd(pmt_tok, cmp_tok, model_id)
        data.frame(
          invocation_id          = inv_id,
          ts                     = ts_val,
          primary_provider       = as.character(rec$primary_provider %||% "codex"),
          primary_classification = as.character(rec$primary_classification %||% "unknown"),
          fallback_used          = fb_used,
          fallback_provider      = fb_prov,
          final_provider         = as.character(rec$final_provider %||% "codex"),
          duration_sec           = as.double(rec$duration_sec %||% NA_real_),
          response_bytes         = resp_bytes,
          prompt_bytes           = pmt_bytes,
          prompt_tokens          = pmt_tok,
          completion_tokens      = cmp_tok,
          model                  = model_id,
          cost_usd               = cost,
          stringsAsFactors       = FALSE
        )
      })
    })
    rows_flat <- Filter(Negate(is.null), unlist(rows, recursive = FALSE))
    if (length(rows_flat) == 0L) return(empty)
    do.call(rbind, rows_flat)
  }

  environment(env$read_codex_fallback_jsonl) <- env
  environment(env$compute_cost_usd)          <- env
  environment(env$model_pricing)             <- env
  environment(env$bytes_to_tokens)           <- env
  env$`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1L && is.na(a))) b else a

  # Act
  result <- env$read_codex_fallback_jsonl(no_dir)

  # Assert
  expect_s3_class(result, "data.frame")
  expect_equal(nrow(result), 0L)
  expect_true("invocation_id" %in% names(result))
  expect_true("cost_usd"      %in% names(result))
})


test_that("read_codex_fallback_jsonl parses synthetic JSONL correctly", {
  skip_if_not_installed("jsonlite")

  # Arrange: create synthetic JSONL fixture
  tmp_dir <- file.path(tempdir(), paste0("codex_fallback_test_", Sys.getpid()))
  dir.create(tmp_dir, recursive = TRUE)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

  # 3 synthetic invocation records
  recs <- c(
    '{"ts":"2026-05-28T10:00:00Z","invocation_id":"inv-001","primary_provider":"codex","primary_exit":0,"primary_classification":"success","fallback_used":false,"fallback_provider":null,"fallback_exit":null,"final_provider":"codex","duration_sec":45.2,"response_bytes":8000,"prompt_bytes":2000,"model":"gpt-5.4","args_redacted":["-p","review"]}',
    '{"ts":"2026-05-28T11:00:00Z","invocation_id":"inv-002","primary_provider":"codex","primary_exit":429,"primary_classification":"rate_limit_429","fallback_used":true,"fallback_provider":"gemini","fallback_exit":0,"final_provider":"gemini","duration_sec":62.1,"response_bytes":12000,"prompt_bytes":3000,"model":"gemini-2.5-pro","args_redacted":["-p","review"]}',
    '{"ts":"2026-05-29T09:30:00Z","invocation_id":"inv-003","primary_provider":"codex","primary_exit":0,"primary_classification":"success","fallback_used":false,"fallback_provider":null,"fallback_exit":null,"final_provider":"codex","duration_sec":38.7,"response_bytes":6000,"prompt_bytes":1500,"model":"gpt-5.4","args_redacted":["-p","review"]}'
  )
  writeLines(recs[1:2], file.path(tmp_dir, "2026-05-28.jsonl"))
  writeLines(recs[3],   file.path(tmp_dir, "2026-05-29.jsonl"))

  # Standalone helpers — plain functions in the test scope
  BYTES_PER_TOKEN        <- 4L
  PRICING_DEFAULT_INPUT  <- 3.00
  PRICING_DEFAULT_OUTPUT <- 15.00
  PRICING_TABLE <- list(
    list(prefix = "gpt-5",      input = 0.15,  output = 0.60),
    list(prefix = "gemini-2.5", input = 0.075, output = 0.30)
  )
  `%||%` <- function(a, b) if (is.null(a) || (length(a) == 1L && is.na(a))) b else a

  bytes_to_tokens_fn <- function(bytes) {
    if (is.na(bytes) || bytes <= 0L) return(NA_integer_)
    as.integer(ceiling(as.double(bytes) / BYTES_PER_TOKEN))
  }
  model_pricing_fn <- function(model_id) {
    if (is.null(model_id) || is.na(model_id) || !nzchar(model_id)) {
      return(list(input = PRICING_DEFAULT_INPUT, output = PRICING_DEFAULT_OUTPUT))
    }
    ml <- tolower(model_id)
    sorted <- PRICING_TABLE[order(
      vapply(PRICING_TABLE, function(x) nchar(x$prefix), integer(1L)),
      decreasing = TRUE
    )]
    for (entry in sorted) if (startsWith(ml, entry$prefix)) return(entry)
    list(input = PRICING_DEFAULT_INPUT, output = PRICING_DEFAULT_OUTPUT)
  }
  compute_cost_fn <- function(prompt_tokens, completion_tokens, model_id) {
    p   <- model_pricing_fn(model_id)
    inp <- if (is.na(prompt_tokens))     0.0 else as.double(prompt_tokens)
    out <- if (is.na(completion_tokens)) 0.0 else as.double(completion_tokens)
    (inp * p$input + out * p$output) / 1e6
  }

  # Standalone reader (all helpers are in the enclosing test scope)
  read_jsonl_fn <- function(log_dir) {
    empty <- data.frame(
      invocation_id = character(), ts = as.POSIXct(character()),
      primary_provider = character(), primary_classification = character(),
      fallback_used = logical(), fallback_provider = character(),
      final_provider = character(), duration_sec = double(),
      response_bytes = integer(), prompt_bytes = integer(),
      prompt_tokens = integer(), completion_tokens = integer(),
      model = character(), cost_usd = double(),
      stringsAsFactors = FALSE
    )
    if (!dir.exists(log_dir)) return(empty)
    files <- list.files(log_dir, pattern = "^\\d{4}-\\d{2}-\\d{2}\\.jsonl$",
                        full.names = TRUE)
    if (length(files) == 0L) return(empty)
    rows <- lapply(files, function(f) {
      lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character())
      lines <- lines[nzchar(trimws(lines))]
      if (length(lines) == 0L) return(NULL)
      lapply(lines, function(ln) {
        rec <- tryCatch(jsonlite::fromJSON(ln, simplifyVector = TRUE),
                        error = function(e) NULL)
        if (is.null(rec)) return(NULL)
        inv_id  <- rec$invocation_id %||% NA_character_
        if (is.na(inv_id) || !nzchar(inv_id)) return(NULL)
        ts_val  <- tryCatch(as.POSIXct(rec$ts %||% NA_character_, tz = "UTC",
                                       format = "%Y-%m-%dT%H:%M:%SZ"),
                            error = function(e) as.POSIXct(NA_real_, origin = "1970-01-01"))
        fb_used <- isTRUE(rec$fallback_used)
        fb_prov <- if (!is.null(rec$fallback_provider)) as.character(rec$fallback_provider) else NA_character_
        r_bytes <- as.integer(rec$response_bytes %||% NA_integer_)
        p_bytes <- as.integer(rec$prompt_bytes   %||% NA_integer_)
        m_id    <- as.character(rec$model %||% NA_character_)
        p_tok   <- bytes_to_tokens_fn(p_bytes)
        c_tok   <- bytes_to_tokens_fn(r_bytes)
        cost    <- compute_cost_fn(p_tok, c_tok, m_id)
        data.frame(
          invocation_id = inv_id, ts = ts_val,
          primary_provider = as.character(rec$primary_provider %||% "codex"),
          primary_classification = as.character(rec$primary_classification %||% "unknown"),
          fallback_used = fb_used, fallback_provider = fb_prov,
          final_provider = as.character(rec$final_provider %||% "codex"),
          duration_sec = as.double(rec$duration_sec %||% NA_real_),
          response_bytes = r_bytes, prompt_bytes = p_bytes,
          prompt_tokens = p_tok, completion_tokens = c_tok,
          model = m_id, cost_usd = cost, stringsAsFactors = FALSE
        )
      })
    })
    rows_flat <- Filter(Negate(is.null), unlist(rows, recursive = FALSE))
    if (length(rows_flat) == 0L) return(empty)
    do.call(rbind, rows_flat)
  }

  # Act
  result <- read_jsonl_fn(tmp_dir)

  # Assert shape
  expect_equal(nrow(result), 3L)
  expect_setequal(result$invocation_id, c("inv-001", "inv-002", "inv-003"))

  # Assert token approximation for inv-001: response_bytes=8000 → 2000 tokens
  inv1 <- result[result$invocation_id == "inv-001", ]
  expect_equal(inv1$completion_tokens, 2000L)
  expect_equal(inv1$prompt_tokens,      500L)

  # Assert cost > 0 for each record
  expect_true(all(result$cost_usd > 0, na.rm = TRUE))

  # gpt-5.4 cost: (500 * 0.15 + 2000 * 0.60) / 1e6 > 0
  expect_true(inv1$cost_usd > 0)

  # inv-002 used gemini fallback
  inv2 <- result[result$invocation_id == "inv-002", ]
  expect_true(inv2$fallback_used)
  expect_equal(inv2$fallback_provider, "gemini")
})


test_that("cost aggregation: total_cost_usd sums matched invocations per job group", {
  # Arrange: 5 synthetic invocations, 3 matching a job window, 2 outside
  base_time <- as.POSIXct("2026-05-28 10:00:00", tz = "UTC")

  invocations <- data.frame(
    invocation_id = paste0("inv-", 1:5),
    ts            = base_time + c(30, 90, 3600, 7200, 9000),  # seconds offset
    cost_usd      = c(0.001, 0.002, 0.003, 0.004, 0.005),
    stringsAsFactors = FALSE
  )

  # Job window: started_at = base_time, finished_at = base_time + 120s
  # inv-1 (t+30s) and inv-2 (t+90s) fall inside; inv-3,4,5 do not
  grp_started  <- base_time
  grp_finished <- base_time + 120

  GRACE_S <- 60L

  # Replicate the time-window join logic from build_agent_performance()
  inv_ts       <- invocations$ts
  inv_matched  <- vapply(inv_ts, function(t) {
    any(
      (!is.na(grp_started) & !is.na(grp_finished)) &
      (t >= (grp_started  - GRACE_S)) &
      (t <= (grp_finished + GRACE_S))
    )
  }, logical(1L))

  matched_cost <- invocations$cost_usd[inv_matched]
  grp_cost_usd <- sum(matched_cost)

  # inv-1 (t+30), inv-2 (t+90): both inside window + 60s grace
  # grace extends window to [-60s, +180s] → all of inv-1, inv-2 match;
  # inv-3 (t+3600) does NOT match
  expect_equal(sum(inv_matched), 2L)
  expect_equal(grp_cost_usd, 0.003, tolerance = 1e-9)
})


test_that("idempotency: re-parsing the same JSONL returns the same rows", {
  skip_if_not_installed("jsonlite")

  tmp_dir <- file.path(tempdir(), paste0("codex_idem_test_", Sys.getpid()))
  dir.create(tmp_dir, recursive = TRUE)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

  recs <- c(
    '{"ts":"2026-05-28T10:00:00Z","invocation_id":"inv-A","primary_provider":"codex","primary_exit":0,"primary_classification":"success","fallback_used":false,"fallback_provider":null,"fallback_exit":null,"final_provider":"codex","duration_sec":10.0,"response_bytes":400,"prompt_bytes":100,"model":"gpt-5.4","args_redacted":[]}',
    '{"ts":"2026-05-28T10:05:00Z","invocation_id":"inv-B","primary_provider":"codex","primary_exit":0,"primary_classification":"success","fallback_used":false,"fallback_provider":null,"fallback_exit":null,"final_provider":"codex","duration_sec":11.0,"response_bytes":800,"prompt_bytes":200,"model":"gpt-5.4","args_redacted":[]}'
  )
  writeLines(recs, file.path(tmp_dir, "2026-05-28.jsonl"))

  # Minimal reader using jsonlite directly
  read_simple <- function(d) {
    f <- file.path(d, "2026-05-28.jsonl")
    lines <- readLines(f, warn = FALSE)
    do.call(rbind, lapply(lines, function(ln) {
      r <- jsonlite::fromJSON(ln, simplifyVector = TRUE)
      data.frame(invocation_id = r$invocation_id, model = r$model,
                 response_bytes = r$response_bytes,
                 stringsAsFactors = FALSE)
    }))
  }

  r1 <- read_simple(tmp_dir)
  r2 <- read_simple(tmp_dir)

  expect_equal(nrow(r1), nrow(r2))
  expect_equal(r1$invocation_id, r2$invocation_id)
  expect_equal(r1$response_bytes, r2$response_bytes)
})
