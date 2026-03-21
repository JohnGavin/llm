---
paths:
  - "R/**"
  - "tests/**"
  - "inst/**"
---
# DuckDB Security Hardening

Based on [Simon Willison's DuckDB security research](https://github.com/simonw/research/tree/main/duckdb-security). DuckDB can read arbitrary files, make HTTP requests, and consume unbounded resources by default.

## 1. Connection Hardening (MANDATORY)

Every `DBI::dbConnect(duckdb::duckdb(), ...)` MUST be followed by hardening. Use the secure connection template:

```r
connect_duckdb_secure <- function(dbdir = ":memory:",
                                  read_only = FALSE,
                                  allowed_dirs = NULL,
                                  memory_limit = "1GB",
                                  max_threads = 4L,
                                  max_temp_size = "500MB") {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only)

  # Set allowed paths BEFORE disabling external access

  if (!is.null(allowed_dirs)) {
    dirs_sql <- paste0("'", allowed_dirs, "'", collapse = ", ")
    DBI::dbExecute(con, paste0("SET allowed_directories = [", dirs_sql, "]"))
  }

  # Disable file and network access
  DBI::dbExecute(con, "SET enable_external_access = false")

  # Resource limits
  DBI::dbExecute(con, paste0("SET memory_limit = '", memory_limit, "'"))
  DBI::dbExecute(con, paste0("SET threads = ", max_threads))
  DBI::dbExecute(con, paste0("SET max_temp_directory_size = '", max_temp_size, "'"))

  # Lock configuration LAST — prevents SET after this point
  DBI::dbExecute(con, "SET lock_configuration = true")

  con
}
```

## 2. When to Use Read-Only Mode

| Scenario | Mode |
|---|---|
| Analysis vignettes, read from cache | `read_only = TRUE` |
| Shiny apps reading pre-built DB | `read_only = TRUE` |
| ETL pipeline writing results | `read_only = FALSE` + hardening |
| Interactive exploration | `read_only = FALSE` + hardening |

## 3. Threats Mitigated

| Threat | Default DuckDB | After Hardening |
|---|---|---|
| Read `/etc/passwd` via `read_csv()` | Possible | Blocked (`enable_external_access = false`) |
| SSRF via `read_csv('https://...')` | Possible | Blocked |
| Unbounded memory | Unlimited | Capped (`memory_limit`) |
| CPU exhaustion | All cores | Capped (`threads`) |
| Temp disk abuse | Unlimited | Capped (`max_temp_directory_size`) |
| Runtime `SET` tampering | Possible | Blocked (`lock_configuration`) |

## 4. Query Timeout (No Native Support)

DuckDB has no built-in query timeout ([duckdb#8564](https://github.com/duckdb/duckdb/issues/8564)). Use R-side interruption:

```r
duckdb_execute_timeout <- function(con, query, timeout_sec = 30) {
  result <- NULL
  err <- NULL
  thread <- callr::r_bg(function(dbdir, query) {
    con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con))
    DBI::dbGetQuery(con, query)
  }, args = list(dbdir = con@dbdir, query = query))
  thread$wait(timeout = timeout_sec * 1000)
  if (thread$is_alive()) {
    thread$kill()
    cli::cli_abort("DuckDB query exceeded {timeout_sec}s timeout")
  }
  thread$get_result()
}
```

For duckplyr pipelines, wrap `collect()` with `R.utils::withTimeout()` or use targets with `tar_option_set(seconds_timeout = 300)`.

## 5. Disabled Filesystems

For maximum restriction (e.g., Shiny apps):

```r
DBI::dbExecute(con, "SET disabled_filesystems = 'LocalFileSystem,HTTPFileSystem'")
```

**Order matters:** Set `allowed_directories` → `disabled_filesystems` → `enable_external_access = false` → `lock_configuration = true`.

## 6. Adversarial Test Vectors

Add to `test-adversarial-*.R` for any function accepting DuckDB connections or queries:

```r
test_that("DuckDB connection is hardened", {
  con <- connect_duckdb_secure(allowed_dirs = tempdir())
  # File access blocked

  expect_error(DBI::dbGetQuery(con, "SELECT * FROM read_csv('/etc/passwd')"))
  # Network access blocked
  expect_error(DBI::dbGetQuery(con, "SELECT * FROM read_csv('https://evil.com/data')"))
  # Config locked
  expect_error(DBI::dbExecute(con, "SET enable_external_access = true"))
  DBI::dbDisconnect(con)
})
```

## Checklist

- [ ] Every `dbConnect(duckdb())` uses `connect_duckdb_secure()` or equivalent hardening
- [ ] `enable_external_access = false` set on all connections
- [ ] Resource limits set (`memory_limit`, `threads`, `max_temp_directory_size`)
- [ ] `lock_configuration = true` set LAST
- [ ] Read-only mode used for analysis/display connections
- [ ] Query timeout in place for user-facing or long-running queries
- [ ] Adversarial tests cover file read, SSRF, and config tampering
