---
name: vctrs-patterns
description: >
  Guide for building custom S3 vector classes with vctrs. Use when:
  (1) Creating domain-specific types (percentages, currencies, units),
  (2) Implementing type coercion with vec_cast()/vec_ptype2(),
  (3) Adding arithmetic operations with vec_arith(),
  (4) Ensuring compatibility with tibble and dplyr,
  (5) Validating vector types and sizes with vec_assert()/vec_check_size(),
  (6) Deciding between vctrs and simple S3 classes.
metadata:
  author: johngavin
  version: "1.0"
  github-issue: 42
---

# Custom Vector Classes with vctrs

Build type-safe, tidyverse-compatible S3 vector classes using the vctrs package.

## When to Use vctrs vs Simple S3

| Scenario | Use vctrs | Use simple S3 |
|----------|-----------|---------------|
| Needs to work in tibble columns | Yes | No |
| Requires type-safe coercion rules | Yes | No |
| Custom arithmetic operations | Yes | Maybe |
| Needs dplyr verb compatibility | Yes | No |
| Simple container (list-like) | Overkill | Yes |
| One-off wrapper | Overkill | Yes |
| Domain type used across packages | Yes | No |

**Rule of thumb:** If your type will live in a data frame, use vctrs. If it is a
standalone object (like a model or connection), use simple S3.

### Before Building a Custom Type: Check `units` First

For **physical measurements, currencies, or any quantity with conversion rules**, use the
[units](https://cran.r-project.org/package=units) package instead of building a vctrs class
from scratch. `units` already provides: type-safe arithmetic, automatic conversion between
compatible units, ggplot2 axis labelling, and dplyr/tibble integration.

| Need | Use `units` | Build with vctrs |
|------|-------------|-----------------|
| Physical quantity (m, kg, s, Hz) | Yes — built-in | Unnecessary |
| Custom measurement (micromort, microlife) | Yes — `install_unit()` | Unnecessary |
| Quantity + uncertainty (1 ± 0.3 m/s) | Yes — `quantities` package | Unnecessary |
| Non-numeric domain type (colour, IP address) | No | Yes |
| Type with non-standard arithmetic | No | Yes |

```r
# Example: custom units in 3 lines, not 100+
units::install_unit("micromort")
units::install_unit("microlife", "30 min")
x <- units::set_units(2.5, micromort)  # type-safe, auto-converts, ggplot-ready
```

### The r-quantities Ecosystem: units + errors + quantities

For values that carry both a **unit and uncertainty** (e.g., lab measurements, model estimates),
use the [r-quantities](https://github.com/r-quantities) family:

| Package | What It Adds | Example |
|---------|-------------|---------|
| `units` | Measurement units, conversion, type safety | `set_units(9.81, m/s^2)` |
| `errors` | Uncertainty propagation (first-order Taylor) | `set_errors(9.81, 0.02)` → `9.81 ± 0.02` |
| `quantities` | Combined: unit + uncertainty in one object | `9.81 ± 0.02 [m/s^2]` |
| `constants` | CODATA physical constants as `quantities` | `syms$c` → speed of light with unit + uncertainty |

```r
library(quantities)

# Lab measurement: value + uncertainty + unit
hb <- set_quantities(13.2, g/dL, 0.3)   # 13.2 ± 0.3 [g/dL]
set_units(hb, g/L)                        # 132.0 ± 3.0 [g/L] — auto-converts

# Arithmetic propagates both
hb_low <- set_quantities(10.5, g/dL, 0.2)
hb - hb_low                               # 2.7 ± 0.4 [g/dL] — uncertainty propagated

# Model estimate with CI
or <- set_errors(1.85, 0.23)              # odds ratio 1.85 ± 0.23
log(or)                                    # 0.615 ± 0.124 — log-transformed with propagated error
```

**When to use which:**

| Scenario | Package |
|----------|---------|
| Physical/custom measurements only | `units` |
| Values with error bars, no units (odds ratios, coefficients) | `errors` |
| Lab values with units AND uncertainty (haemoglobin g/dL ± 0.3) | `quantities` |
| Radiation dose constants for micromort calculations | `constants` + `units` |

**Project relevance:**
- **coMMpass**: lab measurements (haemoglobin, albumin, creatinine) — `quantities` for value + unit + uncertainty
- **football**: model estimates (odds ratios, Elo ratings) — `errors` for uncertainty propagation
- **micromort**: risk metrics — `units` for micromort/microlife, `constants` for radiation dose

Also see: `clock` (vctrs-based date-time, stricter than lubridate).

## Creating a Custom Vector Class

### Step 1: Constructor with `new_vctr()`

The low-level constructor creates the object. It should be fast and not validate:

```r
new_percent <- function(x = double()) {
  vec_assert(x, double())
  new_vctr(x, class = "my_percent")
}
```

### Step 2: User-Facing Constructor

The user-facing constructor validates and coerces inputs:

```r
percent <- function(x = double()) {
  x <- vec_cast(x, double())
  if (any(x < 0 | x > 1, na.rm = TRUE)) {
    cli::cli_abort(c(
      "{.arg x} must be between 0 and 1",
      "x" = "Got values in range [{min(x, na.rm = TRUE)}, {max(x, na.rm = TRUE)}]"
    ))
  }
  new_percent(x)
}
```

### Step 3: Prototype Helper

For testing and type declarations, expose a zero-length prototype:

```r
#' @export
is_percent <- function(x) {
  inherits(x, "my_percent")
}
```

## Display: format and print Methods

### format Method (Required)

`format()` controls how each element displays. Must return a character vector:

```r
#' @export
format.my_percent <- function(x, ...) {
  out <- formatC(vec_data(x) * 100, format = "f", digits = 1)
  out[is.na(x)] <- NA
  paste0(out, "%")
}
```

### obj_print_data and obj_print_footer (Optional)

Fine-grained control over printing:

```r
#' @export
obj_print_data.my_percent <- function(x, ...) {
  if (length(x) == 0) return(invisible(x))
  cat(format(x), sep = "\n")
}
```

### Pillar Method for Tibble Display

For custom tibble column formatting, implement `pillar_shaft`:

```r
#' @export
pillar_shaft.my_percent <- function(x, ...) {
  out <- format(x)
  pillar::new_pillar_shaft_simple(out, align = "right")
}

#' @export
type_sum.my_percent <- function(x) "pct"
```

## Type Coercion: vec_ptype2 and vec_cast

These two methods form the double-dispatch system for type safety.

### vec_ptype2: "What type should the result be?"

Determines the common type when combining vectors. Must be symmetric:

```r
#' @export
vec_ptype2.my_percent.my_percent <- function(x, y, ...) new_percent()

#' @export
vec_ptype2.my_percent.double <- function(x, y, ...) double()
#' @export
vec_ptype2.double.my_percent <- function(x, y, ...) double()
```

### vec_cast: "How do I convert to this type?"

Performs the actual conversion:

```r
#' @export
vec_cast.my_percent.my_percent <- function(x, to, ...) x

#' @export
vec_cast.my_percent.double <- function(x, to, ...) new_percent(x)

#' @export
vec_cast.double.my_percent <- function(x, to, ...) vec_data(x)
```

### Coercion Rules Summary

| From \ To | percent | double | integer | character |
|-----------|---------|--------|---------|-----------|
| percent   | identity | unwrap | lossy   | format    |
| double    | wrap    | -      | -       | -         |
| integer   | via dbl | -      | -       | -         |
| character | parse   | -      | -       | -         |

### Registering Methods

In your package, register with `s3_register()` or roxygen2 `@export`:

```r
.onLoad <- function(libname, pkgname) {
  vctrs::s3_register("pillar::pillar_shaft", "my_percent")
  vctrs::s3_register("pillar::type_sum", "my_percent")
}
```

## Arithmetic: vec_arith

Implement arithmetic operations for your type:

```r
#' @export
vec_arith.my_percent <- function(op, x, y, ...) {
  UseMethod("vec_arith.my_percent", y)
}

#' @export
vec_arith.my_percent.default <- function(op, x, y, ...) {
  stop_incompatible_op(op, x, y)
}

# percent + percent = double (sum of proportions)
#' @export
vec_arith.my_percent.my_percent <- function(op, x, y, ...) {
  switch(op,
    "+" = new_percent(vec_data(x) + vec_data(y)),
    "-" = new_percent(vec_data(x) - vec_data(y)),
    stop_incompatible_op(op, x, y)
  )
}

# percent * numeric = percent (scaling)
#' @export
vec_arith.my_percent.numeric <- function(op, x, y, ...) {
  switch(op,
    "*" = new_percent(vec_data(x) * y),
    "/" = new_percent(vec_data(x) / y),
    stop_incompatible_op(op, x, y)
  )
}

# Unary operations
#' @export
vec_arith.my_percent.MISSING <- function(op, x, y, ...) {
  switch(op,
    "-" = new_percent(-vec_data(x)),
    "+" = x,
    stop_incompatible_op(op, x, y)
  )
}
```

## Validation Helpers

### vec_assert: Type Checking

Asserts that a vector has a specific prototype:

```r
validate_inputs <- function(rate, amount) {
  vec_assert(rate, new_percent())
  vec_assert(amount, double())
}
```

### vec_check_size and vec_recycle_common

```r
apply_rate <- function(rate, amount) {
  vec_check_size(rate, size = 1L)       # must be scalar
  args <- vec_recycle_common(rate, amount)  # recycle 1-to-n
  args[[1]] * args[[2]]
}
```

## Real-World Example: Currency Type

A type with an attribute (currency code) that constrains coercion:

```r
new_currency <- function(x = double(), code = "USD") {
  vec_assert(x, double())
  new_vctr(x, code = code, class = "my_currency")
}

currency <- function(x = double(), code = "USD") {
  x <- vec_cast(x, double())
  code <- toupper(code)
  if (!code %in% c("USD", "EUR", "GBP")) {
    cli::cli_abort("Unsupported currency code: {.val {code}}")
  }
  new_currency(x, code = code)
}

currency_code <- function(x) attr(x, "code")

#' @export
format.my_currency <- function(x, ...) {
  symbol <- switch(currency_code(x), USD = "$", EUR = "\u20ac", GBP = "\u00a3")
  out <- formatC(vec_data(x), format = "f", digits = 2, big.mark = ",")
  out[is.na(x)] <- NA
  paste0(symbol, out)
}

# Only same-currency combining allowed
#' @export
vec_ptype2.my_currency.my_currency <- function(x, y, ...) {
  if (currency_code(x) != currency_code(y)) {
    stop_incompatible_type(x, y, details = "Can't combine different currencies")
  }
  new_currency(code = currency_code(x))
}
```

See [references/custom-class-template.md](references/custom-class-template.md)
for a full "types with attributes" pattern including cast and arithmetic methods.

## Tibble and dplyr Compatibility

vctrs classes work automatically with tibble and dplyr once coercion methods
are defined:

```r
# Tibble display uses pillar_shaft/type_sum
tibble::tibble(
  item = c("Widget", "Gadget"),
  price = currency(c(9.99, 24.50)),
  margin = percent(c(0.15, 0.22))
)
#> # A tibble: 2 x 3
#>   item     price margin
#>   <chr>     <ccy>  <pct>
#> 1 Widget    $9.99  15.0%
#> 2 Gadget   $24.50  22.0%

# dplyr verbs work with vec_ptype2/vec_cast defined
df |>
  dplyr::filter(margin > percent(0.10)) |>
  dplyr::mutate(discount = margin * 0.5)
```

For `summarise()`, you need `vec_ptype2` so vctrs can combine results.
For `filter()`/`arrange()`, implement `vec_proxy_compare()`:

```r
#' @export
vec_proxy_compare.my_percent <- function(x, ...) vec_data(x)
```

## Testing vctrs Classes

Test four areas: construction/validation, coercion, arithmetic, and display.
See [references/custom-class-template.md](references/custom-class-template.md)
for a complete test file.

```r
test_that("percent constructor validates", {
  expect_s3_class(percent(0.5), "my_percent")
  expect_error(percent(1.5), "between 0 and 1")
  expect_length(percent(), 0)
})

test_that("percent coercion works", {
  x <- percent(0.5)
  expect_equal(vec_cast(x, double()), 0.5)
  expect_s3_class(vec_cast(0.5, new_percent()), "my_percent")
})

test_that("percent arithmetic works", {
  x <- percent(0.3)
  y <- percent(0.2)
  expect_equal(vec_data(x + y), 0.5)
  expect_equal(vec_data(x * 2), 0.6)
  expect_error(x * y)  # percent * percent is not meaningful
})

test_that("percent formats correctly", {
  expect_equal(format(percent(0.156)), "15.6%")
  expect_equal(format(percent(NA_real_)), NA_character_)
})
```

## Common Pitfalls

1. **Forgetting `vec_data()`** -- Always use `vec_data(x)` to access the
   underlying data, not `unclass(x)` (which strips all attributes).

2. **Asymmetric `vec_ptype2`** -- If `vec_ptype2.A.B` is defined, you must
   also define `vec_ptype2.B.A`.

3. **Missing identity cast** -- Always define `vec_cast.myclass.myclass`.

4. **Forgetting NA handling** -- `format()` must handle NAs explicitly.

5. **Not registering pillar methods** -- Use `.onLoad` with `s3_register()`
   for pillar methods to avoid hard dependency.

6. **Attribute loss in operations** -- Attributes on the vctr (like `code`)
   must be preserved in arithmetic and cast methods.

## Package Setup Checklist

1. Add `vctrs` to `Imports` in DESCRIPTION
2. Add `pillar` to `Suggests` in DESCRIPTION
3. Add `@importFrom vctrs new_vctr vec_assert vec_cast vec_ptype2` to package docs
4. Create constructor: `new_mytype()`, `mytype()`, `is_mytype()`
5. Implement `format.mytype()`
6. Implement `vec_ptype2` pairs (symmetric!)
7. Implement `vec_cast` pairs
8. Implement `vec_arith` if arithmetic makes sense
9. Implement `vec_proxy_compare` if ordering makes sense
10. Register pillar methods in `.onLoad()`
11. Write tests for construction, coercion, arithmetic, display

## Related Skills

- **tidyverse-style** -- General tidyverse conventions and dplyr integration
- **lifecycle-management** -- Deprecating old type constructors
- **cli-package** -- Error messages in validators
- **testthat-patterns** -- Testing strategies for custom types

## Reference

- **[references/custom-class-template.md](references/custom-class-template.md)** —
  Complete copy-paste template for a new vctrs vector class.
- **[references/coercion-methods.md](references/coercion-methods.md)** —
  `vec_ptype2` and `vec_cast` double-dispatch implementation patterns.
- **[references/testing-vctrs.md](references/testing-vctrs.md)** —
  Testing type stability, coercion, casting, arithmetic, and display.
- **[references/type-stable-functions.md](references/type-stable-functions.md)** —
  `vec_cast()` at output, `vec_assert()` at input, base R alternatives.

## Resources

- [vctrs package documentation](https://vctrs.r-lib.org/)
- [S3 vectors vignette](https://vctrs.r-lib.org/articles/s3-vector.html)
- [Type and size stability](https://vctrs.r-lib.org/articles/stability.html)
- [vctrs theory](https://vctrs.r-lib.org/articles/theory.html)
