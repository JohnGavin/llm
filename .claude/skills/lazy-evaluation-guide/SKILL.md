# Lazy Evaluation in R - A Taxonomy

## Description

R uses the term "lazy" in multiple distinct ways, which can cause confusion. This skill clarifies the six different meanings of lazy evaluation in R and when each applies.

## Purpose

Use this skill when:
- Confused by "lazy" terminology in documentation
- Debugging unexpected evaluation timing
- Choosing between lazy vs. eager execution
- Working with futures, promises, or database packages
- Understanding package LazyData behavior

## The Six Meanings of "Lazy" in R

### 1. Language Lazy Evaluation (Core R)

Function arguments are only evaluated when accessed.

```r
# Arguments evaluated lazily
f <- function(x, y) {
  print("Starting function")
  x  # Only x is evaluated
  # y is never evaluated - no error even if y would fail
}

f(1 + 1, stop("This never runs"))
#> [1] "Starting function"
#> [1] 2

# How it works internally:
# - Each argument is a "promise" object
# - Promise contains: expression + environment + cached value
# - Expression evaluated only when value needed
# - Result cached for subsequent access
```

**When this matters:**
- Default arguments can reference other arguments
- Side effects in arguments may not execute
- Non-standard evaluation (NSE) captures expressions

### 2. Futures and Promises (Parallel Computing)

The `{future}` package uses "lazy" differently - to defer computation.

```r
library(future)
plan(multisession)

# EAGER (default): Computation starts immediately
f1 <- future({
  Sys.sleep(5)
  42
})
# Computation already running in background

# LAZY: Computation deferred until value() called
f2 <- future({
  Sys.sleep(5)
  42
}, lazy = TRUE)
# Nothing running yet!

value(f2)  # NOW computation starts
```

**Key distinction from language laziness:**
- Language: evaluates when accessed in R code
- Futures: `lazy = TRUE` means "don't start until explicit `value()` call"

### 3. Lazy Database Operations (dbplyr, dtplyr)

Database queries are built but not executed until materialization.

```r
library(dplyr)
library(dbplyr)

con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
copy_to(con, mtcars, "mtcars")

# Build query lazily - NO database hit yet
query <- tbl(con, "mtcars") |>
  filter(mpg > 20) |>
  select(mpg, cyl) |>
  arrange(desc(mpg))

# See the SQL (still no execution)
show_query(query)

# NOW execute - collect() materializes the result
result <- collect(query)
```

**duckplyr behavior:**

```r
library(duckplyr)

# duckplyr is "externally eager, internally lazy"
# Appears eager to user, but optimizes internally
df <- duckplyr::as_duckplyr_tibble(mtcars)
result <- df |> filter(mpg > 20)  # Returns immediately

# Control materialization behavior
options(duckplyr.prudence = "lavish")   # Materialize freely
options(duckplyr.prudence = "stingy")   # Avoid materialization
options(duckplyr.prudence = "thrifty")  # Balanced (default)

# Get fallback information
options(duckplyr.fallback_info = TRUE)  # Log when falling back to dplyr
```

### 4. LazyData in Packages

Package datasets loaded on demand, not at package load.

```r
# In DESCRIPTION:
# LazyData: true

# What this means:
library(mypackage)
# Package loads, but datasets NOT in memory yet

mypackage::my_dataset
# NOW the dataset is loaded from disk

# Check if data is lazy-loaded
data(package = "mypackage")  # Lists available datasets
pryr::object_size(my_dataset)  # Triggers load if lazy
```

**Benefits:**
- Faster package loading
- Lower memory usage until data needed
- Better for packages with large datasets

### 5. Frugal File Modifications (pkgdown, etc.)

"Lazy" meaning "only do work if necessary."

```r
# pkgdown only rebuilds changed pages
pkgdown::build_site()
# Checks: is source newer than destination?
# If not, skips rebuilding that page

# Similar pattern in targets
library(targets)
tar_make()
# Only runs targets whose dependencies changed
```

**This is "lazy" in the colloquial sense:** avoiding unnecessary work.

### 6. Lazy Quantifiers (Regular Expressions)

Regex "lazy" vs. "greedy" matching.
```r
text <- "aaaa"

# GREEDY (default): Match as much as possible
stringr::str_extract(text, "a+")
#> [1] "aaaa"

# LAZY (stingy): Match as little as possible
stringr::str_extract(text, "a+?")
#> [1] "a"

# Common lazy quantifiers:
# *?  - zero or more (lazy)
# +?  - one or more (lazy)
# ??  - zero or one (lazy)
# {n,}? - n or more (lazy)
```

## Decision Guide: Which "Lazy" Applies?

```
Question: What domain are you in?
│
├─ Core R programming?
│  └─ Meaning 1: Language lazy evaluation
│     (function arguments evaluated when accessed)
│
├─ Parallel/async computing?
│  └─ Meaning 2: Futures
│     (lazy = TRUE defers computation until value())
│
├─ Database/data frame queries?
│  └─ Meaning 3: Lazy database ops
│     (queries built but not executed until collect())
│
├─ Package development?
│  └─ Meaning 4: LazyData
│     (datasets loaded on demand)
│
├─ Build systems/caching?
│  └─ Meaning 5: Frugal rebuilds
│     (skip unnecessary work)
│
└─ Text processing/regex?
   └─ Meaning 6: Lazy quantifiers
      (minimal matching with +?, *?, etc.)
```

## Common Pitfalls

### Confusing Future Laziness with Language Laziness

```r
# Language lazy: expression captured, evaluated when needed
f <- function(x) {
  Sys.sleep(1)
  x  # Evaluates the promise for x
}

# Future lazy: computation explicitly deferred
library(future)
fut <- future({ Sys.sleep(1); 42 }, lazy = TRUE)
# Not started! Must call value(fut) to begin
```

### Unexpected Database Evaluation

```r
# ❌ Accidentally materializing multiple times
library(dplyr)
query <- tbl(con, "big_table") |> filter(...)

nrow(query)       # Hits database
head(query)       # Hits database AGAIN
collect(query)    # Hits database THIRD time

# ✅ Materialize once
result <- collect(query)
nrow(result)      # Uses cached data
head(result)      # Uses cached data
```

### LazyData Not Loading

```r
# If LazyData: true but data not accessible:

# Check it's exported in NAMESPACE
# Should have: export(my_dataset)
# Or use data() explicitly:
data("my_dataset", package = "mypackage")
```

## Best Practices

1. **Be explicit about timing**: When using futures, document whether `lazy = TRUE`
2. **Materialize strategically**: With dbplyr, `collect()` once and reuse
3. **Document laziness**: In function docs, clarify when arguments are evaluated
4. **Use duckplyr prudence**: Set `options(duckplyr.fallback_info = TRUE)` for debugging
5. **Test lazy regex**: Use `str_extract_all()` to verify greedy vs. lazy behavior

## Memory Implications

```r
# Lazy loading saves memory until needed
library(nycflights13)
# flights dataset NOT in memory yet

object.size(flights)  # Triggers load, now in memory
# [1] 38.7 MB

# For large datasets, consider:
# - LazyData: true in packages
# - Arrow/DuckDB for larger-than-memory
# - Explicit rm() after use
```

## Resources

- [R-hub Blog: The Many Meanings of Lazy](https://blog.r-hub.io/2025/02/13/lazy-meanings/)
- [Advanced R: Lazy Evaluation](https://adv-r.hadley.nz/functions.html#lazy-evaluation)
- [dbplyr: Lazy Queries](https://dbplyr.tidyverse.org/articles/dbplyr.html)
- [future Package](https://future.futureverse.org/)
- [duckplyr Prudence](https://duckdblabs.github.io/duckplyr/)

## Related Skills

- parallel-processing (futures, mirai)
- data-wrangling-duckdb (lazy database queries)
- r-package-workflow (LazyData in packages)
