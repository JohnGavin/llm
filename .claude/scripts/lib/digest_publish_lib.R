# digest_publish_lib.R (llm#1389 follow-up)
#
# Pure helper the overnight email uses to report the scheduled
# private_terms_publish.sh job (daily 03:20) without the owner having to look.
# No DB, no network, no side effects, so it can be tested directly.
#
# Input: the job's housekeeping_runs heartbeat rows (written by the script
# itself on --apply: status 'ok' + rows_written = term count when it
# refreshed the digests, 'skipped' when the list was unchanged, 'failed' on
# any other exit).
#
# Rule (owner request: "stop creating manual work for me"): ONE failure is
# not the owner's problem -- the job retries tomorrow. "Needs you" needs TWO
# consecutive failed slots. A slot counts as failed when its run failed or
# when no run happened at all: a latest run older than 36 h means at least
# one daily slot was missed, older than 60 h means two.
#
#   runs  data.frame with columns status, rows_written, at (POSIXct, UTC)
#   now   POSIXct
# Returns list(state, bucket, label, n_terms, failures):
#   state  refreshed | current | one_failure | needs_you | indeterminate
#   bucket ok | failed | indeterminate   (the email's existing buckets; a
#          single failure is "ok" with a visible label, never an action row)

digest_publish_assess <- function(runs, now) {
  ind <- function(why) list(state = "indeterminate", bucket = "indeterminate",
                            label = sprintf("indeterminate — %s", why),
                            n_terms = NA_integer_, failures = NA_integer_)
  if (is.null(runs) || !is.data.frame(runs) || nrow(runs) == 0L ||
      !all(c("status", "rows_written", "at") %in% names(runs))) {
    return(ind("no run recorded for the digest publish job"))
  }
  runs <- runs[order(runs$at, decreasing = TRUE), , drop = FALSE]
  if (is.na(runs$at[[1L]]) || is.na(now)) return(ind("run time unreadable"))
  age_h <- as.numeric(difftime(now, runs$at[[1L]], units = "hours"))
  missed <- if (age_h > 36) as.integer(floor((age_h - 12) / 24)) else 0L
  good <- runs$status %in% c("ok", "skipped")
  lead <- 0L
  for (g in good) { if (g) break; lead <- lead + 1L }
  failures <- missed + lead

  if (failures >= 2L) {
    return(list(state = "needs_you", bucket = "failed",
                label = sprintf("needs you — %d consecutive failed or missing runs of the digest publish job", failures),
                n_terms = NA_integer_, failures = failures))
  }
  if (failures == 1L) {
    why <- if (missed == 1L) "no run in the last 36 h" else "last run failed"
    return(list(state = "one_failure", bucket = "ok",
                label = sprintf("ok — %s; retries tomorrow, nothing to do yet", why),
                n_terms = NA_integer_, failures = 1L))
  }
  st <- runs$status[[1L]]
  if (identical(st, "ok")) {
    n <- suppressWarnings(as.integer(runs$rows_written[[1L]]))
    if (is.na(n)) return(ind("refresh recorded without a term count"))
    return(list(state = "refreshed", bucket = "ok",
                label = sprintf("digests refreshed to %d terms", n),
                n_terms = n, failures = 0L))
  }
  list(state = "current", bucket = "ok", label = "digests current",
       n_terms = NA_integer_, failures = 0L)
}

# auto_merge_assess (llm#1471): the same idea for the 30-minute auto-merge
# sweep (bin/auto_merge_sweep.sh --apply). Heartbeat: status ok/failed,
# rows_written = PRs merged that run. ONE failure is quiet; "needs you" needs
# two consecutive failed runs, or no run at all for 2 h.
# Optional `mh` (merge history, merge_history_check.sh + the sync heartbeat):
# list(owner_verb, auto, tier2, alerts, sync_failed, check_rc). When given, the
# line gains "merges 7d: owner-verb N, auto M, tier2 K, alerts A", an alerting
# check or a failed sync is "needs you", and check_rc 3 is indeterminate.
# Returns list(state, bucket, label, merged_24h, failures).
auto_merge_assess <- function(runs, now, mh = NULL) {
  ind <- function(why) list(state = "indeterminate", bucket = "indeterminate",
                            label = sprintf("indeterminate — %s", why),
                            merged_24h = NA_integer_, failures = NA_integer_)
  if (is.null(runs) || !is.data.frame(runs) || nrow(runs) == 0L ||
      !all(c("status", "rows_written", "at") %in% names(runs))) {
    return(ind("no run recorded for the auto-merge sweep"))
  }
  runs <- runs[order(runs$at, decreasing = TRUE), , drop = FALSE]
  if (is.na(runs$at[[1L]]) || is.na(now)) return(ind("run time unreadable"))
  age_h <- as.numeric(difftime(now, runs$at[[1L]], units = "hours"))
  in24 <- as.numeric(difftime(now, runs$at, units = "hours")) <= 24
  m <- as.integer(sum(runs$rows_written[in24 & runs$status == "ok"], na.rm = TRUE))
  lead <- 0L
  for (g in runs$status == "ok") { if (g) break; lead <- lead + 1L }
  last <- if (identical(runs$status[[1L]], "ok")) "ok" else "failed"
  line <- sprintf("auto-merge: %d merged in 24 h, last run %s", m, last)
  mh_why <- character(0)
  if (!is.null(mh)) {
    line <- sprintf("%s; merges 7d: owner-verb %d, auto %d, tier2 %d, alerts %d", line,
                    as.integer(mh$owner_verb), as.integer(mh$auto), as.integer(mh$tier2), as.integer(mh$alerts))
    if (isTRUE(mh$alerts > 0)) mh_why <- c(mh_why, "merge-history check alerting")
    if (isTRUE(mh$sync_failed)) mh_why <- c(mh_why, "merge-history sync failed")
  }
  if (age_h > 2 || lead >= 2L || length(mh_why) > 0L) {
    why <- if (age_h > 2) "no run in the last 2 h" else if (lead >= 2L) sprintf("%d consecutive failed runs", lead) else paste(mh_why, collapse = "; ")
    return(list(state = "needs_you", bucket = "failed",
                label = sprintf("needs you — %s (%s)", line, why),
                merged_24h = m, failures = max(lead, 2L)))
  }
  if (!is.null(mh) && isTRUE(mh$check_rc == 3L)) {
    return(list(state = "indeterminate", bucket = "indeterminate",
                label = sprintf("indeterminate — %s (merge history could not be checked)", line),
                merged_24h = m, failures = lead))
  }
  list(state = if (lead == 1L) "one_failure" else "ok", bucket = "ok",
       label = line, merged_24h = m, failures = lead)
}
