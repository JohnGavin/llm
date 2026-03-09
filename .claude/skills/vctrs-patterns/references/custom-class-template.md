# Custom vctrs Class Template

Copy this template when creating a new custom vector class. Replace `mytype`
with your actual type name throughout.

## File: R/mytype.R

```r
# ============================================================================
# mytype: A custom vector class
# ============================================================================

# -- Constructors ------------------------------------------------------------

#' Low-level constructor (fast, no validation)
#' @param x Underlying data (double vector)
#' @return A `pkg_mytype` vector
#' @noRd
new_mytype <- function(x = double()) {
  vec_assert(x, double())
  new_vctr(x, class = "pkg_mytype")
}

#' Create a mytype vector
#'
#' @param x A numeric vector of values.
#' @return A `pkg_mytype` vector.
#' @export
#' @examples
#' mytype(c(1.5, 2.3, 4.0))
mytype <- function(x = double()) {
  x <- vec_cast(x, double())
  # Add domain-specific validation here:
  # if (any(x < 0, na.rm = TRUE)) {
  #   cli::cli_abort("{.arg x} must be non-negative")
  # }
  new_mytype(x)
}

#' Test if an object is a mytype
#' @param x Object to test.
#' @return Logical scalar.
#' @export
is_mytype <- function(x) {
  inherits(x, "pkg_mytype")
}

# -- Display -----------------------------------------------------------------

#' @export
format.pkg_mytype <- function(x, ...) {
  out <- formatC(vec_data(x), format = "f", digits = 2)
  out[is.na(x)] <- NA
  # Customize display format here, e.g.:
  # paste0(out, " units")
  out
}

#' @export
obj_print_data.pkg_mytype <- function(x, ...) {
  if (length(x) == 0) return(invisible(x))
  cat(format(x), sep = "\n")
}

# -- Coercion: vec_ptype2 (common type) -------------------------------------
# Rule: vec_ptype2 must be SYMMETRIC. Define both directions.

#' @export
vec_ptype2.pkg_mytype.pkg_mytype <- function(x, y, ...) {
  new_mytype()
}

# mytype + double -> double (or mytype, depending on your semantics)
#' @export
vec_ptype2.pkg_mytype.double <- function(x, y, ...) {
  new_mytype()
}
#' @export
vec_ptype2.double.pkg_mytype <- function(x, y, ...) {
  new_mytype()
}

# Optionally support integer
#' @export
vec_ptype2.pkg_mytype.integer <- function(x, y, ...) {
  new_mytype()
}
#' @export
vec_ptype2.integer.pkg_mytype <- function(x, y, ...) {
  new_mytype()
}

# -- Coercion: vec_cast (actual conversion) ----------------------------------

#' @export
vec_cast.pkg_mytype.pkg_mytype <- function(x, to, ...) {
  x
}

#' @export
vec_cast.pkg_mytype.double <- function(x, to, ...) {
  new_mytype(x)
}

#' @export
vec_cast.double.pkg_mytype <- function(x, to, ...) {
  vec_data(x)
}

#' @export
vec_cast.pkg_mytype.integer <- function(x, to, ...) {
  new_mytype(as.double(x))
}

#' @export
vec_cast.integer.pkg_mytype <- function(x, to, ...) {
  as.integer(vec_data(x))
}

# -- Arithmetic: vec_arith ---------------------------------------------------

#' @export
vec_arith.pkg_mytype <- function(op, x, y, ...) {
  UseMethod("vec_arith.pkg_mytype", y)
}

#' @export
vec_arith.pkg_mytype.default <- function(op, x, y, ...) {
  stop_incompatible_op(op, x, y)
}

#' @export
vec_arith.pkg_mytype.pkg_mytype <- function(op, x, y, ...) {
  switch(op,
    "+" = new_mytype(vec_data(x) + vec_data(y)),
    "-" = new_mytype(vec_data(x) - vec_data(y)),
    stop_incompatible_op(op, x, y)
  )
}

#' @export
vec_arith.pkg_mytype.numeric <- function(op, x, y, ...) {
  switch(op,
    "*" = new_mytype(vec_data(x) * y),
    "/" = new_mytype(vec_data(x) / y),
    stop_incompatible_op(op, x, y)
  )
}

#' @export
vec_arith.numeric.pkg_mytype <- function(op, x, y, ...) {
  switch(op,
    "*" = new_mytype(x * vec_data(y)),
    stop_incompatible_op(op, x, y)
  )
}

#' @export
vec_arith.pkg_mytype.MISSING <- function(op, x, y, ...) {
  switch(op,
    "-" = new_mytype(-vec_data(x)),
    "+" = x,
    stop_incompatible_op(op, x, y)
  )
}

# -- Comparison proxy --------------------------------------------------------

#' @export
vec_proxy_compare.pkg_mytype <- function(x, ...) {
  vec_data(x)
}

#' @export
vec_proxy_equal.pkg_mytype <- function(x, ...) {
  vec_data(x)
}

# -- Pillar (tibble display) -------------------------------------------------
# Registered in .onLoad to avoid hard dependency on pillar

pillar_shaft_mytype <- function(x, ...) {
  out <- format(x)
  pillar::new_pillar_shaft_simple(out, align = "right")
}

type_sum_mytype <- function(x) {
  "mytyp"
}
```

## File: R/zzz.R (method registration)

```r
.onLoad <- function(libname, pkgname) {
  vctrs::s3_register("pillar::pillar_shaft", "pkg_mytype",
    pillar_shaft_mytype)
  vctrs::s3_register("pillar::type_sum", "pkg_mytype",
    type_sum_mytype)
}
```

## File: tests/testthat/test-mytype.R

```r
test_that("mytype constructor works", {
  x <- mytype(c(1, 2, 3))
  expect_s3_class(x, "pkg_mytype")
  expect_length(x, 3)
  expect_equal(vec_data(x), c(1, 2, 3))
})

test_that("mytype handles empty and NA", {
  expect_length(mytype(), 0)
  x <- mytype(c(1, NA, 3))
  expect_true(is.na(x[2]))
})

test_that("mytype formats correctly", {
  x <- mytype(c(1.234, NA))
  fmt <- format(x)
  expect_equal(fmt[1], "1.23")
  expect_true(is.na(fmt[2]))
})

test_that("mytype coercion: mytype <-> double", {
  x <- mytype(1.5)

  # Cast to double unwraps
  d <- vec_cast(x, double())
  expect_type(d, "double")
  expect_equal(d, 1.5)

  # Cast from double wraps
  y <- vec_cast(1.5, new_mytype())
  expect_s3_class(y, "pkg_mytype")
  expect_equal(vec_data(y), 1.5)
})

test_that("mytype coercion: combining with c()", {
  x <- mytype(1)
  y <- mytype(2)
  combined <- vec_c(x, y)
  expect_s3_class(combined, "pkg_mytype")
  expect_length(combined, 2)
})

test_that("mytype arithmetic: same type", {
  x <- mytype(3)
  y <- mytype(2)

  expect_equal(vec_data(x + y), 5)
  expect_equal(vec_data(x - y), 1)
  expect_error(x * y)
})

test_that("mytype arithmetic: with numeric", {
  x <- mytype(4)

  expect_equal(vec_data(x * 3), 12)
  expect_equal(vec_data(x / 2), 2)
  expect_equal(vec_data(3 * x), 12)
})

test_that("mytype arithmetic: unary", {
  x <- mytype(5)
  expect_equal(vec_data(-x), -5)
  expect_equal(vec_data(+x), 5)
})

test_that("mytype comparison works", {
  x <- mytype(c(3, 1, 2))
  expect_equal(sort(x), mytype(c(1, 2, 3)))
  expect_true(mytype(1) < mytype(2))
})

test_that("mytype works in tibble", {
  skip_if_not_installed("tibble")
  df <- tibble::tibble(val = mytype(c(1, 2, 3)))
  expect_s3_class(df$val, "pkg_mytype")
  expect_equal(nrow(df), 3)
})

test_that("mytype works with dplyr", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("tibble")

  df <- tibble::tibble(
    group = c("a", "b", "a"),
    val = mytype(c(1, 2, 3))
  )

  filtered <- dplyr::filter(df, val > mytype(1.5))
  expect_equal(nrow(filtered), 2)
})
```

## File: DESCRIPTION additions

```
Imports:
    cli,
    rlang,
    vctrs
Suggests:
    pillar,
    tibble,
    testthat (>= 3.0.0)
```

## File: R/pkg-package.R additions

```r
#' @importFrom vctrs new_vctr vec_assert vec_cast vec_ptype2
#' @importFrom vctrs vec_arith vec_data vec_c vec_recycle_common
#' @importFrom vctrs stop_incompatible_op stop_incompatible_type
#' @importFrom vctrs stop_incompatible_cast
NULL
```

## Adaptation Checklist

When copying this template for a new type:

1. Replace `pkg_mytype` with your `{package}_{typename}` (prefix with package name)
2. Replace `mytype` in function names: `new_mytype()`, `mytype()`, `is_mytype()`
3. Choose underlying storage type (`double()`, `integer()`, `character()`)
4. Add domain-specific validation to the user-facing constructor
5. Customize `format()` for your display needs
6. Decide coercion rules: what types can combine with yours?
7. Decide arithmetic rules: which operations make sense?
8. Update the `type_sum` abbreviation (max 5 chars for tibble headers)
9. Add any attributes your type needs (like `code` for currency)
10. If your type has attributes, preserve them in all arithmetic and cast methods

## Types with Attributes

If your type carries attributes (e.g., currency code, unit label), modify the
constructor and add attribute preservation:

```r
new_measured <- function(x = double(), unit = "kg") {
  vec_assert(x, double())
  new_vctr(x, unit = unit, class = "pkg_measured")
}

get_unit <- function(x) attr(x, "unit")

# Coercion must check attribute compatibility
#' @export
vec_ptype2.pkg_measured.pkg_measured <- function(x, y, ...) {
  if (get_unit(x) != get_unit(y)) {
    stop_incompatible_type(
      x, y,
      details = cli::format_inline(
        "Can't combine {.val {get_unit(x)}} with {.val {get_unit(y)}}"
      )
    )
  }
  new_measured(unit = get_unit(x))
}

# Arithmetic must preserve attributes
#' @export
vec_arith.pkg_measured.pkg_measured <- function(op, x, y, ...) {
  if (get_unit(x) != get_unit(y)) {
    stop_incompatible_op(op, x, y)
  }
  switch(op,
    "+" = new_measured(vec_data(x) + vec_data(y), unit = get_unit(x)),
    "-" = new_measured(vec_data(x) - vec_data(y), unit = get_unit(x)),
    stop_incompatible_op(op, x, y)
  )
}
```
