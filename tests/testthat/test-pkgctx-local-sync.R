# NOTE: `local_ctx_sync()` and `read_ctx_package_meta()` live in
# `R/tar_plans/plan_pkgctx.R` — a targets-plan file sourced explicitly,
# NOT a package function loaded by `devtools::load_all()`.
# The companion `helper-pkgctx-local-sync.R` sources the plan file into
# the global env before tests run.

test_that("local_ctx_sync returns empty tibble for directory with no ctx files", {
  empty_dir <- withr::local_tempdir()
  result <- local_ctx_sync(dirs = empty_dir, cache_dir = withr::local_tempdir())
  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 0L)
  expect_named(result, c("project_dir", "ctx_src", "package", "version", "dest", "action"))
})

test_that("local_ctx_sync returns 1-row tibble for directory with 1 valid ctx.yaml", {
  proj_dir  <- withr::local_tempdir()
  cache_dir <- withr::local_tempdir()

  # Write a minimal multi-doc ctx.yaml
  writeLines(
    c(
      "---",
      "kind: context_header",
      "llm_instructions: test",
      "---",
      "kind: package",
      "schema_version: '1.1'",
      "name: mypkg",
      "version: 0.2.0",
      "language: R",
      "description: Test package"
    ),
    file.path(proj_dir, "ctx.yaml")
  )

  result <- local_ctx_sync(dirs = proj_dir, cache_dir = cache_dir, dry_run = TRUE)

  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 1L)
  expect_equal(result$package, "mypkg")
  expect_equal(result$version, "0.2.0")
  expect_equal(result$action, "dry_run")
})

test_that("local_ctx_sync warns and marks parse_failed for malformed yaml", {
  proj_dir  <- withr::local_tempdir()
  cache_dir <- withr::local_tempdir()

  # Write an empty file — yaml::yaml.load on an empty file raises an error,
  # which local_ctx_sync catches and re-emits as a cli_warn() call.
  writeLines(character(0), file.path(proj_dir, "ctx.yaml"))

  result <- suppressWarnings(
    local_ctx_sync(dirs = proj_dir, cache_dir = cache_dir, dry_run = TRUE)
  )
  # Empty file -> parse error -> parse_failed row
  expect_equal(nrow(result), 1L)
  expect_equal(result$action, "parse_failed")
  expect_true(is.na(result$package))
})

test_that("local_ctx_sync dry_run=TRUE does not write files to cache", {
  proj_dir  <- withr::local_tempdir()
  cache_dir <- withr::local_tempdir()

  writeLines(
    c(
      "---",
      "kind: package",
      "name: testpkg",
      "version: 1.0.0",
      "language: R",
      "description: Test"
    ),
    file.path(proj_dir, "ctx.yaml")
  )

  result <- local_ctx_sync(dirs = proj_dir, cache_dir = cache_dir, dry_run = TRUE)

  # No files should be written to cache
  cache_files <- list.files(cache_dir, pattern = "\\.ctx\\.yaml$")
  expect_equal(length(cache_files), 0L)
  expect_equal(result$action, "dry_run")
})

test_that("local_ctx_sync dry_run=FALSE copies file to central cache", {
  proj_dir  <- withr::local_tempdir()
  cache_dir <- withr::local_tempdir()

  writeLines(
    c(
      "---",
      "kind: package",
      "name: writepkg",
      "version: 0.3.1",
      "language: R",
      "description: Write test"
    ),
    file.path(proj_dir, "ctx.yaml")
  )

  result <- local_ctx_sync(dirs = proj_dir, cache_dir = cache_dir, dry_run = FALSE)

  expect_equal(result$action, "copied")
  expect_true(file.exists(file.path(cache_dir, "writepkg@0.3.1.ctx.yaml")))
})

test_that("local_ctx_sync dry_run=FALSE marks 'skipped' when dest is identical", {
  proj_dir  <- withr::local_tempdir()
  cache_dir <- withr::local_tempdir()

  ctx_lines <- c(
    "---",
    "kind: package",
    "name: skippkg",
    "version: 1.0.0",
    "language: R",
    "description: Skip test"
  )
  src_file  <- file.path(proj_dir, "ctx.yaml")
  dest_file <- file.path(cache_dir, "skippkg@1.0.0.ctx.yaml")
  writeLines(ctx_lines, src_file)
  writeLines(ctx_lines, dest_file)

  result <- local_ctx_sync(dirs = proj_dir, cache_dir = cache_dir, dry_run = FALSE)
  expect_equal(result$action, "skipped")
})

test_that("local_ctx_sync aborts if dirs is not a character vector", {
  expect_error(
    local_ctx_sync(dirs = 42L),
    "dirs"
  )
})

test_that("local_ctx_sync aborts if dry_run is not a single logical", {
  expect_error(
    local_ctx_sync(dry_run = c(TRUE, FALSE)),
    "dry_run"
  )
})

test_that("read_ctx_package_meta extracts name and version from multi-doc yaml", {
  tmp <- withr::local_tempfile(fileext = ".ctx.yaml")
  writeLines(
    c(
      "---",
      "kind: context_header",
      "llm_instructions: test",
      "---",
      "kind: package",
      "name: mypkg",
      "version: 2.0.0",
      "language: R",
      "description: A test",
      "---",
      "kind: function",
      "name: foo"
    ),
    tmp
  )
  meta <- read_ctx_package_meta(tmp)
  expect_equal(meta$name, "mypkg")
  expect_equal(meta$version, "2.0.0")
})

test_that("read_ctx_package_meta returns NULL for non-existent file", {
  expect_null(read_ctx_package_meta("/does/not/exist.ctx.yaml"))
})

test_that("read_ctx_package_meta returns NULL when no kind: package document exists", {
  tmp <- withr::local_tempfile(fileext = ".ctx.yaml")
  writeLines(c("---", "kind: function", "name: foo"), tmp)
  expect_null(read_ctx_package_meta(tmp))
})

test_that("find_project_ctx_files returns character(0) for non-existent dir", {
  result <- find_project_ctx_files("/does/not/exist")
  expect_equal(result, character(0))
})

test_that("find_project_ctx_files finds ctx.yaml at project root", {
  proj_dir <- withr::local_tempdir()
  ctx_file <- file.path(proj_dir, "ctx.yaml")
  writeLines("---\nkind: package\nname: x\nversion: 0.1.0\n", ctx_file)
  result <- find_project_ctx_files(proj_dir)
  expect_true(ctx_file %in% result)
})

# ── ctx_sync(): one package's generate_ctx() error must not abort the batch ──
#
# Regression test for a bug where ctx_sync()'s `for` loops called
# generate_ctx() with no error handling: an uncaught error from ANY package
# aborted the whole ctx_sync() call, silently skipping every package still
# queued after it. Reported as "ctx_sync silently failed for 11 packages".
#
# generate_ctx() is stubbed (reassigned in .GlobalEnv, restored on exit) so
# these tests never shell out to `nix run github:b-rodrigues/pkgctx` — that
# would be slow, network-dependent, and irrelevant to the loop-control bug
# under test.

test_that("ctx_sync continues processing remaining packages after one generate_ctx() error", {
  proj_dir  <- withr::local_tempdir()
  cache_dir <- withr::local_tempdir()

  desc_path <- file.path(proj_dir, "DESCRIPTION")
  writeLines(
    c(
      "Package: dummy",
      "Imports:",
      "    zzzfakepkgone,",
      "    zzzfakepkgtwo,",
      "    zzzfakepkgthree"
    ),
    desc_path
  )

  orig_generate_ctx <- generate_ctx
  on.exit(assign("generate_ctx", orig_generate_ctx, envir = .GlobalEnv), add = TRUE)

  calls <- character(0)
  assign("generate_ctx", function(pkg, version = NULL, cache_dir = CTX_CACHE) {
    calls <<- c(calls, pkg)
    if (pkg == "zzzfakepkgtwo") {
      stop("simulated generate_ctx failure for ", pkg)
    }
    list(pkg = pkg, version = "0.0.0", status = "GENERATED", file = NA_character_)
  }, envir = .GlobalEnv)

  result <- suppressWarnings(
    ctx_sync(desc_path, cache_dir, fix_missing = TRUE, fix_stale = TRUE)
  )

  # All three packages must have been ATTEMPTED -- proves the loop continued
  # past zzzfakepkgtwo's error instead of aborting the whole batch.
  expect_setequal(calls, c("zzzfakepkgone", "zzzfakepkgtwo", "zzzfakepkgthree"))

  expect_equal(nrow(result), 3L)
  expect_equal(result$result[result$package == "zzzfakepkgone"], "GENERATED")
  expect_equal(result$result[result$package == "zzzfakepkgtwo"], "ERROR")
  expect_equal(result$result[result$package == "zzzfakepkgthree"], "GENERATED")
})

test_that("ctx_sync warns loudly (never silently) when generate_ctx() errors", {
  proj_dir  <- withr::local_tempdir()
  cache_dir <- withr::local_tempdir()

  desc_path <- file.path(proj_dir, "DESCRIPTION")
  writeLines(c("Package: dummy", "Imports:", "    zzzfakepkgfour"), desc_path)

  orig_generate_ctx <- generate_ctx
  on.exit(assign("generate_ctx", orig_generate_ctx, envir = .GlobalEnv), add = TRUE)
  assign("generate_ctx", function(pkg, version = NULL, cache_dir = CTX_CACHE) {
    stop("boom")
  }, envir = .GlobalEnv)

  expect_warning(
    ctx_sync(desc_path, cache_dir, fix_missing = TRUE, fix_stale = TRUE),
    "zzzfakepkgfour"
  )
})
