# R Source File Rules

**Applies to**: `R/*.R` (excluding `R/dev/**`, `R/tar_plans/**`)

## Documentation (roxygen2)

1. **Every exported function MUST have**:
   - `@title` (or first line as title)
   - `@description` explaining what it does
   - `@param` for each parameter with type and purpose
   - `@return` describing the return value
   - `@export` for public functions
   - `@examples` with runnable code

2. **Example format**:
   ```r
   #' Analyze wave extremes
   #'
   #' Identifies extreme wave events from buoy measurements.
   #'
   #' @param data A data frame with columns `time`, `wave_height`, `station_id`.
   #' @param threshold Numeric. Height threshold in meters (default: 5.0).
   #' @param ... Additional arguments passed to internal functions.
   #'
   #' @return A tibble with extreme events, including:
   #'   - `time`: POSIXct timestamp
   #'   - `wave_height`: Numeric wave height in meters
   #'   - `exceedance`: Numeric amount above threshold
   #'
   #' @examples
   #' data <- tibble::tibble(
   #'   time = Sys.time() + 1:10,
   #'   wave_height = c(3, 4, 6, 2, 8, 5, 7, 3, 4, 5),
   #'   station_id = "M3"
   #' )
   #' analyze_wave_extremes(data, threshold = 5)
   #'
   #' @export
   ```

## Error Handling (cli/rlang)

**REQUIRED**: Use `cli::cli_abort()` for all errors.

```r
# WRONG - Do NOT use stop()
stop("Error: x must be numeric")

# CORRECT - Use cli with structured bullets
cli::cli_abort(c(
  "x" = "{.arg x} must be numeric",
  "i" = "You provided {.cls {class(x)}}",
  ">" = "Convert with {.code as.numeric(x)}"
))
```

**Error bullet types**:
- `"x"` = Error (what went wrong)
- `"i"` = Information (context)
- `">"` = Suggestion (how to fix)
- `"*"` = Bullet point

## Defensive Programming

### Input Validation (REQUIRED for exported functions)

```r
my_function <- function(data, n = 10, method = c("fast", "accurate")) {

  # 1. Check required args
.  rlang::check_required(data)

  # 2. Validate types
  if (!inherits(data, "data.frame")) {
    cli::cli_abort(c(
      "x" = "{.arg data} must be a data frame",
      "i" = "You provided {.cls {class(data)}}"
    ))
  }

  # 3. Validate numeric constraints
  if (!is.numeric(n) || length(n) != 1 || n < 1) {
    cli::cli_abort("{.arg n} must be a positive integer")
  }

  # 4. Match enum-style args
  method <- rlang::arg_match(method)

  # 5. Handle NULL with default
  n <- n %||% 10L

  # ... function body
}
```

### NULL/NA Handling

```r
# Explicit NULL handling
x <- x %||% default_value

# Check for NA
if (anyNA(x)) {
  cli::cli_abort("NA values not allowed in {.arg x}")
}

# Or handle gracefully
x <- x[!is.na(x)]
```

## Imports (Package Functions vs Scripts)

### In Package Functions (R/*.R)

**NEVER use `library()` or `require()` inside package functions.**

**Why**: These attach packages to the global search path, causing:
- Namespace conflicts with other packages
- Non-reproducible behavior depending on load order
- R CMD check warnings/errors

```r
# WRONG - Pollutes global namespace
my_function <- function(data) {
  library(dplyr)        # NO! Attaches dplyr globally
  require(tidyr)        # NO! Same problem
  filter(data, x > 0)
}

# CORRECT - Explicit namespace qualification
my_function <- function(data) {
  dplyr::filter(data, x > 0)  # Explicit, no side effects
}

# CORRECT - Import via roxygen2 (in NAMESPACE)
#' @importFrom dplyr filter mutate
my_function <- function(data) {
  filter(data, x > 0)  # Imported into package namespace
}
```

### In Scripts (R/dev/*.R, analysis scripts)

`library()` is fine in development scripts and analysis code - just not in package functions.

### Separate Rule: No install.packages() in Nix

This is a **Nix rule**, not a package rule:

```r
# FORBIDDEN IN NIX - Breaks immutability
install.packages("dplyr")     # NO!
devtools::install()           # NO!
pak::pkg_install()            # NO!

# To add packages: Edit DESCRIPTION → source("default.R") → re-enter Nix
```

### Summary

| Context | library/require | install.packages |
|---------|-----------------|------------------|
| Package functions (R/*.R) | ❌ FORBIDDEN | ❌ FORBIDDEN (Nix) |
| Dev scripts (R/dev/*.R) | ✅ OK | ❌ FORBIDDEN (Nix) |
| Interactive R session | ✅ OK | ❌ FORBIDDEN (Nix) |
| Outside Nix | ✅ OK | ✅ OK |

## Tidyverse Style

1. **Pipes**: Use native `|>` (not magrittr `%>%`)
2. **Names**: snake_case for functions and variables
3. **Line length**: Max 80 characters
4. **Spacing**: Space after commas, around operators
5. **Braces**: Opening brace on same line, closing on own line

```r
# Good
result <- data |>
  dplyr::filter(x > 0) |>
  dplyr::mutate(
    y = x * 2,
    z = y + 1
  ) |>
  dplyr::summarise(total = sum(z))

# Bad
result<-data%>%filter(x>0)%>%mutate(y=x*2,z=y+1)%>%summarise(total=sum(z))
```

## Return Values

1. **Be explicit**: Use `return()` for early returns only
2. **Document structure**: Describe complex return objects
3. **Prefer tibbles**: Return `tibble` over `data.frame`
4. **Invisible returns**: Use `invisible()` for side-effect functions

```r
#' @return A tibble with columns:
#'   \describe{
#'     \item{time}{POSIXct timestamp}
#'     \item{value}{Numeric measurement}
#'   }
```

## box Module Variant

If using `box::use()` instead of packages:

1. Every module MUST have `#' @export` for public functions
2. Use `box::use(pkg[func])` not `library(pkg)`
3. Prefer qualified access: `dplyr$filter()` for clarity
4. Test with `testthat::test_file()` not `devtools::test()`
