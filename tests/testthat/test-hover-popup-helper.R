# Tests for tt() hover-popup helper (R/hover_popup_helper.R)
# Covers: basic usage, HTML escaping, embedded links, multi-line body.
# Issue #246 — hover-popup standard MVP.

# Load the helper directly so we can test without a full package load.
.helper_path <- file.path(
  pkgload::pkg_path(),
  "R", "hover_popup_helper.R"
)

test_that("tt() produces a span with the correct CSS class and attribute", {
  source(.helper_path, local = TRUE)
  result <- tt("LLM", "Large Language Model. See <a href='https://example.com'>example</a>.")
  expect_true(grepl('class="tt"', result, fixed = TRUE))
  expect_true(grepl('data-tippy-content=', result, fixed = TRUE))
  expect_true(grepl('tabindex="0"', result, fixed = TRUE))
  expect_true(grepl(">LLM<", result, fixed = TRUE))
})

test_that("tt() HTML-escapes double-quotes in body to prevent attribute breakage", {
  source(.helper_path, local = TRUE)
  body_with_quotes <- 'Use "quotes" carefully. See <a href="https://example.com">link</a>.'
  result <- tt("term", body_with_quotes)
  # The rendered attribute must not contain raw " — only &quot;
  attr_content <- regmatches(result, regexpr('data-tippy-content="[^"]*"', result))
  expect_false(grepl('"quotes"', attr_content, fixed = TRUE),
    info = "Raw double-quotes inside attribute value break HTML parsing")
  expect_true(grepl("&quot;quotes&quot;", attr_content, fixed = TRUE))
})

test_that("tt() HTML-escapes ampersands in body", {
  source(.helper_path, local = TRUE)
  result <- tt("R&D", "Research & Development. See <a href='https://example.com'>ref</a>.")
  # The & in "Research & Development" should be escaped to &amp;
  # The & already in &amp; from the first pass should not be double-escaped
  attr_content <- regmatches(result, regexpr('data-tippy-content="[^"]*"', result))
  expect_true(grepl("Research &amp; Development", attr_content, fixed = TRUE))
})

test_that("tt() preserves an embedded <a href> link in the attribute value", {
  source(.helper_path, local = TRUE)
  link_body <- paste0(
    "<b>Targets pipeline</b>. A make-like build system for R. ",
    "See <a href='https://books.ropensci.org/targets/'>targets book</a>."
  )
  result <- tt("targets", link_body)
  expect_true(grepl("href=", result, fixed = TRUE))
  expect_true(grepl("targets book", result, fixed = TRUE))
})

test_that("tt() handles multi-line body collapsed to a single attribute value", {
  source(.helper_path, local = TRUE)
  multi_line <- paste(
    "<b>Quality Assurance</b>. Systematic checks applied to pipeline outputs",
    "before deployment. Includes HTML error scans and methodology block checks.",
    "See <a href='https://r-pkgs.org/testing-basics.html'>R packages testing guide</a>."
  )
  result <- tt("QA", multi_line)
  # Result must be a single character string (no newlines in the attribute)
  expect_length(result, 1L)
  expect_false(grepl("\n", result, fixed = TRUE))
  expect_true(nchar(result) > 50L)
})

test_that("tt() rejects empty term or body", {
  source(.helper_path, local = TRUE)
  expect_error(tt("", "Some body text."))
  expect_error(tt("term", ""))
})

test_that("tt() wraps term text verbatim (term not HTML-escaped)", {
  source(.helper_path, local = TRUE)
  # term is the visible text — passed through as-is for Quarto/knitr processing
  result <- tt("CI/CD", "Continuous integration. See <a href='https://example.com'>ref</a>.")
  expect_true(grepl(">CI/CD<", result, fixed = TRUE))
})

test_that("tt() raises an error when body has fewer than 2 sentences", {
  source(.helper_path, local = TRUE)
  # One sentence — should be rejected
  expect_error(
    tt("term", "Only one sentence here with <a href='https://example.com'>link</a>."),
    regexp = "at least 2 sentences"
  )
})

test_that("tt() raises an error when body has no <a href> anchor", {
  source(.helper_path, local = TRUE)
  # Two sentences but no link — should be rejected
  expect_error(
    tt("term", "First sentence. Second sentence without any link."),
    regexp = "at least one <a href"
  )
})

test_that("tt() accepts body with exactly 2 sentences and one link", {
  source(.helper_path, local = TRUE)
  # Minimum compliant body
  result <- tt(
    "API",
    "Application Programming Interface. Used to integrate external services, see <a href='https://example.com/api'>docs</a>."
  )
  expect_true(grepl('class="tt"', result, fixed = TRUE))
  expect_true(grepl("href=", result, fixed = TRUE))
})
