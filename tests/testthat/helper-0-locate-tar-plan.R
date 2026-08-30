# Helper auto-loaded by testthat before any test in this directory.
#
# R/tar_plans/ files are deliberately NOT collated into the package
# namespace (each plan file's own header comment says so) -- only
# tar_source() loads them, at pipeline-build time inside a real
# targets::tar_make() run. Tests that exercise their functions directly
# must source() the file, which requires locating it correctly in two very
# different runtime contexts:
#
#   1. Real install (R CMD check / covr::package_coverage() /
#      tools::testInstalledPackage()): the raw .R source under
#      R/tar_plans/ is NEVER installed -- an installed package's R/
#      directory holds only the compiled namespace database (llm.rdb /
#      llm.rdx), not browsable source files, regardless of whether the
#      file would otherwise have been collated. inst/tar_plans/ symlinks
#      the plan files actually sourced by tests (plan_qa_gates.R,
#      plan_vignette_outputs.R, plan_pkgctx.R) so they ARE shipped and
#      resolvable via system.file() -- mirrors the existing
#      inst/scripts/email_styles.R / inst/scripts/send_roborev_email.R
#      symlink pattern.
#   2. Dev tree (devtools::load_all() / devtools::test()): pkgload's
#      system.file() shim normally resolves this correctly too, but keep
#      the pkgload::pkg_path()-based dev-tree fallback for robustness in
#      case system.file() doesn't yet reflect a freshly-added symlink.
#      Mirrors the two-path idiom already used for locate_claude_script()
#      in test-roborev-dashboard-link.R.
#
# Returns NA_character_ if neither resolves, so call sites can degrade to
# skip_if_not() rather than a hard crash.
locate_tar_plan <- function(filename) {
  installed <- system.file("tar_plans", filename, package = "llm")
  if (nzchar(installed) && file.exists(installed)) {
    return(installed)
  }

  dev_tree <- tryCatch(
    file.path(pkgload::pkg_path(), "R", "tar_plans", filename),
    error = function(e) NA_character_
  )
  if (!is.na(dev_tree) && file.exists(dev_tree)) {
    return(dev_tree)
  }

  NA_character_
}
