# Helper auto-loaded by testthat before any test in this directory.
#
# `local_ctx_sync()` and `read_ctx_package_meta()` are defined in
# `R/tar_plans/plan_pkgctx.R`, a targets-plan file. devtools::load_all()
# does NOT source plan files, so the functions are unavailable in tests
# unless we source the plan file explicitly.
#
# We source into the global env (default for source() with local = FALSE)
# so `test_that()` blocks can see the functions through normal R lookup.
#
# Tracked in JohnGavin/llm#257 follow-up.
local({
  plan_file <- testthat::test_path("..", "..", "R", "tar_plans", "plan_pkgctx.R")
  if (file.exists(plan_file)) {
    source(plan_file, local = FALSE)
  }
})
