# Tidyverse Style and Package Guide

## Description

Comprehensive guide to tidyverse packages, style conventions, and when to use each package. Covers recommended packages, excluded packages with rationale, and integration with our Nix/R workflow.

## Purpose

Use this skill when:
- Deciding which tidyverse package to use for a task
- Reviewing code for tidyverse style compliance
- Choosing between tidyverse and base R approaches
- Setting up package dependencies

## Package Recommendations

### Tier 1: Core (Always Use)

| Package | Purpose | Use Instead Of |
|---------|---------|----------------|
| **dplyr** | Data manipulation | base `subset()`, `transform()`, `aggregate()` |
| **ggplot2** | Visualization | base `plot()`, `hist()`, `barplot()` |
| **tidyr** | Data reshaping | base `reshape()`, `stack()` |
| **purrr** | Functional programming | base `lapply()`, `sapply()`, `Map()` |
| **stringr** | String manipulation | base `grep()`, `gsub()`, `substr()` |
| **readr** | Read rectangular data | base `read.csv()`, `read.delim()` |

### Tier 2: Specialized (Use When Needed)

| Package | Purpose | When to Use |
|---------|---------|-------------|
| **lubridate** | Date/time handling | Any date manipulation beyond basics |
| **forcats** | Factor manipulation | Reordering, collapsing factor levels |
| **glue** | String interpolation | Complex string construction |
| **tibble** | Modern data frames | Already implicit with dplyr |
| **cli** | CLI output formatting | User-facing messages in packages |
| **rlang** | Metaprogramming | Writing functions that use dplyr verbs |

### Tier 3: Domain-Specific (Project Dependent)

| Package | Purpose | When to Use |
|---------|---------|-------------|
| **dbplyr** | Database backends | SQL via dplyr syntax |
| **dtplyr** | data.table backend | Large data needing data.table speed |
| **haven** | SPSS/Stata/SAS files | Importing statistical software data |
| **readxl** | Excel files | Reading .xlsx/.xls |
| **jsonlite** | JSON handling | API responses (or use duckdb) |
| **xml2** | XML/HTML parsing | Web scraping, config files |

### Excluded Packages (With Rationale)

| Package | Status | Rationale |
|---------|--------|-----------|
| **tidyverse** (meta) | ❌ Avoid | Too heavy; loads 30+ packages. Import specific packages instead. Critical for Shinylive/WASM where size matters. |
| **plyr** | ❌ Deprecated | Superseded by dplyr/purrr. Causes conflicts if loaded with dplyr. |
| **reshape2** | ❌ Deprecated | Superseded by tidyr. Use `pivot_longer()`/`pivot_wider()`. |
| **magrittr** | ⚠️ Limited | Use base pipe `|>` instead of `%>%`. Only use magrittr for `%<>%` or `%$%` if truly needed. |

### Preferred Alternatives to Tidyverse

| Task | Tidyverse | Our Preference | Rationale |
|------|-----------|----------------|-----------|
| Parallel map | `purrr::map()` + furrr | `mirai::mirai_map()` | Lighter, faster startup |
| SQL on files | `readr` + `dplyr` | `duckdb` | Query without loading to memory |
| Large data | `readr` + `dplyr` | `arrow` + `duckdb` | Zero-copy, larger than memory |

## Style Guide

### Naming Conventions

```r
# ✅ GOOD: snake_case for everything
calculate_mean_value <- function(input_data) { }
user_age <- 25
MAX_ITERATIONS <- 100

# ❌ BAD: Other conventions
calculateMeanValue <- function(inputData) { }  # camelCase
user.age <- 25                                   # dot.case
```

### Pipe Usage

```r
# ✅ GOOD: Base pipe |> (R 4.1+)
result <- data |>
  filter(age > 18) |>
  mutate(age_group = cut(age, breaks = c(18, 30, 50, Inf))) |>
  summarise(n = n(), .by = age_group)

# ⚠️ ACCEPTABLE: magrittr %>% in existing codebases
result <- data %>%
filter(age > 18) %>%
  summarise(n = n())

# ❌ BAD: Nested calls
result <- summarise(filter(data, age > 18), n = n())
```
### Line Length and Breaking

```r
# ✅ GOOD: Break after pipe, indent 2 spaces
data |>
  filter(
    age > 18,
    status == "active"
  ) |>
  mutate(
    full_name = paste(first_name, last_name),
    age_group = case_when(
      age < 30 ~ "young",
      age < 50 ~ "middle",
      TRUE ~ "senior"
    )
  )

# ❌ BAD: Long lines, inconsistent breaks
data |> filter(age > 18, status == "active") |> mutate(full_name = paste(first_name, last_name))
```

### Function Arguments

```r
# ✅ GOOD: Named arguments for clarity
ggplot(data, aes(x = age, y = income)) +
  geom_point(alpha = 0.5, size = 2) +
  labs(
    title = "Income by Age",
    x = "Age (years)",
    y = "Annual Income ($)"
  )

# ❌ BAD: Positional arguments beyond first two
ggplot(data, aes(age, income)) +
  geom_point(0.5, 2)  # What do these mean?
```

### Tidyverse Verbs Reference

```r
# Data manipulation (dplyr)
select()    # Choose columns
filter()    # Choose rows
mutate()    # Create/modify columns
summarise() # Aggregate
arrange()   # Sort rows
group_by()  # Group for operations
join()      # Combine tables (left_join, inner_join, etc.)

# Data reshaping (tidyr)
pivot_longer()   # Wide to long
pivot_wider()    # Long to wide
separate()       # Split column
unite()          # Combine columns
nest()           # Create list-columns
unnest()         # Expand list-columns

# String operations (stringr)
str_detect()     # Pattern matching (returns logical)
str_extract()    # Extract matches
str_replace()    # Replace matches
str_split()      # Split strings
str_c()          # Concatenate (or use glue)

# Functional programming (purrr)
map()            # Apply function, return list
map_chr()        # Apply function, return character
map_dbl()        # Apply function, return double
map2()           # Iterate over two inputs
pmap()           # Iterate over multiple inputs
walk()           # Apply for side effects

# BUT PREFER for parallel:
mirai::mirai_map()  # Parallel map (replaces furrr::future_map)
```

## Package Code vs Scripts

### In Package Code (R/)

```r
# ✅ GOOD: Explicit namespacing
#' @importFrom dplyr filter mutate
#' @importFrom rlang .data
process_data <- function(data) {
  data |>
    dplyr::filter(.data$age > 18) |>
    dplyr::mutate(status = "processed")
}

# ❌ BAD: library() calls
process_data <- function(data) {
  library(dplyr)  # NEVER in package code
  filter(data, age > 18)
}
```

### In Scripts/Vignettes

```r
# ✅ GOOD: library() at top
library(dplyr)
library(ggplot2)

data |>
  filter(age > 18) |>
  ggplot(aes(x = age)) +
  geom_histogram()
```

### In DESCRIPTION

```
Imports:
    dplyr (>= 1.1.0),
    ggplot2,
    rlang
Suggests:
    tidyr,
    purrr,
    stringr
```

**Rule:** Imports = used in R/ code. Suggests = used in tests/vignettes only.

## Common Patterns

### Data Transformation Pipeline

```r
library(dplyr)
library(tidyr)

clean_data <- raw_data |>
  # Clean names
rename_with(janitor::make_clean_names) |>

  # Filter valid rows
  filter(
    !is.na(id),
    date >= "2024-01-01"
  ) |>

  # Transform columns
  mutate(
    date = as.Date(date),
    amount = as.numeric(amount),
    category = factor(category)
  ) |>

  # Reshape if needed
  pivot_longer(
    cols = starts_with("value_"),
    names_to = "metric",
    values_to = "value"
  )
```

### Grouped Summaries

```r
library(dplyr)

summary_stats <- data |>
  summarise(
    n = n(),
    mean_value = mean(value, na.rm = TRUE),
    sd_value = sd(value, na.rm = TRUE),
    .by = c(group, category)  # Modern grouped summarise
  )

# Or traditional group_by (still valid)
summary_stats <- data |>
  group_by(group, category) |>
  summarise(
    n = n(),
    mean_value = mean(value, na.rm = TRUE),
    .groups = "drop"
  )
```

### String Operations

```r
library(stringr)
library(glue)

# Pattern matching
data |>
  filter(str_detect(name, "^Dr\\.")) |>
  mutate(
    first_name = str_extract(name, "(?<=\\s)\\w+"),
    greeting = glue("Hello, {first_name}!")
  )
```

### Safe Column References (rlang)

```r
library(rlang)
library(dplyr)

# For functions that take column names as arguments
summarise_column <- function(data, col) {
  data |>
    summarise(
      mean = mean({{ col }}, na.rm = TRUE),
      sd = sd({{ col }}, na.rm = TRUE)
    )
}

# Usage
data |> summarise_column(age)
data |> summarise_column(income)
```

## Integration with Our Stack

### With DuckDB

```r
library(duckdb)
library(dplyr)
library(dbplyr)

con <- dbConnect(duckdb())

# dplyr verbs translate to SQL
result <- tbl(con, sql("SELECT * FROM read_parquet('data.parquet')")) |>
  filter(status == "active") |>
  mutate(year = year(date)) |>
  summarise(n = n(), .by = year) |>
  collect()  # Execute and bring to R
```

### With Arrow

```r
library(arrow)
library(dplyr)

# dplyr verbs work on Arrow datasets
result <- open_dataset("data/") |>
  filter(year == 2024) |>
  select(id, value, category) |>
  collect()
```

### With targets

```r
# _targets.R
library(targets)
library(tarchetypes)

# Targets uses tidy evaluation
tar_option_set(packages = c("dplyr", "ggplot2"))

list(
  tar_target(clean_data, raw_data |> filter(!is.na(id))),
  tar_target(summary, clean_data |> summarise(n = n()))
)
```

## Review Checklist (for reviewer agent)

- [ ] Uses `|>` not `%>%` (unless legacy codebase)
- [ ] snake_case naming throughout
- [ ] No `library()` in package R/ code
- [ ] Explicit namespace (`dplyr::filter`) or `@importFrom`
- [ ] `.data$col` or `{{ col }}` for column references in functions
- [ ] Tidyr verbs instead of reshape2
- [ ] purrr pattern appropriate (or mirai for parallel)
- [ ] No tidyverse meta-package import

## Resources

- [Tidyverse Style Guide](https://style.tidyverse.org/)
- [Tidyverse Design Principles](https://design.tidyverse.org/)
- [R Packages (2e) - Dependencies](https://r-pkgs.org/dependencies-in-practice.html)
- [Workflow vs Script](https://tidyverse.org/blog/2017/12/workflow-vs-script/)
- [rlang Tidy Evaluation](https://rlang.r-lib.org/reference/topic-data-mask.html)
