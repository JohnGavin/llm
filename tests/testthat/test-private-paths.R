# Tests for llm#1382: private path prefixes come from local config only.

make_cfg <- function(lines) {
  f <- withr::local_tempfile(fileext = ".txt", .local_envir = parent.frame())
  writeLines(lines, f)
  f
}

test_that("private_path_prefixes normalises paths and slugs, skips comments", {
  f <- make_cfg(c("# c", "", "/Users/someone/docs/_private_root/", "-Users-x-y-"))
  expect_equal(
    private_path_prefixes(f),
    c("-Users-someone-docs--private-root-", "-Users-x-y-")
  )
})

test_that("a missing config warns visibly and returns no prefixes", {
  expect_warning(
    res <- private_path_prefixes(file.path(tempdir(), "does_not_exist.txt")),
    "not found"
  )
  expect_equal(res, character(0))
})

test_that("canonicalize aliases a slug under a configured private prefix", {
  f <- make_cfg("/Users/someone/docs/_private_root/projx/")
  withr::local_envvar(c(LLM_PRIVATE_PATHS_FILE = f))
  raw <- c(
    "-Users-someone-docs--private-root-projx-secretname",
    "-Users-someone-docs-gh-llm"
  )
  out <- canonicalize_ccusage_project(raw)
  expect_equal(out, c("private-project", "llm"))
  expect_false(any(grepl("private-root|secretname", out)))
})

test_that("sanitize_ccusage_json removes every private token", {
  f <- make_cfg("-Users-someone-docs--private-root-projx-")
  json <- withr::local_tempfile(fileext = ".json")
  writeLines(c(
    '{"-Users-someone-docs--private-root-projx-name": [1],',
    ' "projectPath": "-Users-someone-docs--private-root-projx-name/abc-123",',
    ' "ok": "-Users-someone-docs-gh-llm"}'
  ), json)
  n <- sanitize_ccusage_json(json, prefixes = private_path_prefixes(f))
  txt <- paste(readLines(json), collapse = "\n")
  expect_equal(n, 2L)
  expect_false(grepl("private-root", txt))
  expect_match(txt, "private-project/abc-123", fixed = TRUE)
  expect_match(txt, "-Users-someone-docs-gh-llm", fixed = TRUE)
  expect_silent(jsonlite::fromJSON(json))
})

test_that("sanitize_ccusage_json refuses to run with no prefixes", {
  json <- withr::local_tempfile(fileext = ".json")
  writeLines("{}", json)
  expect_error(sanitize_ccusage_json(json, prefixes = character(0)), "No private")
})
