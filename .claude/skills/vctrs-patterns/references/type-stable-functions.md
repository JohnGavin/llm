# Type-Stable Functions with vctrs

Guarantee output types regardless of input values.

## The Problem: Type Instability

Base R functions change return types depending on input:

```r
# BAD: return type depends on data
sapply(list(1:3, 4:6), sum)     # integer vector
sapply(list(), sum)              # list (empty!)
sapply(list(1:3), sum)           # integer (length-1)

# ifelse strips attributes
ifelse(TRUE, Sys.Date(), Sys.Date())  # numeric, not Date!
```

## Solution: `vec_cast()` at Output

Force a guaranteed return type:

```r
# GOOD: output is always double, regardless of input
my_function <- function(x, y) {
  result <- x + y
  vec_cast(result, double())
}
```

## Solution: `vec_assert()` at Input

Validate inputs early to prevent type surprises downstream:

```r
safe_function <- function(x) {
  vec_assert(x, double())  # errors immediately if x isn't double
  x * 2
}

# With informative error
safe_function <- function(x, arg = rlang::caller_arg(x),
                          call = rlang::caller_env()) {
  tryCatch(
    vec_assert(x, double()),
    vctrs_error_assert_ptype = function(e) {
      cli::cli_abort(
        "{.arg {arg}} must be a double vector, not {.cls {class(x)}}.",
        call = call
      )
    }
  )
  x * 2
}
```

## Type-Safe Alternatives to Base R

| Base R (Unstable) | vctrs (Stable) | Guarantee |
|-------------------|----------------|-----------|
| `c(x, y)` | `vec_c(x, y)` | Common type rules |
| `rbind(df1, df2)` | `vec_rbind(df1, df2)` | Column type matching |
| `ifelse(cond, x, y)` | `dplyr::if_else(cond, x, y)` | Same type both arms |
| `sapply(x, f)` | `vapply(x, f, type)` or `map_dbl()` | Declared type |
| `x[0]` (may change class) | `vec_slice(x, 0L)` | Preserves class |

## Size Stability

```r
# Ensure consistent output size
vec_check_size(x, size = 1L)  # must be scalar

# Recycle to common size (like R's recycling but stricter)
args <- vec_recycle_common(rate, amount)
# Only allows: same size, or one is length 1
# Errors on partial recycling (e.g., length 2 + length 3)
```

## Complete Example: Type-Safe Pipeline Function

```r
#' @export
safe_ratio <- function(numerator, denominator) {
  vec_assert(numerator, double())
  vec_assert(denominator, double())
  args <- vec_recycle_common(numerator, denominator)

  result <- args[[1]] / args[[2]]
  result[is.infinite(result)] <- NA_real_

  vec_cast(result, double())  # guarantee return type
}
```
