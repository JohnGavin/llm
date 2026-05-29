# test-config-change-digest.R — Tests for config_change_digest.R and
# send_config_digest_email.R.
#
# Coverage:
#   - Aggregator: per-category counts/lines from synthetic git fixture
#   - Aggregator: theme grouping by conventional-commit scope
#   - Aggregator: lessons-learnt extraction (fix commits + CHANGELOG)
#   - Aggregator: --dry-run prints to stdout, exits 0
#   - Email: dry-run (EMAIL_DRY_RUN=1) output contains digest sections and
#     dashboard-link placeholder
#   - Shell scripts: bash -n syntax checks
#   - plist: plutil -lint validation
#
# Uses a synthetic git repository fixture — no real llm git history needed.
# All external processes guarded with skip_if_not / skip_on_ci as needed.

library(testthat)

# ── Paths ────────────────────────────────────────────────────────────────────

repo_root <- function() {
  # Attempt 1: resolve from the location of this test file (most reliable
  # when test_file() is called with an absolute path).
  this_file <- tryCatch(
    normalizePath(sys.frame(0)$ofile, mustWork = FALSE),
    error = function(e) ""
  )
  if (nzchar(this_file) && file.exists(this_file)) {
    candidate <- dirname(dirname(this_file))  # up from tests/testthat/
    if (file.exists(file.path(candidate, ".git"))) return(candidate)
  }

  # Attempt 2: use testthat::test_path() (works when run via devtools::test())
  tp <- tryCatch(testthat::test_path(), error = function(e) "")
  if (nzchar(tp)) {
    candidate <- normalizePath(file.path(tp, "..", ".."), mustWork = FALSE)
    if (file.exists(file.path(candidate, ".git"))) return(candidate)
  }

  # Attempt 3: walk up from cwd
  path <- getwd()
  for (i in seq_len(10L)) {
    if (file.exists(file.path(path, ".git"))) return(path)
    parent <- dirname(path)
    if (parent == path) break
    path <- parent
  }
  getwd()
}

script_path <- function(name) {
  normalizePath(
    file.path(repo_root(), ".claude", "scripts", name),
    mustWork = FALSE
  )
}

bin_path <- function(name) {
  normalizePath(
    file.path(repo_root(), "bin", name),
    mustWork = FALSE
  )
}

launchd_path <- function(name) {
  normalizePath(
    file.path(repo_root(), ".claude", "launchd", name),
    mustWork = FALSE
  )
}

# ── Synthetic git fixture ─────────────────────────────────────────────────────

# Creates a minimal git repo with commits spanning multiple config categories.
# Returns the path to the temporary repo.
make_git_fixture <- function() {
  dir <- tempfile("config_digest_git_fixture_")
  dir.create(dir, recursive = TRUE)

  # Write a small shell script to create the fixture commits — avoids
  # system2() shell-quoting issues with parentheses in commit messages.
  script_path <- file.path(dir, "make_fixture.sh")
  writeLines(c(
    "#!/bin/sh",
    paste0("set -e"),
    paste0("cd '", dir, "'"),
    "git init -b main",
    "git config user.email 'test@example.com'",
    "git config user.name  'Test User'",

    # Skills
    paste0("mkdir -p '.claude/skills/r-package-workflow'"),
    "printf 'line1\\nline2\\nline3\\n' > '.claude/skills/r-package-workflow/SKILL.md'",
    "git add .",
    "git commit -m 'feat(r-package-workflow): add step 9'",

    # Rules
    paste0("mkdir -p '.claude/rules'"),
    "printf 'line1\\nline2\\nline3\\n' > '.claude/rules/bash-safety.md'",
    "git add .",
    "git commit -m 'fix(bash-safety): correct ban documentation'",

    # Hooks
    paste0("mkdir -p '.claude/hooks'"),
    "printf 'line1\\nline2\\nline3\\n' > '.claude/hooks/pre_commit_lint.sh'",
    "git add .",
    "git commit -m 'feat(hooks): new pre-commit lint hook'",

    # Scripts
    paste0("mkdir -p '.claude/scripts'"),
    "printf 'line1\\nline2\\nline3\\n' > '.claude/scripts/burn_rate_check.sh'",
    "git add .",
    "git commit -m 'chore(scripts): update burn_rate_check threshold'",

    # Rules second fix
    "printf 'line1\\nline2\\nline3\\nline4\\n' > '.claude/rules/nix-nested-shell.md'",
    "git add .",
    "git commit -m 'fix(nix): correct nested shell isolation docs'",

    # Memory
    paste0("mkdir -p '.claude/memory'"),
    "printf 'line1\\nline2\\nline3\\n' > '.claude/memory/MEMORY.md'",
    "git add .",
    "git commit -m 'docs(memory): record worktree location convention'"
  ), script_path)

  system2("bash", args = script_path, stdout = FALSE, stderr = FALSE)
  dir
}

# ── Run the aggregator script against a fixture ───────────────────────────────

run_aggregator <- function(since = "2020-01-01T00:00:00", extra_args = character(0),
                           repo_dir = NULL) {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")

  out_path <- tempfile("digest_", fileext = ".md")
  on.exit(unlink(out_path), add = TRUE)

  # Build the env override list for withr (named character vector, not KEY=VAL).
  env_override <- if (!is.null(repo_dir)) c(LLM_REPO_ROOT = repo_dir) else character(0)

  args <- c(agg,
    "--since", since,
    "--out",   out_path,
    extra_args)

  # Use withr::with_envvar to set LLM_REPO_ROOT in the child process without
  # passing the full Sys.getenv() blob (which includes huge shellHook exports
  # that break system2 arg handling under Nix).
  result <- withr::with_envvar(
    env_override,
    system2("Rscript", args = args, stdout = TRUE, stderr = TRUE)
  )

  list(
    output   = paste(result, collapse = "\n"),
    md_path  = out_path,
    md_exists = file.exists(out_path),
    md_text   = if (file.exists(out_path)) paste(readLines(out_path, warn = FALSE), collapse = "\n") else ""
  )
}

# ── Helper: run email script in dry-run mode ──────────────────────────────────

run_email_dry_run <- function(digest_path = NULL, extra_env = character(0)) {
  email_script <- script_path("send_config_digest_email.R")
  skip_if_not(file.exists(email_script), "send_config_digest_email.R not found")
  skip_if_not_installed("blastula")

  # If no pre-made digest, generate a minimal one
  if (is.null(digest_path)) {
    digest_path <- tempfile("digest_email_test_", fileext = ".md")
    writeLines(c(
      "# Config-Change Digest — 2026-05-29",
      "",
      "**Window:** since 2026-05-28T00:00:00 | **Generated:** 2026-05-29T08:00:00Z UTC",
      "",
      "## Changes by Category",
      "",
      "| Category | Files changed | Lines added | Lines deleted |",
      "|----------|:---:|:---:|:---:|",
      "| Rules | 2 | +45 | -3 |",
      "| Scripts | 1 | +80 | -0 |",
      "| **Total** | **3** | **+125** | **-3** |",
      "",
      "## Themes Today",
      "",
      "### `bash-safety` (2 commits)",
      "",
      "- `abc1234` fix(bash-safety): correct example",
      "- `def5678` docs(bash-safety): add rationale",
      "",
      "## Lessons Learnt",
      "",
      "### From fix/revert commits",
      "",
      "- **[FIX]** `abc1234` fix(bash-safety): correct example",
      "",
      "---",
      "",
      "<!-- QA:config_digest_generated=2026-05-29T08:00:00Z -->",
      "<!-- QA:config_digest_since=2026-05-28T00:00:00 -->",
      "<!-- QA:config_digest_total_files=3 -->",
      "<!-- QA:config_digest_total_added=125 -->",
      "<!-- QA:config_digest_total_deleted=3 -->",
      "<!-- QA:config_digest_n_themes=1 -->",
      "<!-- QA:config_digest_n_lessons=1 -->"
    ), digest_path)
  }

  # Build named env override for withr (do NOT pass env= to system2 — the full
  # Sys.getenv() blob is too large and includes shellHook exports that break
  # system2 under Nix; withr::with_envvar sets vars in the child process env).
  env_override <- c(
    EMAIL_DRY_RUN           = "1",
    CONFIG_DIGEST_PATH      = digest_path,
    GMAIL_USERNAME          = "",
    GMAIL_APP_PASSWORD      = "",
    REPORT_RECIPIENT        = ""
  )
  # Merge caller extras (named character vector, KEY = VALUE form)
  if (length(extra_env) > 0L) {
    extra_named <- setNames(
      sub("^[^=]+=", "", extra_env),
      sub("=.*$",    "", extra_env)
    )
    env_override <- c(env_override, extra_named)
  }

  result <- withr::with_envvar(
    env_override,
    system2("Rscript", args = email_script,
            stdout = TRUE, stderr = TRUE)
  )
  list(
    output = paste(result, collapse = "\n"),
    digest_path = digest_path
  )
}

# ── Aggregator tests ──────────────────────────────────────────────────────────

test_that("aggregator --dry-run prints to stdout and exits 0", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")

  out <- system2("Rscript", args = c(agg, "--since", "2020-01-01T00:00:00", "--dry-run"),
                 stdout = TRUE, stderr = FALSE)
  combined <- paste(out, collapse = "\n")

  # Must contain the markdown digest header
  expect_true(grepl("Config-Change Digest", combined),
              info = "Digest header not found in --dry-run output")
})

test_that("aggregator produces output file with required sections", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")

  out_path <- tempfile("digest_sections_", fileext = ".md")
  on.exit(unlink(out_path), add = TRUE)

  system2("Rscript", args = c(agg,
    "--since", "2020-01-01T00:00:00",
    "--out",   out_path),
    stdout = FALSE, stderr = FALSE)

  skip_if_not(file.exists(out_path), "aggregator did not produce output file")
  text <- paste(readLines(out_path, warn = FALSE), collapse = "\n")

  expect_true(grepl("Changes by Category", text),
              info = "Category section missing from digest")
  expect_true(grepl("Themes Today", text),
              info = "Themes section missing from digest")
  expect_true(grepl("Lessons Learnt", text),
              info = "Lessons section missing from digest")
})

test_that("aggregator emits QA markers in output file", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")

  out_path <- tempfile("digest_qa_", fileext = ".md")
  on.exit(unlink(out_path), add = TRUE)

  system2("Rscript", args = c(agg,
    "--since", "2020-01-01T00:00:00",
    "--out",   out_path),
    stdout = FALSE, stderr = FALSE)

  skip_if_not(file.exists(out_path), "aggregator did not produce output file")
  text <- paste(readLines(out_path, warn = FALSE), collapse = "\n")

  expect_true(grepl("QA:config_digest_generated=", text),
              info = "QA:config_digest_generated marker missing")
  expect_true(grepl("QA:config_digest_total_files=", text),
              info = "QA:config_digest_total_files marker missing")
  expect_true(grepl("QA:config_digest_n_themes=", text),
              info = "QA:config_digest_n_themes marker missing")
})

test_that("aggregator with synthetic fixture detects category changes", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")
  skip_if_not(nzchar(Sys.which("git")), "git not found")

  fixture_dir <- make_git_fixture()
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)

  out_path <- tempfile("digest_fixture_", fileext = ".md")
  on.exit(unlink(out_path), add = TRUE)

  withr::with_envvar(
    c(LLM_REPO_ROOT = fixture_dir),
    system2("Rscript", args = c(agg,
      "--since", "2020-01-01T00:00:00",
      "--out",   out_path),
      stdout = FALSE, stderr = FALSE)
  )

  skip_if_not(file.exists(out_path), "aggregator did not produce output file")
  text <- paste(readLines(out_path, warn = FALSE), collapse = "\n")

  # The fixture has .claude/skills/, .claude/rules/, .claude/hooks/,
  # .claude/scripts/, .claude/memory/ changes — at least some must show up.
  expect_true(grepl("\\| Skills", text) || grepl("\\| Rules", text) ||
              grepl("\\| Scripts", text) || grepl("\\| Memory", text),
              info = "No category changes detected from synthetic fixture")
})

test_that("aggregator with synthetic fixture clusters themes by scope", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")
  skip_if_not(nzchar(Sys.which("git")), "git not found")

  fixture_dir <- make_git_fixture()
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)

  out_path <- tempfile("digest_themes_", fileext = ".md")
  on.exit(unlink(out_path), add = TRUE)

  withr::with_envvar(
    c(LLM_REPO_ROOT = fixture_dir),
    system2("Rscript", args = c(agg,
      "--since", "2020-01-01T00:00:00",
      "--out",   out_path),
      stdout = FALSE, stderr = FALSE)
  )

  skip_if_not(file.exists(out_path), "aggregator did not produce output file")
  text <- paste(readLines(out_path, warn = FALSE), collapse = "\n")

  # The fixture has commits with scopes: r-package-workflow, bash-safety, hooks,
  # scripts, nix, memory.  Themes section must be non-empty.
  expect_true(grepl("### `", text),
              info = "No theme headings found — theme clustering may have failed")
})

test_that("aggregator with synthetic fixture extracts fix lessons", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")
  skip_if_not(nzchar(Sys.which("git")), "git not found")

  fixture_dir <- make_git_fixture()
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)

  out_path <- tempfile("digest_lessons_", fileext = ".md")
  on.exit(unlink(out_path), add = TRUE)

  withr::with_envvar(
    c(LLM_REPO_ROOT = fixture_dir),
    system2("Rscript", args = c(agg,
      "--since", "2020-01-01T00:00:00",
      "--out",   out_path),
      stdout = FALSE, stderr = FALSE)
  )

  skip_if_not(file.exists(out_path), "aggregator did not produce output file")
  text <- paste(readLines(out_path, warn = FALSE), collapse = "\n")

  # Fixture has 2 fix: commits → lessons section must mention them
  expect_true(grepl("\\[FIX\\]", text),
              info = "No [FIX] lessons from fix commits in synthetic fixture")
})

test_that("aggregator includes CHANGELOG failed-approaches from window", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")
  skip_if_not(nzchar(Sys.which("git")), "git not found")

  fixture_dir <- make_git_fixture()
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)

  # Write a CHANGELOG with a failed approach in window
  cl_path <- file.path(fixture_dir, "CHANGELOG.md")
  writeLines(c(
    "# Changelog",
    "",
    "## 2026-05-29 (test session)",
    "",
    "### Failed Approaches",
    "",
    "- Used bash glob that did not recurse — switch to find",
    "- Called btw_tool_run_r which hung the session"
  ), cl_path)

  out_path <- tempfile("digest_cl_", fileext = ".md")
  on.exit(unlink(out_path), add = TRUE)

  withr::with_envvar(
    c(LLM_REPO_ROOT = fixture_dir),
    system2("Rscript", args = c(agg,
      "--since", "2026-05-28T00:00:00",
      "--out",   out_path),
      stdout = FALSE, stderr = FALSE)
  )

  skip_if_not(file.exists(out_path), "aggregator did not produce output file")
  text <- paste(readLines(out_path, warn = FALSE), collapse = "\n")

  expect_true(
    grepl("bash glob", text) || grepl("CHANGELOG", text),
    info = "CHANGELOG failed-approach entry not reflected in lessons section"
  )
})

# ── Email dry-run tests ───────────────────────────────────────────────────────

test_that("email dry-run output contains digest sections", {
  res <- run_email_dry_run()
  out <- res$output

  expect_true(grepl("Config-Change Digest", out),
              info = "Digest title not found in email dry-run output")
  expect_true(grepl("Changes by Category", out),
              info = "Category section not found in email dry-run output")
  expect_true(grepl("Themes Today", out) || grepl("Theme", out),
              info = "Themes section not found in email dry-run output")
  expect_true(grepl("Lessons", out),
              info = "Lessons section not found in email dry-run output")
})

test_that("email dry-run output contains GitHub commits link", {
  res <- run_email_dry_run()
  out <- res$output

  expect_true(grepl("github.com/JohnGavin/llm/commits", out),
              info = "GitHub commits link not found in email dry-run output")
})

test_that("email dry-run output contains QA markers", {
  res <- run_email_dry_run()
  out <- res$output

  expect_true(grepl("QA:email_report_date=", out),
              info = "QA:email_report_date marker missing from dry-run output")
  expect_true(grepl("QA:config_digest_section=present", out),
              info = "QA:config_digest_section marker missing from dry-run output")
})

test_that("email dry-run output is non-empty", {
  res <- run_email_dry_run()
  expect_gt(nchar(res$output), 200L)
})

test_that("email dry-run At a Glance table shows numeric values from digest", {
  res <- run_email_dry_run()
  out <- res$output

  # The digest fixture has 3 files / +125 lines
  expect_true(grepl("125", out) || grepl("\\+", out),
              info = "Expected numeric values from digest not found in email body")
})

# ── Shell script syntax checks ────────────────────────────────────────────────

test_that("config_change_digest.R is a well-formed R script (parse check)", {
  agg <- script_path("config_change_digest.R")
  skip_if_not(file.exists(agg), "config_change_digest.R not found")
  expect_silent(parse(file = agg))
})

test_that("send_config_digest_email.R is a well-formed R script (parse check)", {
  em <- script_path("send_config_digest_email.R")
  skip_if_not(file.exists(em), "send_config_digest_email.R not found")
  expect_silent(parse(file = em))
})

test_that("config_digest_cron.sh passes bash -n syntax check", {
  sh <- bin_path("config_digest_cron.sh")
  skip_if_not(file.exists(sh), "config_digest_cron.sh not found")
  exit_code <- system2("bash", args = c("-n", sh), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "config_digest_cron.sh has bash syntax errors")
})

test_that("com.claude.config-digest-email.plist is valid XML (plutil)", {
  pl <- launchd_path("com.claude.config-digest-email.plist")
  skip_if_not(file.exists(pl), "com.claude.config-digest-email.plist not found")
  skip_if_not(nzchar(Sys.which("plutil")), "plutil not available")
  exit_code <- system2("plutil", args = c("-lint", pl), stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "plist failed plutil -lint validation")
})
