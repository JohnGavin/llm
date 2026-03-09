# dplyr 1.1+ Modern Patterns

## Description

Guide to dplyr 1.1+ features that replace older idioms: per-operation grouping with `.by`, `pick()` for tidy-select in data-masking contexts, `reframe()` for multi-row summaries, `join_by()` for flexible joins, and `consecutive_id()` for run-length grouping.

## Purpose

Use this skill when:
- Writing new dplyr code (prefer 1.1+ idioms by default)
- Modernising legacy dplyr pipelines
- Reviewing code for outdated `group_by()` + `ungroup()` patterns
- Implementing inequality, rolling, or overlap joins
- Needing multi-row summaries per group

## Requirements

```
Imports:
    dplyr (>= 1.1.0)
```

Always verify: `packageVersion("dplyr") >= "1.1.0"`.

## 1. Per-Operation Grouping with `.by`

`.by` replaces the `group_by()` + verb + `ungroup()` pattern for single operations. The result is always ungrouped, so you never need `ungroup()` and never get the peeling-off message.

### Before (dplyr < 1.1)

```r
# Three verbs for one grouped operation
df |>
  group_by(region) |>
  summarise(avg_cost = mean(cost)) |>
  ungroup()

# Multi-column grouping emits a message about .groups
df |>
  group_by(id, region) |>
  summarise(avg_cost = mean(cost))
#> `summarise()` has grouped output by 'id'. You can override using
#> the `.groups` argument.
```

### After (dplyr 1.1+)

```r
# One verb, inline grouping, always ungrouped result
df |>
  summarise(avg_cost = mean(cost), .by = region)

# Multi-column: use c(), no message, no residual grouping
df |>
  summarise(avg_cost = mean(cost), .by = c(id, region))
```

### Supported verbs

| Verb | Argument |
|------|----------|
| `mutate()` | `.by` |
| `summarise()` | `.by` |
| `reframe()` | `.by` |
| `filter()` | `.by` |
| `slice()` | `.by` |
| `slice_head()`, `slice_tail()` | `by` |
| `slice_min()`, `slice_max()` | `by` |
| `slice_sample()` | `by` |

### Key differences from `group_by()`

| `.by` | `group_by()` |
|:------|:-------------|
| Affects single verb only | Persists across multiple verbs |
| Uses tidy-select (`c()`, `starts_with()`) | Uses data-masking (expressions) |
| Preserves original row order of group keys | Sorts group keys ascending |
| Result is always ungrouped | Result may retain grouping layers |

### Practical examples

```r
# Grouped mutate: window function per group
df |>
  mutate(
    pct_of_group = cost / sum(cost),
    .by = region
  )

# Grouped filter: keep groups meeting a condition
df |>
  filter(n() >= 3, .by = region)

# Grouped slice: top 2 per group
df |>
  slice_max(cost, n = 2, by = region)

# Character vector of column names
group_cols <- c("id", "region")
df |>
  summarise(total = sum(cost), .by = all_of(group_cols))
```

## 2. `pick()` for Tidy-Select in Data-Masking

`pick()` lets you use tidy-select syntax inside data-masking verbs like `mutate()` and `summarise()`. It returns a data frame of the selected columns for the current group.

### Replaces

- `across(.fns = NULL)` or `across(c(x, y))` with no function
- `cur_data()` (soft-deprecated)
- `cur_data_all()` (soft-deprecated)

### Examples

```r
df <- tibble(
  x = c(3, 2, 2, 1),
  y = c(0, 2, 1, 4),
  z = c("a", "a", "b", "a")
)

# Joint ranking across multiple columns
df |>
  mutate(rank = dense_rank(pick(x, y)))

# Pass selected columns to a function expecting a data frame
df |>
  summarise(
    cor = cor(pick(x, y))[1, 2],
    .by = z
  )

# Bridge between data-masking and tidy-select
# Useful when writing wrapper functions
my_group_by <- function(data, cols) {
  group_by(data, pick({{ cols }}))
}

df |> my_group_by(c(x, starts_with("z")))

# Dynamic column selection in count()
df |> count(pick(starts_with("z")))
```

### When to use `pick()` vs `across()`

| Goal | Use |
|------|-----|
| Select columns, pass as data frame | `pick(x, y)` |
| Apply a function to each column | `across(c(x, y), mean)` |
| Apply a function to selected columns as a group | `pick(x, y)` + function |

## 3. `reframe()` for Multi-Row Summaries

`reframe()` allows functions that return any number of rows per group. `summarise()` expects exactly one row per group (and warns if you return more).

### Before (dplyr < 1.1)

```r
# This triggers a deprecation warning in dplyr 1.1+
df |>
  group_by(species) |>
  summarise(
    quantile = quantile(height, c(0.25, 0.5, 0.75)),
    prob = c(0.25, 0.5, 0.75)
  )
#> Warning: Returning more (or fewer) than 1 row per `summarise()` group
#> was deprecated in dplyr 1.1.0.
#> i Please use `reframe()` instead.
```

### After (dplyr 1.1+)

```r
# reframe() is designed for multi-row results
df |>
  reframe(
    quantile = quantile(height, c(0.25, 0.5, 0.75)),
    prob = c(0.25, 0.5, 0.75),
    .by = species
  )

# Helper function returning a data frame
quantile_df <- function(x, probs = c(0.25, 0.5, 0.75)) {
  tibble(
    val = quantile(x, probs, na.rm = TRUE),
    quant = probs
  )
}

starwars |>
  reframe(quantile_df(height), .by = homeworld)

# Combine with across() for multiple columns
starwars |>
  reframe(
    across(c(height, mass), quantile_df, .unpack = TRUE),
    .by = homeworld
  )
```

### `summarise()` vs `reframe()`

| | `summarise()` | `reframe()` |
|---|---|---|
| Rows per group | Exactly 1 | Any number |
| Output grouping | May retain groups | Always ungrouped |
| Use case | Aggregation (mean, sum, n) | Quantiles, intersections, expansions |
| Supports `.by` | Yes | Yes |

**Rule of thumb:** If your function returns a single scalar, use `summarise()`. If it returns multiple rows, use `reframe()`.

## 4. `join_by()` for Flexible Joins

`join_by()` replaces character vector `by` specifications with an expressive syntax supporting equality, inequality, rolling, and overlap joins.

### Equality joins

```r
# Before
left_join(orders, customers, by = c("cust_id" = "id"))

# After: more readable
left_join(orders, customers, by = join_by(cust_id == id))
```

### Inequality joins

Find all commercials that aired before each sale:

```r
sales <- tibble(
  sale_id = 1:3,
  sale_date = as.Date(c("2024-03-01", "2024-03-15", "2024-04-01"))
)
commercials <- tibble(
  ad_id = 1:4,
  air_date = as.Date(c("2024-02-15", "2024-03-01", "2024-03-10", "2024-03-20"))
)

# All commercials aired on or before each sale
left_join(
  sales, commercials,
  by = join_by(sale_date >= air_date)
)
```

### Rolling joins with `closest()`

Find only the most recent match:

```r
# Most recent commercial before each sale
left_join(
  sales, commercials,
  by = join_by(closest(sale_date >= air_date))
)
```

### Overlap joins

Three helpers: `between()`, `within()`, `overlaps()`.

```r
# between(): point falls within [lower, upper]
inner_join(sales, promos,
  by = join_by(between(sale_date, start_date, end_date)))

# overlaps(): two intervals share any overlap
inner_join(events, windows,
  by = join_by(overlaps(start, end, win_start, win_end)))

# within(): first interval entirely inside second
inner_join(periods_a, periods_b,
  by = join_by(within(start_a, end_a, start_b, end_b)))
```

### Quality control arguments

```r
left_join(
  orders, customers,
  by = join_by(cust_id == id),
  # Warn if a row in x matches multiple rows in y
  multiple = "warning",
  # Error if a row in x has no match (would be dropped)
  unmatched = "error"
)
```

| Argument | Values | Purpose |
|----------|--------|---------|
| `multiple` | `"all"`, `"any"`, `"first"`, `"last"`, `"warning"`, `"error"` | Control multiple matches |
| `unmatched` | `"drop"`, `"error"` | Control unmatched rows |
| `keep` | `NULL`, `TRUE`, `FALSE` | Keep join columns from both sides |

## 5. `consecutive_id()` for Run-Length Grouping

`consecutive_id()` generates a unique identifier that increments each time values change. Inspired by `data.table::rleid()`.

### Example: grouping contiguous runs

```r
df <- tibble(
  time = 1:10,
  state = c("A", "A", "A", "B", "B", "A", "A", "C", "C", "C")
)

df |>
  mutate(run_id = consecutive_id(state))
#> # A tibble: 10 x 3
#>     time state run_id
#>    <int> <chr>  <dbl>
#>  1     1 A          1
#>  2     2 A          1
#>  3     3 A          1
#>  4     4 B          2
#>  5     5 B          2
#>  6     6 A          3
#>  7     7 A          3
#>  8     8 C          4
#>  9     9 C          4
#> 10    10 C          4
```

### Practical use: summarise contiguous runs

```r
# Duration of each contiguous state
df |>
  summarise(
    state = first(state),
    start = min(time),
    end = max(time),
    duration = n(),
    .by = consecutive_id(state)
  )
#> # A tibble: 4 x 5
#>   state start   end duration `consecutive_id(state)`
#>   <chr> <int> <int>    <int>                   <dbl>
#> 1 A         1     3        3                       1
#> 2 B         4     5        2                       2
#> 3 A         6     7        2                       3
#> 4 C         8    10        3                       4

# Multi-column: changes when ANY column changes
df2 <- tibble(
  x = c(1, 1, 2, 2, 1, 1),
  y = c("a", "a", "a", "b", "b", "b")
)
df2 |>
  mutate(run = consecutive_id(x, y))
#> # A tibble: 6 x 3
#>       x y       run
#>   <dbl> <chr> <dbl>
#> 1     1 a         1
#> 2     1 a         1
#> 3     2 a         2
#> 4     2 b         3
#> 5     1 b         4
#> 6     1 b         4
```

## 6. Quick Migration Table

| Old idiom | New idiom (dplyr 1.1+) |
|---|---|
| `group_by(g) \|> summarise(x = mean(y)) \|> ungroup()` | `summarise(x = mean(y), .by = g)` |
| `group_by(g) \|> mutate(x = sum(y)) \|> ungroup()` | `mutate(x = sum(y), .by = g)` |
| `group_by(g) \|> filter(n() > 1) \|> ungroup()` | `filter(n() > 1, .by = g)` |
| `group_by(g) \|> slice_max(x, n = 1) \|> ungroup()` | `slice_max(x, n = 1, by = g)` |
| `across(c(x, y))` (no `.fns`) | `pick(x, y)` |
| `cur_data()` | `pick(everything())` |
| `cur_data_all()` | `pick(everything())` |
| `summarise()` returning >1 row per group | `reframe()` |
| `by = c("a" = "b")` in joins | `by = join_by(a == b)` |
| Manual inequality join workarounds | `join_by(x >= y)` |
| `data.table::rleid()` | `consecutive_id()` |

See [migration-guide.md](references/migration-guide.md) for detailed before/after examples.

## 7. When to Still Use `group_by()`

`.by` is not always the right choice. Prefer `group_by()` when:

### Multiple operations on the same groups

```r
# group_by() avoids repeating .by in every verb
df |>
  group_by(region) |>
  mutate(pct = cost / sum(cost)) |>
  filter(pct > 0.1) |>
  summarise(
    n = n(),
    total = sum(cost)
  ) |>
  ungroup()

# With .by you would repeat the grouping 3 times -- worse
```

### Computed grouping expressions

```r
# group_by() uses data-masking: can compute new groups inline
df |>
  group_by(decade = 10 * (year %/% 10)) |>
  summarise(avg = mean(value))

# .by uses tidy-select: cannot compute expressions
# You must mutate first
df |>
  mutate(decade = 10 * (year %/% 10)) |>
  summarise(avg = mean(value), .by = decade)
```

### When you need sorted group keys

```r
# group_by() sorts keys ascending by default
df |>
  group_by(month) |>
  summarise(avg = mean(temp))
# Months sorted alphabetically: apr, aug, dec, ...

# .by preserves first-appearance order
df |>
  summarise(avg = mean(temp), .by = month)
# Months in data order: jan, feb, mar, ...

# If you need sorting with .by, add explicit arrange()
df |>
  summarise(avg = mean(temp), .by = month) |>
  arrange(month)
```

### Decision guide

| Scenario | Use |
|----------|-----|
| Single grouped operation | `.by` |
| Multiple verbs, same groups | `group_by()` |
| Need computed grouping expression | `group_by()` (or `mutate()` then `.by`) |
| Need sorted keys | `group_by()` or `.by` + `arrange()` |
| Writing package code (clarity) | `.by` (explicit, no hidden state) |

## Package Code Patterns

In package code, always namespace-qualify and use `.data` or `{{ }}`:

```r
#' Summarise by group using .by
#' @param data A data frame
#' @param group_col Column to group by (unquoted)
#' @param value_col Column to summarise (unquoted)
#' @importFrom dplyr summarise
#' @importFrom rlang .data
#' @export
summarise_by <- function(data, group_col, value_col) {
  data |>
    dplyr::summarise(
      mean = mean({{ value_col }}, na.rm = TRUE),
      n = dplyr::n(),
      .by = {{ group_col }}
    )
}
```

## Review Checklist

- [ ] Uses `.by` for single grouped operations (not `group_by()` + `ungroup()`)
- [ ] Uses `pick()` instead of `across()` with no `.fns` or `cur_data()`
- [ ] Uses `reframe()` for multi-row summaries (not `summarise()` with >1 row warning)
- [ ] Uses `join_by()` syntax for joins (not character vector `by`)
- [ ] Uses `consecutive_id()` for run-length grouping (not manual `cumsum(x != lag(x))`)
- [ ] `group_by()` retained only where justified (multi-verb, computed groups)
- [ ] Explicit `multiple` and `unmatched` arguments in production join code

## Related Skills

- **tidyverse-style**: General tidyverse conventions and package tiers
- **missing-data-handling**: NA handling in grouped operations
- **adversarial-qa**: Edge cases for grouping and join patterns

## References

- [dplyr 1.1.0 blog post](https://www.tidyverse.org/blog/2023/02/dplyr-1-1-0-per-operation-grouping/)
- [Per-operation grouping vignette](https://dplyr.tidyverse.org/reference/dplyr_by.html)
- [join_by() documentation](https://dplyr.tidyverse.org/reference/join_by.html)
- [reframe() documentation](https://dplyr.tidyverse.org/reference/reframe.html)
- [pick() documentation](https://dplyr.tidyverse.org/reference/pick.html)
- [consecutive_id() documentation](https://dplyr.tidyverse.org/reference/consecutive_id.html)
