# Regression test for check_methodology_blocks() source-to-HTML path mapping.
# Covers roborev #3342: both top-level vignettes/ and vignettes/articles/ .qmd
# files must resolve to docs/articles/*.html (pkgdown layout).

# Source the functions under test from the package source tree.
# pkgload::pkg_path() gives the package root regardless of test working dir.
.qa_gates_path <- file.path(
  pkgload::pkg_path(),
  "R", "tar_plans", "plan_qa_gates.R"
)

test_that("check_methodology_blocks inspects top-level and nested vignette HTML", {
  # Build a minimal fixture tree that mirrors pkgdown output layout:
  #   vignettes/a.qmd           -> docs/articles/a.html
  #   vignettes/articles/b.qmd  -> docs/articles/b.html
  tmp <- withr::local_tempdir()
  vignettes_src <- file.path(tmp, "vignettes")
  vignettes_art <- file.path(tmp, "vignettes", "articles")
  docs_articles <- file.path(tmp, "docs", "articles")

  dir.create(vignettes_src, recursive = TRUE)
  dir.create(vignettes_art, recursive = TRUE)
  dir.create(docs_articles, recursive = TRUE)

  # Source .qmd stubs (content irrelevant — only name matters for path mapping)
  writeLines("# stub", file.path(vignettes_src, "a.qmd"))
  writeLines("# stub", file.path(vignettes_art, "b.qmd"))

  # Rendered HTML with all three mandatory methodology markers
  good_html <- paste(
    "<h2>Methodology</h2>",
    "<h3>What this vignette computes</h3>",
    "<h3>Data sources</h3>",
    "<h3>AI disclosure</h3>",
    sep = "\n"
  )
  writeLines(good_html, file.path(docs_articles, "a.html"))
  writeLines(good_html, file.path(docs_articles, "b.html"))

  source(.qa_gates_path, local = TRUE)
  result <- check_methodology_blocks(
    vignettes_dir = docs_articles,
    src_vignettes = vignettes_src
  )

  # Both files (top-level and articles/) should have been checked and passed
  expect_length(result, 2L)
  expect_true(all(grepl("\\.html$", result)))
})

test_that("check_methodology_blocks flags vignette missing AI disclosure", {
  tmp <- withr::local_tempdir()
  vignettes_src <- file.path(tmp, "vignettes")
  docs_articles <- file.path(tmp, "docs", "articles")

  dir.create(vignettes_src, recursive = TRUE)
  dir.create(docs_articles, recursive = TRUE)

  writeLines("# stub", file.path(vignettes_src, "c.qmd"))

  # HTML missing "AI disclosure" section
  incomplete_html <- paste(
    "<h2>Methodology</h2>",
    "<h3>What this vignette computes</h3>",
    "<h3>Data sources</h3>",
    sep = "\n"
  )
  writeLines(incomplete_html, file.path(docs_articles, "c.html"))

  source(.qa_gates_path, local = TRUE)
  expect_error(
    check_methodology_blocks(
      vignettes_dir = docs_articles,
      src_vignettes = vignettes_src
    ),
    regexp = "All rendered vignettes"
  )
})

# ── check_no_blank_plots() (#787) ────────────────────────────────────────────

test_that("check_no_blank_plots flags a deliberately-blanked plot fixture", {
  skip_if_not_installed("png")
  tmp  <- withr::local_tempdir()
  docs <- file.path(tmp, "docs")
  dir.create(docs, recursive = TRUE)

  # Deliberately blank: all-white PNG. Small dimensions keep the compressed
  # file well under the size threshold, matching a real blank-canvas render.
  blank_img <- array(1, dim = c(100L, 100L, 3L))
  png::writePNG(blank_img, file.path(docs, "blank-plot-1.png"))

  source(.qa_gates_path, local = TRUE)
  expect_error(
    check_no_blank_plots(html_dir = docs),
    regexp = "look blank or near-blank"
  )
})

test_that("check_no_blank_plots does not flag a real, varied-content PNG", {
  skip_if_not_installed("png")
  tmp  <- withr::local_tempdir()
  docs <- file.path(tmp, "docs")
  dir.create(docs, recursive = TRUE)

  # A stand-in "real chart": enough colour variation that both the
  # near-white-pixel fraction is low AND the compressed file size clears the
  # threshold -- the same two properties the #786 calibration set showed for
  # four genuinely non-blank figures.
  withr::local_seed(1L)
  real_img <- array(stats::runif(300L * 300L * 3L), dim = c(300L, 300L, 3L))
  png::writePNG(real_img, file.path(docs, "real-chart-1.png"))

  source(.qa_gates_path, local = TRUE)
  expect_no_error(check_no_blank_plots(html_dir = docs))
})

test_that("check_no_blank_plots respects skip_basenames for by-design near-blank figures", {
  skip_if_not_installed("png")
  tmp  <- withr::local_tempdir()
  docs <- file.path(tmp, "docs")
  dir.create(docs, recursive = TRUE)

  blank_img <- array(1, dim = c(100L, 100L, 3L))
  png::writePNG(blank_img, file.path(docs, "intentionally-blank.png"))

  source(.qa_gates_path, local = TRUE)
  expect_no_error(
    check_no_blank_plots(html_dir = docs, skip_basenames = "intentionally-blank.png")
  )
})
