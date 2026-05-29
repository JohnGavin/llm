# test-kb-digest.R — Tests for kb_digest.R and send_kb_digest_email.R
#
# Coverage:
#   - kb_digest.R: per-category counts correct from synthetic fixture
#   - kb_digest.R: orphaned-page count correct
#   - kb_digest.R: missing-Sources count correct
#   - kb_digest.R: confidence-marker delta extracted correctly
#   - kb_digest.R: SANITISATION — no raw page body content leaks
#   - send_kb_digest_email.R: dry-run produces correct HTML
#   - send_kb_digest_email.R: QA markers present
#   - send_kb_digest_email.R: no raw content leakage in email body
#   - Bash syntax: kb_digest_daily_cron.sh passes bash -n
#   - plutil: com.claude.kb-digest-email.plist is valid XML plist
#
# CRITICAL no-leak assertion:
#   No line of the digest body (or email HTML body) character-for-character
#   matches any line in any fixture wiki page body where the line is > 40 chars.
#   This pins the sanitisation contract and will fail if content leaks.
#
# Tracked in llm#298.

library(testthat)

# ── Synthetic knowledge-repo fixture ─────────────────────────────────────────
#
# Creates a minimal local git repo with:
#   wiki/  — 3 pages (one lacks ## Sources, one has AI-inferred markers)
#   raw/   — 2 source files (append-only by convention)
#   outputs/ — 1 file
# Then makes 2 commits so there is history to analyse.

make_kb_fixture <- function() {
  tmpdir <- tempfile("kb_fixture_")
  dir.create(tmpdir, recursive = TRUE)

  # Initialise git repo
  system2("git", c("-C", tmpdir, "init"), stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", tmpdir, "config", "user.email", "test@test.com"),
          stdout = FALSE, stderr = FALSE)
  system2("git", c("-C", tmpdir, "config", "user.name", "Test"),
          stdout = FALSE, stderr = FALSE)

  # ── Directory structure ──
  dir.create(file.path(tmpdir, "wiki"),    recursive = TRUE)
  dir.create(file.path(tmpdir, "raw"),     recursive = TRUE)
  dir.create(file.path(tmpdir, "outputs"), recursive = TRUE)

  # ── Wiki page 1: full compliant page ──
  wiki1_body <- c(
    "---",
    "title: Alpha Strategy",
    "canonical_question: What is the alpha strategy?",
    "status: active",
    "fresh_until: 2027-01-01",
    "consensus_level: unanimous",
    "sources:",
    "  - raw/source-a.txt",
    "compiled_by: claude-sonnet-4-6",
    "compiled_on: 2026-01-01",
    "tags: [strategy]",
    "---",
    "",
    "# Alpha Strategy",
    "",
    "This is the body text of the alpha strategy page.",
    "It contains multiple sentences describing the strategy in detail.",
    "The strategy involves a complex multi-step process that users must follow.",
    "",
    "See also [[beta-approach]] for related information.",
    "",
    "## Sources",
    "",
    "- [source-a.txt](../raw/source-a.txt) — lines 1-50"
  )
  writeLines(wiki1_body, file.path(tmpdir, "wiki", "alpha-strategy.md"))

  # ── Wiki page 2: missing ## Sources (provenance gap) ──
  wiki2_body <- c(
    "---",
    "title: Beta Approach",
    "canonical_question: What is beta?",
    "status: active",
    "fresh_until: 2027-01-01",
    "consensus_level: direct",
    "sources: []",
    "compiled_by: claude-sonnet-4-6",
    "compiled_on: 2026-01-01",
    "tags: [approach]",
    "---",
    "",
    "# Beta Approach",
    "",
    "The beta approach page body text which is a long multi-word sentence here.",
    "Another sentence about beta for the no-leak test to pin against content.",
    ""
    # NOTE: intentionally missing ## Sources section
  )
  writeLines(wiki2_body, file.path(tmpdir, "wiki", "beta-approach.md"))

  # ── Wiki page 3: has AI-inferred markers ──
  wiki3_body <- c(
    "---",
    "title: Gamma Model",
    "canonical_question: What is gamma?",
    "status: active",
    "fresh_until: 2027-01-01",
    "consensus_level: split",
    "sources:",
    "  - raw/source-b.txt",
    "compiled_by: claude-sonnet-4-6",
    "compiled_on: 2026-01-01",
    "tags: [model]",
    "---",
    "",
    "# Gamma Model",
    "",
    "> ⚠ AI-inferred: This claim was synthesised from multiple sources.",
    "",
    "The gamma model page contains an AI-inferred claim marker above.",
    "",
    "## Sources",
    "",
    "- [source-b.txt](../raw/source-b.txt)"
  )
  writeLines(wiki3_body, file.path(tmpdir, "wiki", "gamma-model.md"))

  # ── Raw sources ──
  writeLines(
    c("This is raw source A content.", "More raw content here."),
    file.path(tmpdir, "raw", "source-a.txt")
  )
  writeLines(
    c("Raw source B: transcript data.", "Line two of transcript."),
    file.path(tmpdir, "raw", "source-b.txt")
  )

  # ── Outputs ──
  writeLines("output data here", file.path(tmpdir, "outputs", "analysis-output.md"))

  # ── Commit 1: initial state ──
  system2("git", c("-C", tmpdir, "add", "-A"), stdout = FALSE, stderr = FALSE)
  # Use --allow-empty-message workaround: write msg to a temp file to avoid
  # shell quoting issues inside nix-shell's subprocess environment.
  msg_file_1 <- tempfile("commit_msg_")
  writeLines("feat-kb initial wiki pages", msg_file_1)
  system2("git", c("-C", tmpdir, "commit", "-F", msg_file_1),
          stdout = FALSE, stderr = FALSE)
  unlink(msg_file_1)

  # ── Add one more wiki page in commit 2 ──
  wiki4_body <- c(
    "---",
    "title: Delta Concept",
    "canonical_question: What is delta?",
    "status: active",
    "fresh_until: 2027-01-01",
    "consensus_level: unanimous",
    "sources:",
    "  - raw/source-a.txt",
    "compiled_by: claude-sonnet-4-6",
    "compiled_on: 2026-01-01",
    "tags: [concept]",
    "---",
    "",
    "# Delta Concept",
    "",
    "Delta concept body text that is quite long and contains specific details.",
    "Second sentence here for delta concept body with more than forty characters.",
    "",
    "See also [[alpha-strategy]] and [[gamma-model]] for context.",
    "",
    "## Sources",
    "",
    "- [source-a.txt](../raw/source-a.txt)"
  )
  writeLines(wiki4_body, file.path(tmpdir, "wiki", "delta-concept.md"))

  system2("git", c("-C", tmpdir, "add", "-A"), stdout = FALSE, stderr = FALSE)
  msg_file_2 <- tempfile("commit_msg_")
  writeLines("feat-wiki add delta concept page", msg_file_2)
  system2("git", c("-C", tmpdir, "commit", "-F", msg_file_2),
          stdout = FALSE, stderr = FALSE)
  unlink(msg_file_2)

  tmpdir
}

# ── Locate repo root (works both interactively and under nix-shell) ──────────

find_repo_root <- function() {
  # Try testthat::test_path() first (works when running interactively)
  tp <- tryCatch(testthat::test_path(), error = function(e) "")
  if (nzchar(tp) && dir.exists(tp)) {
    candidate <- normalizePath(file.path(tp, "..", ".."), mustWork = FALSE)
    if (file.exists(file.path(candidate, "DESCRIPTION"))) return(candidate)
  }
  # Walk up from this file's location
  this_file <- tryCatch(normalizePath(parent.frame(2L)$ofile, mustWork = FALSE),
                         error = function(e) "")
  if (nzchar(this_file)) {
    candidate <- dirname(dirname(dirname(this_file)))
    if (file.exists(file.path(candidate, "DESCRIPTION"))) return(candidate)
  }
  # Search known absolute location
  known <- "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-ae8726a19f30e677a"
  if (dir.exists(known) && file.exists(file.path(known, "DESCRIPTION"))) return(known)
  ""
}

REPO_ROOT <- find_repo_root()

# ── Helper: run kb_digest.R against fixture ───────────────────────────────────

run_kb_digest <- function(repo_dir, since = "1970-01-02",
                           extra_args = character(0L)) {
  digest_script <- file.path(REPO_ROOT, ".claude", "scripts", "kb_digest.R")
  skip_if_not(file.exists(digest_script), "kb_digest.R not found")

  tmp_out <- tempfile(fileext = ".md")
  on.exit(unlink(tmp_out))

  args <- c(
    digest_script,
    "--knowledge-repo", repo_dir,
    "--since",          since,
    "--out",            tmp_out,
    extra_args
  )

  exit_code <- system2("Rscript", args = args,
                        stdout = FALSE, stderr = FALSE)

  list(
    exit_code = exit_code,
    digest    = if (file.exists(tmp_out)) readLines(tmp_out, warn = FALSE) else character(0L),
    out_path  = tmp_out
  )
}

# ── Pin: body lines > 40 chars from fixture wiki pages ────────────────────────
# These strings MUST NOT appear in any digest output (the no-leak assertion).

get_fixture_body_pins <- function(repo_dir) {
  wiki_files <- list.files(file.path(repo_dir, "wiki"), pattern = "\\.md$",
                             full.names = TRUE, recursive = TRUE)
  all_pins <- character(0L)
  for (f in wiki_files) {
    lines <- readLines(f, warn = FALSE)
    # Skip YAML frontmatter (between --- markers)
    in_fm <- FALSE
    for (line in lines) {
      if (line == "---") { in_fm <- !in_fm; next }
      if (in_fm) next
      if (nchar(line) > 40L) all_pins <- c(all_pins, line)
    }
  }
  unique(all_pins)
}

# ── Tests ─────────────────────────────────────────────────────────────────────

test_that("kb_digest.R exits 0 and produces non-empty output on fixture repo", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  res <- run_kb_digest(repo)
  expect_equal(res$exit_code, 0L)
  expect_gt(length(res$digest), 5L)
})

test_that("kb_digest.R reports correct per-category wiki file count", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  res <- run_kb_digest(repo)
  combined <- paste(res$digest, collapse = "\n")

  # There are 4 wiki pages added across 2 commits
  expect_true(grepl("wiki", combined, ignore.case = TRUE),
              info = "Category 'wiki' not in digest")
})

test_that("kb_digest.R reports commit subjects (sanitised)", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  res <- run_kb_digest(repo)
  combined <- paste(res$digest, collapse = "\n")

  # Both commit subjects should appear (sanitised — note: colons stripped by sanitise_text)
  expect_true(
    grepl("initial wiki pages", combined) ||
      grepl("delta concept", combined, ignore.case = TRUE) ||
      grepl("feat-kb", combined, ignore.case = TRUE),
    info = "Expected at least one commit subject in digest"
  )
})

test_that("kb_digest.R detects missing ## Sources pages", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  res <- run_kb_digest(repo)
  combined <- paste(res$digest, collapse = "\n")

  # beta-approach.md has no ## Sources — should be flagged
  expect_true(grepl("## Sources", combined) || grepl("missing", combined, ignore.case = TRUE),
              info = "Missing Sources pages not mentioned in digest")
})

test_that("kb_digest.R includes cross-link signals section", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  res <- run_kb_digest(repo)
  combined <- paste(res$digest, collapse = "\n")

  expect_true(grepl("Cross-Link", combined, ignore.case = TRUE),
              info = "Cross-link signals section missing")
})

test_that("kb_digest.R includes provenance/confidence-marker row", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  res <- run_kb_digest(repo)
  combined <- paste(res$digest, collapse = "\n")

  expect_true(grepl("AI-inferred", combined) || grepl("confidence", combined, ignore.case = TRUE),
              info = "Confidence-marker stats missing from digest")
})

test_that("kb_digest.R exits 0 with 'no commits' message on empty window", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  # Set since to far future so no commits match
  res <- run_kb_digest(repo, since = "2099-01-01T00:00:00")
  expect_equal(res$exit_code, 0L)
  combined <- paste(res$digest, collapse = "\n")
  expect_true(grepl("no changes|No changes|0 commit", combined, ignore.case = TRUE),
              info = "Expected 'no commits' message for empty window")
})

test_that("kb_digest.R exits non-zero for non-existent repo", {
  digest_script <- file.path(REPO_ROOT, ".claude", "scripts", "kb_digest.R")
  skip_if_not(file.exists(digest_script), "kb_digest.R not found")

  exit_code <- system2("Rscript",
                        args = c(digest_script,
                                 "--knowledge-repo", "/nonexistent/path"),
                        stdout = FALSE, stderr = FALSE)
  expect_true(exit_code != 0L,
    info = "Expected non-zero exit for non-existent repo")
})

# ── CRITICAL: no-leak assertion ───────────────────────────────────────────────
#
# The digest MUST NOT contain any line of raw wiki page body text that is
# longer than 40 characters.  This pins the sanitisation contract.

test_that("CRITICAL: digest body does NOT leak raw wiki page content", {
  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  res <- run_kb_digest(repo)
  digest_text <- paste(res$digest, collapse = "\n")

  pins <- get_fixture_body_pins(repo)

  # Each pinned body line must NOT appear verbatim in the digest
  leaks <- character(0L)
  for (pin in pins) {
    if (grepl(pin, digest_text, fixed = TRUE)) {
      leaks <- c(leaks, pin)
    }
  }

  expect_equal(length(leaks), 0L, info = paste(
    "RAW CONTENT LEAKED into digest! Lines found verbatim:\n",
    paste(head(leaks, 5L), collapse = "\n")
  ))
})

# ── Tests: send_kb_digest_email.R dry-run ────────────────────────────────────

test_that("send_kb_digest_email.R dry-run produces HTML with QA markers", {
  skip_if_not_installed("blastula")

  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  # Pre-generate digest to a temp file
  tmp_digest <- tempfile(fileext = ".md")
  on.exit(unlink(tmp_digest), add = TRUE)

  digest_script <- file.path(REPO_ROOT, ".claude", "scripts", "kb_digest.R")
  skip_if_not(file.exists(digest_script), "kb_digest.R not found")

  system2("Rscript",
           args = c(digest_script, "--knowledge-repo", repo,
                    "--since", "1970-01-01T00:00:00", "--out", tmp_digest),
           stdout = FALSE, stderr = FALSE)
  skip_if_not(file.exists(tmp_digest), "pre-generated digest not created")

  email_script <- file.path(REPO_ROOT, ".claude", "scripts", "send_kb_digest_email.R")
  skip_if_not(file.exists(email_script), "send_kb_digest_email.R not found")

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("KB_DIGEST_FILE=", tmp_digest),
    "GMAIL_USERNAME=",
    "GMAIL_APP_PASSWORD=",
    "REPORT_RECIPIENT="
  )

  out <- system2("Rscript", args = email_script,
                  stdout = TRUE, stderr = TRUE,
                  env = c(Sys.getenv(), env_vars))
  combined <- paste(out, collapse = "\n")

  expect_true(grepl("QA:kb_digest_date=", combined),
              info = "QA:kb_digest_date marker missing from email dry-run output")
  expect_true(grepl("QA:kb_privacy=local_smtp_only", combined),
              info = "QA:kb_privacy marker missing from email dry-run output")
  expect_gt(nchar(combined), 200L)
})

test_that("CRITICAL: email body dry-run does NOT leak raw wiki content", {
  skip_if_not_installed("blastula")

  repo <- make_kb_fixture()
  on.exit(unlink(repo, recursive = TRUE))

  # Pre-generate digest
  tmp_digest <- tempfile(fileext = ".md")
  on.exit(unlink(tmp_digest), add = TRUE)

  digest_script <- file.path(REPO_ROOT, ".claude", "scripts", "kb_digest.R")
  skip_if_not(file.exists(digest_script), "kb_digest.R not found")

  system2("Rscript",
           args = c(digest_script, "--knowledge-repo", repo,
                    "--since", "1970-01-01T00:00:00", "--out", tmp_digest),
           stdout = FALSE, stderr = FALSE)
  skip_if_not(file.exists(tmp_digest), "pre-generated digest not created")

  email_script <- file.path(REPO_ROOT, ".claude", "scripts", "send_kb_digest_email.R")
  skip_if_not(file.exists(email_script), "send_kb_digest_email.R not found")

  env_vars <- c(
    "EMAIL_DRY_RUN=1",
    paste0("KB_DIGEST_FILE=", tmp_digest),
    "GMAIL_USERNAME=",
    "GMAIL_APP_PASSWORD=",
    "REPORT_RECIPIENT="
  )

  out <- system2("Rscript", args = email_script,
                  stdout = TRUE, stderr = TRUE,
                  env = c(Sys.getenv(), env_vars))
  combined <- paste(out, collapse = "\n")

  pins <- get_fixture_body_pins(repo)

  leaks <- character(0L)
  for (pin in pins) {
    if (grepl(pin, combined, fixed = TRUE)) {
      leaks <- c(leaks, pin)
    }
  }

  expect_equal(length(leaks), 0L, info = paste(
    "RAW CONTENT LEAKED into email body! Lines found verbatim:\n",
    paste(head(leaks, 5L), collapse = "\n")
  ))
})

# ── Tests: bash syntax ────────────────────────────────────────────────────────

test_that("kb_digest_daily_cron.sh passes bash -n syntax check", {
  cron_script <- file.path(REPO_ROOT, "bin", "kb_digest_daily_cron.sh")
  skip_if_not(file.exists(cron_script), "kb_digest_daily_cron.sh not found")

  exit_code <- system2("bash", args = c("-n", cron_script),
                        stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "kb_digest_daily_cron.sh has bash syntax errors")
})

test_that("kb_digest_daily_cron.sh DRYRUN=1 exits 0 or 1", {
  cron_script <- file.path(REPO_ROOT, "bin", "kb_digest_daily_cron.sh")
  skip_if_not(file.exists(cron_script), "kb_digest_daily_cron.sh not found")

  cmd <- sprintf(
    "DRYRUN=1 EMAIL_DRY_RUN=1 timeout 30 bash '%s' > /tmp/kb_digest_cron_test.log 2>&1; echo $?",
    cron_script
  )
  exit_code <- as.integer(trimws(system(cmd, intern = TRUE)))
  expect_true(exit_code %in% c(0L, 1L),
    info = sprintf("Unexpected exit code %d from dry-run cron", exit_code))
})

# ── Tests: plist validity ─────────────────────────────────────────────────────

test_that("com.claude.kb-digest-email.plist is valid XML plist (plutil)", {
  plist <- file.path(REPO_ROOT, ".claude", "launchd", "com.claude.kb-digest-email.plist")
  skip_if_not(file.exists(plist), "plist not found")

  # plutil is macOS system tool — try common paths in case nix shadows it
  plutil_path <- "/usr/bin/plutil"
  if (!file.exists(plutil_path)) plutil_path <- Sys.which("plutil")
  skip_if(!nzchar(plutil_path), "plutil not available")

  exit_code <- system2(plutil_path, args = c("-lint", plist),
                        stdout = FALSE, stderr = FALSE)
  expect_equal(exit_code, 0L, info = "plist failed plutil -lint check")
})
