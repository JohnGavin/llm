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
| **tidyverse** (meta) | Avoid | Too heavy; loads 30+ packages. Import specific packages. Critical for Shinylive/WASM. |
| **plyr** | Deprecated | Superseded by dplyr/purrr. Causes conflicts. |
| **reshape2** | Deprecated | Superseded by tidyr. Use `pivot_longer()`/`pivot_wider()`. |
| **magrittr** | Limited | Use base pipe `|>`. Only for `%<>%` or `%$%` if truly needed. |

### Preferred Alternatives to Tidyverse

| Task | Tidyverse | Our Preference | Rationale |
|------|-----------|----------------|-----------|
| Parallel map | `purrr::map()` + furrr | `mirai::mirai_map()` | Lighter, faster startup |
| SQL on files | `readr` + `dplyr` | `duckdb` | Query without loading to memory |
| Large data | `readr` + `dplyr` | `arrow` + `duckdb` | Zero-copy, larger than memory |

## Style Guide

Key rules: snake_case naming, base pipe `|>`, break after pipes with 2-space indent, named arguments for clarity, `\()` for single-line lambdas and `function()` for multi-line. Always run `air format .` after generating code.

See [formatting-rules.md](references/formatting-rules.md) for detailed examples and code formatting guidance.

### Tidyverse Verbs

Quick lookup for dplyr, tidyr, stringr, and purrr verbs. For parallel operations, prefer `mirai::mirai_map()` over `furrr::future_map()`.

See [verbs-reference.md](references/verbs-reference.md) for the complete verbs reference.

### String Manipulation (stringr)

Prefer stringr over base R string functions (`grep`, `gsub`, `substr`) for consistent API and pipe-friendly data-first syntax. Use `str_view()` to debug regexes, `fixed()` for literal strings, and `str_glue()` for interpolation. Named capture groups with `str_match()` are powerful for structured extraction.

See [stringr-patterns.md](references/stringr-patterns.md) for the complete stringr reference including base R migration table, regex patterns for data cleaning, and pattern modifier details.

## Package Code vs Scripts

### In Package Code (R/)

```r
# GOOD: Explicit namespacing
#' @importFrom dplyr filter mutate
#' @importFrom rlang .data
process_data <- function(data) {
  data |>
    dplyr::filter(.data$age > 18) |>
    dplyr::mutate(status = "processed")
}

# BAD: library() calls - NEVER in package code
```

### In Scripts/Vignettes

```r
# GOOD: library() at top
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

## Missing Data Handling

Key principles: explicit NA strings in `readr::read_csv(na = c(...))`, explicit `col_types` (never guess), typed NAs (`NA_integer_` not bare `NA`), safe column extraction for optional columns, and always `na.rm = TRUE` or document NA behavior in aggregations. Never use `suppressWarnings(as.integer())`.

See [missing-data.md](references/missing-data.md) for detailed patterns and code examples.

## Common Patterns and Stack Integration

Standard tidyverse patterns for data transformation pipelines, grouped summaries, string operations with stringr/glue, and tidy evaluation with rlang (`{{ col }}`). Includes integration examples for DuckDB, Arrow, and targets.

See [common-patterns.md](references/common-patterns.md) for detailed code examples.

## Review Checklist (for reviewer agent)

- [ ] Uses `|>` not `%>%` (unless legacy codebase)
- [ ] snake_case naming throughout
- [ ] No `library()` in package R/ code
- [ ] Explicit namespace (`dplyr::filter`) or `@importFrom`
- [ ] `.data$col` or `{{ col }}` for column references in functions
- [ ] Tidyr verbs instead of reshape2
- [ ] purrr pattern appropriate (or mirai for parallel)
- [ ] No tidyverse meta-package import
- [ ] Uses `readr::read_csv()` not `read.csv()`
- [ ] Explicit `na = c(...)` in read_csv calls
- [ ] Explicit `col_types` (no type guessing)
- [ ] No `suppressWarnings(as.integer())` anti-pattern
- [ ] Typed NAs used (`NA_integer_`, not bare `NA`)
- [ ] Aggregations have explicit `na.rm = TRUE` or documented NA behavior

## Resources

- [Tidyverse Style Guide](https://style.tidyverse.org/)
- [Tidyverse Design Principles](https://design.tidyverse.org/)
- [R Packages (2e) - Dependencies](https://r-pkgs.org/dependencies-in-practice.html)
- [Workflow vs Script](https://tidyverse.org/blog/2017/12/workflow-vs-script/)
- [rlang Tidy Evaluation](https://rlang.r-lib.org/reference/topic-data-mask.html)
