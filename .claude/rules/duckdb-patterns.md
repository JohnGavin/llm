---
description: DuckDB patterns — duckplyr (no raw SQL), security hardening, non-determinism pitfalls
paths:
  - "R/**"
  - "tests/**"
  - "_targets.R"
---

# Rule: DuckDB Patterns

Consolidated from: `duckdplyr-not-sql`, `duckdb-security`, `duckdb-non-determinism`.

---

## Part 1: Use duckplyr, Not Raw SQL

### Rule

Use duckplyr or `dplyr::tbl()` for ALL DuckDB queries. Never `DBI::dbGetQuery()` with SQL strings.

```r
# FORBIDDEN
DBI::dbGetQuery(con, "SELECT * FROM clinical WHERE ...")

# REQUIRED
clinical_tbl <- dplyr::tbl(con, "clinical")
result <- clinical_tbl |> filter(gender == "female") |> collect()
```

### duckplyr for Remote Parquet

```r
duckplyr::read_parquet_duckdb("hf://datasets/user/repo/file.parquet") |>
  summarise(n = n(), .by = ticker) |>
  collect()
```

### duckplyr Gotchas

| Pattern | Problem | Fix |
|---------|---------|-----|
| `group_by(x) \|> summarise()` | "stingy duckplyr frame" error | Use `.by = x` inside `summarise()` |
| `as.character()` inside summarise | Type coercion fails | Move to after `collect()` |

### Exceptions

- `DBI::dbExecute()` for DDL (CREATE TABLE)
- `DBI::dbWriteTable()` for bulk loading
- NO exceptions for SELECT — always dplyr

---

## Part 2: Security Hardening (MANDATORY)

Source: [Simon Willison's DuckDB security research](https://github.com/simonw/research/tree/main/duckdb-security).

### Secure Connection Template

```r
connect_duckdb_secure <- function(dbdir = ":memory:", read_only = FALSE,
                                  allowed_dirs = NULL, memory_limit = "1GB") {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only)

  if (!is.null(allowed_dirs)) {
    dirs_sql <- paste0("'", allowed_dirs, "'", collapse = ", ")
    DBI::dbExecute(con, paste0("SET allowed_directories = [", dirs_sql, "]"))
  }

  DBI::dbExecute(con, "SET enable_external_access = false")
  DBI::dbExecute(con, paste0("SET memory_limit = '", memory_limit, "'"))
  DBI::dbExecute(con, "SET lock_configuration = true")  # MUST be LAST

  con
}
```

### Threats Mitigated

| Threat | After Hardening |
|---|---|
| Read `/etc/passwd` | Blocked |
| SSRF via HTTP | Blocked |
| Unbounded memory | Capped |
| Runtime `SET` tampering | Blocked |

---

## Part 3: Non-Determinism Pitfalls

DuckDB parallelizes and **never guarantees row order**.

### 1. Window Functions Need `window_order()`

```r
# BAD
tbl |> group_by(id) |> mutate(rn = row_number())

# GOOD — include unique tiebreaker
tbl |> group_by(id) |> window_order(date, rowid) |> mutate(rn = row_number())
```

### 2. Avoid `distinct(.keep_all = TRUE)`

```r
# BAD — arbitrary row kept
tbl |> distinct(id, .keep_all = TRUE)

# GOOD — explicit control
tbl |> group_by(id) |> window_order(date) |> filter(row_number() == 1L)
```

### 3. `slice_min/max` Needs Tiebreaker

```r
# BAD
tbl |> group_by(id) |> slice_min(order_by = date, with_ties = FALSE)

# GOOD
tbl |> group_by(id) |> slice_min(order_by = tibble(date, rowid), with_ties = FALSE)
```

### 4. Inequality Joins Create Fan-Out

Detect after any inequality join:
```r
joined |> count(id) |> filter(n > 1) |> collect()
# Non-empty = fan-out
```

Fix: Pre-resolve to unique (key, date) pairs.

### 5. Synthetic Duplicates

Keep expansion index throughout pipeline:
```r
expanded |> window_order(row_idx) |> mutate(rn = row_number())
```

---

## Checklist

- [ ] No `DBI::dbGetQuery()` with raw SQL strings
- [ ] Every `dbConnect()` uses secure hardening
- [ ] `enable_external_access = false` on all connections
- [ ] `lock_configuration = true` set LAST
- [ ] Every `row_number()` has `window_order()` with tiebreaker
- [ ] No `distinct(.keep_all = TRUE)`
- [ ] Inequality joins checked for fan-out

---

## Related

- `btw-timeouts` — R execution timeout patterns
