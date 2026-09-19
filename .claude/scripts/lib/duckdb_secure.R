# duckdb_secure.R — hardened DuckDB connection helper (JohnGavin/llm#1156)
#
# .claude/skills/duckdb-patterns/SKILL.md Part 2 ("Secure Connection
# Template") documents `connect_duckdb_secure()` as MANDATORY, but until this
# file it existed only as a markdown code example — a repo-wide grep found
# zero real call sites, while ~10+ real DBI::dbConnect(duckdb::duckdb(), ...)
# calls across the codebase applied none of the hardening. This is the first
# real implementation.
#
# Source this file, then call connect_duckdb_secure() in place of a raw
# DBI::dbConnect(duckdb::duckdb(), ...) call:
#
#   source(file.path(<script_dir>, "lib", "duckdb_secure.R"))
#   con <- connect_duckdb_secure(dbdir = db_path, read_only = FALSE)
#
# IMPORTANT — enable_external_access = false disables DuckDB's own
# extension-loading and file/ATTACH machinery for the life of the
# connection (verified empirically: even LOAD of a bundled extension like
# `sqlite` fails once this is set, regardless of allowed_directories). Do
# NOT use this helper for a connection that will LOAD an extension or
# ATTACH an external database file (e.g. the roborev scripts' `:memory:`
# connections that ATTACH ~/.roborev/reviews.db via the sqlite extension) —
# it will break them. It is safe for a connection that only reads/writes
# its own DuckDB-native tables (CREATE TABLE, dbAppendTable, CREATE VIEW,
# parameterized DBI queries) with no DuckDB-side external I/O.
#
# Function body is copied verbatim from the skill's Part 2 template except
# for the `load_icu` parameter (JohnGavin/llm#1223) — do not otherwise
# redesign it here; if a call site needs different behaviour (e.g. a
# controlled ATTACH), that is a separate helper, not a change to this one.
#
# load_icu: any TIMESTAMPTZ literal cast, or TZ-aware date function
# (CURRENT_DATE, CURRENT_TIMESTAMP, AGE(), etc.) requires DuckDB's `icu`
# extension. DuckDB normally autoloads it lazily on first use — but
# `enable_external_access = false` (below) disables autoloading too, per
# this file's own header warning, so a connection that runs ANY TZ-aware
# SQL after that lockdown fails with "Loading external extensions is
# disabled through configuration", caught by the caller's own tryCatch and
# silently read as "no rows" rather than "the query never ran" — exactly
# the checks-must-distinguish-unknown failure this project's other rules
# exist to prevent. Load icu FIRST, before the lockdown, when the caller's
# SQL needs it; the default stays FALSE so callers with no TZ-aware SQL are
# unaffected (icu is generally cheap to load, but this keeps the function's
# behaviour unchanged for existing callers per the "don't redesign" note
# above). Reference precedent: the mycare project's own db_connect() already
# does `LOAD icu` before any lockdown, for the same reason.
connect_duckdb_secure <- function(dbdir = ":memory:", read_only = FALSE,
                                  allowed_dirs = NULL, memory_limit = "1GB",
                                  load_icu = FALSE) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = dbdir, read_only = read_only)
  if (isTRUE(load_icu)) {
    tryCatch(
      DBI::dbExecute(con, "LOAD icu"),
      error = function(e) {
        message("connect_duckdb_secure: LOAD icu failed: ", conditionMessage(e),
                " — TZ-aware queries on this connection will error, not silently misparse.")
      }
    )
  }
  if (!is.null(allowed_dirs)) {
    dirs_sql <- paste0("'", allowed_dirs, "'", collapse = ", ")
    DBI::dbExecute(con, paste0("SET allowed_directories = [", dirs_sql, "]"))
  }
  DBI::dbExecute(con, "SET enable_external_access = false")
  DBI::dbExecute(con, paste0("SET memory_limit = '", memory_limit, "'"))
  DBI::dbExecute(con, "SET lock_configuration = true")  # MUST be LAST
  con
}
