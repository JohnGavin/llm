# dplyr 1.1+ Migration Guide

Detailed before/after examples for migrating from legacy dplyr idioms to dplyr 1.1+ patterns.

## 1. `group_by()` + `ungroup()` to `.by`

### Simple grouped summarise

```r
# BEFORE
mtcars |>
  group_by(cyl) |>
  summarise(
    avg_mpg = mean(mpg),
    avg_hp = mean(hp)
  ) |>
  ungroup()

# AFTER
mtcars |>
  summarise(
    avg_mpg = mean(mpg),
    avg_hp = mean(hp),
    .by = cyl
  )
```

### Multi-column grouping

```r
# BEFORE: emits "grouped output by 'cyl'" message
mtcars |>
  group_by(cyl, vs) |>
  summarise(avg_mpg = mean(mpg))
#> `summarise()` has grouped output by 'cyl'. You can override using
#> the `.groups` argument.

# AFTER: no message, no residual grouping
mtcars |>
  summarise(avg_mpg = mean(mpg), .by = c(cyl, vs))
```

### Grouped mutate (window functions)

```r
# BEFORE
mtcars |>
  group_by(cyl) |>
  mutate(
    mpg_rank = rank(mpg),
    pct_of_group = mpg / sum(mpg)
  ) |>
  ungroup()

# AFTER
mtcars |>
  mutate(
    mpg_rank = rank(mpg),
    pct_of_group = mpg / sum(mpg),
    .by = cyl
  )
```

### Grouped filter

```r
# BEFORE
mtcars |>
  group_by(cyl) |>
  filter(mpg == max(mpg)) |>
  ungroup()

# AFTER
mtcars |>
  filter(mpg == max(mpg), .by = cyl)
```

### Grouped slice

```r
# BEFORE
mtcars |>
  group_by(cyl) |>
  slice_max(mpg, n = 2) |>
  ungroup()

# AFTER (note: argument is `by`, not `.by`, for slice variants)
mtcars |>
  slice_max(mpg, n = 2, by = cyl)

# Slice with multiple grouping columns
mtcars |>
  slice_min(mpg, n = 1, by = c(cyl, vs))
```

### Using character vector of group columns

```r
# BEFORE
group_vars <- c("cyl", "vs")
mtcars |>
  group_by(across(all_of(group_vars))) |>
  summarise(avg_mpg = mean(mpg)) |>
  ungroup()

# AFTER
group_vars <- c("cyl", "vs")
mtcars |>
  summarise(avg_mpg = mean(mpg), .by = all_of(group_vars))
```

### Row ordering difference

```r
df <- tibble(
  month = c("mar", "jan", "feb", "jan", "mar", "feb"),
  value = c(10, 20, 30, 40, 50, 60)
)

# group_by() sorts keys ascending
df |>
  group_by(month) |>
  summarise(total = sum(value))
#> feb = 90, jan = 60, mar = 60  (alphabetical)

# .by preserves first-appearance order
df |>
  summarise(total = sum(value), .by = month)
#> mar = 60, jan = 60, feb = 90  (data order)
```

## 2. `across()` without `.fns` to `pick()`

### Selecting columns inside mutate

```r
# BEFORE (deprecated: across() with no .fns)
df |>
  mutate(row_sum = rowSums(across(c(x, y, z))))

# AFTER
df |>
  mutate(row_sum = rowSums(pick(x, y, z)))
```

### Joint ranking

```r
# BEFORE
df |>
  mutate(rank = dense_rank(across(c(x, y))))

# AFTER
df |>
  mutate(rank = dense_rank(pick(x, y)))
```

### Replacing `cur_data()` and `cur_data_all()`

```r
# BEFORE (soft-deprecated)
df |>
  mutate(n_cols = ncol(cur_data()))

df |>
  group_by(g) |>
  mutate(n_cols = ncol(cur_data_all()))

# AFTER
df |>
  mutate(n_cols = ncol(pick(everything())))
```

### Bridge pattern: tidy-select inside data-masking

```r
# Using pick() to bridge data-masking and tidy-select
my_count <- function(data, ...) {
  data |>
    count(pick(...))
}

df |> my_count(starts_with("z"))

# Wrapper with embracing
my_group_summary <- function(data, group_cols, value_col) {
  data |>
    summarise(
      mean_val = mean({{ value_col }}, na.rm = TRUE),
      .by = {{ group_cols }}
    )
}

df |> my_group_summary(c(region, year), revenue)
```

## 3. Multi-Row `summarise()` to `reframe()`

### Quantile computation

```r
# BEFORE (warns in dplyr 1.1+)
mtcars |>
  group_by(cyl) |>
  summarise(
    q = quantile(mpg, c(0.25, 0.5, 0.75)),
    prob = c(0.25, 0.5, 0.75)
  )
#> Warning: Returning more (or fewer) than 1 row per `summarise()` group
#> was deprecated in dplyr 1.1.0.

# AFTER
mtcars |>
  reframe(
    q = quantile(mpg, c(0.25, 0.5, 0.75)),
    prob = c(0.25, 0.5, 0.75),
    .by = cyl
  )
```

### Helper function returning a tibble

```r
quantile_df <- function(x, probs = c(0.25, 0.5, 0.75)) {
  tibble(
    value = quantile(x, probs, na.rm = TRUE),
    quantile = probs
  )
}

# BEFORE
mtcars |>
  group_by(cyl) |>
  summarise(quantile_df(mpg))  # warns

# AFTER
mtcars |>
  reframe(quantile_df(mpg), .by = cyl)
```

### Set operations per group

```r
allowed_items <- c("a", "b", "d", "f")

df <- tibble(
  group = c(1, 1, 1, 2, 2, 2),
  item = c("a", "b", "c", "d", "e", "f")
)

# Items from each group that are in the allowed set
df |>
  reframe(
    item = intersect(item, allowed_items),
    .by = group
  )
```

### Multiple columns with `across()` + `.unpack`

```r
starwars |>
  reframe(
    across(c(height, mass), quantile_df, .unpack = TRUE),
    .by = species
  )
```

## 4. Character Vector `by` to `join_by()`

### Simple equality join

```r
orders <- tibble(order_id = 1:3, cust_id = c(10, 20, 10))
customers <- tibble(id = c(10, 20), name = c("Alice", "Bob"))

# BEFORE
left_join(orders, customers, by = c("cust_id" = "id"))

# AFTER
left_join(orders, customers, by = join_by(cust_id == id))
```

### Same-name columns

```r
# BEFORE
inner_join(df1, df2, by = "id")

# AFTER
inner_join(df1, df2, by = join_by(id))

# Multiple equality conditions
inner_join(df1, df2, by = join_by(id, year))
```

### Inequality joins (NEW - no legacy equivalent)

```r
sales <- tibble(
  sale_id = 1:3,
  sale_date = as.Date(c("2024-03-01", "2024-03-15", "2024-04-01")),
  amount = c(100, 200, 150)
)
promos <- tibble(
  promo_id = 1:2,
  start_date = as.Date(c("2024-02-15", "2024-03-10")),
  end_date = as.Date(c("2024-03-10", "2024-03-31")),
  discount = c(0.1, 0.2)
)

# All promos active on or before each sale
left_join(
  sales, promos,
  by = join_by(sale_date >= start_date)
)
```

### Rolling joins with `closest()` (NEW)

```r
# Find the most recent promo that started before each sale
left_join(
  sales, promos,
  by = join_by(closest(sale_date >= start_date))
)
```

### Overlap joins with helpers (NEW)

```r
# between(): point falls within [lower, upper]
inner_join(
  sales, promos,
  by = join_by(between(sale_date, start_date, end_date))
)

# within(): [x_lower, x_upper] falls entirely inside [y_lower, y_upper]
inner_join(
  periods_a, periods_b,
  by = join_by(within(start_a, end_a, start_b, end_b))
)

# overlaps(): [x_lower, x_upper] overlaps with [y_lower, y_upper]
inner_join(
  periods_a, periods_b,
  by = join_by(overlaps(start_a, end_a, start_b, end_b))
)
```

### Quality control arguments (NEW)

```r
# BEFORE: no built-in way to detect unexpected multiple matches
left_join(orders, customers, by = c("cust_id" = "id"))
# Silently returns multiple rows if customer has duplicates

# AFTER: explicit control
left_join(
  orders, customers,
  by = join_by(cust_id == id),
  multiple = "error",    # Fail if multiple matches found
  unmatched = "error"    # Fail if any order has no customer
)

# For inequality joins, multiple = "all" is the default (expected)
left_join(
  sales, promos,
  by = join_by(sale_date >= start_date),
  multiple = "all"  # default for inequality joins
)
```

## 5. Manual Run-Length Encoding to `consecutive_id()`

### Basic run identification

```r
df <- tibble(
  time = 1:8,
  status = c("up", "up", "down", "down", "down", "up", "up", "up")
)

# BEFORE: manual cumsum + lag trick
df |>
  mutate(run_id = cumsum(status != lag(status, default = first(status))) + 1L)

# AFTER
df |>
  mutate(run_id = consecutive_id(status))
```

### Summarise contiguous runs

```r
# Duration and properties of each contiguous run
df |>
  summarise(
    status = first(status),
    start_time = min(time),
    end_time = max(time),
    duration = n(),
    .by = consecutive_id(status)
  )
```

### Multi-column consecutive ID

```r
df <- tibble(
  sensor = c("A", "A", "B", "B", "A", "A"),
  quality = c("good", "good", "good", "bad", "bad", "good")
)

# Increments when ANY column changes
df |>
  mutate(run = consecutive_id(sensor, quality))
#>   sensor quality   run
#>   A      good        1
#>   A      good        1
#>   B      good        2
#>   B      bad         3
#>   A      bad         4
#>   A      good        5
```

### Real-world example: session detection

```r
# Identify user sessions (gap > 30 minutes = new session)
activity_log <- tibble(
  user_id = c(1, 1, 1, 1, 2, 2),
  timestamp = as.POSIXct(c(
    "2024-01-15 10:00", "2024-01-15 10:05", "2024-01-15 14:00",
    "2024-01-15 14:03", "2024-01-15 09:00", "2024-01-15 09:10"
  ))
)

activity_log |>
  arrange(user_id, timestamp) |>
  mutate(
    gap_minutes = as.numeric(
      difftime(timestamp, lag(timestamp), units = "mins"),
    ),
    new_session = is.na(gap_minutes) |
      gap_minutes > 30 |
      user_id != lag(user_id),
    session_id = consecutive_id(user_id, cumsum(new_session)),
    .by = user_id
  )
```

## 6. Complete Migration Reference Table

| Old Pattern | New Pattern | Notes |
|---|---|---|
| `group_by(g) \|> summarise(...)  \|> ungroup()` | `summarise(..., .by = g)` | Always ungrouped result |
| `group_by(g) \|> mutate(...) \|> ungroup()` | `mutate(..., .by = g)` | Always ungrouped result |
| `group_by(g) \|> filter(...) \|> ungroup()` | `filter(..., .by = g)` | Always ungrouped result |
| `group_by(g) \|> slice_max(x) \|> ungroup()` | `slice_max(x, by = g)` | Note: `by` not `.by` |
| `group_by(g) \|> slice_min(x) \|> ungroup()` | `slice_min(x, by = g)` | Note: `by` not `.by` |
| `group_by(g) \|> slice_head(n = 1) \|> ungroup()` | `slice_head(n = 1, by = g)` | Note: `by` not `.by` |
| `group_by(g) \|> slice_sample(n = 1) \|> ungroup()` | `slice_sample(n = 1, by = g)` | Note: `by` not `.by` |
| `group_by(across(all_of(cols))) \|> summarise(...)` | `summarise(..., .by = all_of(cols))` | Character vector of names |
| `across(c(x, y))` (no `.fns`) | `pick(x, y)` | Returns data frame |
| `across(everything())` (no `.fns`) | `pick(everything())` | Returns data frame |
| `cur_data()` | `pick(everything())` | Soft-deprecated |
| `cur_data_all()` | `pick(everything())` | Soft-deprecated |
| `summarise()` returning >1 row | `reframe()` | Always ungrouped |
| `do(fn(.))` | `reframe(fn(pick(everything())))` | `do()` long deprecated |
| `left_join(x, y, by = "id")` | `left_join(x, y, by = join_by(id))` | Same-name columns |
| `left_join(x, y, by = c("a" = "b"))` | `left_join(x, y, by = join_by(a == b))` | Different-name columns |
| Manual cross-join + filter for inequality | `left_join(x, y, by = join_by(a >= b))` | Native inequality join |
| Manual closest-match logic | `left_join(x, y, by = join_by(closest(a >= b)))` | Native rolling join |
| Manual interval overlap detection | `inner_join(x, y, by = join_by(overlaps(...)))` | Native overlap join |
| `cumsum(x != lag(x, default = first(x)))` | `consecutive_id(x)` | Run-length ID |
| `data.table::rleid(x)` | `consecutive_id(x)` | dplyr equivalent |
| No equivalent | `multiple = "error"` in joins | Quality control |
| No equivalent | `unmatched = "error"` in joins | Quality control |

## 7. Package Code Migration

When migrating package code, remember to update roxygen and DESCRIPTION:

### DESCRIPTION

```
Imports:
    dplyr (>= 1.1.0)
```

### Roxygen

```r
#' Process data with modern dplyr
#'
#' @param data A data frame
#' @param group_col Column to group by (tidy-select)
#' @importFrom dplyr summarise n
#' @export
process <- function(data, group_col) {
  data |>
    dplyr::summarise(
      count = dplyr::n(),
      .by = {{ group_col }}
    )
}
```

### Conditional use for backward compatibility

If your package must support dplyr < 1.1.0, you can use runtime checks:

```r
has_by_arg <- packageVersion("dplyr") >= "1.1.0"

if (has_by_arg) {
  df |> summarise(n = n(), .by = group)
} else {
  df |> group_by(group) |> summarise(n = n()) |> ungroup()
}
```

However, this is rarely needed. Prefer setting `dplyr (>= 1.1.0)` in DESCRIPTION and using modern syntax throughout.
