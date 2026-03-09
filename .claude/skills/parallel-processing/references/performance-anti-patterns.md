# Performance Anti-Patterns

Common mistakes that silently destroy R performance.

## 1. Growing Objects in Loops

```r
# BAD: O(n²) — copies entire vector on each iteration
result <- c()
for (i in seq_len(n)) {
  result <- c(result, compute(i))
}

# GOOD: Pre-allocate
result <- vector("list", n)
for (i in seq_len(n)) {
  result[[i]] <- compute(i)
}

# BETTER: Use purrr
result <- purrr::map(seq_len(n), compute)
```

## 2. Optimizing Without Measuring

```r
# BAD: "I think this is slow, let me rewrite it"
# GOOD: Profile first, optimize only what profvis shows
profvis::profvis({ my_pipeline() })
```

## 3. Type-Unstable Functions

```r
# BAD: sapply — return type depends on input
sapply(x, f)        # list? matrix? vector? who knows

# GOOD: vapply or purrr — guaranteed return type
vapply(x, f, double(1))
purrr::map_dbl(x, f)
```

## 4. Unnecessary Copies

```r
# BAD: subsetting creates a copy each time
for (grp in groups) {
  subset_data <- data[data$group == grp, ]
  process(subset_data)
}

# GOOD: split once, iterate
split_data <- split(data, data$group)
purrr::walk(split_data, process)

# BEST: use grouped operations (no splitting needed)
data |> dplyr::group_by(group) |> dplyr::group_walk(~ process(.x))
```

## 5. Row-Wise Operations on Data Frames

```r
# BAD: rowwise is almost always wrong
data |>
  dplyr::rowwise() |>
  dplyr::mutate(result = complex_fn(a, b, c))

# GOOD: vectorize the function
data |> dplyr::mutate(result = complex_fn(a, b, c))

# If truly row-wise, use pmap
data |> dplyr::mutate(result = purrr::pmap_dbl(
  list(a, b, c), complex_fn
))
```

## 6. Parallelizing Cheap Operations

```r
# BAD: overhead > computation
mirai::mirai_map(1:1000, \(x) x^2)  # microseconds per item

# GOOD: only parallelize expensive work (>100ms per item)
mirai::mirai_map(models, \(m) fit_model(m, data))
```

## 7. Ignoring Vectorization

```r
# BAD: loop over elements
result <- numeric(length(x))
for (i in seq_along(x)) {
  result[i] <- if (x[i] > 0) log(x[i]) else NA_real_
}

# GOOD: vectorized
result <- dplyr::if_else(x > 0, log(x), NA_real_)
```

## 8. Reading Data Repeatedly

```r
# BAD: read inside a function called many times
process <- function(id) {
  data <- readr::read_csv("big.csv")  # reads EVERY call
  data |> dplyr::filter(id == .env$id)
}

# GOOD: read once, pass as argument
data <- readr::read_csv("big.csv")
purrr::map(ids, \(id) data |> dplyr::filter(id == .env$id))
```
