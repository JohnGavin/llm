#!/usr/bin/env Rscript
# roborev_revalidate.R — Heuristic stale-finding revalidator.
#
# For each open High+ roborev finding in reviews.db, checks whether the
# referenced file/line still contains a distinctive pattern from the Problem
# text. Classifies each review as:
#   likely-fixed   — file missing OR pattern gone from nearby lines
#   still-present  — file exists AND pattern still found nearby
#   ambiguous      — file exists but no distinctive pattern could be extracted
#
# Default: DRY-RUN (prints what would be closed but does nothing).
# With --apply: calls `roborev close <job_id>` for likely-fixed reviews.
#
# Per-review verdict = weakest classification across sub-findings:
#   if ANY sub-finding is still-present → review is still-present
#   else if ANY sub-finding is ambiguous → review is ambiguous
#   else → likely-fixed
#
# Data source: ~/.roborev/reviews.db (read-only via native SQLite).
# Does NOT use duckdb sqlite_scanner.
#
# CLI args:
#   --repo NAME           (default: llm)
#   --min-severity {Critical,High,Medium,Low}  (default: High)
#   --limit N             (default: 0 = no limit)
#   --out PATH            (default: ~/.claude/logs/roborev_revalidate/<repo>_<sev>_<date>.md)
#   --apply               (default: dry-run)
#   --repo-root PATH      (default: ~/docs_gh/<repo>)
#
# Tracked in llm#280 (roborev stale-finding revalidation).

suppressPackageStartupMessages({
  library(jsonlite)
})

# ── CLI parsing ────────────────────────────────────────────────────────────────

parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  defaults <- list(
    repo         = "llm",
    min_severity = "High",
    limit        = 0L,
    out          = NULL,
    apply        = FALSE,
    repo_root    = NULL
  )

  sev_order <- c(Critical = 4L, High = 3L, Medium = 2L, Low = 1L)

  i <- 1L
  args <- defaults
  while (i <= length(argv)) {
    switch(argv[[i]],
      "--repo"         = { args$repo         <- argv[[i + 1L]]; i <- i + 2L },
      "--min-severity" = { args$min_severity <- argv[[i + 1L]]; i <- i + 2L },
      "--limit"        = { args$limit        <- as.integer(argv[[i + 1L]]); i <- i + 2L },
      "--out"          = { args$out          <- argv[[i + 1L]]; i <- i + 2L },
      "--repo-root"    = { args$repo_root    <- argv[[i + 1L]]; i <- i + 2L },
      "--apply"        = { args$apply        <- TRUE; i <- i + 1L },
      { stop("Unknown argument: ", argv[[i]]) }
    )
  }

  if (!args$min_severity %in% names(sev_order)) {
    stop("--min-severity must be one of: ", paste(names(sev_order), collapse = ", "))
  }
  args$min_severity_num <- sev_order[[args$min_severity]]
  args$sev_order <- sev_order
  args
}

# ── Database helpers ──────────────────────────────────────────────────────────
#
# Uses two backends:
#   1. RSQLite (preferred) — if installed and not in test mode.
#   2. python3 subprocess — reads via sqlite3 mode=ro, outputs JSON to stdout.
#      This fulfils the spec requirement "native python3 sqlite mode=ro".
#
# `open_reviews_db_ro()` returns a list(backend, handle) or NULL for python3.
# `fetch_open_reviews()` dispatches to the appropriate backend.

reviews_db_path <- function() {
  path.expand(Sys.getenv(
    "ROBOREV_DB",
    file.path(Sys.getenv("HOME"), ".roborev", "reviews.db")
  ))
}

open_reviews_db_ro <- function() {
  db_path <- reviews_db_path()
  if (!file.exists(db_path)) stop("reviews.db not found: ", db_path)

  if (requireNamespace("RSQLite", quietly = TRUE)) {
    con <- DBI::dbConnect(RSQLite::SQLite(), dbname = db_path,
                          flags = RSQLite::SQLITE_RO)
    return(list(backend = "rsqlite", handle = con, db_path = db_path))
  }
  # Fall back to python3 backend (no persistent connection)
  list(backend = "python3", handle = NULL, db_path = db_path)
}

# Close connection (no-op for python3 backend)
close_reviews_db <- function(db) {
  if (!is.null(db$handle)) DBI::dbDisconnect(db$handle)
  invisible(NULL)
}

# Fetch via RSQLite
.fetch_rsqlite <- function(con, repo) {
  # llm#1265: roborev v0.68.2 migrated every row's review text out of
  # `output` (empty on all live rows) into `structured_output` (JSON).
  sql <- "
    SELECT r.id AS review_id,
           r.job_id,
           rj.git_ref,
           r.created_at,
           r.output,
           r.structured_output
    FROM reviews r
    JOIN review_jobs rj ON r.job_id = rj.id
    JOIN repos rep      ON rj.repo_id = rep.id
    WHERE rep.name = ?
      AND r.closed = 0
    ORDER BY r.created_at
  "
  tryCatch(
    DBI::dbGetQuery(con, sql, params = list(repo)),
    error = function(e) {
      # Defensive fallback for a reviews.db predating the v0.68.2 migration
      # (no structured_output column).
      sql2 <- "
        SELECT r.id AS review_id,
               r.job_id,
               rj.git_ref,
               r.created_at,
               r.output,
               NULL AS structured_output
        FROM reviews r
        JOIN review_jobs rj ON r.job_id = rj.id
        JOIN repos rep      ON rj.repo_id = rep.id
        WHERE rep.name = ?
          AND r.closed = 0
        ORDER BY r.created_at
      "
      DBI::dbGetQuery(con, sql2, params = list(repo))
    }
  )
}

# Fetch via python3 subprocess — outputs JSON array
.fetch_python3 <- function(db_path, repo) {
  # llm#1265: roborev v0.68.2 migrated every row's review text out of
  # `output` (empty on all live rows) into `structured_output` (JSON).
  # Falls back to an `output`-only query if the column doesn't exist (a
  # reviews.db predating the migration).
  py_script <- sprintf(
    paste(
      "import sqlite3, json, sys",
      "con = sqlite3.connect('file:%s?mode=ro', uri=True)",
      "cur = con.cursor()",
      "try:",
      "  cur.execute('''",
      "    SELECT r.id, r.job_id, rj.git_ref, r.created_at, r.output, r.structured_output",
      "    FROM reviews r",
      "    JOIN review_jobs rj ON r.job_id = rj.id",
      "    JOIN repos rep ON rj.repo_id = rep.id",
      "    WHERE rep.name = ? AND r.closed = 0",
      "    ORDER BY r.created_at",
      "  ''', (%s,))",
      "except sqlite3.OperationalError:",
      "  cur.execute('''",
      "    SELECT r.id, r.job_id, rj.git_ref, r.created_at, r.output, NULL",
      "    FROM reviews r",
      "    JOIN review_jobs rj ON r.job_id = rj.id",
      "    JOIN repos rep ON rj.repo_id = rep.id",
      "    WHERE rep.name = ? AND r.closed = 0",
      "    ORDER BY r.created_at",
      "  ''', (%s,))",
      "rows = cur.fetchall()",
      "con.close()",
      "print(json.dumps(rows))",
      sep = "\n"
    ),
    db_path,
    paste0('"', repo, '"'),
    paste0('"', repo, '"')
  )

  out <- system2("python3", args = c("-c", shQuote(py_script)),
                 stdout = TRUE, stderr = FALSE)
  if (length(out) == 0L || !nzchar(out[[1L]])) {
    return(data.frame(
      review_id  = integer(0),
      job_id     = integer(0),
      git_ref    = character(0),
      created_at = character(0),
      output     = character(0),
      structured_output = character(0),
      stringsAsFactors = FALSE
    ))
  }

  rows_list <- jsonlite::fromJSON(paste(out, collapse = "\n"), simplifyVector = FALSE)
  if (length(rows_list) == 0L) {
    return(data.frame(
      review_id  = integer(0),
      job_id     = integer(0),
      git_ref    = character(0),
      created_at = character(0),
      output     = character(0),
      structured_output = character(0),
      stringsAsFactors = FALSE
    ))
  }

  data.frame(
    review_id  = vapply(rows_list, function(r) r[[1L]], integer(1L)),
    job_id     = vapply(rows_list, function(r) r[[2L]], integer(1L)),
    git_ref    = vapply(rows_list, function(r) as.character(r[[3L]]), character(1L)),
    created_at = vapply(rows_list, function(r) as.character(r[[4L]]), character(1L)),
    output     = vapply(rows_list, function(r) as.character(r[[5L]]), character(1L)),
    structured_output = vapply(rows_list, function(r) {
      if (length(r) < 6L || is.null(r[[6L]])) NA_character_ else as.character(r[[6L]])
    }, character(1L)),
    stringsAsFactors = FALSE
  )
}

fetch_open_reviews <- function(db, repo, min_severity_num, sev_order, limit) {
  rows <- if (db$backend == "rsqlite") {
    .fetch_rsqlite(db$handle, repo)
  } else {
    .fetch_python3(db$db_path, repo)
  }

  # llm#1265: `output` is empty on every row since roborev v0.68.2 migrated
  # review text into `structured_output`. Reconstruct per-row text (via the
  # findings-block builder below, which handles schema_version 0/1/2 and
  # falls back to `output`) BEFORE running the severity-marker regex, so the
  # threshold filter keeps working unchanged.
  findings_text <- vapply(
    seq_len(nrow(rows)),
    function(i) .review_findings_text(rows$output[[i]], rows$structured_output[[i]]),
    character(1L)
  )

  # Filter by minimum severity: keep reviews that contain at least one
  # sub-finding at or above the threshold.
  keep <- vapply(findings_text, function(out) {
    found_sevs <- regmatches(out,
      gregexpr("(?<=\\*\\*Severity\\*\\*:\\s)[A-Za-z]+", out, perl = TRUE))[[1L]]
    any(sev_order[found_sevs] >= min_severity_num, na.rm = TRUE)
  }, logical(1L))
  rows <- rows[keep, , drop = FALSE]

  if (limit > 0L && nrow(rows) > limit) rows <- rows[seq_len(limit), , drop = FALSE]
  rows
}

# ── structured_output reader (llm#1265) ─────────────────────────────────────
#
# roborev v0.68.2 migrated every row's review text out of `output` into a
# new `structured_output` JSON column (schema_version 0: original markdown
# verbatim under data$legacy$markdown; schema_version >= 1: verdict/summary/
# findings, findings carrying severity/problem/fix/location). This script's
# OWN parse_findings() below expects "---"-separated blocks (a format unique
# to this file, distinct from the "## Review Findings" bullet-list shape the
# other roborev_*.sh/R consumers reconstruct) -- so rather than reuse the
# shared roborev_classify.py/.R review_output_text() reconstruction (blank-
# line separated, would silently collapse a multi-finding structured review
# into ONE block and drop all but the first finding's detail), this builds
# "---"-joined blocks directly from the findings array, which parse_findings()
# already knows how to split. schema_version 0 rows return legacy.markdown
# verbatim (byte-identical to the pre-migration `output` text, so the
# existing "---"-block parsing behaves exactly as before). Both-empty/
# unparseable falls back to the raw `output` column, then "".
.review_findings_text <- function(output, structured_output) {
  data <- NULL
  if (!is.null(structured_output) && !is.na(structured_output) && nzchar(structured_output)) {
    data <- tryCatch(jsonlite::fromJSON(structured_output, simplifyVector = FALSE),
                      error = function(e) NULL)
  }
  if (!is.null(data) && is.list(data)) {
    legacy <- data[["legacy"]]
    if (is.list(legacy)) {
      md <- legacy[["markdown"]]
      if (is.character(md) && length(md) == 1L && nzchar(trimws(md))) return(md)
    }
    findings <- data[["findings"]]
    if (is.list(findings) && length(findings) > 0L) {
      # PR #1269 round 4 (defense-in-depth, same crash class as review
      # 10536 finding 2 in .review_structured_findings_list() above): a
      # JSON array field becomes a non-scalar list/vector under
      # simplifyVector=FALSE, and as.character()+nzchar() on that crashes
      # `if()` in R 4.2+. Only a length-1 character value is used; anything
      # else renders as blank rather than aborting this fallback path
      # (which is itself the regex path's OWN input, exercised whenever the
      # JSON-direct reader above finds nothing usable to read).
      blocks <- vapply(findings, function(f) {
        if (!is.list(f)) return("")
        sev <- f[["severity"]]
        sev <- if (is.character(sev) && length(sev) == 1L) trimws(sev) else ""
        sev_cap <- if (nzchar(sev)) paste0(toupper(substr(sev, 1, 1)), substr(sev, 2, nchar(sev))) else ""
        lines <- sprintf("**Severity**: %s", sev_cap)
        loc <- f[["location"]]
        if (is.character(loc) && length(loc) == 1L && nzchar(loc)) {
          lines <- c(lines, sprintf("**Location**: %s", loc))
        }
        prob <- f[["problem"]]
        if (is.character(prob) && length(prob) == 1L && nzchar(prob)) {
          lines <- c(lines, sprintf("**Problem**: %s", prob))
        }
        paste(lines, collapse = "\n")
      }, character(1L))
      return(paste(blocks, collapse = "\n---\n"))
    }
    # Valid structured_output, no findings (a "passed" review) -- nothing
    # for parse_findings() to extract; distinct from the both-empty case.
    return("")
  }
  if (!is.null(output) && !is.na(output) && nzchar(output)) return(output)
  ""
}

# ── JSON-direct findings (PR #1269 round 3) ─────────────────────────────────
#
# Investigated whether this file's regex path (.review_findings_text() +
# parse_findings() below) is vulnerable to the same corruption class fixed
# elsewhere in this round (a finding's own problem/fix prose quoting a
# severity marker as an example, e.g. review ids 10523/10524). Conclusion:
# NOT vulnerable in classify_review()'s use, for three independent reasons
# specific to this file's design: (1) blocks are split one-per-finding on
# "---", so a DIFFERENT finding's prose can never corrupt this one; (2)
# .review_findings_text() always emits "**Severity**: X" as EACH block's
# first line, before Location/Problem; (3) parse_findings() extracts
# severity via regexpr() (first match only, not gregexpr()), so it always
# reads the synthesized leading marker, never a later one embedded in the
# same finding's own Problem text. The `fix` field (where the live
# examples actually quoted the marker) is also never rendered by
# .review_findings_text() to begin with. This function is added anyway,
# as a strict, defense-in-depth replacement: reading findings[].severity/
# location/problem DIRECTLY from JSON removes even the residual
# fragility of "regex happens to still be correct because of block/field
# ordering", and keeps this file's severity source consistent with every
# other roborev_*.sh/R consumer fixed in this round. Returns a list of
# list(severity=,location=,problem=) -- severity CAPITALISED to match
# sev_order's naming convention (Critical/High/Medium/Low), same as
# parse_findings()'s own regex-captured values -- for a schema_version 1/2
# row with a non-empty findings list, or NULL when there is nothing to
# read (schema_version 0 / legacy rows use the existing regex path over
# legacy.markdown / `output`, unchanged).
.review_structured_findings_list <- function(structured_output) {
  if (is.null(structured_output) || is.na(structured_output) || !nzchar(structured_output)) return(NULL)
  data <- tryCatch(jsonlite::fromJSON(structured_output, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(data) || !is.list(data)) return(NULL)
  legacy <- data[["legacy"]]
  if (is.list(legacy)) {
    md <- legacy[["markdown"]]
    if (is.character(md) && length(md) == 1L && nzchar(trimws(md))) return(NULL)  # schema 0 -> legacy regex path
  }
  schema_version <- data[["schema_version"]]
  known_schema <- is.numeric(schema_version) && length(schema_version) == 1L &&
    !is.na(schema_version) && (schema_version == 1 || schema_version == 2)
  if (!known_schema) return(NULL)
  findings <- data[["findings"]]
  if (!is.list(findings) || length(findings) == 0L) return(NULL)
  out <- lapply(findings, function(f) {
    if (!is.list(f)) return(NULL)
    # PR #1269 round 4 (review 10536 finding 2): `severity`/`location`/
    # `problem` can be a JSON array, which simplifyVector=FALSE turns into
    # an R list rather than a scalar. as.character() on that, followed by
    # `nzchar(...)` inside an `if`, crashes in R 4.2+ ("condition has
    # length > 1"). Only a length-1 character value is accepted here;
    # anything else is treated as absent. A finding with no usable severity
    # is dropped entirely (returns NULL, filtered out below) rather than
    # kept with severity=NA -- so that when EVERY finding in this row is
    # unusable, this function returns NULL and the caller falls through to
    # the regex path instead of reporting a determinate-looking "no
    # findings above threshold" from data that was never actually read
    # (review 10536 finding 3, checks-must-distinguish-unknown).
    sev <- f[["severity"]]
    if (!is.character(sev) || length(sev) != 1L || !nzchar(trimws(sev))) return(NULL)
    # Lower-case first, THEN capitalise the first letter, so any input
    # casing ("HIGH", "high", "High") normalises to the "High" shape
    # sev_order's names use (Critical/High/Medium/Low) -- review 10536
    # finding 1. Upper-casing only the first character left "HIGH" as
    # "HIGH", which never matches sev_order's "High".
    sev_lower <- tolower(trimws(sev))
    sev_cap <- paste0(toupper(substr(sev_lower, 1, 1)), substr(sev_lower, 2, nchar(sev_lower)))
    # An off-vocabulary word (not Critical/High/Medium/Low) is not a usable
    # severity either -- drop the finding rather than keep a value
    # classify_review()'s sev_order lookup will just discard anyway. This
    # keeps "no finding has a recognised severity" (review 10536 finding 3)
    # meaning exactly the same thing here as it does for the vocabulary
    # check every other JSON-direct reader fixed in this round applies.
    if (!(sev_cap %in% c("Critical", "High", "Medium", "Low"))) return(NULL)
    loc  <- f[["location"]]
    prob <- f[["problem"]]
    list(
      severity = sev_cap,
      location = if (is.character(loc) && length(loc) == 1L && nzchar(trimws(loc))) trimws(loc) else NA_character_,
      problem  = if (is.character(prob) && length(prob) == 1L && nzchar(trimws(prob))) trimws(prob) else NA_character_
    )
  })
  out <- Filter(Negate(is.null), out)
  if (length(out) == 0L) return(NULL)
  out
}

# ── Finding parser ────────────────────────────────────────────────────────────

SEVERITY_RE   <- "\\*\\*Severity\\*\\*:\\s*([A-Za-z]+)"
LOCATION_RE   <- "\\*\\*Location\\*\\*:\\s*(.+?)(?=\\n)"
PROBLEM_RE    <- "\\*\\*Problem\\*\\*:\\s*(.+?)(?=\\n- \\*\\*|\\n---\\s*\\n|\\n## |$)"

parse_findings <- function(output) {
  # Split on "---" horizontal rules (sub-finding separators) or repeated ---
  blocks <- strsplit(output, "\n---\\s*\n|\n---$", perl = TRUE)[[1L]]
  blocks <- trimws(blocks)
  blocks <- blocks[nchar(blocks) > 0]

  lapply(blocks, function(blk) {
    sev  <- regmatches(blk, regexpr(SEVERITY_RE,  blk, perl = TRUE))
    loc  <- regmatches(blk, regexpr(LOCATION_RE,  blk, perl = TRUE))
    prob <- regmatches(blk, regexpr(PROBLEM_RE,   blk, perl = TRUE, ignore.case = TRUE))

    sev  <- if (length(sev)  == 0L) NA_character_ else sub("\\*\\*Severity\\*\\*:\\s*",  "", sev)
    loc  <- if (length(loc)  == 0L) NA_character_ else sub("\\*\\*Location\\*\\*:\\s*",  "", loc)
    prob <- if (length(prob) == 0L) NA_character_ else sub("\\*\\*Problem\\*\\*:\\s*",   "", prob)

    # Clean up backtick fences in location (e.g. `path:L1-L2` → path:L1-L2)
    loc <- gsub("`", "", loc)
    # Take only first location (comma/semicolon can produce multiple)
    loc <- trimws(strsplit(loc, "[;,]")[[1L]][[1L]])

    list(severity = sev, location = loc, problem = prob)
  })
}

# ── Location resolver ─────────────────────────────────────────────────────────

# Parse location string "path:lines" where lines may be "N", "N-M", "N,M,K".
parse_location <- function(loc) {
  if (is.na(loc) || !nzchar(loc)) return(list(path = NA_character_, lines = integer(0)))

  # Strip backtick fences (in case called with raw location string)
  loc <- gsub("`", "", loc)
  # Strip any trailing "existing ..." clause (e.g. "a.yml:1-5, existing b.yml:4-10")
  loc <- trimws(loc)
  loc <- sub(",?\\s+existing\\s+.*$", "", loc)

  # Split at colon but allow for Windows-style paths (single letter drive)
  m <- regexpr("^(.+?):((?:[0-9]+[-,])*[0-9]+)$", loc, perl = TRUE)
  if (m == -1L) return(list(path = loc, lines = integer(0)))

  starts <- attr(m, "capture.start")
  lengths <- attr(m, "capture.length")
  path_str  <- substr(loc, starts[1], starts[1] + lengths[1] - 1)
  lines_str <- substr(loc, starts[2], starts[2] + lengths[2] - 1)

  # Parse lines: "N", "N-M", "N,M,K"
  lines <- tryCatch({
    parts <- strsplit(lines_str, ",")[[1L]]
    unlist(lapply(parts, function(p) {
      rng <- as.integer(strsplit(p, "-")[[1L]])
      if (length(rng) == 2L) seq(rng[1L], rng[2L]) else rng
    }))
  }, error = function(e) integer(0))

  list(path = path_str, lines = lines)
}

# ── Distinctive pattern extractor ─────────────────────────────────────────────

# Extract distinctive patterns from problem text — identifiers, function calls,
# flag names, or quoted phrases.
# Returns a character vector of patterns (empty if none found).
extract_patterns <- function(problem) {
  if (is.na(problem) || !nzchar(problem)) return(character(0))

  patterns <- character(0)

  # Quoted strings (backtick or double-quote)
  bt    <- regmatches(problem, gregexpr("`[^`]{3,40}`", problem, perl = TRUE))[[1L]]
  dq    <- regmatches(problem, gregexpr('"[^"]{3,40}"', problem, perl = TRUE))[[1L]]
  # Function calls: word(
  fncal <- regmatches(problem, gregexpr("[a-zA-Z_][a-zA-Z0-9_.]{2,30}\\(", problem, perl = TRUE))[[1L]]
  # Identifiers: snake_case or camelCase with length >= 5 (less likely to be common words)
  ids   <- regmatches(problem, gregexpr("[a-zA-Z_][a-zA-Z0-9_]{4,30}", problem, perl = TRUE))[[1L]]

  # Clean up quotes
  bt    <- gsub("`", "", bt)
  dq    <- gsub('"', '', dq)
  # Strip parentheses from function calls
  fncal <- sub("\\($", "", fncal)

  candidates <- unique(c(bt, dq, fncal, ids))

  # Remove very common English words and short tokens
  stopwords <- c("with", "that", "this", "from", "when", "will", "there",
                 "which", "only", "still", "then", "each", "even", "have",
                 "also", "than", "they", "into", "been", "should", "would",
                 "could", "does", "true", "false", "null", "none", "uses",
                 "adds", "runs", "sets", "gets", "uses", "adds", "calls",
                 "error", "value", "check", "valid", "empty", "output",
                 "input", "first", "second", "third", "block", "cause",
                 "class", "state", "using", "after", "before", "where",
                 "while", "until", "other", "these", "those", "every",
                 "fails", "reads", "write", "makes", "build", "lines",
                 "change", "return", "always", "never", "existing")

  candidates <- candidates[!tolower(candidates) %in% stopwords]
  candidates <- candidates[nchar(candidates) >= 4L]

  # Prefer backtick-quoted (most precise) then function calls then identifiers
  ordered <- unique(c(
    candidates[candidates %in% bt],
    candidates[candidates %in% fncal],
    candidates
  ))

  # Return at most 3 patterns to keep checks fast
  head(ordered, 3L)
}

# ── Sub-finding classifier ────────────────────────────────────────────────────

# CONTEXT_LINES: how many lines above/below the target lines to search.
CONTEXT_LINES <- 15L

classify_finding <- function(finding, repo_root) {
  verdict <- "ambiguous"
  reason  <- "no distinctive pattern extracted"

  loc <- parse_location(finding$location)
  if (is.na(loc$path)) {
    return(list(verdict = "ambiguous",
                reason  = "could not parse location",
                finding = finding))
  }

  full_path <- file.path(repo_root, loc$path)

  if (!file.exists(full_path)) {
    return(list(verdict = "likely-fixed",
                reason  = paste0("file not found: ", loc$path),
                finding = finding))
  }

  # File exists — try to find the distinctive pattern
  patterns <- extract_patterns(finding$problem)
  if (length(patterns) == 0L) {
    return(list(verdict = "ambiguous",
                reason  = "no distinctive pattern could be extracted from Problem text",
                finding = finding))
  }

  file_lines <- tryCatch(readLines(full_path, warn = FALSE),
                         error = function(e) character(0))
  if (length(file_lines) == 0L) {
    return(list(verdict = "ambiguous",
                reason  = "file exists but could not be read",
                finding = finding))
  }

  # Build window: target lines ± CONTEXT_LINES, clamped to file extent
  target_lines <- loc$lines
  if (length(target_lines) == 0L) {
    # No specific lines; scan whole file
    window <- file_lines
  } else {
    lo <- max(1L, min(target_lines) - CONTEXT_LINES)
    hi <- min(length(file_lines), max(target_lines) + CONTEXT_LINES)
    window <- file_lines[lo:hi]
  }
  window_text <- paste(window, collapse = "\n")

  # Check if ANY pattern appears in the window (case-insensitive, fixed)
  found <- any(vapply(patterns, function(p) {
    grepl(p, window_text, fixed = TRUE, ignore.case = FALSE) ||
      grepl(tolower(p), tolower(window_text), fixed = TRUE)
  }, logical(1L)))

  if (found) {
    list(verdict = "still-present",
         reason  = paste0("pattern '", patterns[[1L]], "' found near ",
                          loc$path, ":", paste(range(target_lines), collapse = "-")),
         finding = finding)
  } else {
    list(verdict = "likely-fixed",
         reason  = paste0("pattern '", patterns[[1L]], "' absent from ",
                          loc$path, " ± ", CONTEXT_LINES, " lines"),
         finding = finding)
  }
}

# ── Review-level verdict ───────────────────────────────────────────────────────

# Weakest classification wins: still-present > ambiguous > likely-fixed
VERDICT_WEIGHT <- c("still-present" = 3L, "ambiguous" = 2L, "likely-fixed" = 1L)

classify_review <- function(review_row, repo_root, min_severity_num, sev_order) {
  # PR #1269 round 3: JSON-direct findings first (see
  # .review_structured_findings_list()'s docstring above for why this
  # file's regex path was already safe, and why this is added anyway).
  # Falls back to the regex path (llm#1265: `output` is empty on every row
  # post-v0.68.2; reconstruct "---"-separated finding blocks from
  # structured_output) only when there is no structured findings list to
  # read from at all (schema_version 0 / legacy rows).
  findings <- .review_structured_findings_list(review_row$structured_output)
  if (is.null(findings)) {
    findings <- parse_findings(.review_findings_text(
      review_row$output, review_row$structured_output
    ))
  }

  # Filter to sub-findings at or above threshold
  sev_names <- names(sev_order)
  findings_above_threshold <- Filter(function(f) {
    if (is.na(f$severity)) return(FALSE)
    # PR #1269 round 4 (review 10536 finding 1): `[[` on an atomic named
    # vector raises "subscript out of bounds" for a name not present,
    # instead of returning NA -- an off-vocabulary severity (or a casing
    # miss, before the capitalisation fix above) would abort classify_review()
    # for the WHOLE review, silently skipping the is.null/is.na guard on the
    # next line. `[` returns a length-1 NA for an unmatched name instead of
    # erroring.
    sev_num <- unname(sev_order[f$severity])
    if (is.null(sev_num) || is.na(sev_num)) return(FALSE)
    sev_num >= min_severity_num
  }, findings)

  if (length(findings_above_threshold) == 0L) {
    # No qualifying sub-findings → skip / likely-fixed
    return(list(
      review_id   = review_row$review_id,
      job_id      = review_row$job_id,
      git_ref     = review_row$git_ref,
      created_at  = review_row$created_at,
      verdict     = "likely-fixed",
      primary_loc = NA_character_,
      reason      = "no sub-findings at or above severity threshold",
      sub_results = list()
    ))
  }

  sub_results <- lapply(findings_above_threshold, function(f) {
    classify_finding(f, repo_root)
  })

  verdicts <- vapply(sub_results, function(r) r$verdict, character(1L))
  weights  <- VERDICT_WEIGHT[verdicts]
  worst_idx <- which.max(weights)
  review_verdict <- verdicts[[worst_idx]]

  primary_loc <- findings_above_threshold[[worst_idx]]$location
  primary_reason <- sub_results[[worst_idx]]$reason

  list(
    review_id   = review_row$review_id,
    job_id      = review_row$job_id,
    git_ref     = review_row$git_ref,
    created_at  = review_row$created_at,
    verdict     = review_verdict,
    primary_loc = primary_loc,
    reason      = primary_reason,
    sub_results = sub_results
  )
}

# ── Report generator ──────────────────────────────────────────────────────────

format_report <- function(results, repo, min_severity, dry_run, timestamp) {
  n_total     <- length(results)
  n_fixed     <- sum(vapply(results, function(r) r$verdict == "likely-fixed",  logical(1L)))
  n_present   <- sum(vapply(results, function(r) r$verdict == "still-present", logical(1L)))
  n_ambiguous <- sum(vapply(results, function(r) r$verdict == "ambiguous",     logical(1L)))

  mode_str <- if (dry_run) "DRY-RUN" else "APPLY"

  lines <- c(
    paste0("# roborev Stale-Finding Revalidation Report"),
    paste0(""),
    paste0("**Repo:** ", repo, "  |  **Min-severity:** ", min_severity,
           "  |  **Mode:** ", mode_str, "  |  **Run:** ", timestamp),
    paste0(""),
    paste0("## Summary"),
    paste0(""),
    paste0("| Category | Count |"),
    paste0("|---|---|"),
    paste0("| Open reviews checked | ", n_total, " |"),
    paste0("| Likely-fixed (candidate to close) | ", n_fixed, " |"),
    paste0("| Still-present (action needed) | ", n_present, " |"),
    paste0("| Ambiguous (needs human review) | ", n_ambiguous, " |"),
    paste0("")
  )

  # Likely-fixed table
  lines <- c(lines, "## Likely-Fixed (Candidates to Close)", "")
  fixed_results <- Filter(function(r) r$verdict == "likely-fixed", results)
  if (length(fixed_results) == 0L) {
    lines <- c(lines, "_None._", "")
  } else {
    lines <- c(lines,
      "| review_id | job_id | created_at | git_ref | primary Location | why-classified | suggested command |",
      "|---|---|---|---|---|---|---|"
    )
    for (r in fixed_results) {
      short_ref <- substr(r$git_ref, 1L, 8L)
      loc_str   <- if (is.na(r$primary_loc)) "—" else r$primary_loc
      cmd_str   <- paste0("`roborev close ", r$job_id, "`")
      lines <- c(lines, paste0(
        "| ", r$review_id, " | ", r$job_id, " | ", r$created_at,
        " | ", short_ref, " | ", loc_str, " | ", r$reason, " | ", cmd_str, " |"
      ))
    }
    lines <- c(lines, "")
  }

  # Still-present table
  lines <- c(lines, "## Still-Present (Action Needed)", "")
  present_results <- Filter(function(r) r$verdict == "still-present", results)
  if (length(present_results) == 0L) {
    lines <- c(lines, "_None._", "")
  } else {
    lines <- c(lines,
      "| review_id | job_id | primary Location | Problem excerpt |",
      "|---|---|---|---|"
    )
    for (r in present_results) {
      findings <- parse_findings(
        # Reconstruct — we only need the first High sub-finding
        paste0("**Problem**: ", r$reason)  # stub; use sub_results
      )
      # Get the first sub-finding problem text from sub_results
      first_problem <- ""
      if (length(r$sub_results) > 0L) {
        f1 <- r$sub_results[[1L]]$finding
        if (!is.null(f1) && !is.na(f1$problem)) {
          first_problem <- substr(f1$problem, 1L, 80L)
          if (nchar(f1$problem) > 80L) first_problem <- paste0(first_problem, "…")
        }
      }
      loc_str <- if (is.na(r$primary_loc)) "—" else r$primary_loc
      lines <- c(lines, paste0(
        "| ", r$review_id, " | ", r$job_id, " | ", loc_str,
        " | ", first_problem, " |"
      ))
    }
    lines <- c(lines, "")
  }

  # Ambiguous table
  lines <- c(lines, "## Ambiguous (Needs Human Review)", "")
  ambig_results <- Filter(function(r) r$verdict == "ambiguous", results)
  if (length(ambig_results) == 0L) {
    lines <- c(lines, "_None._", "")
  } else {
    lines <- c(lines,
      "| review_id | job_id | primary Location | reason |",
      "|---|---|---|---|"
    )
    for (r in ambig_results) {
      loc_str <- if (is.na(r$primary_loc)) "—" else r$primary_loc
      lines <- c(lines, paste0(
        "| ", r$review_id, " | ", r$job_id, " | ", loc_str, " | ", r$reason, " |"
      ))
    }
    lines <- c(lines, "")
  }

  # Recovery note
  lines <- c(lines,
    "---",
    "",
    "**Recovery:** `roborev close --reopen <job_id>` to reopen a mistakenly closed review.",
    ""
  )

  paste(lines, collapse = "\n")
}

# ── Apply mode ────────────────────────────────────────────────────────────────

apply_closures <- function(results, timestamp) {
  fixed_results <- Filter(function(r) r$verdict == "likely-fixed", results)
  cat(sprintf("apply mode: closing %d likely-fixed reviews\n", length(fixed_results)))

  results_log <- list()
  for (r in fixed_results) {
    comment_msg <- sprintf(
      "auto-closed: stale (re-validated, original file/line no longer matches) [run:%s]",
      timestamp
    )
    # roborev comment — pass as a single shell-quoted argument
    ret_comment <- system2(
      "roborev",
      args = c("comment", as.character(r$job_id), shQuote(comment_msg)),
      stdout = TRUE, stderr = TRUE
    )
    # roborev close
    ret_close <- system2(
      "roborev",
      args = c("close", as.character(r$job_id)),
      stdout = TRUE, stderr = TRUE
    )
    results_log[[length(results_log) + 1L]] <- list(
      job_id         = r$job_id,
      review_id      = r$review_id,
      comment_result = paste(ret_comment, collapse = " "),
      close_result   = paste(ret_close,   collapse = " ")
    )
    cat(sprintf("  closed job_id=%d review_id=%d\n", r$job_id, r$review_id))
  }
  invisible(results_log)
}

# ── Main ───────────────────────────────────────────────────────────────────────

main <- function(argv = commandArgs(trailingOnly = TRUE)) {
  args <- parse_args(argv)

  repo      <- args$repo
  min_sev   <- args$min_severity
  limit     <- args$limit
  apply_mode <- args$apply
  dry_run   <- !apply_mode

  repo_root <- args$repo_root
  if (is.null(repo_root)) {
    repo_root <- path.expand(file.path("~", "docs_gh", repo))
  }
  repo_root <- path.expand(repo_root)

  if (!dir.exists(repo_root)) {
    warning("repo-root not found: ", repo_root,
            "\nFile-existence checks will classify all findings as likely-fixed.")
  }

  timestamp <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  date_str  <- format(Sys.Date(), "%Y-%m-%d")

  out_path <- args$out
  if (is.null(out_path)) {
    out_dir  <- path.expand(file.path(
      "~", ".claude", "logs", "roborev_revalidate"
    ))
    if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
    out_path <- file.path(out_dir,
      paste0(repo, "_", min_sev, "_", date_str, ".md"))
  } else {
    out_path <- path.expand(out_path)
    out_dir  <- dirname(out_path)
    if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  }

  # Prefer RSQLite; fall back to python3 subprocess (native sqlite3 mode=ro).
  if (!requireNamespace("RSQLite", quietly = TRUE)) {
    python3 <- Sys.which("python3")
    if (!nzchar(python3)) stop("Neither RSQLite nor python3 available.")
    message("RSQLite not found; using python3 sqlite3 backend.")
  }

  cat(sprintf(
    "roborev_revalidate: repo=%s min-severity=%s limit=%d mode=%s\n",
    repo, min_sev, limit, if (dry_run) "DRY-RUN" else "APPLY"
  ))

  db <- open_reviews_db_ro()
  on.exit(close_reviews_db(db), add = TRUE)

  reviews <- fetch_open_reviews(db, repo, args$min_severity_num, args$sev_order, limit)
  cat(sprintf("Fetched %d open review(s) matching criteria.\n", nrow(reviews)))

  if (nrow(reviews) == 0L) {
    cat("Nothing to revalidate.\n")
    return(invisible(NULL))
  }

  results <- lapply(seq_len(nrow(reviews)), function(i) {
    classify_review(reviews[i, ], repo_root, args$min_severity_num, args$sev_order)
  })

  report <- format_report(results, repo, min_sev, dry_run, timestamp)

  writeLines(report, out_path)
  cat("Report written to:", out_path, "\n")
  cat(report, "\n")

  if (!dry_run) {
    apply_closures(results, timestamp)
  }

  # Return summary invisibly for programmatic use
  n_fixed   <- sum(vapply(results, function(r) r$verdict == "likely-fixed",  logical(1L)))
  n_present <- sum(vapply(results, function(r) r$verdict == "still-present", logical(1L)))
  n_ambig   <- sum(vapply(results, function(r) r$verdict == "ambiguous",     logical(1L)))
  invisible(list(
    results      = results,
    n_reviews    = length(results),
    n_fixed      = n_fixed,
    n_present    = n_present,
    n_ambiguous  = n_ambig,
    report_path  = out_path
  ))
}

# ── Entry point ────────────────────────────────────────────────────────────────
# Guard: skip auto-run when sourced for testing.
# Set ROBOREV_REVALIDATE_SKIP_MAIN=1 to source helpers without running main().

if (!interactive() && !nzchar(Sys.getenv("ROBOREV_REVALIDATE_SKIP_MAIN"))) {
  main()
}
