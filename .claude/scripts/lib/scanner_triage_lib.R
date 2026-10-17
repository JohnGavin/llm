# scanner_triage_lib.R (llm#1458 part 2)
#
# Pure helpers the overnight email uses to decide whether a scanner's NEW
# findings need the owner. No DB, no network, no side effects, so they can be
# tested directly.
#
#   policy  .claude/state/scanner_policy.tsv -- the ONE table mapping
#           (scanner, finding_type) to auto-fix | auto-file | human.
#           A finding type that is not listed is human (fail-safe).
#   outcome ~/.claude/logs/scanner_triage/<date>.json -- written by
#           scanner_triage.sh: what it fixed, filed and tracked for one run.
#
# A new finding stops being "action required" only when the policy says it is
# auto-fix or auto-file AND the outcome for THAT run says it was handled. A
# missing or unreadable outcome is INDETERMINATE, never silently ok
# (checks-must-distinguish-unknown).

if (!exists("%||%", mode = "function")) {
  `%||%` <- function(a, b) if (is.null(a) || length(a) == 0L || is.na(a[[1L]])) b else a
}

scanner_policy_read <- function(path) {
  if (is.null(path) || length(path) != 1L || is.na(path) || !file.exists(path)) return(NULL)
  p <- tryCatch(
    utils::read.delim(path, sep = "\t", quote = "", comment.char = "",
                      stringsAsFactors = FALSE, colClasses = "character"),
    error = function(e) NULL)
  if (is.null(p) || !all(c("scanner", "finding_type", "class") %in% names(p))) return(NULL)
  p
}

# Class of each finding type. Unlisted, duplicated, unknown-class or an
# unreadable policy all give "human".
scanner_class_of <- function(policy, scanner, types) {
  cls <- rep("human", length(types))
  if (is.null(policy) || length(types) == 0L) return(cls)
  for (i in seq_along(types)) {
    hit <- policy$class[policy$scanner == scanner & policy$finding_type == types[[i]]]
    if (length(hit) == 1L && hit %in% c("auto-fix", "auto-file")) cls[[i]] <- hit
  }
  cls
}

# Newest outcome file whose run_id matches. Returns
# list(status = "ok", outcome = <list>) or list(status = "missing" |
# "unreadable" | "indeterminate", why = <chr>).
scanner_triage_outcome_read <- function(dir, run_id, scanner) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    return(list(status = "unreadable", why = "jsonlite is not installed"))
  }
  if (is.null(dir) || !dir.exists(dir)) {
    return(list(status = "missing", why = "scanner triage has not run (no outcome directory)"))
  }
  files <- sort(list.files(dir, pattern = "\\.json$", full.names = TRUE), decreasing = TRUE)
  files <- utils::head(files, 5L)
  unreadable <- 0L
  for (f in files) {
    o <- tryCatch(jsonlite::fromJSON(f, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(o)) { unreadable <- unreadable + 1L; next }
    if (!identical(o$run_id, run_id) || !identical(o$scanner, scanner)) next
    if (!identical(o$status, "done")) {
      return(list(status = "indeterminate",
                  why = sprintf("scanner triage could not look: %s", o$why %||% "no reason recorded")))
    }
    return(list(status = "ok", outcome = o))
  }
  if (unreadable > 0L) {
    return(list(status = "unreadable", why = "an outcome file could not be parsed"))
  }
  list(status = "missing", why = "scanner triage has no outcome for this run")
}

.triage_type_count <- function(o, group, type) {
  v <- o$types[[group]][[type]]
  if (is.null(v) || length(v) != 1L || !is.numeric(v) || is.na(v)) return(0L)
  as.integer(v)
}

# new_types: character vector, the finding type of every NEW row.
# Returns list(needs_you, fixed, filed, tracked, unresolved, indeterminate,
# why, reverts, needs_types).
#   needs_you  rows only the owner can deal with (human class, or an auto
#              class the triage run did not get to, e.g. over the cap)
#   unresolved auto-class rows with no usable outcome (=> indeterminate)
scanner_triage_assess <- function(new_types, scanner, policy, outcome_res) {
  res <- list(needs_you = 0L, fixed = 0L, filed = 0L, tracked = 0L, unresolved = 0L,
              indeterminate = FALSE, why = NA_character_, reverts = character(0),
              needs_types = character(0))
  if (length(new_types) == 0L) return(res)
  n_by <- table(new_types)
  types <- names(n_by)
  cls <- scanner_class_of(policy, scanner, types)
  ok <- identical(outcome_res$status, "ok")
  for (i in seq_along(types)) {
    n <- as.integer(n_by[[i]])
    t <- types[[i]]
    if (cls[[i]] == "human") {
      res$needs_you <- res$needs_you + n
      res$needs_types <- c(res$needs_types, t)
      next
    }
    if (!ok) {
      res$unresolved <- res$unresolved + n
      next
    }
    o <- outcome_res$outcome
    left <- n
    take <- function(group) {
      k <- min(left, .triage_type_count(o, group, t))
      left <<- left - k
      k
    }
    res$fixed   <- res$fixed   + take("fixed")
    res$filed   <- res$filed   + take("filed")
    res$tracked <- res$tracked + take("tracked")
    take("already_ok")
    if (left > 0L) {
      res$needs_you <- res$needs_you + left
      res$needs_types <- c(res$needs_types, t)
    }
  }
  if (res$unresolved > 0L) {
    res$indeterminate <- TRUE
    res$why <- outcome_res$why
  }
  if (ok) {
    res$reverts <- unlist(lapply(outcome_res$outcome$reverts, as.character))
    if (is.null(res$reverts)) res$reverts <- character(0)
  }
  res$needs_types <- unique(res$needs_types)
  res
}
