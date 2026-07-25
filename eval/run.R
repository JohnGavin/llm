#!/usr/bin/env Rscript
# eval/run.R — Tier-1 deterministic runner for the agent-behaviour eval
# harness (llm#816). See eval/README.md for the three-tier plan.
#
# This is an MVP skeleton: Tier-1 (deterministic regex checks over fixture
# text) only. Tier-2 (LLM-as-judge) and Tier-3 (fuzzy judge) are deliberate
# follow-ups — see the TODO markers below and in eval/README.md.
#
# Usage (from the repo root, in the project nix shell):
#   nix-shell default.nix --run "Rscript eval/run.R"
# or, from inside eval/:
#   Rscript run.R
#
# No network access, no LLM calls. Loads every eval/tasks/*.yaml, evaluates
# its `check` against the referenced eval/fixtures/ file, and writes a
# scored report to eval/results/latest.json plus a human-readable summary
# to stdout.
#
# Exit codes:
#   0 — runner completed (regardless of individual task pass/fail)
#   1 — runner-level error (missing fixture, malformed task file, etc.)

suppressPackageStartupMessages({
  library(yaml)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x

# --- Locate eval/ regardless of invocation cwd -----------------------------
get_eval_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) == 1) {
    script_path <- normalizePath(sub("^--file=", "", file_arg))
    return(dirname(script_path))
  }
  # Fallbacks for interactive use / non-standard invocation.
  if (file.exists("run.R") && dir.exists("tasks")) {
    return(normalizePath("."))
  }
  if (file.exists("eval/run.R")) {
    return(normalizePath("eval"))
  }
  stop(
    "Cannot determine eval/ directory. Run via ",
    "'Rscript eval/run.R' from the repo root, or 'Rscript run.R' from ",
    "inside eval/."
  )
}

eval_dir     <- get_eval_dir()
tasks_dir    <- file.path(eval_dir, "tasks")
fixtures_dir <- file.path(eval_dir, "fixtures")
results_dir  <- file.path(eval_dir, "results")
dir.create(results_dir, showWarnings = FALSE, recursive = TRUE)

task_files <- sort(list.files(tasks_dir, pattern = "\\.ya?ml$", full.names = TRUE))
if (length(task_files) == 0) {
  stop("No task files found in ", tasks_dir)
}

# --- Tier-1 deterministic check --------------------------------------------
# A task's `check` block has two optional lists of regex patterns:
#   contains_all  — every pattern must match at least one line of the fixture
#   contains_none — no pattern may match any line of the fixture
# Matching is per-line (not across the whole file) so that `^`/`$` anchors
# behave predictably, and is case-insensitive because these are prose/log
# transcripts, not code identifiers.
check_task <- function(task) {
  fixture_path <- file.path(fixtures_dir, task$fixture)
  if (!file.exists(fixture_path)) {
    return(list(
      id = task$id %||% NA_character_,
      status = "error",
      message = paste("fixture not found:", fixture_path)
    ))
  }
  lines <- readLines(fixture_path, warn = FALSE)

  contains_all  <- task$check$contains_all  %||% list()
  contains_none <- task$check$contains_none %||% list()

  missing <- character(0)
  for (p in contains_all) {
    if (!any(grepl(p, lines, perl = TRUE, ignore.case = TRUE))) {
      missing <- c(missing, p)
    }
  }

  present <- character(0)
  for (p in contains_none) {
    if (any(grepl(p, lines, perl = TRUE, ignore.case = TRUE))) {
      present <- c(present, p)
    }
  }

  passed <- length(missing) == 0 && length(present) == 0
  list(
    id                  = task$id,
    category            = task$category %||% NA_character_,
    description         = task$description %||% NA_character_,
    fixture             = task$fixture,
    status              = if (passed) "pass" else "fail",
    missing_patterns    = missing,
    unexpected_patterns = present
  )
}

# --- Run every task ---------------------------------------------------------
results <- lapply(task_files, function(f) {
  task <- tryCatch(yaml::read_yaml(f), error = function(e) NULL)
  if (is.null(task)) {
    return(list(id = basename(f), status = "error", message = "malformed YAML"))
  }

  # TODO(llm#816 Tier-2): tasks with check_type != "deterministic" (e.g.
  # "llm_judge") will be evaluated by a calibrated LLM-as-judge runner in a
  # future slice. For this MVP they are reported as skipped, never silently
  # dropped, so the aggregate score always reflects the full task count.
  if (!identical(task$check_type, "deterministic")) {
    return(list(
      id = task$id %||% basename(f),
      status = "skipped",
      message = paste0(
        "check_type '", task$check_type %||% "<missing>",
        "' is not a Tier-1 deterministic check (see TODO in run.R)"
      )
    ))
  }

  tryCatch(
    check_task(task),
    error = function(e) {
      list(id = task$id %||% basename(f), status = "error", message = conditionMessage(e))
    }
  )
})

n_total   <- length(results)
n_pass    <- sum(vapply(results, function(r) identical(r$status, "pass"), logical(1)))
n_fail    <- sum(vapply(results, function(r) identical(r$status, "fail"), logical(1)))
n_error   <- sum(vapply(results, function(r) identical(r$status, "error"), logical(1)))
n_skipped <- sum(vapply(results, function(r) identical(r$status, "skipped"), logical(1)))

scoreable <- n_total - n_skipped
score_pct <- if (scoreable > 0) round(100 * n_pass / scoreable, 1) else NA_real_

report <- list(
  harness      = "llm eval MVP — Tier-1 deterministic runner (llm#816)",
  generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  n_total      = n_total,
  n_pass       = n_pass,
  n_fail       = n_fail,
  n_error      = n_error,
  n_skipped    = n_skipped,
  score_pct    = score_pct,
  tasks        = results
)

out_path <- file.path(results_dir, "latest.json")
jsonlite::write_json(report, out_path, auto_unbox = TRUE, pretty = TRUE, null = "null")

# --- Human-readable summary --------------------------------------------------
cat("== llm eval harness -- Tier-1 deterministic (MVP, llm#816) ==\n")
for (r in results) {
  label <- toupper(r$status)
  cat(sprintf("  [%-7s] %-32s %s\n", label, r$id, if (!is.null(r$category) && !is.na(r$category)) paste0("(", r$category, ")") else ""))
  if (identical(r$status, "fail")) {
    if (length(r$missing_patterns) > 0) {
      cat("            missing:  ", paste(r$missing_patterns, collapse = " | "), "\n")
    }
    if (length(r$unexpected_patterns) > 0) {
      cat("            unwanted: ", paste(r$unexpected_patterns, collapse = " | "), "\n")
    }
  }
  if (r$status %in% c("error", "skipped")) {
    cat("            note: ", r$message, "\n")
  }
}
cat(sprintf(
  "\nScore: %d/%d passed (%.1f%%) -- %d skipped (non-Tier-1), %d errors\n",
  n_pass, scoreable, score_pct, n_skipped, n_error
))
cat(sprintf("Report written to: %s\n", out_path))

if (n_error > 0) {
  quit(status = 1, save = "no")
}
quit(status = 0, save = "no")
