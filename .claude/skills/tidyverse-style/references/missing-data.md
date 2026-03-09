# Missing Data Handling

Detailed patterns for handling missing data in tidyverse workflows.

## NA String Recognition

Always specify NA strings explicitly when reading external data:

```r
# GOOD: Explicit NA strings
df <- readr::read_csv(
  "data.csv",
  na = c("", "NA", "N/A", "n/a", "-", "NULL", "#N/A")
)

# BAD: Default only recognizes "NA"
df <- read.csv("data.csv")  # Empty strings stay as ""
```

## Explicit Column Types

Never rely on type guessing - use explicit `col_types`:

```r
# GOOD: Explicit column specification
col_types <- readr::cols(
  id = readr::col_integer(),
  amount = readr::col_double(),
  name = readr::col_character(),
  .default = readr::col_character()  # Unknown columns stay character
)
df <- readr::read_csv("data.csv", col_types = col_types)

# Check for parse problems
if (nrow(readr::problems(df)) > 0L) {
  cli::cli_warn("Parse problems detected")
}

# BAD: Suppress coercion warnings
safe_int <- function(x) suppressWarnings(as.integer(x))  # NEVER DO THIS
```

## Typed NAs

Use typed NA values to preserve column types:

```r
# GOOD: Typed NAs
tibble::tibble(
  int_col = c(1L, NA_integer_, 3L),
  num_col = c(1.0, NA_real_, 3.0),
  chr_col = c("a", NA_character_, "c")
)

# AVOID: Untyped NA (coerces to logical first)
c(1L, NA, 3L)  # Works but NA is logical
```

## Safe Column Extraction

Handle missing optional columns gracefully:

```r
# GOOD: Safe extraction helper
extract_int_col <- function(df, col, n_rows) {
  if (col %in% colnames(df)) df[[col]] else rep(NA_integer_, n_rows)
}

n <- nrow(raw)
result <- tibble::tibble(
  required = raw[["required_col"]],
  optional = extract_int_col(raw, "optional_col", n)
)

# BAD: Direct access returns NULL for missing columns
raw[["missing_col"]]  # NULL causes tibble size mismatch
```

## NA in Aggregations

Always be explicit about NA handling:

```r
# GOOD: Explicit na.rm
data |>
  summarise(
    mean_val = mean(value, na.rm = TRUE),
    n_missing = sum(is.na(value)),
    .by = group
  )

# CAREFUL: No na.rm returns NA if any NA present
mean(c(1, 2, NA))  # Returns NA
```
