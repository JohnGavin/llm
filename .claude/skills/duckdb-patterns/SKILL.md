---
name: duckdb-patterns
description: >
  Patterns for DuckDB database operations in R. Use this skill when:
  (1) Writing duckplyr queries instead of raw SQL,
  (2) Setting up secure database connections,
  (3) Debugging non-deterministic query results,
  (4) Working with DuckDB's hf:// protocol for HuggingFace datasets,
  (5) Implementing window functions with proper ordering,
  (6) Handling inequality joins and fan-out detection.
  Covers security hardening, duckplyr patterns, and non-determinism pitfalls.
metadata:
  category: Data & Analysis
  tier: workflow
  maturity: stable
---

# Skill: DuckDB Patterns

Patterns for DuckDB: duckplyr (no raw SQL), security hardening, non-determinism pitfalls.

## Triggers

- Working with DuckDB databases
- Writing duckplyr queries
- Setting up database connections
- Debugging non-deterministic query results

## Part 1: Use duckplyr, Not Raw SQL

**Rule:** Use duckplyr or `dplyr::tbl()` for ALL queries. Never `DBI::dbGetQuery()` with SQL strings.

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

## Part 2: Security Hardening (MANDATORY)

Source: [Simon Willison's DuckDB security research](https://github.com/simonw/research/tree/main/duckdb-security).

### Secure Connection Template

Real implementation: `.claude/scripts/lib/duckdb_secure.R` (`connect_duckdb_secure()`).
Source it and call it in place of a raw `DBI::dbConnect(duckdb::duckdb(), ...)`:

```r
source(file.path(<script_dir>, "lib", "duckdb_secure.R"))
con <- connect_duckdb_secure(dbdir = db_path, read_only = FALSE)
```

Working example: `.claude/scripts/backfill_skill_usage.R` (DB-write connection,
`con <- connect_duckdb_secure(dbdir = db_path, read_only = FALSE)`), covered by
`tests/test_backfill_skill_usage_secure_connection.R`.

### CRITICAL — `enable_external_access = false` breaks any connection that LOADs an extension or ATTACHes a file

Verified empirically (JohnGavin/llm#1156): once `enable_external_access` is
set to `false`, DuckDB's extension-loading path is disabled for the life of
the connection — including its own **autoloading** of a bundled extension
for a function you didn't explicitly `LOAD`. `allowed_directories` does
**not** carve out an exception; it only scopes filesystem paths for
operations that `enable_external_access` still permits at all.

Two real failure modes found while wiring this in:

| Pattern | Why it breaks | Example in this repo |
|---|---|---|
| `LOAD sqlite` then `ATTACH '<file>' (TYPE sqlite, READ_ONLY)` | `LOAD` itself is blocked | `roborev_metrics_etl.R`'s `read_con`, `roborev_daily_report.R`'s three `tmp_con` sites, `roborev_weekly_rollup.R`, `send_overnight_self_review_email.R` — all read `~/.roborev/reviews.db` this way; NOT retrofitted |
| A query uses a function backed by an auto-loadable extension (e.g. `DATEDIFF()` → `icu`) | DuckDB's autoload-on-first-use is itself extension loading | `skill_usage_etl.R`'s `STALENESS_VIEW_DDL` uses `DATEDIFF()`; NOT retrofitted |

`date_trunc()`, `regexp_replace()`, `CAST`, and `current_timestamp` are
core functions and do not trigger this — confirmed empirically, and that is
why `backfill_skill_usage.R` (which uses exactly those) was a safe target.
Before retrofitting any other `dbConnect()` call site, run the script
end-to-end against a real temp DB and projects/ input, not just a grep for
`ATTACH`/`LOAD` — the icu-autoload failure above produces no grep-visible
warning sign in the source.

### Threats Mitigated (on connections where it's safe to apply)

| Threat | After Hardening |
|---|---|
| Read `/etc/passwd` | Blocked |
| SSRF via HTTP | Blocked |
| Unbounded memory | Capped |
| Runtime `SET` tampering | Blocked |

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

## Checklist

- [ ] No `DBI::dbGetQuery()` with raw SQL strings
- [ ] Every `dbConnect()` that only touches its own DuckDB-native tables uses `connect_duckdb_secure()`
- [ ] Any connection that must `LOAD` an extension or `ATTACH` an external file is deliberately left unhardened, with a comment saying why (see the CRITICAL note above)
- [ ] `lock_configuration = true` set LAST, on connections where hardening is applied
- [ ] Every `row_number()` has `window_order()` with tiebreaker
- [ ] No `distinct(.keep_all = TRUE)`
- [ ] Inequality joins checked for fan-out

## Related

- `btw-timeouts` rule — R execution timeout patterns
