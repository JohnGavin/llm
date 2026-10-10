# self_review_content_signals.R
#
# Library for the two "content" sections of the overnight self-review email
# (llm#235 steps 1-2), sourced by send_overnight_self_review_email.R:
#
#   1. Conversation signals -- repeated user corrections and repeated command
#      failures, read from the daily digest JSON written by
#      codex_overnight_learning.py (launchd com.claude.codex-overnight-learning,
#      06:10; output ~/.codex/learning/YYYY-MM-DD-summary.json). The digest is
#      reused as-is: this file never reads a transcript.
#   2. Code review -- open roborev findings created in the last 24 h, by
#      severity, per repo, from ~/.roborev/reviews.db (read-only).
#
# Every section distinguishes three outcomes and never lets two share a
# rendering (checks-must-distinguish-unknown):
#   data present            -> shown
#   data present, nothing   -> an explicit "no repeated signals" / "0 open"
#   could not read the data -> a visible "... unavailable: <reason>" line
#
# Callers must have sourced email_styles.R first (colour/font constants).
# Pure functions: no globals are read or written, so they are unit-testable
# without the live unified.duckdb (tests/testthat/test-self-review-content-
# signals.R).

# ── Shared helpers ───────────────────────────────────────────────────────────

.scr_html_escape <- function(text) {
  text <- gsub("&", "&amp;", text, fixed = TRUE)
  text <- gsub("<", "&lt;", text, fixed = TRUE)
  text <- gsub(">", "&gt;", text, fixed = TRUE)
  gsub("\"", "&quot;", text, fixed = TRUE)
}

# Mirrors codex_overnight_learning.py's PATH_RE / URL_RE so anything shown here
# is redacted at least as strictly as the digest itself, even if a future
# digest field stops being pre-normalised. Also truncates (the digest keeps
# correction text to ~90 chars) and HTML-escapes.
.SCR_PATH_RE <- "/Users/[A-Za-z0-9._-]+(?:/[^\\s\"']+)?"
.SCR_URL_RE  <- "https?://\\S+"
.SCR_MAX_TITLE_CHARS <- 90L

scr_redact <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub(.SCR_URL_RE, "<URL>", x, perl = TRUE)
  x <- gsub(.SCR_PATH_RE, "<PATH>", x, perl = TRUE)
  x <- trimws(gsub("[[:space:]]+", " ", x))
  too_long <- nchar(x) > .SCR_MAX_TITLE_CHARS
  x[too_long] <- paste0(substr(x[too_long], 1L, .SCR_MAX_TITLE_CHARS), "…")
  .scr_html_escape(x)
}

.scr_unavailable_html <- function(label, reason) {
  sprintf(
    '<p style="color:%s;font-size:%s;">&#9888; %s unavailable: %s. This is NOT the same as &ldquo;nothing found&rdquo;.</p>',
    ACCENT_ORANGE, EMAIL_FONT_BODY, label, scr_redact(reason)
  )
}

.scr_table <- function(headers, rows_html, aligns) {
  th <- paste(sprintf('<th style="padding:5px 10px;text-align:%s;">%s</th>', aligns, headers),
              collapse = "")
  sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead><tr style="background-color:%s;">%s</tr></thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, th, paste(rows_html, collapse = "\n")
  )
}

# ── Step 1: conversation signals from the learning digest ────────────────────

SCR_DIGEST_MAX_AGE_HOURS <- 26

.scr_parse_utc <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) return(as.POSIXct(NA))
  # The digest writes UTC (isoformat of a UTC datetime): "...T05:10:04.5+00:00".
  # Any other offset is refused rather than silently misread.
  if (!grepl("(\\+00:00|Z)$", x)) return(as.POSIXct(NA))
  core <- sub("(\\.[0-9]+)?(\\+00:00|Z)$", "", x)
  as.POSIXct(core, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
}

.scr_digest_unavailable <- function(reason) {
  list(status = "unavailable", reason = reason, date = NA_character_)
}

# Reads the newest YYYY-MM-DD-summary.json in `dir`. Returns a list with
# status in {"fresh", "empty", "empty_input", "unavailable"}:
#   fresh        digest within max_age_h and has >=1 correction/failure signal
#   empty        digest within max_age_h, analysed sessions, zero such signals
#   empty_input  digest within max_age_h but analysed 0 sessions (nothing to
#                detect; must not read as "no repeated signals")
#   unavailable  missing / stale / unparseable, with `reason`
scr_read_digest <- function(dir, now = Sys.time(), max_age_h = SCR_DIGEST_MAX_AGE_HOURS) {
  if (!dir.exists(dir)) {
    return(.scr_digest_unavailable("no digest directory found"))
  }
  files <- list.files(dir, pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}-summary\\.json$",
                      full.names = TRUE)
  if (length(files) == 0L) {
    return(.scr_digest_unavailable("no digest files found"))
  }
  path <- sort(files)[[length(files)]]

  data <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                   error = function(e) NULL)
  if (is.null(data) || !is.list(data)) {
    return(.scr_digest_unavailable(
      sprintf("latest digest (%s) is not valid JSON", basename(path))))
  }
  if (!is.list(data[["all_signals"]])) {
    return(.scr_digest_unavailable(
      sprintf("latest digest (%s) has no all_signals list", basename(path))))
  }

  generated <- .scr_parse_utc(data[["generated_at_utc"]])
  if (is.na(generated)) {
    return(.scr_digest_unavailable(
      sprintf("latest digest (%s) has no readable generated_at_utc", basename(path))))
  }
  age_h <- as.numeric(difftime(now, generated, units = "hours"))
  if (age_h > max_age_h) {
    return(.scr_digest_unavailable(sprintf(
      "latest digest is stale (%s, generated %.0f h ago, limit %.0f h): the learning job did not run today",
      substr(basename(path), 1L, 10L), age_h, max_age_h)))
  }
  if (age_h < -1) {
    return(.scr_digest_unavailable(
      "latest digest claims to be generated in the future (clock or file error)"))
  }

  pick <- function(category) {
    sigs <- Filter(function(s) is.list(s) && identical(s[["category"]], category),
                   data[["all_signals"]])
    if (length(sigs) == 0L) {
      return(data.frame(title = character(0), repetitions = integer(0),
                        sessions = integer(0), stringsAsFactors = FALSE))
    }
    df <- data.frame(
      title       = vapply(sigs, function(s) as.character(s[["title"]] %scr_or% ""), character(1)),
      repetitions = vapply(sigs, function(s) as.integer(s[["repetition_count"]] %scr_or% 0L), integer(1)),
      sessions    = vapply(sigs, function(s) as.integer(s[["session_count"]] %scr_or% 0L), integer(1)),
      stringsAsFactors = FALSE
    )
    df[order(-df$sessions, -df$repetitions, df$title), , drop = FALSE]
  }

  corrections <- pick("correction")
  failures    <- pick("failure")
  sc <- data[["session_count"]]
  n_sessions <- if (is.numeric(sc) && length(sc) == 1L && !is.na(sc)) as.integer(sc) else NA_integer_

  status <- if (nrow(corrections) + nrow(failures) > 0L) {
    "fresh"
  } else if (!is.na(n_sessions) && n_sessions == 0L) {
    "empty_input"
  } else {
    "empty"
  }

  list(status = status, reason = NA_character_,
       date = as.character(data[["summary_date"]] %scr_or% substr(basename(path), 1L, 10L)),
       generated = generated, age_h = age_h, n_sessions = n_sessions,
       corrections = corrections, failures = failures)
}

# Returns list(summary, body, color) for collapsible_block().
scr_render_signals <- function(res, top_n = 5L) {
  label <- "conversation signals"
  if (identical(res$status, "unavailable")) {
    return(list(summary = "unavailable",
                body = .scr_unavailable_html(label, res$reason),
                color = ACCENT_ORANGE))
  }

  provenance <- sprintf(
    '<p style="color:%s;font-size:%s;margin-top:8px;">Source: learning digest %s (generated %s UTC, %.1f h before this email). Pattern-based on the digest\'s own fields; no transcript was re-read, and a repeated phrase is a candidate, not a verdict.</p>',
    DARK_MUTED, EMAIL_FONT_SUBTITLE, .scr_html_escape(res$date),
    format(res$generated, "%H:%M", tz = "UTC"), res$age_h
  )

  if (identical(res$status, "empty_input")) {
    return(list(
      summary = sprintf("digest %s analysed 0 sessions", res$date),
      body = paste0(sprintf(
        '<p style="color:%s;font-size:%s;">The %s digest analysed 0 sessions, so there was nothing to detect. That is unexamined, not an all-clear.</p>',
        ACCENT_ORANGE, EMAIL_FONT_BODY, .scr_html_escape(res$date)), provenance),
      color = ACCENT_ORANGE))
  }

  if (identical(res$status, "empty")) {
    return(list(
      summary = sprintf("digest %s · no repeated corrections or failures", res$date),
      body = paste0(sprintf(
        '<p style="color:%s;font-size:%s;">No repeated user corrections or repeated command failures in the %s digest (%s session(s) analysed).</p>',
        ACCENT_GREEN, EMAIL_FONT_BODY, .scr_html_escape(res$date),
        if (is.na(res$n_sessions)) "?" else res$n_sessions), provenance),
      color = ACCENT_GREEN))
  }

  render_rows <- function(df) {
    df <- utils::head(df, top_n)
    vapply(seq_len(nrow(df)), function(i) {
      sprintf(
        '<tr style="background-color:%s;"><td style="padding:5px 10px;">%s</td><td style="padding:5px 10px;text-align:right;">%d</td><td style="padding:5px 10px;text-align:right;">%d</td></tr>',
        DARK_CARD, scr_redact(df$title[[i]]), df$repetitions[[i]], df$sessions[[i]]
      )
    }, character(1))
  }
  section <- function(heading, df) {
    if (nrow(df) == 0L) {
      return(sprintf('<p style="color:%s;font-size:%s;margin:8px 0 2px 0;"><b>%s</b>: none repeated.</p>',
                     DARK_TEXT, EMAIL_FONT_BODY, heading))
    }
    paste0(
      sprintf('<p style="color:%s;font-size:%s;margin:8px 0 2px 0;"><b>%s</b> (top %d of %d)</p>',
              DARK_TEXT, EMAIL_FONT_BODY, heading, min(top_n, nrow(df)), nrow(df)),
      .scr_table(c("Signal", "Repetitions", "Sessions"), render_rows(df),
                 c("left", "right", "right"))
    )
  }

  list(
    summary = sprintf("digest %s · %d correction(s) · %d failure(s)",
                      res$date, nrow(res$corrections), nrow(res$failures)),
    body = paste0(section("Repeated user corrections", res$corrections),
                  section("Repeated command failures", res$failures),
                  provenance),
    color = ACCENT_BLUE
  )
}

# ── Step 2: open roborev findings, last 24 h ─────────────────────────────────

.SCR_SEV_ORD <- c(critical = 4L, high = 3L, medium = 2L, low = 1L)
.SCR_SEV_NAME <- c("1" = "low", "2" = "medium", "3" = "high", "4" = "critical")

# Max severity of one review row. Mirrors roborev_metrics_etl.R's reader:
# structured_output findings[].severity (schema_version 1/2) first -- read from
# the JSON, never by regex over prose, because a finding's own text can quote a
# severity marker -- then the legacy `**Severity**: X` markers in `output`.
# Returns "critical"/"high"/"medium"/"low", "clean" (valid structured output
# with an empty findings list), or NA when nothing usable could be read
# (unscored: never reported as clean).
scr_row_severity <- function(structured_output, output) {
  so <- if (is.null(structured_output) || length(structured_output) == 0L ||
            is.na(structured_output)) "" else as.character(structured_output)
  if (nzchar(so)) {
    data <- tryCatch(jsonlite::fromJSON(so, simplifyVector = FALSE), error = function(e) NULL)
    if (is.list(data)) {
      sv <- data[["schema_version"]]
      known <- is.numeric(sv) && length(sv) == 1L && !is.na(sv) && sv %in% c(1, 2)
      if (known && is.list(data[["findings"]])) {
        if (length(data[["findings"]]) == 0L) return("clean")
        ords <- vapply(data[["findings"]], function(f) {
          s <- if (is.list(f)) f[["severity"]] else NULL
          if (!is.character(s) || length(s) != 1L) return(NA_integer_)
          o <- .SCR_SEV_ORD[tolower(trimws(s))]
          if (length(o) != 1L || is.na(o)) NA_integer_ else unname(o)
        }, integer(1))
        if (all(is.na(ords))) return(NA_character_)
        return(unname(.SCR_SEV_NAME[[as.character(max(ords, na.rm = TRUE))]]))
      }
      legacy <- data[["legacy"]]
      if (is.list(legacy) && is.character(legacy[["markdown"]]) &&
          length(legacy[["markdown"]]) == 1L) {
        output <- legacy[["markdown"]]
      }
    }
  }
  txt <- if (is.null(output) || length(output) == 0L || is.na(output)) "" else as.character(output)
  pat <- "\\*\\*Severity\\*\\*:[[:space:]]*(Critical|High|Medium|Low)"
  m <- regmatches(txt, gregexpr(pat, txt, ignore.case = TRUE))[[1L]]
  if (length(m) == 0L) return(NA_character_)
  words <- tolower(sub(pat, "\\1", m, ignore.case = TRUE))
  unname(.SCR_SEV_NAME[[as.character(max(.SCR_SEV_ORD[words]))]])
}

# rows: data.frame(id, created_at, closed, repo, severity), one per review in
# the window. Only OPEN reviews (closed == 0) count toward findings.
scr_roborev_summarise <- function(rows) {
  open <- rows[!is.na(rows$closed) & rows$closed == 0L, , drop = FALSE]
  repos <- sort(unique(open$repo[open$severity %in% c("critical", "high", "medium")]))
  cnt <- function(repo, sev) sum(open$repo == repo & open$severity == sev, na.rm = TRUE)
  by_repo <- data.frame(
    repo     = repos,
    critical = vapply(repos, cnt, integer(1), sev = "critical"),
    high     = vapply(repos, cnt, integer(1), sev = "high"),
    medium   = vapply(repos, cnt, integer(1), sev = "medium"),
    stringsAsFactors = FALSE, row.names = NULL
  )
  list(
    n_reviews  = nrow(rows),
    n_open     = nrow(open),
    n_unscored = sum(is.na(open$severity)),
    by_repo    = by_repo,
    n_findings = sum(by_repo$critical, by_repo$high, by_repo$medium)
  )
}

# Reads reviews created in the last `hours` hours from roborev's SQLite db via
# DuckDB's sqlite extension (the same read-only ATTACH pattern as the agent-
# failure section of the email and roborev_metrics_etl.R). Returns
# list(status = "ok", summary = ...) or list(status = "unavailable", reason = ...).
scr_roborev_fetch <- function(db_path, now = Sys.time(), hours = 24) {
  if (!file.exists(db_path)) {
    return(list(status = "unavailable", reason = "reviews.db not found"))
  }
  tryCatch({
    con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
    on.exit(tryCatch(DBI::dbDisconnect(con, shutdown = TRUE), error = function(e) NULL),
            add = TRUE)
    tryCatch(invisible(DBI::dbExecute(con, "LOAD sqlite")), error = function(e) {
      invisible(DBI::dbExecute(con, "INSTALL sqlite"))
      invisible(DBI::dbExecute(con, "LOAD sqlite"))
    })
    invisible(DBI::dbExecute(con, sprintf(
      "ATTACH '%s' AS rb (TYPE sqlite, READ_ONLY)", gsub("'", "''", db_path, fixed = TRUE))))
    # reviews.created_at is sqlite datetime('now'): UTC text 'YYYY-MM-DD HH:MM:SS',
    # so a lexical compare against a UTC-formatted cutoff is correct.
    cutoff <- format(as.POSIXct(now, tz = "UTC") - hours * 3600, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    # Raw SQL kept (r-no-raw-sql is warn-level): a 3-table join over an
    # ATTACHed sqlite schema, matching agent_failure_stats() in the email
    # script and roborev_metrics_etl.R. The only interpolated value is the
    # cutoff, formatted from a POSIXct by this function.
    raw <- DBI::dbGetQuery(con, sprintf("
      SELECT rv.id AS id, rv.created_at AS created_at, rv.closed AS closed,
             COALESCE(rp.name, '(unknown repo)') AS repo,
             rv.structured_output AS structured_output, rv.output AS output
      FROM rb.reviews rv
      LEFT JOIN rb.review_jobs rj ON rj.id = rv.job_id
      LEFT JOIN rb.repos rp ON rp.id = rj.repo_id
      WHERE rv.created_at >= '%s'
    ", cutoff))
    rows <- data.frame(
      id = raw$id, created_at = raw$created_at, closed = as.integer(raw$closed),
      repo = raw$repo,
      severity = if (nrow(raw) == 0L) character(0) else
        vapply(seq_len(nrow(raw)), function(i)
          scr_row_severity(raw$structured_output[[i]], raw$output[[i]]), character(1)),
      stringsAsFactors = FALSE
    )
    list(status = "ok", summary = scr_roborev_summarise(rows))
  }, error = function(e) {
    list(status = "unavailable",
         reason = paste("could not read reviews.db:", conditionMessage(e)))
  })
}

scr_render_roborev <- function(res) {
  label <- "roborev findings"
  if (!identical(res$status, "ok")) {
    return(list(summary = "unavailable",
                body = .scr_unavailable_html(label, res$reason),
                color = ACCENT_ORANGE))
  }
  s <- res$summary

  if (s$n_reviews == 0L) {
    return(list(
      summary = "no roborev reviews in the last 24 h",
      body = sprintf(
        '<p style="color:%s;font-size:%s;">There were no roborev reviews in the last 24 h, so no code was reviewed. This is not the same as &ldquo;no open findings&rdquo;.</p>',
        ACCENT_ORANGE, EMAIL_FONT_BODY),
      color = ACCENT_ORANGE))
  }

  unscored_note <- if (s$n_unscored > 0L) {
    sprintf('<p style="color:%s;font-size:%s;margin-top:8px;">%d open review(s) were unscored (no parseable severity); they are not counted above and are not known to be clean.</p>',
            ACCENT_ORANGE, EMAIL_FONT_SUBTITLE, s$n_unscored)
  } else ""
  scope_note <- sprintf(
    '<p style="color:%s;font-size:%s;margin-top:8px;">Open (unclosed) reviews created in the last 24 h, by highest finding severity per review (%d review(s) in the window, %d still open).</p>',
    DARK_MUTED, EMAIL_FONT_SUBTITLE, s$n_reviews, s$n_open)

  if (s$n_findings == 0L) {
    return(list(
      summary = sprintf("0 open Critical/High/Medium finding(s) in %d review(s)%s",
                        s$n_reviews,
                        if (s$n_unscored > 0L) sprintf(" · %d unscored", s$n_unscored) else ""),
      body = paste0(sprintf(
        '<p style="color:%s;font-size:%s;">No open Critical, High or Medium roborev findings were created in the last 24 h.</p>',
        ACCENT_GREEN, EMAIL_FONT_BODY), scope_note, unscored_note),
      color = if (s$n_unscored > 0L) ACCENT_ORANGE else ACCENT_GREEN))
  }

  by <- s$by_repo
  rows_html <- vapply(seq_len(nrow(by)), function(i) {
    sprintf(
      '<tr style="background-color:%s;"><td style="padding:5px 10px;font-family:monospace;">%s</td><td style="padding:5px 10px;text-align:right;">%d</td><td style="padding:5px 10px;text-align:right;">%d</td><td style="padding:5px 10px;text-align:right;">%d</td></tr>',
      DARK_CARD, scr_redact(by$repo[[i]]), by$critical[[i]], by$high[[i]], by$medium[[i]])
  }, character(1))
  list(
    summary = sprintf("%d open Critical/High/Medium finding(s) across %d repo(s)%s",
                      s$n_findings, nrow(by),
                      if (s$n_unscored > 0L) sprintf(" · %d unscored", s$n_unscored) else ""),
    body = paste0(.scr_table(c("Repo", "Critical", "High", "Medium"), rows_html,
                             c("left", "right", "right", "right")),
                  scope_note, unscored_note),
    color = ACCENT_ORANGE
  )
}

# %scr_or%: NULL/length-0/NA, local to this library so it works whether or not
# the caller defined its own (the email script's version also treats "" as
# missing, which would be wrong for a legitimately empty title).
`%scr_or%` <- function(a, b) {
  if (is.null(a) || length(a) == 0L || (length(a) == 1L && is.na(a))) b else a
}
