## Guard repair_widget_deps() (R/vig_snapshot.R). DT::datatable() (and other
## htmlwidgets) record their JS/CSS assets as an *absolute* filesystem path
## in each html_dependency's src$file. saveRDS() preserves that path
## verbatim, so a committed inst/extdata/vignettes/*.rds snapshot carries
## whichever /nix/store/<hash>-r-<pkg>-<version>/library/<PKG>/... path the
## exporting machine happened to have -- a path CI does not have, causing
## quarto render to fail with "path for html_dependency not found" (#883).
## These tests pin the repair contract: leave already-portable/resolvable
## dependencies untouched, re-resolve broken ones via system.file(), and
## leave genuinely unresolvable ones alone rather than silently blanking
## them.

test_that("non-htmlwidget input is returned unchanged", {
  x <- list(a = 1, b = "not a widget")
  expect_identical(repair_widget_deps(x), x)

  y <- structure(list(a = 1), class = "some_other_class")
  expect_identical(repair_widget_deps(y), y)
})

test_that("htmlwidget with no dependencies is returned unchanged", {
  w <- structure(list(x = list(data = 1)), class = c("datatables", "htmlwidget"))
  expect_identical(repair_widget_deps(w), w)

  w_null_deps <- structure(
    list(x = list(data = 1), dependencies = NULL),
    class = c("datatables", "htmlwidget")
  )
  expect_identical(repair_widget_deps(w_null_deps), w_null_deps)
})

test_that("a dependency with a package field is left untouched", {
  dep <- list(
    name = "dt-core",
    package = "DT",
    src = list(file = "/nix/store/deadbeef-r-DT-0.34.0/library/DT/htmlwidgets/lib/datatables")
  )
  w <- structure(
    list(x = list(data = 1), dependencies = list(dep)),
    class = c("datatables", "htmlwidget")
  )

  out <- repair_widget_deps(w)
  expect_identical(out$dependencies[[1]], dep)
})

test_that("a dependency whose path already exists is left untouched (no-op case)", {
  tmp <- withr::local_tempdir()
  dep <- list(name = "jquery", src = list(file = tmp))
  w <- structure(
    list(x = list(data = 1), dependencies = list(dep)),
    class = c("datatables", "htmlwidget")
  )

  out <- repair_widget_deps(w)
  expect_identical(out$dependencies[[1]], dep)
})

test_that("a bogus nix-store path is re-resolved to the real installed package location", {
  skip_if_not_installed("DT")

  # A hash that is guaranteed not to exist on any machine (unlike a real
  # export's hash, which -- on the machine that produced it -- would
  # already exist and hit the no-op branch instead of the repair branch).
  bogus <- "/nix/store/0000000000000000000000000000000000-r-DT-0.34.0/library/DT/htmlwidgets/lib/datatables"
  dep <- list(name = "dt-core", src = list(file = bogus))
  w <- structure(
    list(x = list(data = 1), dependencies = list(dep)),
    class = c("datatables", "htmlwidget")
  )

  out <- repair_widget_deps(w)
  resolved <- out$dependencies[[1]]$src$file

  expect_false(identical(resolved, bogus))
  expect_true(dir.exists(resolved) || file.exists(resolved))
  expect_identical(resolved, system.file("htmlwidgets/lib/datatables", package = "DT"))
})

test_that("a dependency for an unresolvable package is left at its original (broken) path", {
  bogus <- "/nix/store/deadbeef-r-nosuchpkgxyz-0.0.0/library/nosuchpkgxyz/lib/foo"
  dep <- list(name = "mystery", src = list(file = bogus))
  w <- structure(
    list(x = list(data = 1), dependencies = list(dep)),
    class = c("datatables", "htmlwidget")
  )

  out <- repair_widget_deps(w)
  expect_identical(out$dependencies[[1]]$src$file, bogus)
})
