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

## duckplyr for Remote Parquet (MANDATORY)

`dplyr::tbl(con, sql("SELECT * FROM read_parquet(...)"))` still contains raw
SQL inside the `sql()` call — this **violates the rule**.

Use `duckplyr::read_parquet_duckdb()` for zero-SQL access to remote Parquet:

```r
# CORRECT: zero SQL
duckplyr::read_parquet_duckdb("hf://datasets/user/repo/file.parquet") |>
  summarise(n = n(), from = min(date), to = max(date), .by = ticker) |>
  arrange(desc(n)) |>
  collect() |>
  mutate(from = as.character(from), to = as.character(to))
```

duckplyr translates all dplyr verbs (group_by, summarise, filter, mutate,
joins) to DuckDB SQL automatically — including on remote Parquet via `hf://`
URLs. There is NO efficiency excuse for raw SQL. duckplyr pushes predicates,
projections, and aggregations down to DuckDB natively.

### duckplyr Gotchas (learned from historicaldata project, 2026-04)

| Pattern | Problem | Fix |
|---------|---------|-----|
| `group_by(x) \|> summarise()` | Errors with "stingy duckplyr frame" | Use `.by = x` inside `summarise()` |
| `as.character(min(date))` inside `summarise()` | Type coercion fails in DuckDB | Move `as.character()` to after `collect()` |
| `duckplyr` not in `.libPaths()` | Nix shell may not include it even if in flake.nix | Add nix store path fallback (see historicaldata `_targets.R`) |
| `dplyr::tbl(con, sql("SELECT..."))` | Still contains raw SQL inside `sql()` | Use `duckplyr::read_parquet_duckdb()` instead |

Note: The DuckDB community extension called "dplyr" (https://duckdb.org/community_extensions/extensions/dplyr)
is for non-R users — it adds dplyr-like syntax to SQL. It is NOT relevant
for R projects. Use the `duckplyr` R package instead.

## Exceptions

- `DBI::dbConnect()` and `DBI::dbDisconnect()` for connection management
- `DBI::dbExecute()` for DDL only (CREATE TABLE, CREATE INDEX, CREATE VIEW)
- `DBI::dbExecute()` for DML writes that dplyr cannot express (INSERT ... ON CONFLICT, INSERT OR REPLACE)
- `DBI::dbWriteTable()` for bulk data loading
- No exceptions for SELECT queries -- always use dplyr/duckplyr

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

See also: `duckdb-non-determinism` rule for DuckDB parallelism pitfalls.
