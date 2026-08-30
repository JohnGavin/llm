# Tests for check_hover_popups() in R/tar_plans/plan_qa_gates.R
# Exercises: passing case, bare <abbr title>, short tooltip, missing link.
# Issue #246 — hover-popup QA gate.

# locate_tar_plan() is defined in helper-0-locate-tar-plan.R (auto-loaded).
# Resolves via system.file() under a real install (inst/tar_plans/ symlink)
# with a dev-tree fallback -- see that helper's header comment for why
# pkgload::pkg_path() alone breaks under covr::package_coverage()/R CMD check.
.qa_gates_path <- locate_tar_plan("plan_qa_gates.R")

# ---------------------------------------------------------------------------
# 1. Empty docs dir — warning (cli_alert), returns invisible(character(0))
# ---------------------------------------------------------------------------

test_that("check_hover_popups() returns empty vector for empty docs dir", {
  skip_if_not(!is.na(.qa_gates_path), "plan_qa_gates.R not found")
  source(.qa_gates_path, local = TRUE)
  tmp <- withr::local_tempdir()
  # No HTML files exist — should NOT abort, just return invisible(character(0))
  result <- check_hover_popups(tmp)
  expect_equal(length(result), 0L)
})

# ---------------------------------------------------------------------------
# 2. Clean page — no Tippy elements, no bare <abbr> — should pass
# ---------------------------------------------------------------------------

test_that("check_hover_popups() passes for a page with no tooltips at all", {
  skip_if_not(!is.na(.qa_gates_path), "plan_qa_gates.R not found")
  source(.qa_gates_path, local = TRUE)
  tmp <- withr::local_tempdir()
  writeLines(
    c(
      "<html><body>",
      "<p>No tooltips here, just normal text.</p>",
      "<script src='https://unpkg.com/tippy.js@6'></script>",
      "</body></html>"
    ),
    file.path(tmp, "clean.html")
  )
  result <- check_hover_popups(tmp)
  expect_true(length(result) >= 1L)
})

# ---------------------------------------------------------------------------
# 3. Bare <abbr title> with NO Tippy spans — must fail
# ---------------------------------------------------------------------------

test_that("check_hover_popups() fails for bare <abbr title> without Tippy upgrade", {
  skip_if_not(!is.na(.qa_gates_path), "plan_qa_gates.R not found")
  source(.qa_gates_path, local = TRUE)
  tmp <- withr::local_tempdir()
  writeLines(
    c(
      "<html><body>",
      "<p><abbr title='Large Language Model'>LLM</abbr> is used here.</p>",
      "</body></html>"
    ),
    file.path(tmp, "bare-abbr.html")
  )
  expect_error(
    check_hover_popups(tmp),
    regexp = "hover-popup QA failed"
  )
})

# ---------------------------------------------------------------------------
# 4. Tippy element with only 1 sentence in body — must fail
# ---------------------------------------------------------------------------

test_that("check_hover_popups() fails for tooltip with fewer than 2 sentences", {
  skip_if_not(!is.na(.qa_gates_path), "plan_qa_gates.R not found")
  source(.qa_gates_path, local = TRUE)
  tmp <- withr::local_tempdir()
  writeLines(
    c(
      "<html><body>",
      "<script src='https://unpkg.com/tippy.js@6'></script>",
      paste0(
        "<span class=\"tt\" ",
        "data-tippy-content=\"Only one sentence with ",
        "<a href=&quot;https://example.com&quot;>link</a>.\">",
        "term</span>"
      ),
      "</body></html>"
    ),
    file.path(tmp, "short-tooltip.html")
  )
  expect_error(
    check_hover_popups(tmp),
    regexp = "hover-popup QA failed"
  )
})

# ---------------------------------------------------------------------------
# 5. Tippy element with no <a href> in body — must fail
# ---------------------------------------------------------------------------

test_that("check_hover_popups() fails for tooltip with no anchor link", {
  skip_if_not(!is.na(.qa_gates_path), "plan_qa_gates.R not found")
  source(.qa_gates_path, local = TRUE)
  tmp <- withr::local_tempdir()
  writeLines(
    c(
      "<html><body>",
      "<script src='https://unpkg.com/tippy.js@6'></script>",
      paste0(
        "<span class=\"tt\" ",
        "data-tippy-content=\"First sentence. Second sentence. No link at all.\">",
        "term</span>"
      ),
      "</body></html>"
    ),
    file.path(tmp, "no-link.html")
  )
  expect_error(
    check_hover_popups(tmp),
    regexp = "hover-popup QA failed"
  )
})

# ---------------------------------------------------------------------------
# 6. Fully compliant Tippy popup — must pass
# ---------------------------------------------------------------------------

test_that("check_hover_popups() passes for a compliant Tippy popup", {
  skip_if_not(!is.na(.qa_gates_path), "plan_qa_gates.R not found")
  source(.qa_gates_path, local = TRUE)
  tmp <- withr::local_tempdir()
  writeLines(
    c(
      "<html><body>",
      "<script src='https://unpkg.com/tippy.js@6'></script>",
      paste0(
        "<span class=\"tt\" data-tippy-content=\"",
        "<b>Large Language Model</b>. A neural network trained on large text corpora. ",
        "See <a href='https://en.wikipedia.org/wiki/Large_language_model'>Wikipedia</a>.",
        "\">LLM</span>"
      ),
      "</body></html>"
    ),
    file.path(tmp, "compliant.html")
  )
  result <- check_hover_popups(tmp)
  expect_true(length(result) >= 1L)
})

# ---------------------------------------------------------------------------
# 7. Bare <abbr> on same page AS Tippy spans — not an error (Tippy present)
# ---------------------------------------------------------------------------

test_that("check_hover_popups() does NOT fail when bare <abbr> coexists with Tippy spans", {
  skip_if_not(!is.na(.qa_gates_path), "plan_qa_gates.R not found")
  source(.qa_gates_path, local = TRUE)
  tmp <- withr::local_tempdir()
  writeLines(
    c(
      "<html><body>",
      "<script src='https://unpkg.com/tippy.js@6'></script>",
      # bare abbr on same page as Tippy — should only warn, not abort
      "<p><abbr title='Application Programming Interface'>API</abbr></p>",
      # compliant Tippy popup
      paste0(
        "<span class=\"tt\" data-tippy-content=\"",
        "Application Programming Interface. Used for integrating services. ",
        "See <a href='https://example.com'>docs</a>.",
        "\">API</span>"
      ),
      "</body></html>"
    ),
    file.path(tmp, "mixed.html")
  )
  # bare abbr WITH Tippy present should NOT raise an error
  result <- check_hover_popups(tmp)
  expect_true(length(result) >= 1L)
})
