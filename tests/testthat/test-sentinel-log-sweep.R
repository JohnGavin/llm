# test-sentinel-log-sweep.R — Regression tests for the llm#884 steps 2-3
# fix: age-based sentinel sweep + size-based log rotation, wired into the
# existing daily worktree_gc.sh housekeeping job.
#
# Follows the shell-helper test pattern used in test-self-review-stage1.R and
# test-staleness-collect.R (bash -n syntax check via system2(), executable-bit
# regression guard, --selftest / SELFTEST=1 invocation checking "0 FAIL").
#
# All behaviour tests run against temp fixture directories created with
# touch -t controlled mtimes — never against the real ~/.claude/. Both the
# main script (worktree_gc.sh) and the sourced pure-function helper
# (sentinel_log_sweep.sh) are exercised: the helper directly (sourced in a
# bash subprocess against a fixture dir) and the wiring end-to-end (via
# worktree_gc.sh's own SELFTEST=1 harness, run against an isolated fake
# HOME/DOCS_GH so it never touches real state).

library(testthat)

# ── Helpers ───────────────────────────────────────────────────────────────────

repo_root <- function() {
  this_file <- tryCatch(
    normalizePath(sys.frame(0)$ofile, mustWork = FALSE),
    error = function(e) ""
  )
  if (nzchar(this_file) && file.exists(this_file)) {
    candidate <- dirname(dirname(this_file))
    if (file.exists(file.path(candidate, ".git"))) return(candidate)
  }
  tp <- tryCatch(testthat::test_path(), error = function(e) "")
  if (nzchar(tp)) {
    candidate <- normalizePath(file.path(tp, "..", ".."), mustWork = FALSE)
    if (file.exists(file.path(candidate, ".git"))) return(candidate)
  }
  path <- getwd()
  for (i in seq_len(10L)) {
    if (file.exists(file.path(path, ".git"))) return(path)
    parent <- dirname(path)
    if (parent == path) break
    path <- parent
  }
  getwd()
}

gc_sh <- normalizePath(
  file.path(repo_root(), ".claude", "scripts", "worktree_gc.sh"),
  mustWork = FALSE
)
sweep_sh <- normalizePath(
  file.path(repo_root(), ".claude", "scripts", "sentinel_log_sweep.sh"),
  mustWork = FALSE
)

# Run a small bash snippet that sources sentinel_log_sweep.sh, so behaviour
# tests exercise the real sourced functions rather than a re-implementation.
# Written to a temp script file (not passed inline via `bash -c`) because
# system2() does not shell-quote its args vector, and R's system() always
# routes through /bin/sh -c to launch the child — an unquoted multi-line
# string breaks across that outer shell's own parsing.
run_helper_snippet <- function(body) {
  script <- paste0(
    "set -euo pipefail\n",
    "source ", shQuote(sweep_sh), "\n",
    body, "\n"
  )
  tmp_script <- tempfile(fileext = ".sh")
  writeLines(script, tmp_script)
  on.exit(unlink(tmp_script), add = TRUE)
  system2("bash", args = tmp_script, stdout = TRUE, stderr = TRUE)
}

# ── Shell syntax checks ────────────────────────────────────────────────────────

test_that("worktree_gc.sh passes bash -n syntax check", {
  skip_if_not(file.exists(gc_sh), "worktree_gc.sh not found")
  exit_code <- system2("bash", args = c("-n", gc_sh), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "worktree_gc.sh has bash syntax errors")
})

test_that("sentinel_log_sweep.sh passes bash -n syntax check", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")
  exit_code <- system2("bash", args = c("-n", sweep_sh), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "sentinel_log_sweep.sh has bash syntax errors")
})

# ── Executable-bit regression guard (llm#886 failure mode) ───────────────────
# worktree_gc.sh sources sentinel_log_sweep.sh by path (not by invoking it),
# so a missing exec bit would not break sourcing directly — but the file also
# carries its own standalone CLI (guarded by a BASH_SOURCE check) intended to
# be run directly for manual debugging, so it should stay executable like its
# sibling scripts.

test_that("sentinel_log_sweep.sh is executable", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")
  expect_equal(file.access(sweep_sh, mode = 1)[[1]], 0L,
               info = "sentinel_log_sweep.sh is missing the executable bit (llm#886 failure mode)")
})

# ── sweep_stale_sentinels() — direct behaviour tests against a fixture dir ───

test_that("sweep_stale_sentinels removes only files older than the threshold", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  dir <- tempfile("sentinels_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  old_sha  <- file.path(dir, ".session_start_sha_old_proj")
  old_bye  <- file.path(dir, ".bye-requested.oldsid")
  old_ref  <- file.path(dir, ".bye-session-end-refine.oldsid")
  new_sha  <- file.path(dir, ".session_start_sha_new_proj")
  new_bye  <- file.path(dir, ".bye-requested")
  file.create(old_sha, old_bye, old_ref, new_sha, new_bye)

  # Backdate the "old" trio to well past the 7-day threshold.
  system2("touch", args = c("-t", "202601010000", shQuote(old_sha)))
  system2("touch", args = c("-t", "202601010000", shQuote(old_bye)))
  system2("touch", args = c("-t", "202601010000", shQuote(old_ref)))

  out <- run_helper_snippet(sprintf(
    "sweep_stale_sentinels %s 7 0\necho \"SWEPT=$SENTINELS_SWEPT\"",
    shQuote(dir)
  ))
  expect_true(any(grepl("^SWEPT=3$", out)),
              info = paste("expected SWEPT=3, got:", paste(out, collapse = "\n")))

  remaining <- list.files(dir, all.files = TRUE, no.. = TRUE)
  expect_setequal(remaining, c(".session_start_sha_new_proj", ".bye-requested"))
  expect_false(file.exists(old_sha))
  expect_false(file.exists(old_bye))
  expect_false(file.exists(old_ref))
})

test_that("sweep_stale_sentinels dry-run mode never deletes", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  dir <- tempfile("sentinels_dry_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  old_sha <- file.path(dir, ".session_start_sha_old_proj")
  file.create(old_sha)
  system2("touch", args = c("-t", "202601010000", shQuote(old_sha)))

  out <- run_helper_snippet(sprintf(
    "sweep_stale_sentinels %s 7 1\necho \"SWEPT=$SENTINELS_SWEPT\"",
    shQuote(dir)
  ))
  expect_true(any(grepl("^SWEPT=1$", out)))
  expect_true(file.exists(old_sha), info = "dry-run must not delete anything")
})

test_that("sweep_stale_sentinels is a silent no-op on an empty directory", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  dir <- tempfile("sentinels_empty_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  out <- run_helper_snippet(sprintf(
    "sweep_stale_sentinels %s 7 0\necho \"SWEPT=$SENTINELS_SWEPT\"",
    shQuote(dir)
  ))
  expect_true(any(grepl("^SWEPT=0$", out)))
})

test_that("sweep_stale_sentinels is a silent no-op on a missing directory", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  missing_dir <- tempfile("sentinels_missing_")

  out <- run_helper_snippet(sprintf(
    "sweep_stale_sentinels %s 7 0\necho \"SWEPT=$SENTINELS_SWEPT\"",
    shQuote(missing_dir)
  ))
  expect_true(any(grepl("^SWEPT=0$", out)))
})

# ── rotate_log_file() / rotate_logs() — direct behaviour tests ───────────────

make_big_log <- function(path, n_lines = 3000L) {
  lines <- paste0("line ", seq_len(n_lines), " ", strrep("x", 50))
  writeLines(lines, path)
}

test_that("rotate_logs truncates a file over the size threshold and keeps a .1 generation", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  dir <- tempfile("logs_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  big <- file.path(dir, "big.log")
  small <- file.path(dir, "small.log")
  make_big_log(big, 3000L)
  writeLines("small", small)

  out <- run_helper_snippet(sprintf(
    "rotate_logs %s 10000 10 0\necho \"ROTATED=$LOGS_ROTATED\"",
    shQuote(dir)
  ))
  expect_true(any(grepl("^ROTATED=1$", out)),
              info = paste("expected ROTATED=1, got:", paste(out, collapse = "\n")))

  expect_equal(length(readLines(big)), 10L,
               info = "big.log must be truncated to keep_lines")
  expect_true(file.exists(paste0(big, ".1")),
              info = "a .1 generation must be kept")
  expect_equal(length(readLines(paste0(big, ".1"))), 3000L,
               info = ".1 generation must hold the full pre-rotation content")
  expect_equal(length(readLines(small)), 1L,
               info = "a file under threshold must be left untouched")
})

test_that("rotate_logs never touches .duckdb files even when oversized", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  dir <- tempfile("logs_duckdb_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  db <- file.path(dir, "unified.duckdb")
  make_big_log(db, 3000L)

  out <- run_helper_snippet(sprintf(
    "rotate_logs %s 10000 10 0\necho \"ROTATED=$LOGS_ROTATED\"",
    shQuote(dir)
  ))
  expect_true(any(grepl("^ROTATED=0$", out)),
              info = paste("expected ROTATED=0 (duckdb must be skipped), got:",
                            paste(out, collapse = "\n")))
  expect_equal(length(readLines(db)), 3000L,
               info = "a .duckdb file must NEVER be rotated regardless of size")
  expect_false(file.exists(paste0(db, ".1")))
})

test_that("rotate_logs dry-run mode never truncates", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  dir <- tempfile("logs_dry_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  big <- file.path(dir, "big.log")
  make_big_log(big, 3000L)

  out <- run_helper_snippet(sprintf(
    "rotate_logs %s 10000 10 1\necho \"ROTATED=$LOGS_ROTATED\"",
    shQuote(dir)
  ))
  expect_true(any(grepl("^ROTATED=1$", out)))
  expect_equal(length(readLines(big)), 3000L,
               info = "dry-run must not truncate anything")
  expect_false(file.exists(paste0(big, ".1")))
})

test_that("rotate_logs is idempotent — a second run over an already-rotated file is a no-op", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  dir <- tempfile("logs_idem_")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  big <- file.path(dir, "big.log")
  make_big_log(big, 3000L)

  out <- run_helper_snippet(sprintf(
    paste0(
      "rotate_logs %s 10000 10 0\n",
      "rotate_logs %s 10000 10 0\n",
      "echo \"ROTATED=$LOGS_ROTATED\""
    ),
    shQuote(dir), shQuote(dir)
  ))
  expect_true(any(grepl("^ROTATED=0$", out)),
              info = "second rotation pass must be a no-op once the file is under threshold")
})

test_that("rotate_logs is a silent no-op on an empty or missing directory", {
  skip_if_not(file.exists(sweep_sh), "sentinel_log_sweep.sh not found")

  empty_dir <- tempfile("logs_empty_")
  dir.create(empty_dir)
  on.exit(unlink(empty_dir, recursive = TRUE), add = TRUE)
  missing_dir <- tempfile("logs_missing_")

  out_empty <- run_helper_snippet(sprintf(
    "rotate_logs %s 10000 10 0\necho \"ROTATED=$LOGS_ROTATED\"",
    shQuote(empty_dir)
  ))
  expect_true(any(grepl("^ROTATED=0$", out_empty)))

  out_missing <- run_helper_snippet(sprintf(
    "rotate_logs %s 10000 10 0\necho \"ROTATED=$LOGS_ROTATED\"",
    shQuote(missing_dir)
  ))
  expect_true(any(grepl("^ROTATED=0$", out_missing)))
})

# ── End-to-end wiring — worktree_gc.sh SELFTEST=1 against an isolated fake
#    HOME/DOCS_GH (never the real ~/.claude/) ────────────────────────────────

test_that("worktree_gc.sh --selftest suite (incl. sentinel-sweep + log-rotate tests) passes", {
  skip_if_not(file.exists(gc_sh), "worktree_gc.sh not found")

  fake_home <- tempfile("gc_selftest_home_")
  dir.create(file.path(fake_home, ".claude", "logs"), recursive = TRUE)
  dir.create(file.path(fake_home, "docs_gh"), recursive = TRUE)
  on.exit(unlink(fake_home, recursive = TRUE), add = TRUE)

  env <- c(
    paste0("SELFTEST=1"),
    paste0("HOME=", fake_home),
    paste0("DOCS_GH=", file.path(fake_home, "docs_gh")),
    paste0("WORKTREES_BASE=", file.path(fake_home, "docs_gh", "worktrees")),
    paste0("WORKTREES_BASE_LEGACY=", file.path(fake_home, "worktrees_legacy")),
    paste0("UNIFIED_DB_PATH=", file.path(fake_home, ".claude", "logs", "unified.duckdb")),
    paste0("CLAUDE_RUNTIME_ROOT=", file.path(fake_home, ".claude"))
  )

  out <- withr::with_envvar(
    setNames(sub("^[^=]+=", "", env), sub("=.*$", "", env)),
    system2("bash", args = gc_sh, stdout = TRUE, stderr = TRUE)
  )
  combined <- paste(out, collapse = "\n")

  expect_true(
    grepl("0 FAIL", combined),
    info = paste0("worktree_gc.sh --selftest reported failures:\n", combined)
  )
  expect_true(
    grepl("sentinel dry-run counts 3 stale files", combined),
    info = "sentinel-sweep selftest checks did not run — wiring may be broken"
  )
  expect_true(
    grepl("log-rotate real run rotates 1 file", combined),
    info = "log-rotate selftest checks did not run — wiring may be broken"
  )
})

test_that("worktree_gc.sh dry-run never mutates a fixture ~/.claude/ (no --apply)", {
  skip_if_not(file.exists(gc_sh), "worktree_gc.sh not found")

  fake_home <- tempfile("gc_dryrun_home_")
  dir.create(file.path(fake_home, ".claude", "logs"), recursive = TRUE)
  dir.create(file.path(fake_home, "docs_gh"), recursive = TRUE)
  on.exit(unlink(fake_home, recursive = TRUE), add = TRUE)

  old_sha <- file.path(fake_home, ".claude", ".session_start_sha_old_proj")
  file.create(old_sha)
  system2("touch", args = c("-t", "202601010000", shQuote(old_sha)))
  big <- file.path(fake_home, ".claude", "logs", "big_test.log")
  make_big_log(big, 3000L)

  env <- setNames(
    c(fake_home,
      file.path(fake_home, "docs_gh"),
      file.path(fake_home, "docs_gh", "worktrees"),
      file.path(fake_home, "worktrees_legacy"),
      file.path(fake_home, ".claude", "logs", "unified.duckdb"),
      file.path(fake_home, ".claude"),
      "10000", "10"),
    c("HOME", "DOCS_GH", "WORKTREES_BASE", "WORKTREES_BASE_LEGACY",
      "UNIFIED_DB_PATH", "CLAUDE_RUNTIME_ROOT",
      "LOG_ROTATE_THRESHOLD_BYTES", "LOG_ROTATE_KEEP_LINES")
  )

  withr::with_envvar(env, {
    system2("bash", args = gc_sh, stdout = FALSE, stderr = FALSE)
  })

  expect_true(file.exists(old_sha),
              info = "dry-run (no --apply) must not delete stale sentinels")
  expect_equal(length(readLines(big)), 3000L,
               info = "dry-run (no --apply) must not rotate oversized logs")
})
