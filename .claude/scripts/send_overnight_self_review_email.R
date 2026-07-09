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
# Treats NULL, length-0, NA, AND empty string as "missing" — falls through to b.
# Empty-string handling matters because Sys.getenv() returns "" for unset vars
# (not NA), so the prior version silently used "" as a valid value.
# See llm#559 / PR #560 — wrapper had to export UNIFIED_DB_PATH explicitly to
# work around this.
`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0L) return(b)
  if (is.na(a[[1L]])) return(b)
  if (is.character(a) && !nzchar(a[[1L]])) return(b)
  a
}

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
                "self_review_findings_stage1",
                "worktree_gc_events", "housekeeping_runs",
                "config_events", "kb_events", "launchd_health_events")

sec3_rows <- lapply(all_tables, function(tbl) {
  ts_col <- switch(tbl,
    sessions                    = "started_at",
    agent_runs                  = "started_at",
    hook_events                 = "fired_at",
    errors                      = "logged_at",
    self_review_findings_stage1 = "detected_at",
    worktree_gc_events          = "fired_at",
    housekeeping_runs           = "started_at",
    config_events               = "fired_at",
    kb_events                   = "fired_at",
    launchd_health_events       = "fired_at"
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


# ── Section 3b: Worktree footprint (last 24h) ────────────────────────────────
wt_24h <- safe_query("
  SELECT
    action,
    location_pattern,
    COUNT(*)       AS n,
    SUM(size_mb)   AS total_mb
  FROM worktree_gc_events
  WHERE fired_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
  GROUP BY action, location_pattern
  ORDER BY action, location_pattern
")

if (nrow(wt_24h) > 0L) {
  n_removed   <- sum(wt_24h$n[wt_24h$action == "removed"],        na.rm = TRUE)
  n_wouldrem  <- sum(wt_24h$n[wt_24h$action == "would_remove"],   na.rm = TRUE)
  mb_removed  <- sum(wt_24h$total_mb[wt_24h$action == "removed"], na.rm = TRUE)
  n_locked    <- sum(wt_24h$n[wt_24h$action == "skipped_locked"], na.rm = TRUE)
  n_dirty     <- sum(wt_24h$n[wt_24h$action == "skipped_uncommitted"], na.rm = TRUE)
  n_unmerged  <- sum(wt_24h$n[wt_24h$action %in% c("skipped_unmerged", "flagged")],
                     na.rm = TRUE)

  wt_rows_html <- paste(apply(wt_24h, 1, function(r) {
    act_col <- switch(r[["action"]],
      "removed"          = ACCENT_GREEN,
      "would_remove"     = ACCENT_ORANGE,
      "skipped_unmerged" = "#ff5252",
      "flagged"          = "#ff5252",
      DARK_MUTED
    )
    sprintf(
      '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-family:monospace;font-size:12px;">%s</td>
<td style="padding:5px 10px;font-size:12px;color:%s;">%s</td>
<td style="padding:5px 10px;text-align:right;font-weight:bold;">%s</td>
<td style="padding:5px 10px;text-align:right;color:%s;">%s MB</td>
</tr>',
      DARK_CARD,
      r[["location_pattern"]],
      act_col, r[["action"]],
      r[["n"]],
      DARK_MUTED, r[["total_mb"]] %||% "0"
    )
  }), collapse = "\n")

  wt_table_html <- sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">Pattern</th>
<th style="padding:5px 10px;text-align:left;">Action</th>
<th style="padding:5px 10px;text-align:right;">Count</th>
<th style="padding:5px 10px;text-align:right;">Size</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, wt_rows_html
  )
  if (n_unmerged > 0L) {
    wt_table_html <- paste0(
      wt_table_html,
      sprintf(
        '<p style="color:#ff5252;font-size:%s;margin-top:8px;">
  &#9888; %d squash-merge candidate(s) flagged — run /cleanup-worktrees to triage.</p>',
        EMAIL_FONT_SUBTITLE, n_unmerged
      )
    )
  }

  sec3b_summary <- sprintf(
    "removed %d (%.0f MB) \u00b7 would-remove %d \u00b7 locked %d \u00b7 dirty %d \u00b7 flagged %d",
    n_removed, mb_removed, n_wouldrem, n_locked, n_dirty, n_unmerged
  )
} else {
  wt_table_html <- sprintf(
    '<p style="color:%s;font-size:%s;">No worktree_gc_events in the last 24 h.</p>',
    DARK_MUTED, EMAIL_FONT_BODY
  )
  sec3b_summary <- "no events in last 24h"
}

sec3b_block <- collapsible_block(
  "Worktree footprint (24h)",
  sec3b_summary,
  wt_table_html
)


# ── Section 3c: Config changes (24h) — llm#552 Phase C ───────────────────────
cfg_24h <- safe_query("
  SELECT file_path, change_type, diff_lines, commit_sha, fired_at
  FROM config_events
  WHERE fired_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
  ORDER BY fired_at DESC
  LIMIT 50
")

if (nrow(cfg_24h) > 0L) {
  n_added    <- sum(cfg_24h$change_type == "added",    na.rm = TRUE)
  n_modified <- sum(cfg_24h$change_type == "modified", na.rm = TRUE)
  n_removed  <- sum(cfg_24h$change_type == "removed",  na.rm = TRUE)

  cfg_rows_html <- paste(apply(cfg_24h, 1, function(r) {
    ct_col <- switch(r[["change_type"]],
      "added"    = ACCENT_GREEN,
      "removed"  = "#ff5252",
      "modified" = ACCENT_ORANGE,
      DARK_MUTED
    )
    sha_short <- if (!is.na(r[["commit_sha"]]) && nchar(r[["commit_sha"]]) >= 7L)
      substr(r[["commit_sha"]], 1L, 7L) else "—"
    sprintf(
      '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-family:monospace;font-size:12px;max-width:320px;
   word-break:break-all;">%s</td>
<td style="padding:5px 10px;font-size:12px;color:%s;font-weight:bold;">%s</td>
<td style="padding:5px 10px;text-align:right;font-size:12px;">%s</td>
<td style="padding:5px 10px;font-family:monospace;font-size:11px;color:%s;">%s</td>
</tr>',
      DARK_CARD,
      r[["file_path"]],
      ct_col, r[["change_type"]],
      r[["diff_lines"]] %||% "—",
      DARK_MUTED, sha_short
    )
  }), collapse = "\n")

  cfg_table_html <- sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">File</th>
<th style="padding:5px 10px;text-align:left;">Change</th>
<th style="padding:5px 10px;text-align:right;">Lines</th>
<th style="padding:5px 10px;text-align:left;">Commit</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, cfg_rows_html
  )
  sec3c_summary <- sprintf(
    "added %d · modified %d · removed %d",
    n_added, n_modified, n_removed
  )
} else {
  cfg_table_html <- sprintf(
    '<p style="color:%s;font-size:%s;">No config_events in the last 24 h.</p>',
    DARK_MUTED, EMAIL_FONT_BODY
  )
  sec3c_summary <- "no events in last 24h"
}

sec3c_block <- collapsible_block(
  "Config changes (24h)",
  sec3c_summary,
  cfg_table_html
)

# ── Section 3d: Knowledge base (24h) — llm#553 Phase C ───────────────────────
kb_24h <- safe_query("
  SELECT layer, action, COUNT(*) AS n
  FROM kb_events
  WHERE fired_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
  GROUP BY layer, action
  ORDER BY layer, action
")

if (nrow(kb_24h) > 0L) {
  n_kb_total <- sum(kb_24h$n, na.rm = TRUE)
  n_flagged  <- sum(kb_24h$n[kb_24h$action == "flagged"], na.rm = TRUE)

  kb_rows_html <- paste(apply(kb_24h, 1, function(r) {
    layer_col <- switch(r[["layer"]],
      "wiki"    = ACCENT_BLUE,
      "raw"     = ACCENT_GREEN,
      "outputs" = ACCENT_PURPLE,
      DARK_MUTED
    )
    act_col <- switch(r[["action"]],
      "created"  = ACCENT_GREEN,
      "flagged"  = "#ff5252",
      "modified" = ACCENT_ORANGE,
      DARK_MUTED
    )
    sprintf(
      '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-size:12px;color:%s;font-weight:bold;">%s</td>
<td style="padding:5px 10px;font-size:12px;color:%s;">%s</td>
<td style="padding:5px 10px;text-align:right;font-weight:bold;">%s</td>
</tr>',
      DARK_CARD,
      layer_col, r[["layer"]],
      act_col, r[["action"]],
      r[["n"]]
    )
  }), collapse = "\n")

  kb_table_html <- sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">Layer</th>
<th style="padding:5px 10px;text-align:left;">Action</th>
<th style="padding:5px 10px;text-align:right;">Count</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, kb_rows_html
  )
  if (n_flagged > 0L) {
    kb_table_html <- paste0(
      kb_table_html,
      sprintf(
        '<p style="color:#ff5252;font-size:%s;margin-top:8px;">
  &#9888; %d flagged write(s) to raw/ — review immediately.</p>',
        EMAIL_FONT_SUBTITLE, n_flagged
      )
    )
  }
  sec3d_summary <- sprintf(
    "%d events · %d flagged",
    n_kb_total, n_flagged
  )
} else {
  kb_table_html <- sprintf(
    '<p style="color:%s;font-size:%s;">No kb_events in the last 24 h.</p>',
    DARK_MUTED, EMAIL_FONT_BODY
  )
  sec3d_summary <- "no events in last 24h"
}

sec3d_block <- collapsible_block(
  "Knowledge base (24h)",
  sec3d_summary,
  kb_table_html
)

# ── Section 3e: Cron health (last fire) — llm#554 Phase C ────────────────────
cron_health <- safe_query("
  SELECT plist_label, state, last_exit_code, last_fired_at, next_fire_at
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY plist_label ORDER BY fired_at DESC) AS rn
    FROM launchd_health_events
  )
  WHERE rn = 1
  ORDER BY
    CASE state
      WHEN 'loaded_recent_fail' THEN 0
      WHEN 'unloaded'           THEN 1
      WHEN 'missing'            THEN 2
      ELSE 3
    END,
    plist_label
")

if (nrow(cron_health) > 0L) {
  n_fail  <- sum(cron_health$state %in% c("loaded_recent_fail", "unloaded", "missing"),
                 na.rm = TRUE)
  n_ok    <- sum(cron_health$state == "loaded", na.rm = TRUE)
  n_plists <- nrow(cron_health)

  cron_rows_html <- paste(apply(cron_health, 1, function(r) {
    is_fail <- r[["state"]] %in% c("loaded_recent_fail", "unloaded", "missing")
    row_bg  <- if (is_fail) "#2a0a0a" else DARK_CARD
    st_col  <- if (is_fail) "#ff5252" else ACCENT_GREEN
    ec_col  <- {
      ec <- suppressWarnings(as.integer(r[["last_exit_code"]]))
      if (!is.na(ec) && ec != 0L) "#ff5252" else DARK_MUTED
    }
    sprintf(
      '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-family:monospace;font-size:11px;max-width:280px;
   word-break:break-all;">%s</td>
<td style="padding:5px 10px;font-size:12px;color:%s;font-weight:bold;">%s</td>
<td style="padding:5px 10px;text-align:right;font-size:12px;color:%s;">%s</td>
<td style="padding:5px 10px;font-size:11px;color:%s;">%s</td>
<td style="padding:5px 10px;font-size:11px;color:%s;">%s</td>
</tr>',
      row_bg,
      r[["plist_label"]],
      st_col, r[["state"]],
      ec_col, r[["last_exit_code"]] %||% "—",
      DARK_MUTED, r[["last_fired_at"]] %||% "—",
      DARK_MUTED, r[["next_fire_at"]]  %||% "—"
    )
  }), collapse = "\n")

  cron_table_html <- sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">Plist label</th>
<th style="padding:5px 10px;text-align:left;">State</th>
<th style="padding:5px 10px;text-align:right;">Exit code</th>
<th style="padding:5px 10px;text-align:left;">Last fired</th>
<th style="padding:5px 10px;text-align:left;">Next fire</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, cron_rows_html
  )
  if (n_fail > 0L) {
    cron_table_html <- paste0(
      cron_table_html,
      sprintf(
        '<p style="color:#ff5252;font-size:%s;margin-top:8px;">
  &#9888; %d plist(s) failed or unloaded — check launchd status.</p>',
        EMAIL_FONT_SUBTITLE, n_fail
      )
    )
  }
  sec3e_summary <- sprintf(
    "%d plists · %d ok · %d failed/unloaded",
    n_plists, n_ok, n_fail
  )
} else {
  cron_table_html <- sprintf(
    '<p style="color:%s;font-size:%s;">No launchd_health_events recorded yet.</p>',
    DARK_MUTED, EMAIL_FONT_BODY
  )
  sec3e_summary <- "no data yet"
}

sec3e_block <- collapsible_block(
  "Cron health (last fire)",
  sec3e_summary,
  cron_table_html
)

# ── Section 3f: Branch GC (last 24h) — llm#589 Phase B ───────────────────────
branch_gc_body <- tryCatch({
  bge <- DBI::dbGetQuery(con, "
    SELECT action, COUNT(*) AS n
    FROM branch_gc_events
    WHERE fired_at >= current_timestamp - INTERVAL 24 HOUR
    GROUP BY action ORDER BY n DESC
  ")
  if (nrow(bge) == 0) {
    '<p style="color:#888;font-size:13px;">No branch_gc_events in the last 24 h.</p>'
  } else {
    n_del  <- sum(bge$n[bge$action %in% c("deleted_merged","deleted_squash","deleted_reimpl")], na.rm=TRUE)
    n_kept <- sum(bge$n[bge$action %in% c("kept_unmerged","kept_grace")], na.rm=TRUE)
    rows   <- paste(sprintf('<tr><td>%s</td><td style="text-align:right">%d</td></tr>',
                            bge$action, bge$n), collapse="\n")
    sprintf(
      '<p style="font-size:13px;margin:4px 0">Deleted: <b>%d</b> &nbsp;|&nbsp; Kept (review): <b>%d</b></p>
       <table style="font-size:12px;border-collapse:collapse">
         <tr><th style="text-align:left;padding-right:12px">Action</th><th>Count</th></tr>
         %s
       </table>',
      n_del, n_kept, rows)
  }
}, error = function(e) {
  sprintf('<p style="color:#c00;font-size:12px;">branch_gc query error: %s</p>', conditionMessage(e))
})

sec3f_block <- collapsible_block(
  title         = "Branch GC (last 24h)",
  summary_stats = "branch ref GC activity",
  html_body     = branch_gc_body
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

# ── Section: oversized-config surface (audit-teeth #754, llm#749) ──────────────
# session_init.sh writes ~/.claude/logs/oversized_config.txt each run (one
# "LEVEL category lines/limit path" row per WARN/FAIL breach). Surface it here so
# config-size drift has an owner instead of scrolling past the startup banner.
oversized_block <- tryCatch({
  ocfg <- file.path(Sys.getenv("HOME"), ".claude", "logs", "oversized_config.txt")
  if (!file.exists(ocfg)) {
    ""
  } else {
    ln <- readLines(ocfg, warn = FALSE)
    br <- grep("^(WARN|FAIL)", ln, value = TRUE)
    if (length(br) == 0L) {
      sprintf('<h2 style="color:%s;">Config size</h2><p style="color:%s;">&#10003; all config files within limits</p>',
              DARK_TEXT, DARK_TEXT)
    } else {
      nf <- sum(grepl("^FAIL", br)); nw <- sum(grepl("^WARN", br))
      sprintf('<h2 style="color:%s;">Config size &mdash; %d FAIL, %d WARN &gt;limit</h2><pre style="color:%s;background:#111;padding:10px;overflow-x:auto;">%s</pre>',
              DARK_TEXT, nf, nw, DARK_TEXT, paste(br, collapse = "\n"))
    }
  }
}, error = function(e) "")

email_body <- paste0(
  sprintf('<div style="background-color:%s;color:%s;font-family:Arial,sans-serif;
padding:20px;max-width:800px;margin:0 auto;">', DARK_BG, DARK_TEXT),
  header_html,
  sec1_block, "\n",
  sec2_block, "\n",
  sec3_block, "\n",
  sec3b_block, "\n",
  sec3c_block, "\n",
  sec3d_block, "\n",
  sec3e_block, "\n",
  sec3f_block, "\n",
  oversized_block, "\n",
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
# Modern blastula (>= 0.3.x) does not export `html()`; compose_email() accepts
# `htmltools::HTML()` objects as body (see llm#559 — Rapsody upgraded blastula's API).
email_obj <- blastula::compose_email(
  body = htmltools::HTML(email_body)
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
