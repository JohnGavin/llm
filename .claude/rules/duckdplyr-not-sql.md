---
paths:
  - "R/**"
  - "vignettes/**"
  - "_targets.R"
---
# No Raw SQL in R Projects

## Rule

Use duckdplyr or `dplyr::tbl()` syntax for all DuckDB queries. Never use
`DBI::dbGetQuery()` with raw SQL strings.

**Forbidden:**
```r
DBI::dbGetQuery(con, "SELECT * FROM clinical WHERE ...")
DBI::dbExecute(con, "CREATE TABLE ...")
```

**Required:**
```r
clinical_tbl <- dplyr::tbl(con, "clinical")
result <- clinical_tbl |>
  dplyr::filter(gender == "female") |>
  dplyr::select(submitter_id, age_at_diagnosis) |>
  dplyr::collect()
```

## Rationale

- dplyr syntax is idiomatic R and consistent with tidyverse conventions
- Eliminates SQL injection risk from string interpolation
- DuckDB's dplyr backend translates to optimized SQL automatically
- Code examples in vignettes should teach R patterns, not SQL

## Exceptions

- `DBI::dbConnect()` and `DBI::dbDisconnect()` for connection management
- `DBI::dbExecute()` for DDL only (CREATE TABLE, CREATE INDEX, CREATE VIEW)
- `DBI::dbExecute()` for DML writes that dplyr cannot express (INSERT ... ON CONFLICT, INSERT OR REPLACE)
- `DBI::dbWriteTable()` for bulk data loading
- No exceptions for SELECT queries -- always use dplyr

## DuckDB Non-Determinism Pitfalls

DuckDB parallelizes query execution and **never guarantees row order**. These patterns silently produce different results on every run.

### 1. Window functions without `window_order()`

```r
# BAD: row_number(), cumsum(), lag(), lead() without explicit order
tbl |> group_by(id) |> mutate(rn = row_number())

# GOOD: always use window_order() with a unique tiebreaker
tbl |> group_by(id) |> window_order(date, rowid) |> mutate(rn = row_number())
```

The ordering key MUST include a column unique within each group — `group_by()` columns alone are identical for every row in the group.

### 2. `distinct(.keep_all = TRUE)` and `slice_min/max`

```r
# BAD: which row's extra columns are kept is arbitrary
tbl |> distinct(id, .keep_all = TRUE)

# GOOD (option A): explicit control over which row wins
tbl |> group_by(id) |> window_order(date) |> filter(row_number() == 1L)

# GOOD (option B): summarise when you only need aggregates
tbl |> group_by(id) |> summarise(first_date = min(date, na.rm = TRUE))
```

**`with_ties` trap:** `slice_min(with_ties = TRUE)` (default) uses `RANK()` — returns ALL tied rows, expanding data. Use `with_ties = FALSE` (uses `ROW_NUMBER()`) but then `order_by` must break ALL ties:

```r
# BAD: with_ties = FALSE but date alone has ties → arbitrary pick
tbl |> group_by(id) |> slice_min(order_by = date, n = 1, with_ties = FALSE)

# GOOD: tiebreaker column in order_by
tbl |> group_by(id) |> slice_min(order_by = tibble(date, rowid), n = 1, with_ties = FALSE)
```

### 3. Inequality joins creating fan-out

Overlapping reference periods (e.g., rate tables with Jan-Dec and Jul-Dec) cause rows to match multiple times, silently doubling downstream counts.

**Detect fan-out** after any inequality join:

```r
joined |> count(entity_id, line_id) |> filter(n > 1) |> collect()
# Non-empty = fan-out occurred
```

**Fix:** Pre-resolve to unique (key, date) pairs via equi-join back:

```r
rates_resolved <- data |>
  distinct(code, date) |>
  left_join(ref_rates, by = join_by(code, date >= start, date <= end)) |>
  group_by(code, date) |>
  window_order(desc(start), desc(end)) |>
  filter(row_number() == 1L) |>
  ungroup() |>
  select(-start, -end)

# Safe equi-join — no fan-out possible
data |> left_join(rates_resolved, by = c("code", "date"))
```

### 4. Synthetic duplicate rows

Expansion operations (turning `qty = 3` into three rows) create identical duplicates. Window functions cannot distinguish them.

```r
# BAD: expansion index discarded
expanded |> select(-row_idx) |> mutate(rn = row_number())

# GOOD: retain expansion index as tiebreaker throughout pipeline
expanded |> window_order(row_idx) |> mutate(rn = row_number())
# Drop index only AFTER all window operations complete
```

**`union_all()` variant:** Add a source tag before combining so rows remain distinguishable downstream:

```r
combined <- union_all(
  mutate(set_a, .source = "a"),
  mutate(set_b, .source = "b")
)
```

### 5. Type-dependent deduplication

When a table has mixed row types sharing a key, deduplicating by one type's counter silently drops other types' rows.

```r
# BAD: counter_a identical for TYPE_A and TYPE_B within same entity_id
records |>
  group_by(entity_id, counter_a) |>
  filter(row_number() == 1L)
# TYPE_B rows silently eliminated

# GOOD: split by type, deduplicate each with its own counter, recombine
records_a <- records |>
  filter(type != "TYPE_B") |>
  group_by(entity_id, counter_a) |>
  window_order(entity_id, counter_a, line_id) |>
  filter(row_number() == 1L) |> ungroup()

records_b <- records |>
  filter(type == "TYPE_B") |>
  group_by(entity_id, counter_b) |>
  window_order(entity_id, counter_b, line_id) |>
  filter(row_number() == 1L) |> ungroup()

records_final <- union_all(records_a, records_b)
```

### Detection

Run pipelines multiple times comparing aggregates. If totals or row counts vary, binary-search intermediate tables to isolate where non-determinism enters.

```r
runs <- purrr::map(1:8, \(i) {
  source("pipeline.R")
  result |> summarise(total = sum(amount, na.rm = TRUE), n = n()) |> collect()
})
purrr::map_dfr(runs, identity)
# Variation in total or n → non-determinism present
```

### Code Review Checklist

- [ ] Every `row_number()`, `cumsum()`, `lag()`, `lead()` preceded by `window_order()` with true tiebreaker
- [ ] No `window_order()` column exclusively from `group_by()`
- [ ] No `distinct(.keep_all = TRUE)` — use `summarise()` or `window_order() + filter(row_number() == 1L)`
- [ ] Every `slice_min/max(with_ties = FALSE)` has tiebreaker in `order_by`
- [ ] Every inequality join checked for fan-out (`count() |> filter(n > 1)`)
- [ ] Fan-out resolved via pre-resolution, not post-dedup
- [ ] Every expansion keeps index column until after all window operations
- [ ] Each row type deduped with its own counter when logic differs

## Enforcement (MANDATORY)

Add `qa_no_raw_sql` target to `plan_qa_gates.R` in every project:

```r
targets::tar_target(
  qa_no_raw_sql,
  {
    r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
    r_files <- r_files[!grepl("R/dev/", r_files)]
    all_code <- unlist(lapply(r_files, readLines))
    violations <- grep("DBI::dbGetQuery", all_code)
    if (length(violations) > 0) {
      cli::cli_warn(c(
        "!" = "{length(violations)} DBI::dbGetQuery violation(s) found in R/",
        "i" = "Convert to dplyr::tbl() |> dplyr::filter() |> dplyr::collect()"
      ))
    }
    list(violations = length(violations), timestamp = Sys.time())
  },
  cue = targets::tar_cue(mode = "always")
)
```

This target runs on every `tar_make()`, preventing SQL regression after conversion to dplyr.
The quality gate deducts 5 points if any violations are found.
