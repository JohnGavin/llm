# test-roborev-dashboard-link.R — Tests for the roborev dashboard link
# resolution shared by send_roborev_email.R and
# send_roborev_weekly_rollup_email.R.
#
# Context: the llmtelemetry repo was made private on 2026-08-22 (to stop it
# publishing another project's personal-finance data), taking its GitHub
# Pages dashboard offline. Both daily/weekly roborev emails previously
# hardcoded https://johngavin.github.io/llmtelemetry/#roborev as the "View
# Full roborev Dashboard" button target -- a link that now 404s. A
# 2026-09-09 fix (llm#1123 follow-up) replaced that hardcoded string with a
# file:// link to a locally-rendered vignette, falling back to the (private)
# llmtelemetry repo URL when the local file was absent.
#
# 2026-09-24 (user: "the dashboard button is not working. fix it or remove
# it"): the button was REMOVED for the no-override case. Neither of the two
# targets it could previously point at actually worked:
#   1. file:// hrefs are documented to be stripped by major mail clients
#      (Gmail included) -- this was a known, unresolved caveat from
#      2026-09-09 that was never re-verified.
#   2. The repo-URL fallback (github.com/JohnGavin/llmtelemetry) is a
#      PRIVATE repo with no GitHub Pages since 2026-08-22 -- it never showed
#      the dashboard, only GitHub's repo-listing page.
#
# Current contract (resolve_dashboard_links() / resolve_dashboard_href() /
# dashboard_cta_block() / effective_dashboard_url() in
# .claude/scripts/email_styles.R):
#   - ROBOREV_DASHBOARD_URL set to an http(s) URL: dashboard_cta_block()
#     renders a real, clickable <a> button to it. This is the ONLY case
#     that renders a button.
#   - Otherwise: no <a>, no href of any kind (never file://). Plain text
#     names ROBOREV_DASHBOARD_LOCAL_PATH and, when the file exists, its
#     mtime-derived age ("Last rendered: ... (N days ago)"), with a visible
#     "stale" note when N > 2. When the file does not exist, the text says
#     "not rendered on this machine" plus the render command -- freshness is
#     never claimed without a successful file.exists()/file.info() check
#     (checks-must-distinguish-unknown).
#   - effective_dashboard_url() mirrors what dashboard_cta_block() rendered
#     as a single string: the http(s) override, else the local path (no
#     file:// prefix) if it exists, else the literal string "none".
#
# Coverage:
#   - resolve_dashboard_links(): defaults, and ROBOREV_DASHBOARD_LOCAL_PATH
#     override
#   - dashboard_cta_block(): http(s) override -> button; non-http(s)
#     override -> no button; no override + file absent -> "not rendered"
#     text, no href of any kind; no override + file exists (fresh) -> path
#     + "Last rendered", no stale wording; no override + file exists (stale)
#     -> stale wording
#   - effective_dashboard_url(): matches dashboard_cta_block() in each case
#   - Integration: send_roborev_email.R and send_roborev_weekly_rollup_email.R
#     dry-run output never contains a file:// href or the dead GH Pages URL
#
# MUTATION-TEST performed manually for this PR (see fixer report): reverting
# resolve_dashboard_href() to construct a "file://" href for the no-override
# case made the "must NOT use a file:// href" tests below fail, confirming
# they exercise the removal and are not vacuously true.

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

# ── Unit tests: resolve_dashboard_links() ─────────────────────────────────────

test_that("resolve_dashboard_links() defaults point at no override and the roborev vignette path", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = NA
  ))
  sys.source(email_styles_path, envir = env)

  links <- env$resolve_dashboard_links()
  expect_null(links$explicit_url)
  expect_identical(
    links$local_path,
    file.path(Sys.getenv("HOME"), "docs_gh", "llmtelemetry", "vignettes", "roborev_summary.html")
  )
})

test_that("ROBOREV_DASHBOARD_LOCAL_PATH is independently overridable", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = "/tmp/custom-dashboard/index.html"
  ))
  sys.source(email_styles_path, envir = env)

  links <- env$resolve_dashboard_links()
  expect_null(links$explicit_url)
  expect_identical(links$local_path, "/tmp/custom-dashboard/index.html")
})

# ── Unit tests: dashboard_cta_block() / effective_dashboard_url() ────────────

test_that("dashboard_cta_block() with an http(s) override: real button, no local-path text", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = "https://example.com/custom-dashboard",
    ROBOREV_DASHBOARD_LOCAL_PATH = NA
  ))
  sys.source(email_styles_path, envir = env)

  html <- env$dashboard_cta_block(env$ACCENT_BLUE)

  expect_true(grepl('href="https://example.com/custom-dashboard"', html, fixed = TRUE))
  expect_false(grepl("not rendered on this machine", html, fixed = TRUE),
    info = "an explicit http(s) override renders a button, not the local-path fallback text")
  expect_identical(env$effective_dashboard_url(), "https://example.com/custom-dashboard")
})

test_that("dashboard_cta_block() with a non-http(s) override: no button rendered", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  local_path <- file.path(tempdir(), "definitely-does-not-exist", "roborev_summary.html")
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = "ftp://example.com/not-http",
    ROBOREV_DASHBOARD_LOCAL_PATH = local_path
  ))
  sys.source(email_styles_path, envir = env)
  stopifnot(!file.exists(local_path))  # test premise

  html <- env$dashboard_cta_block(env$ACCENT_BLUE)

  expect_false(grepl("<a ", html, fixed = TRUE),
    info = "a non-http(s) override must not be treated as a clickable target")
  expect_true(grepl("not rendered on this machine", html, fixed = TRUE))
})

test_that("dashboard_cta_block() when local file absent: no <a>, no file:// href, 'not rendered' text", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  local_path <- file.path(tempdir(), "definitely-does-not-exist", "roborev_summary.html")
  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = local_path
  ))
  sys.source(email_styles_path, envir = env)
  stopifnot(!file.exists(local_path))  # test premise: the file must genuinely be absent

  html <- env$dashboard_cta_block(env$ACCENT_BLUE)

  expect_false(grepl("<a ", html, fixed = TRUE),
    info = "with no override and no local file, there is nothing to link to")
  expect_false(grepl("file://", html, fixed = TRUE),
    info = "must NEVER construct a file:// href -- mail clients strip it")
  expect_true(grepl("not rendered on this machine", html, fixed = TRUE),
    info = "absence must be stated explicitly, never silently assumed fresh")
  expect_true(grepl(local_path, html, fixed = TRUE),
    info = "the expected local path is still surfaced as text so the reader knows what to render")
  expect_identical(env$effective_dashboard_url(), "none")
})

test_that("dashboard_cta_block() when local file exists and is fresh: path + 'Last rendered', no stale wording", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  local_dir <- tempfile("dashboard_link_fresh_")
  dir.create(local_dir)
  local_path <- file.path(local_dir, "roborev_summary.html")
  writeLines("<html><body>fixture</body></html>", local_path)
  on.exit(unlink(local_dir, recursive = TRUE), add = TRUE)

  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = local_path
  ))
  sys.source(email_styles_path, envir = env)
  stopifnot(file.exists(local_path))  # test premise

  html <- env$dashboard_cta_block(env$ACCENT_BLUE)

  expect_false(grepl("<a ", html, fixed = TRUE),
    info = "no override means no button, even when the local file exists")
  expect_false(grepl("file://", html, fixed = TRUE))
  expect_true(grepl(local_path, html, fixed = TRUE))
  expect_true(grepl("Last rendered:", html, fixed = TRUE))
  expect_false(grepl("stale", html, fixed = TRUE),
    info = "a freshly-written file (mtime = now) must not be reported as stale")
  expect_identical(env$effective_dashboard_url(), local_path)
})

test_that("dashboard_cta_block() when local file exists and is stale (>2 days): stale wording present", {
  skip_if_not(file.exists(email_styles_path), "email_styles.R not found")
  env <- new.env()
  local_dir <- tempfile("dashboard_link_stale_")
  dir.create(local_dir)
  local_path <- file.path(local_dir, "roborev_summary.html")
  writeLines("<html><body>fixture</body></html>", local_path)
  on.exit(unlink(local_dir, recursive = TRUE), add = TRUE)
  # Back-date the file's mtime by 10 days so it crosses the >2-day threshold.
  Sys.setFileTime(local_path, Sys.time() - as.difftime(10, units = "days"))
  stopifnot(file.exists(local_path))  # test premise

  withr::local_envvar(c(
    ROBOREV_DASHBOARD_URL = NA,
    ROBOREV_DASHBOARD_LOCAL_PATH = local_path
  ))
  sys.source(email_styles_path, envir = env)

  html <- env$dashboard_cta_block(env$ACCENT_BLUE)

  expect_false(grepl("<a ", html, fixed = TRUE))
  expect_false(grepl("file://", html, fixed = TRUE))
  expect_true(grepl("stale", html, fixed = TRUE),
    info = "a file rendered 10 days ago (> the 2-day threshold) must be flagged as stale")
  expect_true(grepl("Last rendered:", html, fixed = TRUE))
  expect_true(grepl("(10 days ago)", html, fixed = TRUE))
  expect_identical(env$effective_dashboard_url(), local_path)
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

  # A definitely-absent default local path keeps the "no override" assertions
  # below deterministic regardless of whether this machine happens to have a
  # locally-rendered roborev vignette on disk.
  missing_local_path <- file.path(tempdir(), "roborev_dashlink_absent_", "roborev_summary.html")

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("ROBOREV_DAILY_DIR=", dir),
    "GMAIL_USERNAME=", "GMAIL_APP_PASSWORD=", "REPORT_RECIPIENT=",
    # Explicitly unset/defaulted so a developer's real shell env or local
    # machine state can't leak into the "default" assertions below.
    "ROBOREV_DASHBOARD_URL=",
    paste0("ROBOREV_DASHBOARD_LOCAL_PATH=", missing_local_path),
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

test_that("send_roborev_email.R dry-run: no override + no local file -> no button, no file://, no dead URL", {
  skip_if_not_installed("blastula")
  out <- paste(run_daily_email_dry_run(), collapse = "\n")

  expect_false(grepl("johngavin.github.io/llmtelemetry", out, fixed = TRUE),
    info = "the dead GH Pages URL must never appear in the rendered email")
  expect_false(grepl("href=\"file://", out, fixed = TRUE),
    info = "must never render a file:// href -- mail clients strip it")
  expect_false(grepl('href="https://github.com/JohnGavin/llmtelemetry"', out, fixed = TRUE),
    info = "must never fall back to the private repo URL as a button -- it never showed the dashboard")
  expect_true(grepl("not rendered on this machine", out, fixed = TRUE),
    info = "absence of a local render must be stated explicitly in the dry-run body")
  expect_true(grepl("QA:dashboard_url=none", out, fixed = TRUE),
    info = "QA marker must report 'none' when there is no override and no local file")
})

test_that("send_roborev_email.R dry-run: ROBOREV_DASHBOARD_URL override still works end-to-end", {
  skip_if_not_installed("blastula")
  out <- paste(
    run_daily_email_dry_run(extra_env = "ROBOREV_DASHBOARD_URL=https://example.com/roborev"),
    collapse = "\n"
  )
  expect_true(grepl("example.com/roborev", out, fixed = TRUE),
    info = "explicit http(s) override must still be honoured end-to-end")
  expect_true(grepl("QA:dashboard_url=https://example.com/roborev", out, fixed = TRUE))
})

# ── Integration test: send_roborev_weekly_rollup_email.R dry-run ─────────────

test_that("send_roborev_weekly_rollup_email.R dry-run: no override + no local file -> no button, no dead URL", {
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

  missing_local_path <- file.path(tempdir(), "roborev_weekly_dashlink_absent_", "roborev_summary.html")

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("ROBOREV_WEEKLY_DIR=", dir),
    "GMAIL_USERNAME=", "GMAIL_APP_PASSWORD=", "REPORT_RECIPIENT=",
    "ROBOREV_DASHBOARD_URL=",
    paste0("ROBOREV_DASHBOARD_LOCAL_PATH=", missing_local_path)
  )
  out <- withr::with_envvar(
    setNames(sub("^[^=]+=", "", env_vars), sub("=.*$", "", env_vars)),
    system2("Rscript", args = rollup_script, stdout = TRUE, stderr = TRUE)
  )
  combined <- paste(out, collapse = "\n")

  expect_false(grepl("johngavin.github.io/llmtelemetry", combined, fixed = TRUE),
    info = "the dead GH Pages URL must never appear in the rendered weekly email")
  expect_false(grepl("href=\"file://", combined, fixed = TRUE),
    info = "must never render a file:// href -- mail clients strip it")
  expect_false(grepl('href="https://github.com/JohnGavin/llmtelemetry"', combined, fixed = TRUE),
    info = "must never fall back to the private repo URL as a button")
  expect_true(grepl("not rendered on this machine", combined, fixed = TRUE),
    info = "absence of a local render must be stated explicitly in the dry-run body")
})
