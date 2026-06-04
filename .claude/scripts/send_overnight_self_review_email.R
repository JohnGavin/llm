#!/usr/bin/env Rscript
# send_overnight_self_review_email.R
#
# Daily overnight email surfacing ETL-starvation and self-review findings.
# Reads from ~/.claude/logs/unified.duckdb (read-only, never writes).
# Sends via blastula/SMTP, or prints HTML to stdout in dry-run mode.
#
# Usage:
#   # Dry run (prints HTML, no SMTP):
#   EMAIL_DRY_RUN=1 Rscript .claude/scripts/send_overnight_self_review_email.R
#
#   # Live (requires GMAIL_USERNAME, GMAIL_APP_PASSWORD, REPORT_RECIPIENT):
#   Rscript .claude/scripts/send_overnight_self_review_email.R
#
# Environment:
#   EMAIL_DRY_RUN       "1" → dry-run (default off)
#   GMAIL_USERNAME      sender address
#   GMAIL_APP_PASSWORD  16-char app password
#   REPORT_RECIPIENT    destination address
#   UNIFIED_DB_PATH     override DB path (default ~/.claude/logs/unified.duckdb)
#
# Tracked in llm#491.

# ── Script self-location ───────────────────────────────────────────────────────
.scripts_dir <- tryCatch(
  dirname(normalizePath(sys.frame(0L)$ofile, mustWork = FALSE)),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    idx  <- grep("^--file=", args)
    if (length(idx)) {
      dirname(normalizePath(sub("^--file=", "", args[idx]), mustWork = FALSE))
    } else {
      dirname(normalizePath(
        file.path(Sys.getenv("HOME"), "docs_gh", "llm", ".claude", "scripts",
                  "email_styles.R"),
        mustWork = FALSE
      ))
    }
  }
)

source(file.path(.scripts_dir, "email_styles.R"))

# ── Null-coalescing operator ───────────────────────────────────────────────────
`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[[1]])) a else b

# ── Configuration ──────────────────────────────────────────────────────────────
dry_run        <- identical(Sys.getenv("EMAIL_DRY_RUN"), "1")
gmail_user     <- Sys.getenv("GMAIL_USERNAME")   %||% ""
report_recip   <- Sys.getenv("REPORT_RECIPIENT") %||% gmail_user
db_path        <- Sys.getenv("UNIFIED_DB_PATH")  %||%
                  file.path(Sys.getenv("HOME"), ".claude", "logs", "unified.duckdb")

if (!dry_run) {
  if (!nzchar(gmail_user)) {
    message("ERROR: GMAIL_USERNAME not set. Use EMAIL_DRY_RUN=1 to preview.")
    quit(status = 1L)
  }
  if (!nzchar(Sys.getenv("GMAIL_APP_PASSWORD"))) {
    message("ERROR: GMAIL_APP_PASSWORD not set.")
    quit(status = 1L)
  }
}

# ── Required packages ─────────────────────────────────────────────────────────
for (.pkg in c("DBI", "duckdb", "blastula")) {
  if (!requireNamespace(.pkg, quietly = TRUE)) {
    message(sprintf("ERROR: required package '%s' is not installed.", .pkg))
    quit(status = 1L)
  }
}

# ── Open DB (read-only) ────────────────────────────────────────────────────────
if (!file.exists(db_path)) {
  message(sprintf("ERROR: DuckDB not found at %s", db_path))
  quit(status = 1L)
}
con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

# ── Helper: safe query ────────────────────────────────────────────────────────
safe_query <- function(sql, fallback = data.frame()) {
  tryCatch(DBI::dbGetQuery(con, sql), error = function(e) {
    message(sprintf("  [WARN] query failed: %s", conditionMessage(e)))
    fallback
  })
}

# ── Section 1: New self-review findings (last 24h) ────────────────────────────
sec1_data <- safe_query("
  SELECT
    finding_type,
    severity,
    COUNT(*) AS n
  FROM self_review_findings_stage1
  WHERE detected_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
  GROUP BY finding_type, severity
  ORDER BY
    CASE severity
      WHEN 'critical' THEN 1 WHEN 'major' THEN 2 WHEN 'minor' THEN 3 ELSE 4
    END, finding_type
")

n_new_findings <- if (nrow(sec1_data) > 0L) sum(sec1_data$n) else 0L
n_critical     <- if (nrow(sec1_data) > 0L)
  sum(sec1_data$n[sec1_data$severity == "critical"], na.rm = TRUE) else 0L
n_major        <- if (nrow(sec1_data) > 0L)
  sum(sec1_data$n[sec1_data$severity == "major"], na.rm = TRUE) else 0L

severity_badge <- function(sev) {
  col <- switch(sev,
    critical = "#ff5252",
    major    = "#ff9800",
    minor    = "#ffd54f",
    "#a0a0a0"
  )
  sprintf(
    '<span style="background-color:%s;color:#000;padding:2px 6px;border-radius:3px;
font-size:12px;font-weight:bold;">%s</span>',
    col, toupper(sev)
  )
}

if (nrow(sec1_data) > 0L) {
  rows_html <- paste(apply(sec1_data, 1, function(r) {
    sprintf(
      '<tr style="background-color:%s;">
<td style="padding:6px 10px;">%s</td>
<td style="padding:6px 10px;">%s</td>
<td style="padding:6px 10px;text-align:right;font-weight:bold;">%s</td>
</tr>',
      DARK_CARD, r[["finding_type"]], severity_badge(r[["severity"]]), r[["n"]]
    )
  }), collapse = "\n")
  sec1_table <- sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:6px 10px;text-align:left;">Finding type</th>
<th style="padding:6px 10px;text-align:left;">Severity</th>
<th style="padding:6px 10px;text-align:right;">Count</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, rows_html
  )
} else {
  sec1_table <- sprintf(
    '<p style="color:%s;font-size:%s;">No new findings in the last 24 h.</p>',
    ACCENT_GREEN, EMAIL_FONT_BODY
  )
}

sec1_summary <- sprintf(
  "%d new · %d critical · %d major",
  n_new_findings, n_critical, n_major
)

sec1_block <- collapsible_block(
  "New self-review findings (last 24h)",
  sec1_summary,
  sec1_table
)

# ── Section 2: Source table volume (last 24h) — ETL starvation detector ────────
source_tables <- c("sessions", "agent_runs", "hook_events", "errors")

sec2_rows <- lapply(source_tables, function(tbl) {
  ts_col <- switch(tbl,
    sessions   = "started_at",
    agent_runs = "started_at",
    hook_events = "fired_at",
    errors     = "logged_at"
  )

  info <- safe_query(sprintf("
    SELECT
      COUNT(*) AS total,
      COUNT(CASE WHEN %s >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR THEN 1 END) AS last_24h,
      MAX(%s) AS latest_ts
    FROM %s
  ", ts_col, ts_col, tbl))

  if (nrow(info) == 0L) {
    return(list(table = tbl, total = 0L, last_24h = 0L,
                latest_ts = NA_character_, status = "DEAD"))
  }

  n24      <- as.integer(info$last_24h[[1]])
  latest   <- info$latest_ts[[1]]
  total    <- as.integer(info$total[[1]])

  hours_since <- if (!is.na(latest) && !is.null(latest)) {
    as.numeric(difftime(Sys.time(),
                        as.POSIXct(latest, tz = "UTC"),
                        units = "hours"))
  } else {
    Inf
  }

  status <- if (n24 >= 10L) {
    "live"
  } else if (n24 >= 1L) {
    "sparse"
  } else if (hours_since <= 48) {
    "STALE"
  } else {
    "DEAD"
  }

  list(table = tbl, total = total, last_24h = n24,
       latest_ts = as.character(latest), status = status)
})

status_color <- function(s) {
  switch(s,
    "live"   = ACCENT_GREEN,
    "sparse" = ACCENT_ORANGE,
    "STALE"  = "#ff5252",
    "DEAD"   = "#ff5252",
    DARK_MUTED
  )
}

status_badge <- function(s) {
  col <- status_color(s)
  sprintf(
    '<span style="background-color:%s;color:%s;padding:2px 8px;border-radius:3px;
font-size:12px;font-weight:bold;">%s</span>',
    col,
    if (s %in% c("STALE", "DEAD")) "#fff" else "#000",
    s
  )
}

sec2_rows_html <- paste(lapply(sec2_rows, function(r) {
  sprintf(
    '<tr style="background-color:%s;">
<td style="padding:6px 10px;font-family:monospace;">%s</td>
<td style="padding:6px 10px;text-align:right;">%s</td>
<td style="padding:6px 10px;text-align:right;">%s</td>
<td style="padding:6px 10px;font-size:11px;color:%s;">%s</td>
<td style="padding:6px 10px;text-align:center;">%s</td>
</tr>',
    DARK_CARD,
    r$table,
    format(r$total, big.mark = ","),
    format(r$last_24h, big.mark = ","),
    DARK_MUTED,
    r$latest_ts %||% "—",
    status_badge(r$status)
  )
}), collapse = "\n")

n_stale_tables <- sum(sapply(sec2_rows, function(r) r$status %in% c("STALE", "DEAD")))

sec2_table <- sprintf(
  '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:6px 10px;text-align:left;">Table</th>
<th style="padding:6px 10px;text-align:right;">Total rows</th>
<th style="padding:6px 10px;text-align:right;">Last 24h</th>
<th style="padding:6px 10px;text-align:left;">Latest row</th>
<th style="padding:6px 10px;text-align:center;">Status</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>
<p style="color:%s;font-size:%s;margin-top:8px;">
  Status: <b>live</b> ≥10 rows/24h &nbsp;|&nbsp;
  <b style="color:%s;">sparse</b> 1–9 rows/24h &nbsp;|&nbsp;
  <b style="color:#ff5252;">STALE</b> 0 rows, gap &lt;48h &nbsp;|&nbsp;
  <b style="color:#ff5252;">DEAD</b> 0 rows, gap ≥48h
</p>',
  DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT,
  sec2_rows_html,
  DARK_MUTED, EMAIL_FONT_SUBTITLE,
  ACCENT_ORANGE
)

sec2_summary <- sprintf("%d source tables · %d stale/dead", length(source_tables), n_stale_tables)

sec2_block <- collapsible_block(
  "Source table volume (last 24h)",
  sec2_summary,
  sec2_table
)

# ── Section 3: Cumulative table health ────────────────────────────────────────
all_tables <- c("sessions", "agent_runs", "hook_events", "errors",
                "self_review_findings_stage1")

sec3_rows <- lapply(all_tables, function(tbl) {
  ts_col <- switch(tbl,
    sessions                    = "started_at",
    agent_runs                  = "started_at",
    hook_events                 = "fired_at",
    errors                      = "logged_at",
    self_review_findings_stage1 = "detected_at"
  )

  info <- safe_query(sprintf("
    SELECT
      COUNT(*) AS total_rows,
      MIN(%s)  AS earliest,
      MAX(%s)  AS latest
    FROM %s
  ", ts_col, ts_col, tbl))

  if (nrow(info) == 0L) {
    return(list(table = tbl, total = 0L, earliest = "—", latest = "—"))
  }

  list(
    table    = tbl,
    total    = as.integer(info$total_rows[[1]]),
    earliest = as.character(info$earliest[[1]]) %||% "—",
    latest   = as.character(info$latest[[1]])   %||% "—"
  )
})

sec3_rows_html <- paste(lapply(sec3_rows, function(r) {
  sprintf(
    '<tr style="background-color:%s;">
<td style="padding:6px 10px;font-family:monospace;">%s</td>
<td style="padding:6px 10px;text-align:right;font-weight:bold;">%s</td>
<td style="padding:6px 10px;font-size:11px;color:%s;">%s</td>
<td style="padding:6px 10px;font-size:11px;color:%s;">%s</td>
</tr>',
    DARK_CARD,
    r$table,
    format(r$total, big.mark = ","),
    DARK_MUTED, r$earliest,
    DARK_MUTED, r$latest
  )
}), collapse = "\n")

sec3_table <- sprintf(
  '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:6px 10px;text-align:left;">Table</th>
<th style="padding:6px 10px;text-align:right;">Total rows</th>
<th style="padding:6px 10px;text-align:left;">Earliest</th>
<th style="padding:6px 10px;text-align:left;">Latest</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
  DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, sec3_rows_html
)

sec3_total <- sum(sapply(sec3_rows, function(r) r$total))
sec3_summary <- sprintf("%d tables · %s total rows",
                        length(all_tables),
                        format(sec3_total, big.mark = ","))

sec3_block <- collapsible_block(
  "Cumulative table health",
  sec3_summary,
  sec3_table
)

# ── Section 4: New findings — detail (top 20) ─────────────────────────────────
sec4_data <- safe_query("
  SELECT
    finding_type,
    severity,
    session_id,
    evidence,
    detected_at
  FROM self_review_findings_stage1
  WHERE detected_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
  ORDER BY
    CASE severity
      WHEN 'critical' THEN 1 WHEN 'major' THEN 2 WHEN 'minor' THEN 3 ELSE 4
    END,
    detected_at DESC
  LIMIT 20
")

if (nrow(sec4_data) > 0L) {
  detail_rows_html <- paste(apply(sec4_data, 1, function(r) {
    evidence_str <- tryCatch({
      ev <- jsonlite::fromJSON(r[["evidence"]])
      paste(
        mapply(function(k, v) sprintf("<b>%s</b>: %s", k, v),
               names(ev), as.character(ev)),
        collapse = " &nbsp;·&nbsp; "
      )
    }, error = function(e) as.character(r[["evidence"]]))
    sid <- if (!is.na(r[["session_id"]]) && nchar(r[["session_id"]]) >= 8L)
      substr(r[["session_id"]], 1L, 8L) else "—"
    sprintf(
      '<tr style="background-color:%s;">
<td style="padding:6px 10px;font-size:11px;white-space:nowrap;">%s</td>
<td style="padding:6px 10px;">%s</td>
<td style="padding:6px 10px;font-family:monospace;font-size:11px;">%s…</td>
<td style="padding:6px 10px;font-size:11px;color:%s;max-width:320px;
   white-space:normal;word-break:break-word;">%s</td>
</tr>',
      DARK_CARD,
      format(as.POSIXct(r[["detected_at"]], tz = "UTC"), "%H:%M"),
      severity_badge(r[["severity"]]),
      sid,
      DARK_MUTED,
      evidence_str
    )
  }), collapse = "\n")

  sec4_table <- sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:6px 10px;text-align:left;">Time</th>
<th style="padding:6px 10px;text-align:left;">Severity</th>
<th style="padding:6px 10px;text-align:left;">Session</th>
<th style="padding:6px 10px;text-align:left;">Evidence</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, detail_rows_html
  )
} else {
  sec4_table <- sprintf(
    '<p style="color:%s;font-size:%s;">No new findings in the last 24 h.</p>',
    ACCENT_GREEN, EMAIL_FONT_BODY
  )
}

sec4_summary <- sprintf("top %d by severity · last 24h", min(nrow(sec4_data), 20L))
sec4_block <- collapsible_block(
  "New findings — detail",
  sec4_summary,
  sec4_table
)

# ── Assemble email body ────────────────────────────────────────────────────────
today_str <- format(Sys.Date(), "%Y-%m-%d")

header_html <- sprintf(
  '<div style="background-color:%s;padding:16px 20px;margin-bottom:12px;
border-radius:6px;">
<h2 style="color:%s;font-size:%s;margin:0 0 4px 0;">
  Overnight Self-Review &mdash; %s
</h2>
<p style="color:%s;font-size:%s;margin:0;">
  %d new findings &nbsp;·&nbsp; %d source tables stale or dead
</p>
</div>',
  DARK_CARD, ACCENT_BLUE, EMAIL_FONT_H2,
  today_str,
  DARK_MUTED, EMAIL_FONT_SUBTITLE,
  n_new_findings, n_stale_tables
)

footer_html <- sprintf(
  '<hr style="border-color:%s;margin:20px 0 12px 0;">
<p style="color:%s;font-size:%s;">
  Generated by <code>send_overnight_self_review_email.R</code> at %s &nbsp;·&nbsp;
  DB: <code>%s</code> &nbsp;·&nbsp;
  <a href="https://github.com/JohnGavin/llm/issues/491"
     style="color:%s;">llm#491</a>
</p>',
  DARK_BORDER, DARK_MUTED, EMAIL_FONT_FOOTER,
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S UTC"),
  db_path,
  ACCENT_BLUE
)

# QA markers (HTML comments at end of body)
qa_block <- sprintf(
  '<!-- QA:overnight_self_review_email=true -->
<!-- QA:n_new_findings_24h=%d -->
<!-- QA:n_stale_tables=%d -->
<!-- QA:overnight_email_date=%s -->',
  n_new_findings, n_stale_tables, today_str
)

email_body <- paste0(
  sprintf('<div style="background-color:%s;color:%s;font-family:Arial,sans-serif;
padding:20px;max-width:800px;margin:0 auto;">', DARK_BG, DARK_TEXT),
  header_html,
  sec1_block, "\n",
  sec2_block, "\n",
  sec3_block, "\n",
  sec4_block, "\n",
  footer_html,
  "\n", qa_block, "\n",
  "</div>"
)

# ── Dry run: print and exit ────────────────────────────────────────────────────
if (dry_run) {
  cat(email_body, "\n")
  quit(status = 0L)
}

# ── Send via blastula ──────────────────────────────────────────────────────────
email_obj <- blastula::compose_email(
  body = blastula::html(email_body)
)

smtp_creds <- blastula::creds_envvar(
  user        = gmail_user,
  pass_envvar = "GMAIL_APP_PASSWORD",
  host        = "smtp.gmail.com",
  port        = 465L,
  use_ssl     = TRUE
)

blastula::smtp_send(
  email      = email_obj,
  to         = report_recip,
  from       = gmail_user,
  subject    = sprintf("[llm] Overnight self-review: %s · %d new findings · %d stale tables",
                       today_str, n_new_findings, n_stale_tables),
  credentials = smtp_creds
)

message(sprintf("Sent overnight self-review email to %s", report_recip))
