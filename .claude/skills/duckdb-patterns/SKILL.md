---
name: duckdb-patterns
description: >
  Patterns for DuckDB database operations in R. Use this skill when:
  (1) Writing duckplyr queries instead of raw SQL,
  (2) Setting up secure database connections,
  (3) Debugging non-deterministic query results,
  (4) Working with DuckDB's hf:// protocol for HuggingFace datasets,
  (5) Implementing window functions with proper ordering,
  (6) Handling inequality joins and fan-out detection,
  (7) Multiple processes/agents writing to the same DuckDB file concurrently.
  Covers security hardening, duckplyr patterns, non-determinism pitfalls, and
  the single-writer lock (concurrent-write) failure mode.
metadata:
  category: Data & Analysis
  tier: workflow
  maturity: stable
---

# Skill: DuckDB Patterns

Patterns for DuckDB: duckplyr (no raw SQL), security hardening, non-determinism pitfalls, concurrent-writer lock conflicts.

## Triggers

- Working with DuckDB databases
- Writing duckplyr queries
- Setting up database connections
- Debugging non-deterministic query results
- Multiple scripts/agents/hooks writing to the same `.duckdb` file

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

## Part 4: Concurrent Writers — the Single-Writer Lock

DuckDB takes an **exclusive whole-file lock** on write. No concurrent readers
or writers while it is held — this is not a queue, it's a hard failure for
every process that loses the race.

**Verified directly (llm#1156):** 5 concurrent `duckdb` CLI processes each
issuing one `INSERT` against the same file — 4 of 5 failed immediately:

```
Error: unable to open database "...": IO Error: Could not set lock on file
"...": Conflicting lock is held in .../duckdb (PID nnnnn) by user <you>.
```

This already happened in production at larger scale — a 12-concurrent-writer
experiment on this project's own telemetry DB landed only 1 of 12 writes
(llm#710, llm#956) — and the fix generalizes to any workload where multiple
agents, hooks, or scripts want to write to one DuckDB file around the same
time (exactly the "burst of concurrent queries" pattern agent workloads
produce).

### The fix: append-only staging file, single serialized drain

Never have N concurrent processes each open their own `dbConnect()` against
the shared file. Instead:

1. Each writer appends one line to a plain JSONL file — `printf '...' >>
   staging.jsonl`. A single `>>` append of `<= PIPE_BUF` bytes is an atomic
   kernel write; no DuckDB connection, no lock, cannot conflict with another
   writer doing the same append.
2. One separate process drains the staging file into the real DuckDB table
   later, serialized, at a time when contention is naturally lower (e.g. from
   a nightly ETL) — this is the only process that ever calls `dbConnect()`
   for that write path.

```bash
# WRONG — every concurrent caller opens its own duckdb connection to the
# same file; the loser gets "Conflicting lock is held"
duckdb "$SHARED_DB" -c "INSERT INTO events VALUES (...)"

# RIGHT — lock-free append; a separate drain script owns the one write path
printf '%s\n' "$(jq -nc --arg ts "$(date -u +%FT%TZ)" '{ts:$ts, event:"..."}' )" \
  >> "$STAGING_JSONL"
# ... later, serialized, from events_staging_import.sh:
#   duckdb "$SHARED_DB" -c "INSERT INTO events SELECT * FROM read_json('$STAGING_JSONL')"
```

Reference implementation in this repo: `log_session.sh` (writer side) +
`hook_events_load.sh` / `session_events_staging_import.sh` /
`agent_events_staging_import.sh` / `error_events_staging_import.sh` (drain
side).

**Do NOT** "fix" a lock conflict by adding `2>/dev/null` or `|| true` around
the `duckdb` call — that was the original failure mode (11 of 12 writes
silently lost, discovered only because someone went looking). Route the
write path through the staging pattern instead of suppressing the error.

## Checklist

- [ ] No `DBI::dbGetQuery()` with raw SQL strings
- [ ] Every `dbConnect()` uses secure hardening
- [ ] `enable_external_access = false` on all connections
- [ ] `lock_configuration = true` set LAST
- [ ] Every `row_number()` has `window_order()` with tiebreaker
- [ ] No `distinct(.keep_all = TRUE)`
- [ ] Inequality joins checked for fan-out
- [ ] Any write path invoked by more than one concurrent caller uses the
      staging-file + serialized-drain pattern, not a direct `dbConnect()`
      per caller

## Related

- `btw-timeouts` rule — R execution timeout patterns
- `housekeeping-framework` rule — the `housekeeping_runs`/events-table conventions the drain scripts follow
- JohnGavin/llm#710, JohnGavin/llm#956 — the incidents that produced the staging-file pattern
- JohnGavin/llm#1156 — gap analysis that surfaced this section was missing
