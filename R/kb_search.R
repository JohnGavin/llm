# kb_search.R — Lexical (BM25) search over the local knowledge base
#
# Phase 3a: DuckDB fts extension, BM25 scoring.
# Phase 3b (deferred): vss + embeddings + RRF re-ranking (llm#645).
#
# Two exported functions:
#   kb_index()  — build / rebuild the FTS index
#   kb_search() — query the index (read-only connection)
#
# The index is written to a caller-supplied db_path so it never lands inside
# the knowledge/ directory (which is a separate local-only git repo).

# ── Internal helpers ──────────────────────────────────────────────────────────

#' Split a single markdown/qmd file into searchable chunks
#'
#' Chunks are split on markdown headings (`^#{1,6} `).  Files with no headings
#' are split into ~40-line blocks instead.  Each chunk records the source path,
#' the heading text (or `"(preamble)"` / `"(block N)"`), the start line, and
#' the full chunk text.
#'
#' @param path Character scalar — absolute path to the file.
#' @return A data.frame with columns: path, heading, line_start, text.
#' @noRd
chunk_file <- function(path) {
  stopifnot(is.character(path), length(path) == 1L, nzchar(path))

  lines <- tryCatch(
    readLines(path, warn = FALSE),
    error = function(e) {
      cli::cli_warn(c(
        "!" = "Could not read {.file {path}}",
        "i" = conditionMessage(e)
      ))
      character(0L)
    }
  )

  if (length(lines) == 0L) {
    return(data.frame(
      path       = character(0L),
      heading    = character(0L),
      line_start = integer(0L),
      text       = character(0L),
      stringsAsFactors = FALSE
    ))
  }

  heading_idx <- grep("^#{1,6} ", lines)

  if (length(heading_idx) == 0L) {
    # No headings — fall back to ~40-line blocks
    n_lines  <- length(lines)
    block_sz <- 40L
    starts   <- seq(1L, n_lines, by = block_sz)
    chunks   <- lapply(seq_along(starts), function(i) {
      s <- starts[[i]]
      e <- min(starts[[i]] + block_sz - 1L, n_lines)
      list(
        heading    = sprintf("(block %d)", i),
        line_start = s,
        text       = paste(lines[s:e], collapse = "\n")
      )
    })
  } else {
    # Heading-based split
    # Each chunk: from heading line to one line before next heading (or EOF)
    ends   <- c(heading_idx[-1L] - 1L, length(lines))
    # Optional preamble before the first heading
    chunks <- list()
    if (heading_idx[[1L]] > 1L) {
      preamble_text <- paste(lines[1L:(heading_idx[[1L]] - 1L)], collapse = "\n")
      if (nzchar(trimws(preamble_text))) {
        chunks <- c(chunks, list(list(
          heading    = "(preamble)",
          line_start = 1L,
          text       = preamble_text
        )))
      }
    }
    for (i in seq_along(heading_idx)) {
      s    <- heading_idx[[i]]
      e    <- ends[[i]]
      text <- paste(lines[s:e], collapse = "\n")
      chunks <- c(chunks, list(list(
        heading    = trimws(sub("^#{1,6} ", "", lines[[s]])),
        line_start = s,
        text       = text
      )))
    }
  }

  if (length(chunks) == 0L) {
    return(data.frame(
      path       = character(0L),
      heading    = character(0L),
      line_start = integer(0L),
      text       = character(0L),
      stringsAsFactors = FALSE
    ))
  }

  data.frame(
    path       = path,
    heading    = vapply(chunks, `[[`, character(1L), "heading"),
    line_start = vapply(chunks, `[[`, integer(1L),   "line_start"),
    text       = vapply(chunks, `[[`, character(1L), "text"),
    stringsAsFactors = FALSE
  )
}

# ── Exported API ──────────────────────────────────────────────────────────────

#' Build a DuckDB FTS index over a knowledge-base directory
#'
#' Recursively finds all `.md` and `.qmd` files under `dir`, splits them into
#' chunks on markdown headings, writes a DuckDB table called `chunks`, and
#' creates a BM25 full-text-search index via `PRAGMA create_fts_index`.
#'
#' The resulting database at `db_path` can be queried with [kb_search()].
#'
#' @param dir Character scalar. Root directory to index (recursively).
#' @param db_path Character scalar. Path for the output DuckDB file.  Will be
#'   created (or overwritten) by DuckDB.  Use a path ending in `.kbidx.duckdb`
#'   or inside a `_kb_index/` directory so that the pattern in `.gitignore`
#'   prevents accidental commits.
#'
#' @return Invisibly, the number of chunk rows written to the database.
#' @export
#'
#' @examples
#' \dontrun{
#' # Index the knowledge base into a temp location
#' db_path <- file.path(tempdir(), "kb.kbidx.duckdb")
#' n <- kb_index("~/docs_gh/llm/knowledge", db_path)
#' message(n, " chunks indexed")
#' }
kb_index <- function(dir, db_path) {
  checkmate::assert_string(dir, min.chars = 1L)
  checkmate::assert_string(db_path, min.chars = 1L)

  if (!file.exists(dir)) {
    cli::cli_abort(c(
      "x" = "Directory {.path {dir}} does not exist.",
      "i" = "Supply a valid path to a knowledge-base directory."
    ))
  }

  # Collect all markdown / qmd files
  md_files <- list.files(
    dir,
    pattern    = "\\.(md|qmd)$",
    recursive  = TRUE,
    full.names = TRUE
  )

  if (length(md_files) == 0L) {
    cli::cli_warn(c(
      "!" = "No .md / .qmd files found under {.path {dir}}.",
      "i" = "Index will be empty."
    ))
  }

  # Chunk every file
  chunk_list <- lapply(md_files, chunk_file)
  chunks_df  <- do.call(rbind, chunk_list)

  if (is.null(chunks_df) || nrow(chunks_df) == 0L) {
    chunks_df <- data.frame(
      path       = character(0L),
      heading    = character(0L),
      line_start = integer(0L),
      text       = character(0L),
      stringsAsFactors = FALSE
    )
  }

  n_chunks <- nrow(chunks_df)
  chunks_df$chunk_id <- seq_len(n_chunks)

  # Write to DuckDB (creates or overwrites)
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, "LOAD fts")

  # Drop existing table if present (overwrite semantics)
  DBI::dbExecute(con, "DROP TABLE IF EXISTS chunks")

  DBI::dbExecute(con, "
    CREATE TABLE chunks (
      chunk_id   BIGINT PRIMARY KEY,
      path       VARCHAR,
      heading    VARCHAR,
      line_start INTEGER,
      text       VARCHAR
    )
  ")

  if (n_chunks > 0L) {
    DBI::dbAppendTable(
      con, "chunks",
      chunks_df[, c("chunk_id", "path", "heading", "line_start", "text")]
    )
  }

  # Build the BM25 FTS index (overwrite=1 so re-indexing is safe)
  DBI::dbExecute(
    con,
    "PRAGMA create_fts_index('chunks', 'chunk_id', 'text', overwrite=1)"
  )

  cli::cli_inform(c(
    "v" = "Indexed {n_chunks} chunk{?s} from {length(md_files)} file{?s}.",
    "i" = "Database: {.path {db_path}}"
  ))

  invisible(n_chunks)
}


#' Search the knowledge-base FTS index using BM25
#'
#' Opens `db_path` in **read-only** mode and queries the BM25 index built by
#' [kb_index()].  Returns a tibble with provenance (`path`, `line_start`) in
#' every row, ordered by relevance score descending.
#'
#' @param query Character scalar. The search query string.
#' @param db_path Character scalar. Path to the DuckDB index file created by
#'   [kb_index()].
#' @param k Integer scalar (default 10). Maximum number of results to return.
#'
#' @return A [tibble::tibble] with columns:
#'   \describe{
#'     \item{path}{Absolute path of the source file.}
#'     \item{heading}{Heading text for the chunk (or `"(preamble)"` /
#'       `"(block N)"` for heading-less sections).}
#'     \item{line_start}{Line number in the source file where this chunk begins.}
#'     \item{score}{BM25 relevance score (higher is better).}
#'     \item{snippet}{First 200 characters of the chunk text.}
#'   }
#' @export
#'
#' @examples
#' \dontrun{
#' db_path <- file.path(tempdir(), "kb.kbidx.duckdb")
#' kb_index("~/docs_gh/llm/knowledge", db_path)
#' results <- kb_search("agent dispatch worktree", db_path)
#' print(results)
#' }
kb_search <- function(query, db_path, k = 10L) {
  checkmate::assert_string(query, min.chars = 1L)
  checkmate::assert_string(db_path, min.chars = 1L)
  checkmate::assert_integerish(k, lower = 1L, len = 1L)

  if (!file.exists(db_path)) {
    cli::cli_abort(c(
      "x" = "Index database {.path {db_path}} not found.",
      "i" = "Run {.fn kb_index} to build the index first."
    ))
  }

  k <- as.integer(k)

  # Read-only connection — the safety model for a future read-only MCP server
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, "LOAD fts")

  # Parameterised query: positional ? avoids any injection risk from the query
  # string.  DuckDB fts_main_chunks.match_bm25() accepts the query as its
  # second argument and returns NULL for non-matching rows.
  stmt <- DBI::dbSendQuery(
    con,
    "SELECT
       c.path,
       c.heading,
       c.line_start,
       fts_main_chunks.match_bm25(c.chunk_id, ?) AS score,
       SUBSTRING(c.text, 1, 200)                   AS snippet
     FROM chunks AS c
     WHERE score IS NOT NULL
       AND score > 0
     ORDER BY score DESC
     LIMIT ?"
  )
  DBI::dbBind(stmt, list(query, k))
  res <- DBI::dbFetch(stmt)
  DBI::dbClearResult(stmt)

  tibble::as_tibble(res)
}
