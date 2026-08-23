# test-roborev-dashboard-link.R — Tests for the roborev dashboard link
# resolution shared by send_roborev_email.R and
# send_roborev_weekly_rollup_email.R.
#
# Context: the llmtelemetry repo was made private on 2026-08-22 (to stop it
# publishing another project's personal-finance data), taking its GitHub
# Pages dashboard offline. Both daily/weekly roborev emails previously
# hardcoded https://johngavin.github.io/llmtelemetry/#roborev as the "View
# Full roborev Dashboard" button target — a link that now 404s. The fix
# (resolve_dashboard_links() / dashboard_cta_block() / effective_dashboard_url()
# in .claude/scripts/email_styles.R) replaces that single hardcoded string
# with three independently-overridable env vars and a fallback chain:
#   1. ROBOREV_DASHBOARD_URL (explicit override — wins outright)
#   2. ROBOREV_DASHBOARD_REPO_URL (default: the llmtelemetry GitHub repo)
# plus ROBOREV_DASHBOARD_LOCAL_PATH, surfaced as selectable text (never a
# file:// <a href>, which Gmail and other major clients strip).
#
# Coverage:
#   - resolve_dashboard_links(): default values, and each env var override
#   - dashboard_cta_block(): href resolution, explanatory note only when no
#     explicit override, local path shown as text (not a file:// link)
#   - effective_dashboard_url(): matches the href dashboard_cta_block() renders
#   - Integration: both send_*_email.R scripts render the resolved link in
#     dry-run output, with and without ROBOREV_DASHBOARD_URL set
#
# MUTATION-TEST performed manually for this PR (see fixer report): reverting
# dashboard_cta_block()/resolve_dashboard_links() back to the old hardcoded
# ROBOREV_DASHBOARD_URL default made every test in the first block below fail
# (function not found / wrong default), confirming the tests exercise the
# new code and are not vacuously true.

library(testthat)

# ── Locate a dev-tree file under .claude/scripts/ ──────────────────────────────
#
# .claude/ is excluded from the package build (.Rbuildignore), so these files
# are never part of an installed "llm" package and system.file(package=...)
# cannot see them directly. send_roborev_email.R is the one exception -- it is
# symlinked into inst/scripts/ (see inst/scripts/send_roborev_email.R) so it
# IS resolvable via system.file(). email_styles.R and
# send_roborev_weekly_rollup_email.R are not symlinked, so both need the
# dev-tree fallback: dirname(system.file(package = "llm")) resolves to the
# package root under devtools::load_all() (confirmed: returns "<root>/inst",
# whose dirname is "<root>") -- this is the harness devtools::test() uses, so
# it is stable for local test runs; against a genuinely installed package (R
# CMD check) .claude/ won't exist and these tests skip gracefully, matching
# the existing skip_if_not() pattern already used for bin/*.sh in
# test-roborev-daily-email.R.
locate_claude_script <- function(relative_path) {
  pkg_inst <- system.file(package = "llm")
  if (!nzchar(pkg_inst)) return(NA_character_)
  candidate <- normalizePath(
    file.path(dirname(pkg_inst), ".claude", "scripts", relative_path),
    mustWork = FALSE
  )
  if (file.exists(candidate)) candidate else NA_character_
}

email_styles_path <- locate_claude_script("email_styles.R")

# ── Unit tests: resolve_dashboard_links() / dashboard_cta_block() /───────────
#   effective_dashboard_url() — sourced directly, no subprocess needed

test_that("resolve_dashboard_links() defaults point at the llmtelemetry repo and local _site path", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_REPO_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = NA
  ))
  sys.source(email_styles_path, envir = env)

  links <- env$resolve_dashboard_links()
  expect_null(links$explicit_url)
  expect_identical(links$repo_url, "https://github.com/JohnGavin/llmtelemetry")
  expect_identical(
    links$local_path,
    file.path(Sys.getenv("HOME"), "docs_gh", "llmtelemetry", "_site", "index.html")
  )
})

test_that("ROBOREV_DASHBOARD_URL, when set, wins outright over the repo default", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = "https://example.com/custom-dashboard",
    ROBOREV_DASHBOARD_REPO_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = NA
  ))
  sys.source(email_styles_path, envir = env)

  links <- env$resolve_dashboard_links()
  expect_identical(links$explicit_url, "https://example.com/custom-dashboard")
  expect_identical(env$effective_dashboard_url(), "https://example.com/custom-dashboard")
})

test_that("ROBOREV_DASHBOARD_REPO_URL and ROBOREV_DASHBOARD_LOCAL_PATH are independently overridable", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_REPO_URL = "https://github.com/JohnGavin/some-other-repo",
    ROBOREV_DASHBOARD_LOCAL_PATH = "/tmp/custom-dashboard/index.html"
  ))
  sys.source(email_styles_path, envir = env)

  links <- env$resolve_dashboard_links()
  expect_null(links$explicit_url)
  expect_identical(links$repo_url, "https://github.com/JohnGavin/some-other-repo")
  expect_identical(links$local_path, "/tmp/custom-dashboard/index.html")
  expect_identical(env$effective_dashboard_url(), "https://github.com/JohnGavin/some-other-repo")
})

test_that("dashboard_cta_block() default rendering: repo href, explanatory note, local path as text (not file://)", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_REPO_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = NA
  ))
  sys.source(email_styles_path, envir = env)

  html <- env$dashboard_cta_block(env$ACCENT_BLUE)

  expect_true(grepl('href="https://github.com/JohnGavin/llmtelemetry"', html, fixed = TRUE),
    info = "button href must default to the llmtelemetry repo when no override is set")
  expect_true(grepl("went offline when llmtelemetry was made private", html, fixed = TRUE),
    info = "must explain what changed and why, so a reader who clicked yesterday isn't confused")
  expect_true(grepl("docs_gh/llmtelemetry/_site/index.html", html, fixed = TRUE),
    info = "local rendered path must be surfaced as text")
  expect_false(grepl('href="file://', html, fixed = TRUE),
    info = "the local path must NOT be rendered as a clickable file:// link -- major mail clients (Gmail included) strip those, so a dead-looking link is worse than plain text")
})

test_that("dashboard_cta_block() with an explicit override: no explanatory note, override href used", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = "https://example.com/custom-dashboard",
    ROBOREV_DASHBOARD_REPO_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = NA
  ))
  sys.source(email_styles_path, envir = env)

  html <- env$dashboard_cta_block(env$ACCENT_BLUE)

  expect_true(grepl('href="https://example.com/custom-dashboard"', html, fixed = TRUE))
  expect_false(grepl("went offline when llmtelemetry was made private", html, fixed = TRUE),
    info = "an explicit override means nothing changed from the caller's point of view -- no note needed")
})

# ── Integration tests: send_roborev_email.R dry-run ───────────────────────────

run_daily_email_dry_run <- function(extra_env = character(0)) {
  dir <- tempfile("roborev_dashlink_test_")
  dir.create(dir, recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE))

  json_path <- file.path(dir, "2026-05-28.json")
  writeLines(jsonlite::toJSON(list(
    report_date = "2026-05-28",
    generated_at = "2026-05-28T08:00:00Z",
    lineage_source = "test",
    global_windows = list(d7 = list(
      window_days = 7L, repo = "__all__", n_reviews = 1L,
      freq_table = list(list(verdict_label = "clean", status = "closed", n = 1L)),
      speed = list(ttc_p50_hrs = 1, ttc_p90_hrs = 1, att_p50 = 1, att_p90 = 1, close_rate = 1),
      trends = list()
    )),
    per_repo_7d = list(),
    outliers_recent_7d = list(window_days = 7L, by_time = list(), by_attempts = list(),
                               by_attempts_degenerate = TRUE)
  ), auto_unbox = TRUE, pretty = TRUE, na = "null"), json_path)

  email_script <- system.file("scripts/send_roborev_email.R", package = "llm", mustWork = FALSE)
  if (!nzchar(email_script) || !file.exists(email_script)) {
    email_script <- normalizePath(
      file.path(dirname(dirname(testthat::test_path())), ".claude", "scripts", "send_roborev_email.R"),
      mustWork = FALSE
    )
  }
  skip_if_not(file.exists(email_script), "send_roborev_email.R not found")

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("ROBOREV_DAILY_DIR=", dir),
    "GMAIL_USERNAME=", "GMAIL_APP_PASSWORD=", "REPORT_RECIPIENT=",
    # Explicitly unset so a developer's real shell env can't leak into the
    # "default" assertions below.
    "ROBOREV_DASHBOARD_URL=",
    extra_env
  )
  withr::with_envvar(
    setNames(sub("^[^=]+=", "", env_vars), sub("=.*$", "", env_vars)),
    tryCatch(
      system2("Rscript", args = email_script, stdout = TRUE, stderr = TRUE),
      error = function(e) as.character(e$message)
    )
  )
}

test_that("send_roborev_email.R dry-run: default dashboard link points at the repo, not the dead GH Pages URL", {
  skip_if_not_installed("blastula")
  out <- paste(run_daily_email_dry_run(), collapse = "\n")

  expect_false(grepl("johngavin.github.io/llmtelemetry", out, fixed = TRUE),
    info = "the dead GH Pages URL must never appear in the rendered email")
  expect_true(grepl("github.com/JohnGavin/llmtelemetry", out, fixed = TRUE),
    info = "default dashboard link must fall back to the (private) GitHub repo")
  expect_true(grepl("QA:dashboard_url=https://github.com/JohnGavin/llmtelemetry", out, fixed = TRUE),
    info = "QA marker must reflect the resolved (not raw env var) dashboard URL")
})

test_that("send_roborev_email.R dry-run: ROBOREV_DASHBOARD_URL override still works end-to-end", {
  skip_if_not_installed("blastula")
  out <- paste(
    run_daily_email_dry_run(extra_env = "ROBOREV_DASHBOARD_URL=https://example.com/roborev"),
    collapse = "\n"
  )
  expect_true(grepl("example.com/roborev", out, fixed = TRUE),
    info = "explicit override must still be honoured end-to-end")
})

# ── Integration test: send_roborev_weekly_rollup_email.R dry-run ─────────────

test_that("send_roborev_weekly_rollup_email.R dry-run: default dashboard link points at the repo, not the dead GH Pages URL", {
  skip_if_not_installed("blastula")
  rollup_script <- locate_claude_script("send_roborev_weekly_rollup_email.R")
  skip_if_not(!is.na(rollup_script) && file.exists(rollup_script),
              "send_roborev_weekly_rollup_email.R not found")

  dir <- tempfile("roborev_weekly_dashlink_test_")
  dir.create(dir, recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE))
  writeLines(
    "# roborev Weekly Rollup — 2026-05-28\n\n_Generated: 2026-05-28_\n",
    file.path(dir, "2026-05-28.md")
  )

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("ROBOREV_WEEKLY_DIR=", dir),
    "GMAIL_USERNAME=", "GMAIL_APP_PASSWORD=", "REPORT_RECIPIENT=",
    "ROBOREV_DASHBOARD_URL="
  )
  out <- withr::with_envvar(
    setNames(sub("^[^=]+=", "", env_vars), sub("=.*$", "", env_vars)),
    system2("Rscript", args = rollup_script, stdout = TRUE, stderr = TRUE)
  )
  combined <- paste(out, collapse = "\n")

  expect_false(grepl("johngavin.github.io/llmtelemetry", combined, fixed = TRUE),
    info = "the dead GH Pages URL must never appear in the rendered weekly email")
  expect_true(grepl("github.com/JohnGavin/llmtelemetry", combined, fixed = TRUE),
    info = "default dashboard link must fall back to the (private) GitHub repo")
})
