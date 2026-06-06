# canonical_check.R — R helper for producer-side skip-and-warn (#536)
#
# Source this file in ETL scripts to get:
#   - canonical_slugs(con): returns character vector of canonical slugs + aliases
#   - filter_canonical(df, con): filters a data frame's `repo` column to only
#     canonical entries, logging skips.
#   - log_canonical_skip(slugs, producer): appends to the skip log.
#
# Opt-out: set env var CANONICAL_PROJECTS_INCLUDE_FIXTURES=1 to bypass filtering.
#
# Skip log: ~/.claude/logs/canonical_producer_skip.log
#
# Issue: JohnGavin/llm#536

# ── Internal cache (process-local, populated lazily) ─────────────────────────

.canonical_cache <- new.env(parent = emptyenv())
.canonical_cache$slugs <- NULL  # NULL = not yet loaded

# canonical_slugs(con)
#
# Returns a character vector of all active slugs and aliases from unified.duckdb.
# Caches the result for the lifetime of the R process.
# con: a DBI connection to unified.duckdb (passed in to avoid circular opens).
# When con is NULL or query fails, returns character(0) (all-reject fallback).
canonical_slugs <- function(con) {
  if (!is.null(.canonical_cache$slugs)) {
    return(.canonical_cache$slugs)
  }

  # Opt-out: include all as canonical
  if (isTRUE(nchar(Sys.getenv("CANONICAL_PROJECTS_INCLUDE_FIXTURES")) > 0) &&
      Sys.getenv("CANONICAL_PROJECTS_INCLUDE_FIXTURES") == "1") {
    .canonical_cache$slugs <- character(0L)  # signal: bypass filter
    return(.canonical_cache$slugs)
  }

  if (is.null(con)) {
    .canonical_cache$slugs <- character(0L)
    return(.canonical_cache$slugs)
  }

  result <- tryCatch(
    DBI::dbGetQuery(con, "
      SELECT slug FROM canonical_projects WHERE is_active = TRUE
      UNION ALL
      SELECT alias FROM canonical_project_aliases
    ")$slug,
    error = function(e) {
      message("canonical_check.R: cannot load canonical slugs — ",
              conditionMessage(e), " — will skip all non-matched repos")
      character(0L)
    }
  )

  .canonical_cache$slugs <- result
  result
}

# filter_canonical(df, con, producer, include_fixtures)
#
# Filters df$repo to canonical slugs, logs skipped rows, returns filtered df.
# df:               data.frame with a `repo` column (character)
# con:              DBI connection to unified.duckdb
# producer:         string identifying the calling script (for log)
# include_fixtures: logical; if TRUE, bypass filtering (default: FALSE)
#
# Returns the filtered data.frame (same structure as df).
filter_canonical <- function(df, con, producer = "unknown",
                              include_fixtures = FALSE) {
  if (include_fixtures ||
      identical(Sys.getenv("CANONICAL_PROJECTS_INCLUDE_FIXTURES"), "1")) {
    return(df)
  }

  if (nrow(df) == 0L || !"repo" %in% names(df)) {
    return(df)
  }

  slugs <- canonical_slugs(con)

  # If slugs is empty (DB unavailable), treat as all-reject
  if (length(slugs) == 0L) {
    non_canon <- unique(df$repo)
    if (length(non_canon) > 0L) {
      log_canonical_skip(non_canon, producer)
      message(sprintf(
        "%s: canonical guard FALLBACK — DB unavailable, skipping %d repos: %s",
        producer, length(non_canon), paste(non_canon, collapse = ", ")
      ))
    }
    return(df[character(0L), , drop = FALSE])  # empty frame, same structure
  }

  non_canon <- unique(df$repo[!df$repo %in% slugs])
  if (length(non_canon) > 0L) {
    log_canonical_skip(non_canon, producer)
    message(sprintf(
      "%s: canonical guard skipped %d non-canonical repo(s): %s",
      producer, length(non_canon), paste(non_canon, collapse = ", ")
    ))
  }

  df[df$repo %in% slugs, , drop = FALSE]
}

# log_canonical_skip(slugs, producer)
#
# Appends one line per slug to ~/.claude/logs/canonical_producer_skip.log
log_canonical_skip <- function(slugs, producer = "unknown") {
  skip_log <- file.path(Sys.getenv("HOME"), ".claude", "logs",
                         "canonical_producer_skip.log")
  ts <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  for (slug in slugs) {
    cat(sprintf("%s SKIP slug=%s producer=%s\n", ts, slug, producer),
        file = skip_log, append = TRUE)
  }
}
