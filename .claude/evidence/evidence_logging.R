# Evidence Logging Functions for Claude Code
# Source this file to enable evidence logging in R sessions

#' Log a session action
#'
#' @param action Character. The action performed (e.g., "edit", "test", "commit")
#' @param tool Character. The tool used (e.g., "Edit", "Bash", "Task")
#' @param agent Character. The agent used, if any
#' @param model Character. The model used (haiku, sonnet, opus)
#' @param duration_sec Numeric. Duration in seconds
#' @param tokens_in Integer. Input tokens
#' @param tokens_out Integer. Output tokens
#' @param log_file Character. Path to log file
#'
#' @export
log_session_action <- function(action,
                               tool = NULL,
                               agent = NULL,
                               model = NULL,
                               duration_sec = NULL,
                               tokens_in = NULL,
                               tokens_out = NULL,
                               log_file = "~/.claude/evidence/session_log.jsonl") {

  log_file <- path.expand(log_file)

  entry <- list(
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    action = action,
    tool = tool,
    agent = agent,
    model = model,
    duration_sec = duration_sec,
    tokens_in = tokens_in,
    tokens_out = tokens_out
  )

  # Remove NULL values
entry <- entry[!sapply(entry, is.null)]

  # Ensure directory exists
  dir.create(dirname(log_file), recursive = TRUE, showWarnings = FALSE)

  cat(jsonlite::toJSON(entry, auto_unbox = TRUE), "\n",
      file = log_file, append = TRUE)

  invisible(entry)
}

#' Log a verification result
#'
#' @param claim Character. The claim being verified
#' @param evidence_type Character. Type of evidence (command_output, file_check, etc.)
#' @param verdict Character. PASS or FAIL
#' @param evidence_text Character. The actual evidence (truncated to 500 chars)
#' @param log_file Character. Path to log file
#'
#' @export
log_verification <- function(claim,
                             evidence_type,
                             verdict,
                             evidence_text,
                             log_file = "~/.claude/evidence/verification_log.jsonl") {

  log_file <- path.expand(log_file)

  entry <- list(
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    claim = claim,
    evidence_type = evidence_type,
    verdict = verdict,
    evidence_text = substr(as.character(evidence_text), 1, 500)
  )

  dir.create(dirname(log_file), recursive = TRUE, showWarnings = FALSE)

  cat(jsonlite::toJSON(entry, auto_unbox = TRUE), "\n",
      file = log_file, append = TRUE)

  invisible(entry)
}

#' Log quality gate assessment result
#'
#' @param project Character. Project/package name
#' @param result List. Result from assess_quality_gate()
#' @param log_file Character. Path to parquet log file
#'
#' @export
log_quality_gate <- function(project,
                             result,
                             log_file = "~/.claude/evidence/quality_history.parquet") {

  log_file <- path.expand(log_file)

  entry <- tibble::tibble(
    timestamp = Sys.time(),
    project = project,
    overall_score = result$overall_score %||% NA_real_,
    gate_level = result$gate_level %||% "unknown",
    coverage = result$metrics$coverage$score %||% NA_real_,
    check_score = result$metrics$check$score %||% NA_real_,
    doc_score = result$metrics$documentation$score %||% NA_real_,
    defensive_score = result$metrics$defensive$score %||% NA_real_
  )

  dir.create(dirname(log_file), recursive = TRUE, showWarnings = FALSE)

  if (file.exists(log_file)) {
    existing <- arrow::read_parquet(log_file)
    combined <- dplyr::bind_rows(existing, entry)
  } else {
    combined <- entry
  }

  arrow::write_parquet(combined, log_file)

  invisible(entry)
}

#' Log parallel execution metrics
#'
#' @param n_tasks Integer. Number of parallel tasks
#' @param models_used Character vector. Models used
#' @param wall_clock_sec Numeric. Wall clock time (parallel)
#' @param sum_duration_sec Numeric. Sum of individual durations (if sequential)
#' @param total_tokens Integer. Total tokens used
#' @param log_file Character. Path to log file
#'
#' @export
log_parallel_execution <- function(n_tasks,
                                   models_used,
                                   wall_clock_sec,
                                   sum_duration_sec,
                                   total_tokens = NULL,
                                   log_file = "~/.claude/evidence/parallel_execution_log.jsonl") {

  log_file <- path.expand(log_file)

  entry <- list(
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    n_parallel = n_tasks,
    models_used = paste(unique(models_used), collapse = ","),
    wall_clock_sec = wall_clock_sec,
    sum_duration_sec = sum_duration_sec,
    speedup = sum_duration_sec / wall_clock_sec,
    total_tokens = total_tokens
  )

  entry <- entry[!sapply(entry, is.null)]

  dir.create(dirname(log_file), recursive = TRUE, showWarnings = FALSE)

  cat(jsonlite::toJSON(entry, auto_unbox = TRUE), "\n",
      file = log_file, append = TRUE)

  invisible(entry)
}

# --- Reading Functions ---

#' Read session log
#'
#' @param log_file Character. Path to log file
#' @param n Integer. Maximum number of lines to read (NULL for all)
#'
#' @return tibble of session actions
#' @export
read_session_log <- function(log_file = "~/.claude/evidence/session_log.jsonl",
                             n = NULL) {

  log_file <- path.expand(log_file)

  if (!file.exists(log_file)) {
    return(tibble::tibble(
      timestamp = character(),
      action = character(),
      tool = character(),
      agent = character(),
      model = character()
    ))
  }

  lines <- if (is.null(n)) readLines(log_file) else readLines(log_file, n = n)

  if (length(lines) == 0) {
    return(tibble::tibble(
      timestamp = character(),
      action = character(),
      tool = character(),
      agent = character(),
      model = character()
    ))
  }

  purrr::map_dfr(lines, ~{
    tryCatch(
      tibble::as_tibble(jsonlite::fromJSON(.x)),
      error = function(e) NULL
    )
  })
}

#' Read verification log
#'
#' @param log_file Character. Path to log file
#' @param n Integer. Maximum number of lines to read
#'
#' @return tibble of verifications
#' @export
read_verification_log <- function(log_file = "~/.claude/evidence/verification_log.jsonl",
                                  n = NULL) {

  log_file <- path.expand(log_file)

  if (!file.exists(log_file)) {
    return(tibble::tibble(
      timestamp = character(),
      claim = character(),
      evidence_type = character(),
      verdict = character(),
      evidence_text = character()
    ))
  }

  lines <- if (is.null(n)) readLines(log_file) else readLines(log_file, n = n)

  if (length(lines) == 0) return(tibble::tibble())

  purrr::map_dfr(lines, ~{
    tryCatch(
      tibble::as_tibble(jsonlite::fromJSON(.x)),
      error = function(e) NULL
    )
  })
}

#' Read quality history
#'
#' @param log_file Character. Path to parquet file
#'
#' @return tibble of quality scores
#' @export
read_quality_history <- function(log_file = "~/.claude/evidence/quality_history.parquet") {

  log_file <- path.expand(log_file)

  if (!file.exists(log_file)) {
    return(tibble::tibble(
      timestamp = as.POSIXct(character()),
      project = character(),
      overall_score = numeric(),
      gate_level = character()
    ))
  }

  arrow::read_parquet(log_file)
}

#' Read parallel execution log
#'
#' @param log_file Character. Path to log file
#'
#' @return tibble of parallel executions
#' @export
read_parallel_log <- function(log_file = "~/.claude/evidence/parallel_execution_log.jsonl") {

  log_file <- path.expand(log_file)

  if (!file.exists(log_file)) {
    return(tibble::tibble(
      timestamp = character(),
      n_parallel = integer(),
      speedup = numeric()
    ))
  }

  lines <- readLines(log_file)

  if (length(lines) == 0) return(tibble::tibble())

  purrr::map_dfr(lines, ~{
    tryCatch(
      tibble::as_tibble(jsonlite::fromJSON(.x)),
      error = function(e) NULL
    )
  })
}

# --- Summary Functions ---

#' Summarize evidence
#'
#' @param session_log tibble from read_session_log()
#' @param quality_history tibble from read_quality_history()
#'
#' @return List with summary statistics
#' @export
summarize_evidence <- function(session_log = read_session_log(),
                               quality_history = read_quality_history()) {

  list(
    total_actions = nrow(session_log),
    tools_used = if (nrow(session_log) > 0) {
      dplyr::count(session_log, tool, sort = TRUE)
    } else {
      tibble::tibble(tool = character(), n = integer())
    },
    agents_used = if (nrow(session_log) > 0 && "agent" %in% names(session_log)) {
      dplyr::count(dplyr::filter(session_log, !is.na(agent)), agent, sort = TRUE)
    } else {
      tibble::tibble(agent = character(), n = integer())
    },
    quality_assessments = nrow(quality_history),
    avg_quality_score = if (nrow(quality_history) > 0) {
      mean(quality_history$overall_score, na.rm = TRUE)
    } else {
      NA_real_
    },
    gate_distribution = if (nrow(quality_history) > 0) {
      dplyr::count(quality_history, gate_level, sort = TRUE)
    } else {
      tibble::tibble(gate_level = character(), n = integer())
    }
  )
}

# Null coalesce operator if not available
if (!exists("%||%")) {
  `%||%` <- function(x, y) if (is.null(x)) y else x
}
