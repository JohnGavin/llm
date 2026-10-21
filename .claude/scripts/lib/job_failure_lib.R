# job_failure_lib.R
#
# Pure helpers the overnight email uses to say WHY a scheduled job failed and
# whether that cause is already known. No DB, no network, no writes, so they
# can be tested directly. Same shape as scanner_triage_lib.R: ONE policy table,
# an unlisted case is "human", and anything unreadable is INDETERMINATE.
#
#   policy  .claude/state/job_failure_policy.tsv -- columns
#           job, cause_regex, class, issue, note
#           cause_regex is a POSIX ERE matched against the extracted cause
#           line, or "exit:<n>" to match the job's raw exit code.
#           class is known | self-heal | human.
#
# Three outcomes (checks-must-distinguish-unknown):
#   classified      a policy row matched         -> its class (known/self-heal/human)
#   unclassified    no row matched, evidence read -> "human"
#   INDETERMINATE   the policy table, the plist or the logs could not be read
#                   and no exit-code row matched -> "indeterminate", with a reason
# An empty, missing or unparseable table NEVER yields "known".

if (!exists("%||%", mode = "function")) {
  `%||%` <- function(a, b) if (is.null(a) || length(a) == 0L || is.na(a[[1L]])) b else a
}

.JF_CLASSES <- c("known", "self-heal", "human")
.JF_COLS    <- c("job", "cause_regex", "class", "issue", "note")
.JF_CAUSE_PATTERN <- paste0("error|ERROR|Error|FAILED|failed|exit=|lock|timed out|",
                            "unable to download|Failed to open archive|DNS not up")

# Read the policy. Returns list(status = "ok", policy = <data.frame>) or
# list(status = "missing" | "empty" | "unparseable", why = <chr>).
job_failure_policy_read <- function(path) {
  if (is.null(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    return(list(status = "missing", why = "no policy path given"))
  }
  if (!file.exists(path)) {
    return(list(status = "missing", why = "policy table not found"))
  }
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) NULL)
  if (is.null(lines)) {
    return(list(status = "unparseable", why = "policy table could not be read"))
  }
  lines <- sub("\r$", "", lines)
  lines <- iconv(lines, from = "UTF-8", to = "UTF-8", sub = "?")
  keep <- nzchar(trimws(lines)) & !startsWith(trimws(lines), "#")
  lines <- lines[keep]
  if (length(lines) == 0L) {
    return(list(status = "empty", why = "policy table has no header and no rows"))
  }
  hdr <- strsplit(lines[[1L]], "\t", fixed = TRUE)[[1L]]
  if (!identical(hdr, .JF_COLS)) {
    return(list(status = "unparseable",
                why = sprintf("policy header must be: %s", paste(.JF_COLS, collapse = " <tab> "))))
  }
  body <- lines[-1L]
  if (length(body) == 0L) {
    return(list(status = "empty", why = "policy table has a header but no rows"))
  }
  rows <- vector("list", length(body))
  for (i in seq_along(body)) {
    f <- strsplit(body[[i]], "\t", fixed = TRUE)[[1L]]
    if (length(f) > length(.JF_COLS) || length(f) < 3L) {
      return(list(status = "unparseable",
                  why = sprintf("policy row %d has %d field(s), want 3 to 5", i, length(f))))
    }
    f <- c(f, rep("", length(.JF_COLS) - length(f)))
    names(f) <- .JF_COLS
    if (!nzchar(f[["job"]]) || !nzchar(f[["cause_regex"]])) {
      return(list(status = "unparseable", why = sprintf("policy row %d has an empty job or cause_regex", i)))
    }
    if (!(f[["class"]] %in% .JF_CLASSES)) {
      return(list(status = "unparseable", why = sprintf("policy row %d has an unknown class", i)))
    }
    if (nzchar(f[["issue"]]) && !grepl("^[0-9]+$", f[["issue"]])) {
      return(list(status = "unparseable", why = sprintf("policy row %d has a non-numeric issue", i)))
    }
    rx <- f[["cause_regex"]]
    if (startsWith(rx, "exit:")) {
      if (!grepl("^exit:[0-9]+$", rx)) {
        return(list(status = "unparseable", why = sprintf("policy row %d has a malformed exit: match", i)))
      }
    } else {
      ok <- tryCatch({ grepl(rx, ""); TRUE }, error = function(e) FALSE,
                     warning = function(w) FALSE)
      if (!ok) {
        return(list(status = "unparseable", why = sprintf("policy row %d has an invalid regex", i)))
      }
    }
    rows[[i]] <- as.data.frame(as.list(f), stringsAsFactors = FALSE)
  }
  list(status = "ok", policy = do.call(rbind, rows))
}

# Last n lines of a file without reading all of it. NULL = unreadable or
# missing; character(0) = readable and empty.
.jf_tail_lines <- function(path, n = 200L) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) return(NULL)
  sz <- file.size(path)
  if (is.na(sz)) return(NULL)
  if (sz == 0) return(character(0))
  lim <- 262144
  raw <- tryCatch({
    con <- file(path, "rb")
    on.exit(close(con), add = TRUE)
    if (sz > lim) seek(con, sz - lim)
    readBin(con, "raw", n = min(sz, lim))
  }, error = function(e) NULL, warning = function(w) NULL)
  if (is.null(raw)) return(NULL)
  raw <- raw[raw != as.raw(0)]
  txt <- iconv(rawToChar(raw), from = "UTF-8", to = "UTF-8", sub = "?")
  if (is.na(txt)) return(NULL)
  x <- strsplit(txt, "[\r\n]+")[[1L]]
  if (sz > lim && length(x) > 1L) x <- x[-1L]   # first line is cut mid-way
  utils::tail(x, n)
}

# StandardOutPath / StandardErrorPath from the job's plist (XML form).
# Returns list(status = "ok", out = <chr|NA>, err = <chr|NA>) or
# list(status = "indeterminate", why = <chr>).
job_failure_log_paths <- function(label, plist_dirs) {
  for (d in plist_dirs) {
    f <- file.path(d, paste0(label, ".plist"))
    if (!file.exists(f)) next
    x <- tryCatch(paste(readLines(f, warn = FALSE), collapse = "\n"), error = function(e) NULL)
    if (is.null(x)) next
    key <- function(k) {
      m <- regmatches(x, regexec(sprintf("<key>%s</key>[[:space:]]*<string>([^<]*)</string>", k), x))[[1L]]
      if (length(m) < 2L) return(NA_character_)
      p <- gsub("&amp;", "&", m[[2L]], fixed = TRUE)
      path.expand(p)
    }
    o <- key("StandardOutPath"); e <- key("StandardErrorPath")
    if (is.na(o) && is.na(e)) {
      return(list(status = "indeterminate",
                  why = "plist has no readable StandardOutPath or StandardErrorPath"))
    }
    return(list(status = "ok", out = o, err = e))
  }
  list(status = "indeterminate", why = "plist not found")
}

# The cause line of a failing job: the last line matching an error-like word
# in the tail of its stdout AND stderr logs (stderr can be empty while the real
# error is in stdout), capped at 160 chars, control characters removed.
# Returns list(status = "ok", cause = <chr|NA>, why) or
# list(status = "indeterminate", cause = NA, why).
# cause = NA with status "ok" means: logs read, no error-like line in them.
job_failure_cause <- function(label, plist_dirs, n_lines = 200L) {
  lp <- job_failure_log_paths(label, plist_dirs)
  if (!identical(lp$status, "ok")) {
    return(list(status = "indeterminate", cause = NA_character_, why = lp$why))
  }
  o <- .jf_tail_lines(lp$out, n_lines)
  e <- .jf_tail_lines(lp$err, n_lines)
  if (is.null(o) && is.null(e)) {
    return(list(status = "indeterminate", cause = NA_character_,
                why = "log files not found or not readable"))
  }
  lines <- c(o, e)
  lines <- gsub("[[:cntrl:]]", " ", lines)
  hit <- lines[grepl(.JF_CAUSE_PATTERN, lines)]
  hit <- trimws(hit)
  hit <- hit[nzchar(hit)]
  cause <- if (length(hit) == 0L) NA_character_ else substr(hit[[length(hit)]], 1L, 160L)
  list(status = "ok", cause = cause, why = NA_character_)
}

# Assess one failing job.
#   label       plist label, e.g. "com.claude.self-review-stage1"
#   exit_code   its raw last exit code (anything coercible to integer, or NA)
#   policy_res  job_failure_policy_read() result
#   plist_dirs  directories to look for <label>.plist in, in order
# Returns list(class = known|self-heal|human|indeterminate, cause, issue, note,
# reason). class "human" with reason "no policy row matches" = unclassified.
job_failure_assess <- function(label, exit_code, policy_res, plist_dirs) {
  cs <- job_failure_cause(label, plist_dirs)
  out <- list(class = "indeterminate", cause = cs$cause, issue = "", note = "",
              reason = NA_character_)
  if (is.null(policy_res) || !identical(policy_res$status, "ok")) {
    out$reason <- sprintf("policy table %s: %s",
                          policy_res$status %||% "unavailable", policy_res$why %||% "no reason")
    return(out)
  }
  ec <- NA_integer_
  ec_chr <- as.character(exit_code)
  if (length(ec_chr) == 1L && !is.na(ec_chr) && grepl("^[0-9]+$", trimws(ec_chr))) {
    ec <- as.integer(trimws(ec_chr))
  }
  pol <- policy_res$policy
  rows <- pol[pol$job == label, , drop = FALSE]
  for (i in seq_len(nrow(rows))) {
    rx <- rows$cause_regex[[i]]
    hit <- if (startsWith(rx, "exit:")) {
      !is.na(ec) && ec == as.integer(sub("^exit:", "", rx))
    } else {
      !is.na(cs$cause) && isTRUE(tryCatch(grepl(rx, cs$cause),
                                          error = function(e) FALSE))
    }
    if (hit) {
      out$class  <- rows$class[[i]]
      out$issue  <- rows$issue[[i]]
      out$note   <- rows$note[[i]]
      out$reason <- sprintf("policy row %d for this job matched", i)
      return(out)
    }
  }
  if (!identical(cs$status, "ok")) {
    out$reason <- sprintf("cause unreadable: %s", cs$why)
    return(out)
  }
  out$class  <- "human"
  out$reason <- "no policy row matches"
  out
}

# Issue link for a policy issue number ("" when none).
job_failure_issue_url <- function(issue, repo = "JohnGavin/llm") {
  if (length(issue) != 1L || is.na(issue) || !grepl("^[0-9]+$", issue)) return("")
  sprintf("https://github.com/%s/issues/%s", repo, issue)
}

# Apply the assessment to one interpreted cron row.
#   res  the row's interpretation: list(bucket, label, [raw_vs_hb])
# A failed row (or a raw-exit vs heartbeat disagreement, res$raw_vs_hb) becomes
#   bucket "known"   policy class known | self-heal: one line + issue link,
#                    not counted as failed
#   unchanged        human / INDETERMINATE: stays in the headline, with the
#                    cause and the single decision needed
# A disagreement that no policy row resolves is returned exactly as it was.
job_failure_apply <- function(res, label, exit_code, policy_res, plist_dirs) {
  if (!identical(res$bucket, "failed") && !isTRUE(res$raw_vs_hb)) return(res)
  fa    <- job_failure_assess(label, exit_code, policy_res, plist_dirs)
  url   <- job_failure_issue_url(fa$issue)
  iss   <- if (nzchar(url)) sprintf("#%s", fa$issue) else ""
  cause <- if (is.na(fa$cause)) "no error line in the log" else fa$cause
  if (fa$class %in% c("known", "self-heal")) {
    return(list(bucket = "known", issue_url = url, issue_text = iss,
                label = sprintf("%s — %s (log: %s)", fa$class, fa$note, cause)))
  }
  if (isTRUE(res$raw_vs_hb)) return(res)
  if (identical(fa$class, "human")) {
    track <- if (nzchar(iss)) sprintf("tracked in %s", iss) else "not tracked"
    res$label <- sprintf(
      "%s — unexplained: %s. Decision: investigate (%s), or add a row to job_failure_policy.tsv",
      res$label, cause, track)
    res$issue_url <- url
    res$issue_text <- iss
    return(res)
  }
  res$label <- sprintf("%s — cause INDETERMINATE (%s). Decision: read the job log by hand",
                       res$label, fa$reason)
  res
}

# Headline counts: only UNEXPLAINED failures count as failed; known ones are
# tallied separately.
job_failure_tally <- function(buckets) {
  list(n_known = sum(buckets == "known", na.rm = TRUE),
       n_fail  = sum(buckets == "failed", na.rm = TRUE))
}

# ---- Automatic retry of self-heal jobs (job_failure_retry.sh) ----------------------
# The email runs job_failure_retry.sh before it reads the failure state. These
# helpers parse its stdout and fold the outcome into the row the email shows. Pure
# apart from the one system2() call in job_failure_retry_run (replaceable in tests).
#
#   outcome        row shown
#   recovered      ok (the job failed earlier and a single retry fixed it)
#   still-failing / already-retried / kickstart-failed
#                  failed, "retried once, still failing" (counted in the headline)
#   anything else  (would-retry, deferred, timeout) the row is left as it was
# If the retry could not run or could not be confirmed, job_failure_retry_note()
# returns ONE line saying so (checks-must-distinguish-unknown); it is never omitted.

.jf_retry_empty <- function() data.frame(label = character(0), outcome = character(0),
                                         stringsAsFactors = FALSE)

# "RETRY<TAB>label<TAB>outcome" lines -> data.frame(label, outcome). Other lines ignored.
job_failure_retry_parse <- function(lines) {
  lines <- as.character(lines)
  lines <- lines[!is.na(lines) & startsWith(lines, "RETRY\t")]
  if (length(lines) == 0L) return(.jf_retry_empty())
  f <- strsplit(lines, "\t", fixed = TRUE)
  f <- f[vapply(f, length, integer(1)) >= 3L]
  if (length(f) == 0L) return(.jf_retry_empty())
  data.frame(label = vapply(f, function(x) x[[2L]], character(1)),
             outcome = vapply(f, function(x) x[[3L]], character(1)),
             stringsAsFactors = FALSE)
}

# Run the retry script. apply = FALSE is report-only (changes nothing).
# Returns list(status = "ok" | "indeterminate", outcomes = <data.frame>, note = <chr>).
# `runner` (tests) takes the bash argument vector and returns the stdout lines with
# a "status" attribute, as system2(stdout = TRUE) does.
job_failure_retry_run <- function(script, apply = FALSE, wait = 300L, runner = NULL) {
  bad <- function(why) list(status = "indeterminate", outcomes = .jf_retry_empty(), note = why)
  if (is.null(script) || length(script) != 1L || is.na(script) || !nzchar(script) ||
      !file.exists(script)) {
    return(bad("retry script not found"))
  }
  args <- c(script, if (isTRUE(apply)) c("--apply", "--wait", as.character(wait)))
  out <- tryCatch(
    if (is.null(runner)) {
      withCallingHandlers(system2("bash", args, stdout = TRUE, stderr = FALSE),
                          warning = function(w) invokeRestart("muffleWarning"))
    } else runner(args),
    error = function(e) NULL)
  if (is.null(out)) return(bad("retry script could not be run"))
  rc <- attr(out, "status") %||% 0L
  outcomes <- job_failure_retry_parse(out)
  if (rc %in% c(0L, 1L)) return(list(status = "ok", outcomes = outcomes, note = ""))
  why <- if (rc == 3L) {
    ind <- out[startsWith(as.character(out), "INDETERMINATE:")]
    if (length(ind) > 0L) trimws(sub("^INDETERMINATE:", "", substr(ind[[1L]], 1L, 160L)))
    else "retry could not be confirmed"
  } else sprintf("retry script failed (exit %s)", rc)
  list(status = "indeterminate", outcomes = outcomes, note = why)
}

# One line for the email when the retry did not run cleanly; "" when it did.
job_failure_retry_note <- function(retry) {
  if (is.null(retry)) {
    return("Automatic retry of failed jobs: INDETERMINATE (the retry step did not run), so a failed job below may not have been retried.")
  }
  if (identical(retry$status, "ok")) return("")
  sprintf("Automatic retry of failed jobs: INDETERMINATE (%s), so a failed job below may not have been retried.",
          retry$note %||% "no reason given")
}

# Fold a retry outcome into one interpreted row (see the table above).
job_failure_retry_overlay <- function(res, label, retry) {
  if (is.null(retry) || is.null(retry$outcomes) || nrow(retry$outcomes) == 0L) return(res)
  if (!(res$bucket %in% c("known", "failed"))) return(res)
  o <- retry$outcomes$outcome[retry$outcomes$label == label]
  if (length(o) == 0L) return(res)
  o <- o[[length(o)]]
  if (identical(o, "recovered")) {
    return(list(bucket = "ok", label = "ok — failed earlier, recovered after one automatic retry"))
  }
  if (o %in% c("still-failing", "already-retried", "kickstart-failed")) {
    res$bucket <- "failed"
    res$label  <- sprintf("retried once, still failing — %s", res$label)
    return(res)
  }
  res
}
