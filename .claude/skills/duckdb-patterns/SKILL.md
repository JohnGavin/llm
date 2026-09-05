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

Real implementation: `.claude/scripts/lib/duckdb_secure.R` (`connect_duckdb_secure()`).
Source it and call it in place of a raw `DBI::dbConnect(duckdb::duckdb(), ...)`:

```r
source(file.path(<script_dir>, "lib", "duckdb_secure.R"))
con <- connect_duckdb_secure(dbdir = db_path, read_only = FALSE)
```

Working examples (JohnGavin/llm#1156 retrofit round 2 — verified end-to-end
against real data, not just parsed):

- `.claude/scripts/backfill_skill_usage.R` (DB-write), covered by
  `tests/test_backfill_skill_usage_secure_connection.R`.
- `.claude/scripts/backfill_command_usage.R` (DB-write) — run live with
  `--apply` against `~/.claude/logs/unified.duckdb`.
- `.claude/scripts/launchd_health_report.R` — 3 read-only connections
  (`read_run_metrics()`, `read_run_counts_by_script()`,
  `collect_braindumps_staleness()`), all exercised by a full `--dry-run`.
- `.claude/scripts/roborev_weekly_rollup.R` — `query_close_reasons()`
  only (the `duck_con_filter` canonical-project-filter connection in the
  same file was tried and reverted — see the table below).
- `.claude/scripts/roborev_metrics_etl.R` — the canonical-guard read
  connection and `load_pricing_df()`'s read connection (both exercised by
  a default `--dry-run`), plus `connect_unified_rw()`'s read-write
  connection (only reachable via `--apply`; verified by code inspection
  against the already-live-tested write pattern in
  `backfill_command_usage.R`, not exercised directly in this round).
- `.claude/scripts/roborev_daily_report.R` — the single `UNIFIED_DUCKDB`
  read connection, exercised by a full `--dry-run`.

Two additional sites were tried in this round and **reverted** after live
verification surfaced a real failure — see the next two subsections.

### CRITICAL — `enable_external_access = false` breaks any connection that LOADs an extension or ATTACHes a file

Verified empirically (JohnGavin/llm#1156): once `enable_external_access` is
set to `false`, DuckDB's extension-loading path is disabled for the life of
the connection — including its own **autoloading** of a bundled extension
for a function you didn't explicitly `LOAD`. `allowed_directories` does
**not** carve out an exception; it only scopes filesystem paths for
operations that `enable_external_access` still permits at all.

Four real failure modes found while wiring this in (two from round 1, two
more from round 2's retrofit — see JohnGavin/llm#1156):

| Pattern | Why it breaks | Example in this repo |
|---|---|---|
| `LOAD sqlite` then `ATTACH '<file>' (TYPE sqlite, READ_ONLY)` | `LOAD` itself is blocked | `roborev_metrics_etl.R`'s `read_con`, `roborev_daily_report.R`'s three `tmp_con` sites, `roborev_weekly_rollup.R`, `send_overnight_self_review_email.R` — all read `~/.roborev/reviews.db` this way; NOT retrofitted |
| A query uses a function backed by an auto-loadable extension (e.g. `DATEDIFF()` → `icu`) | DuckDB's autoload-on-first-use is itself extension loading | `skill_usage_etl.R`'s `STALENESS_VIEW_DDL` uses `DATEDIFF()`; NOT retrofitted |
| `(CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::TIMESTAMP` — timezone conversion | `AT TIME ZONE` also autoloads `icu`, same as `DATEDIFF()` — it is not a core function despite reading like one | `send_stage1_findings_email.R` — tried, reproduced live (`Extension Autoloading Error ... Loading external extensions is disabled through configuration`), **reverted to a raw `DBI::dbConnect()` call** |
| A hardened connection to path *P* is leaked (never actually disconnected) because its `on.exit(dbDisconnect(...))` is registered inside an `if` block at the script's **top level**, where `on.exit()` has no enclosing function frame to fire on | The leaked connection already ran `SET lock_configuration = true`; a later connection to the *same* `dbdir` shares the cached DuckDB instance (per-dbdir instance caching, llm#595) and its own `SET enable_external_access = false` then fails with `Cannot change configuration option "enable_external_access" - the configuration has been locked` | `roborev_weekly_rollup.R`'s `duck_con_filter` (canonical-project filter) vs. `query_close_reasons()`, both against `UNIFIED_DUCKDB` in the same process — reproduced live; `duck_con_filter` **reverted to a raw `DBI::dbConnect()` call**, `query_close_reasons()` kept hardened |

`date_trunc()`, `regexp_replace()`, `CAST`, and `current_timestamp` are
core functions and do not trigger this — confirmed empirically, and that is
why `backfill_skill_usage.R` (which uses exactly those) was a safe target.
Before retrofitting any other `dbConnect()` call site, run the script
end-to-end against a real temp DB and projects/ input, not just a grep for
`ATTACH`/`LOAD` — the icu-autoload failure above produces no grep-visible
warning sign in the source. Likewise, grepping for `ATTACH`/`LOAD` cannot
catch the fourth pattern — it only shows up by actually running the script
end-to-end and checking whether **any other connection to the same dbdir**
already ran with `lock_configuration = true` and was never truly closed.

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
- [ ] Every `dbConnect()` that only touches its own DuckDB-native tables uses `connect_duckdb_secure()`
- [ ] Any connection that must `LOAD` an extension or `ATTACH` an external file is deliberately left unhardened, with a comment saying why (see the CRITICAL note above)
- [ ] `lock_configuration = true` set LAST, on connections where hardening is applied
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
