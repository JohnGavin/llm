# Coercion Method Implementations

Complete patterns for `vec_ptype2` and `vec_cast` double dispatch.

## Self-Coercion (Same Type → Same Type)

Always define the identity pair first:

```r
# ptype2: what type results from combining two percents?
vec_ptype2.pkg_percent.pkg_percent <- function(x, y, ...) {
  new_percent()
}

# cast: how to convert percent → percent?
vec_cast.pkg_percent.pkg_percent <- function(x, to, ...) {
  x  # identity — already the right type
}
```

## Coercion with Double

```r
# ptype2: percent + double = double (widen to double)
vec_ptype2.pkg_percent.double <- function(x, y, ...) double()
vec_ptype2.double.pkg_percent <- function(x, y, ...) double()

# cast: convert between percent and double
vec_cast.pkg_percent.double <- function(x, to, ...) {
  new_percent(x)
}
vec_cast.double.pkg_percent <- function(x, to, ...) {
  vec_data(x)
}
```

## Coercion with Integer (via Double)

```r
vec_ptype2.pkg_percent.integer <- function(x, y, ...) double()
vec_ptype2.integer.pkg_percent <- function(x, y, ...) double()

vec_cast.pkg_percent.integer <- function(x, to, ...) {
  new_percent(as.double(x))
}
```

## Blocking Invalid Coercion

```r
# Don't allow combining currency with character
vec_ptype2.my_currency.character <- function(x, y, ...) {
  stop_incompatible_type(x, y,
    details = "Can't combine currency with character"
  )
}
```

## Attribute-Aware Coercion

When your type has attributes (e.g., currency code), check compatibility:

```r
vec_ptype2.my_currency.my_currency <- function(x, y, ...) {
  if (currency_code(x) != currency_code(y)) {
    stop_incompatible_type(x, y,
      details = "Can't combine different currencies"
    )
  }
  new_currency(code = currency_code(x))
}
```

## Usage After Defining Methods

```r
pct <- percent(0.5)

# vec_c uses ptype2 + cast
vec_c(pct, pct)          # Returns percent
vec_c(pct, 0.3)          # Returns double (common type)

# Explicit cast
vec_cast(0.75, percent()) # double → percent
vec_cast(pct, double())   # percent → double (0.5)
```

## Key Rules

1. **Symmetry**: If `vec_ptype2.A.B` exists, `vec_ptype2.B.A` must too
2. **Identity cast**: Always define `vec_cast.A.A`
3. **Hierarchy**: Wider type wins (percent + double = double)
4. **`vec_data()`**: Always use to extract underlying data, never `unclass()`
