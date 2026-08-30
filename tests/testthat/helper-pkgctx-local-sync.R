# Helper auto-loaded by testthat before any test in this directory.
#
# `local_ctx_sync()` and `read_ctx_package_meta()` are defined in
# `R/tar_plans/plan_pkgctx.R`, a targets-plan file. devtools::load_all()
# does NOT source plan files, so the functions are unavailable in tests
# unless we source the plan file explicitly.
#
# testthat::test_path("..", "..", ...) only resolves to the real source
# tree in a dev-tree context. Under covr::package_coverage()/R CMD check
# the working test copy's cwd doesn't reach a source tree with
# R/tar_plans/*.R on disk, so this previously silently no-op'd and every
# test in test-pkgctx-local-sync.R failed with "could not find function".
# locate_tar_plan() (helper-0-locate-tar-plan.R, named to sort and load
# alphabetically before this file) resolves via system.file() under a
# real install (inst/tar_plans/ symlink), with the same dev-tree fallback
# as a backup.
#
# We source into the global env (default for source() with local = FALSE)
# so `test_that()` blocks can see the functions through normal R lookup.
#
# Tracked in JohnGavin/llm#257 follow-up.
local({
  plan_file <- locate_tar_plan("plan_pkgctx.R")
  if (!is.na(plan_file)) {
    source(plan_file, local = FALSE)
  }
})
