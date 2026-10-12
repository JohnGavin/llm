# llm#1405: a test must never copy the live ~/.claude/logs/unified.duckdb
# (6.5 GB and growing). Fourteen such copies in one test run filled the disk.
# Fixtures are schema-only tempfile DBs instead (see
# test-overnight-self-review-email.R, `.schema_base_db()`).

# Return "file:line" for every file.copy( call whose argument text (this line
# plus the next 2, to catch wrapped calls) names the live DB.
.live_db_copy_hits <- function(lines, file) {
  copy_re <- "file\\.copy\\("
  live_re <- "unified\\.duckdb|\\.real_db|real_db"
  hits <- character(0)
  for (i in grep(copy_re, lines)) {
    window <- paste(lines[i:min(i + 2L, length(lines))], collapse = " ")
    if (grepl(live_re, window)) hits <- c(hits, sprintf("%s:%d", basename(file), i))
  }
  hits
}

test_that("scanner detects a file.copy of the live DB (positive control)", {
  expect_length(.live_db_copy_hits("  file.copy(.real_db, dst)", "x.R"), 1L)
  expect_length(.live_db_copy_hits(c("file.copy(", "  '~/.claude/logs/unified.duckdb',", "  dst)"), "x.R"), 1L)
  expect_length(.live_db_copy_hits("file.copy(a, b)  # unrelated", "x.R"), 0L)
})

test_that("no test under tests/ copies the live unified.duckdb (llm#1405)", {
  tests_dir <- normalizePath(file.path(testthat::test_path(), ".."), mustWork = TRUE)
  files <- list.files(tests_dir, pattern = "\\.(R|r)$", recursive = TRUE, full.names = TRUE)
  files <- files[basename(files) != "test-no-live-db-copy.R"]
  skip_if(length(files) < 5L, "tests/ tree not present (stripped build)")
  hits <- unlist(lapply(files, function(f) .live_db_copy_hits(readLines(f, warn = FALSE), f)))
  expect_length(hits, 0L)
  if (length(hits)) message("live-DB copies at: ", paste(hits, collapse = ", "))
})
