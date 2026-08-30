#!/usr/bin/env Rscript
# tests/test_launchd_health_stale_processes.R
#
# testthat tests for the stale/wedged-process detection added to
# .claude/scripts/launchd_health_report.R (llm#957).
#
# Origin: a `timeout 30 signal-cli ... receive` process survived ~40 hours
# holding the signal-cli config lock (llm#937/#957) — bare `timeout N` sends
# SIGTERM once and returns even if the child ignores it. This test proves
# the general detector: any `timeout <N> ...` (or `timeout -k <grace> <N>
# ...`) invocation whose elapsed time is well past its declared budget is
# flagged, using a synthetic process table (no live `ps` dependency, no
# signal-cli invocation).
#
# Run:
#   nix-shell ~/.claude/nix-gcroots/llm-shell.drv --run \
#     "Rscript tests/test_launchd_health_stale_processes.R"

suppressPackageStartupMessages({
  library(testthat)
})

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0L) a else b

this_file <- tryCatch(
  normalizePath(sys.frames()[[1L]]$ofile, mustWork = FALSE),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("^--file=", args, value = TRUE)
    if (length(file_flag) > 0L) sub("^--file=", "", file_flag[1L]) else "."
  }
)
script_dir <- normalizePath(dirname(this_file), mustWork = FALSE)

report_script <- normalizePath(
  file.path(script_dir, "..", ".claude", "scripts", "launchd_health_report.R"),
  mustWork = FALSE
)
if (!file.exists(report_script)) {
  candidate <- file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude",
                          "scripts", "launchd_health_report.R")
  report_script <- candidate[file.exists(candidate)][1L] %||% report_script
}

test_that("launchd_health_report.R exists", {
  # .Rbuildignore excludes .claude/ from the package build, so under
  # covr::package_coverage() / R CMD check this file is genuinely absent —
  # skip (not fail) in that case. skip_if_not() reports the test as SKIPPED,
  # distinct from both PASS and FAIL, so a real regression (script present
  # but broken) still fails loudly while a build-tree exclusion does not.
  testthat::skip_if_not(
    file.exists(report_script),
    sprintf(
      "launchd_health_report.R not found at %s (expected under covr/R CMD check, where .Rbuildignore excludes .claude/)",
      report_script
    )
  )
  expect_true(file.exists(report_script))
})

if (!file.exists(report_script)) {
  message("Skipping execution tests — launchd_health_report.R not found")
  q(status = 0L)
}

# Source with the source-only guard so main-body side effects (scanning the
# real ~/Library/LaunchAgents, hitting the real ledger, calling gh) never run.
options(launchd_health_source_only = TRUE)
source(report_script)

test_that("detector functions are defined after sourcing", {
  expect_true(exists("parse_etime_to_seconds"))
  expect_true(exists("extract_timeout_budget"))
  expect_true(exists("redact_phone_numbers"))
  expect_true(exists("detect_stale_processes"))
  expect_true(exists("collect_process_table"))
  expect_true(exists("render_stale_processes_table"))
})

# ── parse_etime_to_seconds ─────────────────────────────────────────────────

test_that("parse_etime_to_seconds handles bare-seconds (GNU etimes) form", {
  expect_equal(parse_etime_to_seconds("45"), 45L)
})

test_that("parse_etime_to_seconds handles MM:SS form", {
  expect_equal(parse_etime_to_seconds("05:10"), 5L * 60L + 10L)
})

test_that("parse_etime_to_seconds handles HH:MM:SS form", {
  expect_equal(parse_etime_to_seconds("01:02:03"), 3600L + 2L * 60L + 3L)
})

test_that("parse_etime_to_seconds handles DD-HH:MM:SS form (multi-day)", {
  expect_equal(
    parse_etime_to_seconds("2-03:15:10"),
    2L * 86400L + 3L * 3600L + 15L * 60L + 10L
  )
})

# ── extract_timeout_budget ─────────────────────────────────────────────────

test_that("extract_timeout_budget reads a plain `timeout N` prefix", {
  expect_equal(
    extract_timeout_budget("timeout 30 /opt/homebrew/bin/signal-cli -a +15550001111 receive"),
    30L
  )
})

test_that("extract_timeout_budget reads a `timeout -k <grace> <N>` prefix", {
  expect_equal(
    extract_timeout_budget("timeout -k 10 30 /opt/homebrew/bin/signal-cli -a +15550001111 receive"),
    30L
  )
})

test_that("extract_timeout_budget returns NA for a non-timeout command", {
  expect_true(is.na(extract_timeout_budget("/usr/bin/python3 /path/to/script.py --flag 5")))
})

# ── redact_phone_numbers (llm#946 PII requirement) ─────────────────────────

test_that("redact_phone_numbers removes the Signal account number", {
  cmd <- "timeout 30 signal-cli -a +15550001111 --output=json receive"
  redacted <- redact_phone_numbers(cmd)
  expect_false(grepl("15550001111", redacted, fixed = TRUE))
  expect_true(grepl("REDACTED", redacted, fixed = TRUE))
})

test_that("redact_phone_numbers leaves ordinary commands unchanged", {
  cmd <- "timeout 30 npx ccusage daily --json"
  expect_equal(redact_phone_numbers(cmd), cmd)
})

# ── detect_stale_processes: the core llm#957 assertion ─────────────────────

test_that("a timeout-wrapped process alive far past its budget is flagged", {
  proc_table <- data.frame(
    pid     = 4242L,
    etime   = "2-00:00:10",  # 2 days
    command = "timeout 30 /opt/homebrew/bin/signal-cli -a +15550001111 --output=json receive",
    stringsAsFactors = FALSE
  )
  stale <- detect_stale_processes(proc_table)
  expect_equal(nrow(stale), 1L)
  expect_equal(stale$pid, 4242L)
  expect_equal(stale$budget_s, 30L)
  expect_true(stale$elapsed_s > stale$budget_s * 2)
})

test_that("the flagged row's command is phone-redacted", {
  proc_table <- data.frame(
    pid     = 4242L,
    etime   = "2-00:00:10",
    command = "timeout 30 /opt/homebrew/bin/signal-cli -a +15550001111 --output=json receive",
    stringsAsFactors = FALSE
  )
  stale <- detect_stale_processes(proc_table)
  expect_false(grepl("15550001111", stale$command, fixed = TRUE))
})

test_that("a normal short-lived timeout-wrapped process is NOT flagged", {
  proc_table <- data.frame(
    pid     = 5555L,
    etime   = "00:00:05",  # 5 seconds
    command = "timeout 30 npx ccusage daily --json",
    stringsAsFactors = FALSE
  )
  stale <- detect_stale_processes(proc_table)
  expect_equal(nrow(stale), 0L)
})

test_that("a non-timeout long-running process is NOT flagged", {
  proc_table <- data.frame(
    pid     = 6666L,
    etime   = "10-00:00:00",  # 10 days — legitimately long-running daemon
    command = "/usr/local/bin/roborev daemon --config /home/x/.roborev/config.toml",
    stringsAsFactors = FALSE
  )
  stale <- detect_stale_processes(proc_table)
  expect_equal(nrow(stale), 0L)
})

test_that("a mixed table flags only the wedged row", {
  proc_table <- data.frame(
    pid     = c(1001L, 1002L, 1003L),
    etime   = c("2-00:00:10", "00:00:05", "10-00:00:00"),
    command = c(
      "timeout 30 /opt/homebrew/bin/signal-cli -a +15550001111 --output=json receive",
      "timeout 30 npx ccusage daily --json",
      "/usr/local/bin/roborev daemon"
    ),
    stringsAsFactors = FALSE
  )
  stale <- detect_stale_processes(proc_table)
  expect_equal(nrow(stale), 1L)
  expect_equal(stale$pid, 1001L)
})

test_that("detect_stale_processes returns zero rows (not NULL/error) on an empty table", {
  empty_table <- data.frame(pid = integer(), etime = character(),
                             command = character(), stringsAsFactors = FALSE)
  stale <- detect_stale_processes(empty_table)
  expect_true(is.data.frame(stale))
  expect_equal(nrow(stale), 0L)
})

test_that("detect_stale_processes tolerates a NULL process table", {
  stale <- detect_stale_processes(NULL)
  expect_true(is.data.frame(stale))
  expect_equal(nrow(stale), 0L)
})

# ── render_stale_processes_table ────────────────────────────────────────────

test_that("render_stale_processes_table reports 'none detected' for an empty result", {
  empty_table <- data.frame(pid = integer(), elapsed_s = integer(),
                             budget_s = integer(), command = character(),
                             stringsAsFactors = FALSE)
  out <- render_stale_processes_table(empty_table)
  expect_true(grepl("No stale", out))
})

test_that("render_stale_processes_table emits a markdown row for a flagged process", {
  stale <- data.frame(
    pid = 4242L, elapsed_s = 172810L, budget_s = 30L,
    command = "timeout 30 /opt/homebrew/bin/signal-cli -a +[REDACTED] --output=json receive",
    stringsAsFactors = FALSE
  )
  out <- render_stale_processes_table(stale)
  expect_true(grepl("4242", out))
  expect_true(grepl("\\| PID \\| Elapsed \\| Budget \\| Command \\|", out))
})

cat("\n--- All tests completed ---\n")
