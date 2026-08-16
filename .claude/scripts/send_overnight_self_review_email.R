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

# The `staleness_status` view (llm#893) computes `now() - observed_at` on
# TIMESTAMPTZ columns. A fresh R duckdb::duckdb() connection does NOT have
# the icu extension auto-loaded, and TIMESTAMPTZ subtraction has no builtin
# implementation without it -- every query against staleness_status fails
# with a BINDER error ("No function matches -(TIMESTAMP WITH TIME ZONE, ...)")
# even though the same query works fine from the `duckdb` CLI (which does
# load icu). Found live 2026-08-16 while wiring this connection to the shared
# view for llm#893 step 3. LOAD is a no-op if already loaded; INSTALL is a
# no-op if already cached (confirmed present under
# ~/Library/Application Support/org.R-project.R/R/duckdb/extensions/ on this
# machine, so this does not require network access in the common case).
# Best-effort: if this fails (offline + never cached), later
# staleness_status queries fail closed via safe_query()'s fallback and the
# unified-staleness section reports "view absent" rather than crashing.
tryCatch({
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
}, error = function(e) {
  message(sprintf("  [WARN] could not load duckdb icu extension (staleness_status queries will fail-closed): %s",
                   conditionMessage(e)))
})

# ── Helper: safe query ────────────────────────────────────────────────────────
safe_query <- function(sql, fallback = data.frame()) {
  tryCatch(DBI::dbGetQuery(con, sql), error = function(e) {
    message(sprintf("  [WARN] query failed: %s", conditionMessage(e)))
    fallback
  })
}

# ── Helper: HTML escape (avoids htmltools dependency; matches
#    send_kb_digest_email.R's local definition) ────────────────────────────────
htmlEscape <- function(text) {
  text <- gsub("&", "&amp;", text)
  text <- gsub("<", "&lt;", text)
  text <- gsub(">", "&gt;", text)
  text <- gsub("\"", "&quot;", text)
  text
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
    # secret_exposure_scan.sh (llm#951) uses 'high'/'critical' vocabulary,
    # not 'major'/'minor' -- map 'high' onto the same orange as 'major'
    # rather than falling through to the generic grey.
    high     = "#ff9800",
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

# ── Section 1b: Drill-down for high-count finding types (llm#817) ─────────────
# The grouped table above collapses each finding_type × severity combination
# into a single count, so e.g. 70 parallel_session_sprawl rows render as one
# uninformative "70". Any finding_type with more than 3 rows in the window
# gets an expandable per-type detail table nested inside this section.
sec1_type_totals <- if (nrow(sec1_data) > 0L) {
  stats::aggregate(n ~ finding_type, data = sec1_data, sum)
} else {
  data.frame(finding_type = character(0), n = integer(0))
}
sec1_drilldown_types <- sec1_type_totals$finding_type[sec1_type_totals$n > 3L]

# Renders one collapsible sub-table for a given finding_type. parallel_session_
# sprawl gets a tailored day/peak/threshold breakdown (its evidence JSON has
# those keys); every other finding_type falls back to a generic session/
# severity/evidence-preview table, matching the Section 4 detail pattern.
build_finding_drilldown <- function(ftype, total_n) {
  if (identical(ftype, "parallel_session_sprawl")) {
    dd <- safe_query(sprintf("
      SELECT
        evidence->>'day' AS day,
        TRY_CAST(evidence->>'peak_concurrent' AS INTEGER) AS peak,
        evidence->>'threshold' AS threshold
      FROM self_review_findings_stage1
      WHERE finding_type = '%s'
        AND detected_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
      ORDER BY peak DESC, day
    ", ftype))
    if (nrow(dd) == 0L) return(NULL)
    rows_html <- paste(apply(dd, 1, function(r) {
      sprintf(
        '<tr style="background-color:%s;">
<td style="padding:4px 10px;font-family:monospace;">%s</td>
<td style="padding:4px 10px;text-align:right;">%s</td>
<td style="padding:4px 10px;font-size:11px;color:%s;">%s</td>
</tr>',
        DARK_CARD, htmlEscape(r[["day"]]), r[["peak"]], DARK_MUTED, htmlEscape(r[["threshold"]])
      )
    }), collapse = "\n")
    table_html <- sprintf(
      '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:4px 10px;text-align:left;">Day</th>
<th style="padding:4px 10px;text-align:right;">Peak concurrent</th>
<th style="padding:4px 10px;text-align:left;">Threshold</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
      DARK_TEXT, EMAIL_FONT_SUBTITLE, DARK_ROW_ALT, rows_html
    )
  } else {
    dd <- safe_query(sprintf("
      SELECT session_id, severity, evidence
      FROM self_review_findings_stage1
      WHERE finding_type = '%s'
        AND detected_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
      ORDER BY detected_at DESC
      LIMIT 50
    ", ftype))
    if (nrow(dd) == 0L) return(NULL)
    rows_html <- paste(apply(dd, 1, function(r) {
      sid <- if (!is.na(r[["session_id"]]) && nchar(r[["session_id"]]) >= 8L)
        substr(r[["session_id"]], 1L, 8L) else "—"
      ev_preview <- tryCatch({
        ev <- jsonlite::fromJSON(r[["evidence"]])
        paste(
          mapply(function(k, v) sprintf("<b>%s</b>: %s", k, v),
                 names(ev), as.character(ev)),
          collapse = " &nbsp;·&nbsp; "
        )
      }, error = function(e) htmlEscape(as.character(r[["evidence"]])))
      sprintf(
        '<tr style="background-color:%s;">
<td style="padding:4px 10px;font-family:monospace;font-size:11px;">%s…</td>
<td style="padding:4px 10px;">%s</td>
<td style="padding:4px 10px;font-size:11px;color:%s;max-width:320px;
   white-space:normal;word-break:break-word;">%s</td>
</tr>',
        DARK_CARD, sid, severity_badge(r[["severity"]]), DARK_MUTED, ev_preview
      )
    }), collapse = "\n")
    table_html <- sprintf(
      '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:4px 10px;text-align:left;">Session</th>
<th style="padding:4px 10px;text-align:left;">Severity</th>
<th style="padding:4px 10px;text-align:left;">Evidence</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
      DARK_TEXT, EMAIL_FONT_SUBTITLE, DARK_ROW_ALT, rows_html
    )
  }
  collapsible_block(
    sprintf("Detail: %s", ftype),
    sprintf("%d rows", total_n),
    table_html
  )
}

sec1_drilldowns_html <- if (length(sec1_drilldown_types) > 0L) {
  blocks <- vapply(sec1_drilldown_types, function(ft) {
    total_n <- sec1_type_totals$n[sec1_type_totals$finding_type == ft]
    block <- build_finding_drilldown(ft, total_n)
    if (is.null(block)) "" else block
  }, character(1))
  paste(blocks, collapse = "\n")
} else {
  ""
}

sec1_table <- paste(sec1_table, sec1_drilldowns_html, sep = "\n")

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
# errors: retired from this DEAD/STALE flagging set — no producer (llm#784);
# re-add when a producer is wired. Table still appears in Section 3 below
# (cumulative totals only, no alarm).
source_tables <- c("sessions", "agent_runs", "hook_events")

# ── Shared staleness view lookup (llm#893 step 3) ─────────────────────────────
# `sessions` and `agent_runs` are tracked as `etl_source` assets in the
# consolidated `staleness` fact table (see staleness_collect.sh, which carries
# them forward from etl_freshness with cadences of 72h / 48h respectively).
# Their STALE verdict below is read from the single shared `staleness_status`
# view instead of a locally recomputed "0 rows in 24h AND gap<48h" rule, so
# this section can never disagree with the session-start banner
# (staleness_banner.sh) about the same two assets -- the exact drift the
# issue's motivating incident was about.
#
# `hook_events` has no row in `staleness` (no cadence has ever been assigned
# to it) so it keeps the local hours_since-based fallback below unchanged --
# see the llm#893 step-3 dispatch report for why that gap is not closed here
# (assigning it a cadence is a schema-widening decision left to the issue).
staleness_lookup <- function(asset_id) {
  row <- safe_query(sprintf("
    SELECT status,
           FLOOR(EXTRACT(EPOCH FROM observation_age) / 60.0) AS observation_age_min
    FROM staleness_status
    WHERE asset_kind = 'etl_source' AND asset_id = '%s'
  ", gsub("'", "''", asset_id, fixed = TRUE)))
  if (nrow(row) == 0L) return(NULL)
  list(status = row$status[[1]], observation_age_min = row$observation_age_min[[1]])
}

# Renders the "how old is this VERDICT" fact (llm#893's `observation_age`) in
# a form a human reads at a glance, never raw seconds/minutes.
fmt_observation_age <- function(minutes) {
  if (is.null(minutes) || is.na(minutes)) return(NA_character_)
  if (minutes < 60) return(sprintf("%.0fm ago", minutes))
  sprintf("%.0fh ago", minutes / 60)
}

sec2_rows <- lapply(source_tables, function(tbl) {
  ts_col <- switch(tbl,
    sessions   = "started_at",
    agent_runs = "started_at",
    hook_events = "fired_at"
  )

  # Exclude synthetic health-probe rows (project='ClaudeProbe') from the sessions
  # volume so this health readout reflects real sessions, not the probe fleet.
  # Interim email-layer fix pending source-level tagging in llm#812.
  where_clause <- if (identical(tbl, "sessions")) "WHERE project NOT IN ('ClaudeProbe')" else ""

  info <- safe_query(sprintf("
    SELECT
      COUNT(*) AS total,
      COUNT(CASE WHEN %s >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR THEN 1 END) AS last_24h,
      MAX(%s) AS latest_ts
    FROM %s
    %s
  ", ts_col, ts_col, tbl, where_clause))

  sv <- if (tbl %in% c("sessions", "agent_runs")) staleness_lookup(tbl) else NULL
  obs_age_txt <- if (!is.null(sv)) (fmt_observation_age(sv$observation_age_min) %||% "—") else NA_character_

  if (nrow(info) == 0L) {
    fallback_status <- if (!is.null(sv)) toupper(sv$status) else "DEAD"
    return(list(table = tbl, total = 0L, last_24h = 0L,
                latest_ts = NA_character_, status = fallback_status,
                observation_age = obs_age_txt))
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
  } else if (!is.null(sv)) {
    # llm#893: verdict comes from the shared staleness_status view (per-asset
    # cadence), NOT a local hardcoded 48h gap rule. Replaces the old
    # `hours_since <= 48 -> STALE else DEAD` branch for tracked assets.
    toupper(sv$status)
  } else if (hours_since <= 48) {
    "STALE"
  } else {
    "DEAD"
  }

  list(table = tbl, total = total, last_24h = n24,
       latest_ts = as.character(latest), status = status,
       observation_age = obs_age_txt)
})

status_color <- function(s) {
  switch(s,
    "live"   = ACCENT_GREEN,
    "sparse" = ACCENT_ORANGE,
    "FRESH"  = ACCENT_GREEN,   # llm#893: shared-view verdict for tracked assets
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

# ── content_status badge (llm#893 step 4, section D) ──────────────────────────
# `content_status` is a SECOND, independent verdict from the shared
# staleness_status view -- magnitude ("did this grow unusually?"), not
# recency. It is meaningful only for asset_kind IN ('log_growth', 'db_bloat');
# every other row's content_status is permanently NULL there (never
# content-checked) and is rendered as the plain "N/A" dash below, distinct
# from a genuine pending verdict.
#
# NULL on a content-checked row means "no prior observation yet" (a
# delta-based detector's first-ever run has nothing to diff against) --
# rendered PENDING, an orange badge distinct from both the red FIRED badges
# and the quiet green NORMAL badge. This is deliberate: an absent verdict
# must never read the same as a clean one, or a check that has never run
# looks identical to a check that passed (the gap this whole render exists
# to close -- see the content_status doc block in staleness_schema.sql).
content_status_color <- function(s) {
  switch(s,
    "ABNORMAL_GROWTH" = "#ff5252",
    "BLOAT"           = "#ff5252",
    "NORMAL"          = ACCENT_GREEN,
    "PENDING"         = ACCENT_ORANGE,
    DARK_MUTED
  )
}

content_status_badge <- function(s) {
  if (identical(s, "N/A")) {
    return(sprintf('<span style="color:%s;">&mdash;</span>', DARK_MUTED))
  }
  col <- content_status_color(s)
  sprintf(
    '<span style="background-color:%s;color:%s;padding:2px 8px;border-radius:3px;
font-size:12px;font-weight:bold;">%s</span>',
    col,
    if (s %in% c("ABNORMAL_GROWTH", "BLOAT")) "#fff" else "#000",
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
<td style="padding:6px 10px;font-size:11px;color:%s;text-align:right;">%s</td>
</tr>',
    DARK_CARD,
    r$table,
    format(r$total, big.mark = ","),
    format(r$last_24h, big.mark = ","),
    DARK_MUTED,
    r$latest_ts %||% "—",
    status_badge(r$status),
    DARK_MUTED,
    r$observation_age %||% "—"
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
<th style="padding:6px 10px;text-align:right;">Observed (llm#893)</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>
<p style="color:%s;font-size:%s;margin-top:8px;">
  Status: <b>live</b> ≥10 rows/24h &nbsp;|&nbsp;
  <b style="color:%s;">sparse</b> 1–9 rows/24h &nbsp;|&nbsp;
  <b style="color:%s;">FRESH</b>/<b style="color:#ff5252;">STALE</b> 0 rows/24h,
  verdict from the shared <code>staleness_status</code> view for tracked
  assets (sessions, agent_runs) &nbsp;|&nbsp;
  <b style="color:#ff5252;">DEAD</b> 0 rows/24h, untracked asset (hook_events),
  gap &ge;48h
</p>
<p style="color:%s;font-size:%s;margin-top:4px;">
  "Observed" is the shared view\'s <code>observation_age</code> -- how old the
  underlying fact is, not how old the row is. A verdict with a large
  "Observed" age is itself untrustworthy (the collector has not run
  recently) even if it reads FRESH. "—" = asset not tracked in
  <code>staleness</code> (see the unified staleness section below).
</p>',
  DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT,
  sec2_rows_html,
  DARK_MUTED, EMAIL_FONT_SUBTITLE,
  ACCENT_ORANGE, ACCENT_GREEN,
  DARK_MUTED, EMAIL_FONT_SUBTITLE
)

sec2_summary <- sprintf("%d source tables · %d stale/dead · sessions excl. synthetic ClaudeProbe (#812)",
                        length(source_tables), n_stale_tables)

# ── Section 2b: Sessions by project (last 24h) — llm#818 slice ────────────────
# The `sessions` row above already excludes the synthetic ClaudeProbe
# health-probe project (#812) so probe traffic doesn't masquerade as an ETL
# anomaly. This drill-down deliberately does NOT apply that exclusion — it
# shows the full per-project breakdown, ClaudeProbe included, so a genuine
# spike in real project traffic is visible against the synthetic baseline.
#
# NOTE: a hook_events-by-source breakdown is intentionally NOT added here —
# hook_events currently has a single producer (this harness), so a per-source
# split would be degenerate. It awaits hook instrumentation (llm#818).
sec2_sessions_by_project <- safe_query("
  SELECT project, COUNT(*) AS n
  FROM sessions
  WHERE started_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
  GROUP BY project
  ORDER BY n DESC
")

sec2_sessions_drilldown <- if (nrow(sec2_sessions_by_project) > 0L) {
  rows_html <- paste(apply(sec2_sessions_by_project, 1, function(r) {
    is_synthetic <- identical(r[["project"]], "ClaudeProbe")
    note <- if (is_synthetic) {
      sprintf(' <span style="color:%s;font-size:10px;">(synthetic health probe)</span>', DARK_MUTED)
    } else {
      ""
    }
    sprintf(
      '<tr style="background-color:%s;">
<td style="padding:4px 10px;font-family:monospace;">%s%s</td>
<td style="padding:4px 10px;text-align:right;">%s</td>
</tr>',
      DARK_CARD, htmlEscape(r[["project"]]), note, r[["n"]]
    )
  }), collapse = "\n")
  table_html <- sprintf(
    '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead>
<tr style="background-color:%s;">
<th style="padding:4px 10px;text-align:left;">Project</th>
<th style="padding:4px 10px;text-align:right;">Sessions (24h)</th>
</tr>
</thead>
<tbody>%s</tbody>
</table>',
    DARK_TEXT, EMAIL_FONT_SUBTITLE, DARK_ROW_ALT, rows_html
  )
  collapsible_block(
    "Sessions by project (24h)",
    sprintf("%d project(s)", nrow(sec2_sessions_by_project)),
    table_html
  )
} else {
  ""
}

sec2_table <- paste(sec2_table, sec2_sessions_drilldown, sep = "\n")

sec2_block <- collapsible_block(
  "Source table volume (last 24h)",
  sec2_summary,
  sec2_table
)

# ── Section: Unified staleness (llm#893 shared view) ──────────────────────────
# The single `staleness_status` view (llm#893 steps 1-2) is now the ONE
# definition of "is this asset stale" -- this section is the "several
# renderings, one surface" step (llm#893 step 3): every tracked etl_source /
# launchd_job / collector asset, with the SAME status computation used by
# session_init.sh's staleness_banner.sh (a different trigger class from this
# nightly email, so the two can never quietly disagree).
#
# `observation_age` (how old the OBSERVATION is, not the asset) is rendered
# next to every status -- without it a verdict that is hours old reads as
# current. Verified live 2026-08-16: the table showed
# com.claude.roborev-weekly-rollup-email as "stale, observed 172h ago" and
# com.claude.roborev-severity-autoclose as "stale, observed 28h ago" while
# BOTH had actually run successfully that morning -- the collector had simply
# not re-observed since 08:15. observation_age makes that visible instead of
# reading as two false alarms.
staleness_section <- tryCatch({
  view_exists <- safe_query("
    SELECT count(*) AS n FROM information_schema.tables
    WHERE table_name = 'staleness_status'
  ", fallback = data.frame(n = 0L))
  view_present <- nrow(view_exists) > 0L && isTRUE(as.integer(view_exists$n[[1]]) > 0L)

  if (!view_present) {
    list(
      body = sprintf(
        '<p style="color:#ff5252;">The <code>staleness_status</code> view is not
present in this database &mdash; llm#893 steps 1-2 have not run here, or the DB
path is wrong. No staleness verdict is available; this is a configuration
gap, not a clean bill of health.</p>'),
      summary = "view absent"
    )
  } else {
    rows <- safe_query("
      SELECT
        asset_kind, asset_id, status, content_status,
        last_seen_ts,
        FLOOR(EXTRACT(EPOCH FROM observation_age) / 60.0) AS observation_age_min
      FROM staleness_status
      ORDER BY
        CASE WHEN asset_kind = 'collector' THEN 0 ELSE 1 END,
        CASE WHEN status = 'stale' THEN 0 ELSE 1 END,
        asset_kind, asset_id
    ")

    if (nrow(rows) == 0L) {
      list(
        body = sprintf(
          '<p style="color:#ff5252;">staleness_status exists but has zero rows
&mdash; staleness_collect.sh has never written a heartbeat here. Nothing is
trustworthy yet.</p>'),
        summary = "empty (no collector runs yet)"
      )
    } else {
      collector_row <- rows[rows$asset_kind == "collector" & rows$asset_id == "staleness_collect", , drop = FALSE]
      collector_stale <- nrow(collector_row) > 0L && identical(collector_row$status[[1]], "stale")

      # content_status (llm#893 step 4) is a SECOND, independent verdict --
      # meaningful only for asset_kind IN ('log_growth', 'db_bloat'). Every
      # other row's content_status is permanently NULL there and is labelled
      # "N/A" (not content-checked), never "PENDING" (which is reserved for
      # a content-checked row with no prior observation yet -- see
      # content_status_badge() above for why the two must not be conflated).
      content_label_for <- function(asset_kind, content_status) {
        if (!(asset_kind %in% c("log_growth", "db_bloat"))) return("N/A")
        if (is.na(content_status)) return("PENDING")
        toupper(content_status)
      }

      rows_html <- paste(apply(rows, 1, function(r) {
        is_stale <- identical(r[["status"]], "stale")
        content_label <- content_label_for(r[["asset_kind"]], r[["content_status"]])
        is_content_flagged <- content_label %in% c("ABNORMAL_GROWTH", "BLOAT")
        row_bg <- if (is_stale || is_content_flagged) "#2a0a0a" else DARK_CARD
        sprintf(
          '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-size:11px;color:%s;">%s</td>
<td style="padding:5px 10px;font-family:monospace;font-size:12px;max-width:280px;
   word-break:break-all;">%s</td>
<td style="padding:5px 10px;text-align:center;">%s</td>
<td style="padding:5px 10px;text-align:center;">%s</td>
<td style="padding:5px 10px;font-size:11px;color:%s;">%s</td>
<td style="padding:5px 10px;font-size:11px;color:%s;text-align:right;">%s</td>
</tr>',
          row_bg,
          DARK_MUTED, r[["asset_kind"]],
          htmlEscape(r[["asset_id"]]),
          status_badge(toupper(r[["status"]])),
          content_status_badge(content_label),
          DARK_MUTED, r[["last_seen_ts"]] %||% "never",
          DARK_MUTED, fmt_observation_age(suppressWarnings(as.numeric(r[["observation_age_min"]]))) %||% "—"
        )
      }), collapse = "\n")

      table_html <- sprintf(
        '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead><tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">Kind</th>
<th style="padding:5px 10px;text-align:left;">Asset</th>
<th style="padding:5px 10px;text-align:center;">Status</th>
<th style="padding:5px 10px;text-align:center;">Content</th>
<th style="padding:5px 10px;text-align:left;">Last seen</th>
<th style="padding:5px 10px;text-align:right;">Observed</th>
</tr></thead><tbody>%s</tbody></table>',
        DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, rows_html
      )

      n_stale <- sum(rows$status == "stale", na.rm = TRUE)
      n_total <- nrow(rows)

      content_labels <- mapply(content_label_for, rows[["asset_kind"]], rows[["content_status"]])
      n_content_flagged <- sum(content_labels %in% c("ABNORMAL_GROWTH", "BLOAT"))
      n_content_pending <- sum(content_labels == "PENDING")

      collector_warning <- if (collector_stale) {
        sprintf(
          '<p style="color:#ff5252;font-size:%s;font-weight:bold;margin-bottom:8px;">
&#9888; COLLECTOR STALE &mdash; staleness_collect has not run recently. Every
verdict below may be out of date; treat this whole section as untrustworthy
until the collector fires again (see staleness_banner.sh, llm#893 step 2).</p>',
          EMAIL_FONT_SUBTITLE
        )
      } else {
        ""
      }

      body <- paste0(collector_warning, table_html)

      summary <- if (n_stale == 0L) {
        sprintf("%d assets · all fresh%s", n_total,
                if (collector_stale) " (but collector stale -- do not trust this)" else "")
      } else {
        sprintf("%d assets · %d stale%s", n_total, n_stale,
                if (collector_stale) " · COLLECTOR STALE" else "")
      }

      # Content-axis counts (llm#893 step 4) appended to the same summary
      # line, same "only mention what's non-trivial" discipline as the
      # time-axis n_stale clause above. PENDING is reported alongside
      # flagged findings, not silently dropped, per the content_status NULL
      # discipline documented on content_status_badge() above.
      content_note_parts <- character(0)
      if (n_content_flagged > 0L) {
        content_note_parts <- c(content_note_parts, sprintf("%d content flagged", n_content_flagged))
      }
      if (n_content_pending > 0L) {
        content_note_parts <- c(content_note_parts, sprintf("%d pending", n_content_pending))
      }
      if (length(content_note_parts) > 0L) {
        summary <- paste0(summary, " · ", paste(content_note_parts, collapse = ", "))
      }

      list(body = body, summary = summary)
    }
  }
}, error = function(e) {
  list(
    body    = sprintf('<p style="color:#ff5252;">Unified staleness section failed: %s</p>',
                      htmlEscape(conditionMessage(e))),
    summary = "error"
  )
})

sec_staleness_block <- collapsible_block(
  "Unified staleness (shared view, llm#893)",
  staleness_section$summary,
  staleness_section$body
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
    sha_cell <- if (!is.na(r[["commit_sha"]]) && nchar(r[["commit_sha"]]) >= 7L) {
      sprintf(
        '<a href="https://github.com/JohnGavin/llm/commit/%s" style="color:%s;text-decoration:underline;">%s</a>',
        r[["commit_sha"]], ACCENT_BLUE, substr(r[["commit_sha"]], 1L, 7L)
      )
    } else "—"
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
      DARK_MUTED, sha_cell
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

# Hide retired plists (llm#554): launchd_health_events is append-only, so a
# plist_label retired/renamed/uninstalled (its .plist file removed from
# ~/Library/LaunchAgents) still has a last-known row and would otherwise
# keep appearing here forever as "unloaded" — e.g. com.claude.capability-
# registry, retired 2026-07-23, showing up in this table long after removal.
# Filter to labels whose plist file still exists on disk.
if (nrow(cron_health) > 0L) {
  .launch_agents_dir <- path.expand("~/Library/LaunchAgents")
  .plist_installed <- vapply(cron_health$plist_label, function(lbl) {
    file.exists(file.path(.launch_agents_dir, paste0(lbl, ".plist")))
  }, logical(1))
  cron_health <- cron_health[.plist_installed, , drop = FALSE]
}

# Freshness guard (llm#510 attempt #3): the ROW_NUMBER()-partitioned query
# above answers "what is the latest known state per plist", which is only
# trustworthy if the launchd_health_events table itself has been refreshed
# recently. If the table's sole weekly writer (launchd_health_weekly_cron.sh)
# has not fired in a while, every row below is stale — a "failed" state may
# just be old news, not a current problem. Surfaced after the false-positive
# "5 failed" report on 2026-07-11 (metrics-etl/self-review/weekly-rollup were
# actually last-exit 0 per `launchctl print`; the table just hadn't refreshed).
cron_freshness <- safe_query("SELECT MAX(fired_at) AS newest_fired_at FROM launchd_health_events")
cron_stale_note <- ""
if (nrow(cron_freshness) > 0L) {
  .newest_fired_at <- cron_freshness$newest_fired_at[[1]]
  if (!is.null(.newest_fired_at) && !is.na(.newest_fired_at)) {
    .cron_age_hours <- as.numeric(difftime(Sys.time(),
                                            as.POSIXct(.newest_fired_at, tz = "UTC"),
                                            units = "hours"))
    if (!is.na(.cron_age_hours) && .cron_age_hours > 48) {
      cron_stale_note <- sprintf(
        '<p style="color:#ff5252;font-size:%s;margin-bottom:8px;">
  &#9888; launchd_health_events is stale (newest row %s, %.0fh old) — \'failed\'
  states below may be historical, not current. Verify with <code>launchctl print</code>.</p>',
        EMAIL_FONT_SUBTITLE, .newest_fired_at, .cron_age_hours
      )
    }
  }
}

if (nrow(cron_health) > 0L) {
  n_fail  <- sum(cron_health$state %in% c("loaded_recent_fail", "unloaded", "missing"),
                 na.rm = TRUE)
  n_ok    <- sum(cron_health$state == "loaded_ok", na.rm = TRUE)
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

  cron_table_html <- paste0(
    cron_stale_note,
    sprintf(
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
  cron_table_html <- paste0(
    cron_stale_note,
    sprintf(
      '<p style="color:%s;font-size:%s;">No launchd_health_events recorded yet.</p>',
      DARK_MUTED, EMAIL_FONT_BODY
    )
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
    WHERE fired_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR
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

# ── Section: hook liveness — registered vs firing (llm#950) ─────────────────
# Prior to llm#950, only 1 of ~15 registered hooks (context_monitor) wrote to
# hook_events, so a hook that silently stopped firing was indistinguishable
# from a hook with nothing to report — the exact failure mode that already
# bit llm#913 and llm#695. This section cross-references EVERY hook script
# registered in settings.json against hook_events fire counts.
#
# The registered set is derived by PARSING settings.json's hooks block, not
# a hardcoded list — llm#944 showed a hardcoded rule list silently drifting
# out of sync with policy while its checker kept passing. A hook here with
# ZERO fires in 7 days IS the alert (zero-metric-evidence-or-defect rule):
# it means either the hook was never wired to emit, or it was wired and has
# since gone silent — both worth knowing, and indistinguishable without this
# table.

# Walk every event-type array -> matcher-group -> hooks[] -> command,
# extracting the basename of any command that targets a .claude/hooks/<name>.sh
# script. Inline one-liners (afplay/osascript sound triggers etc.) have no
# hook_name to match against hook_events and are intentionally excluded, not
# counted as "silent". Returns character(0) (not an error) if settings.json is
# missing or unparseable — callers decide how to report that.
derive_registered_hooks <- function(settings_path) {
  # NOTE: deliberately does NOT use the file's %||% operator here. %||% reads
  # a[[1L]] and calls is.na()/nzchar() on it, which is only safe for scalar
  # values. hooks_cfg / event_groups / grp$hooks are nested LISTS (multiple
  # event types, each with multiple matcher-groups, each with multiple hook
  # entries) -- calling is.na() on a multi-field list element throws
  # "the condition has length > 1" (found via `EMAIL_DRY_RUN=1` smoke test,
  # llm#950). Use explicit is.null() checks for anything structural instead.
  if (!file.exists(settings_path)) return(character(0))
  settings_cfg <- jsonlite::fromJSON(settings_path, simplifyVector = FALSE)
  hooks_cfg <- settings_cfg$hooks
  if (is.null(hooks_cfg)) hooks_cfg <- list()
  registered <- character(0)
  for (event_groups in hooks_cfg) {
    for (grp in event_groups) {
      hlist <- grp$hooks
      if (is.null(hlist)) hlist <- list()
      for (h in hlist) {
        cmd <- h$command
        if (is.null(cmd) || !is.character(cmd) || length(cmd) != 1L) cmd <- ""
        m <- regmatches(cmd, regexpr("\\.claude/hooks/[A-Za-z0-9_]+\\.sh", cmd))
        if (length(m) && nzchar(m)) {
          registered <- c(registered, sub("^.*/([A-Za-z0-9_]+)\\.sh$", "\\1", m))
        }
      }
    }
  }
  sort(unique(registered))
}

.hook_liveness_settings_path <- path.expand("~/.claude/settings.json")
.hook_liveness_registered <- tryCatch(
  derive_registered_hooks(.hook_liveness_settings_path),
  error = function(e) character(0)
)

hook_liveness_block <- tryCatch({
  if (!file.exists(.hook_liveness_settings_path)) {
    sprintf('<p style="color:%s;">settings.json not found at %s.</p>',
            DARK_MUTED, htmlEscape(.hook_liveness_settings_path))
  } else {
    registered <- .hook_liveness_registered

    if (length(registered) == 0L) {
      sprintf('<p style="color:%s;">No hook scripts found under settings.json\'s hooks block.</p>', DARK_MUTED)
    } else {
      # Independent evidence check (zero-metric-evidence-or-defect): confirm
      # hook_events itself is reachable and has SOME rows before trusting any
      # per-hook zero below — a query that silently returns empty because the
      # table/db is unreachable must not be reported as "0 registered hooks
      # fired", which would misleadingly imply every hook is broken.
      evidence <- safe_query("SELECT count(*) AS n FROM hook_events", fallback = data.frame(n = NA_integer_))
      evidence_n <- if (nrow(evidence) > 0L) evidence$n[[1]] else NA_integer_

      fire_counts <- safe_query("
        SELECT
          hook_name,
          SUM(CASE WHEN fired_at >= current_timestamp::TIMESTAMP - INTERVAL '24' HOUR THEN 1 ELSE 0 END) AS fires_24h,
          SUM(CASE WHEN fired_at >= current_timestamp::TIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END) AS fires_7d,
          MAX(fired_at) AS last_fired_at
        FROM hook_events
        GROUP BY hook_name
      ")

      reg_df <- data.frame(hook_name = registered, stringsAsFactors = FALSE)
      merged <- merge(reg_df, fire_counts, by = "hook_name", all.x = TRUE)
      merged$fires_24h <- ifelse(is.na(merged$fires_24h), 0L, merged$fires_24h)
      merged$fires_7d  <- ifelse(is.na(merged$fires_7d), 0L, merged$fires_7d)
      merged <- merged[order(merged$fires_7d, merged$hook_name), , drop = FALSE]
      n_silent <- sum(merged$fires_7d == 0L)

      if (!is.na(evidence_n) && evidence_n > 0L && all(merged$fires_7d == 0L)) {
        # The raw table has rows but every registered hook shows zero — the
        # per-hook aggregation (not the hooks) is broken. Fail loud rather
        # than rendering a table that looks like "every hook is dead".
        sprintf(
          '<p style="color:#ff5252;">INCONSISTENT: hook_events has %d row(s) but the
per-hook aggregation returned zero for all %d registered hooks — the query, not the
hooks, is likely broken. See zero-metric-evidence-or-defect rule.</p>',
          evidence_n, length(registered)
        )
      } else {
        rows_html <- paste(apply(merged, 1, function(r) {
          is_silent <- as.integer(r[["fires_7d"]]) == 0L
          row_bg <- if (is_silent) "#2a0a0a" else DARK_CARD
          f7_col <- if (is_silent) "#ff5252" else DARK_TEXT
          sprintf(
            '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-family:monospace;font-size:12px;">%s</td>
<td style="padding:5px 10px;text-align:right;font-size:12px;color:%s;">%s</td>
<td style="padding:5px 10px;text-align:right;font-size:12px;color:%s;font-weight:bold;">%s</td>
<td style="padding:5px 10px;font-size:11px;color:%s;">%s</td>
</tr>',
            row_bg,
            htmlEscape(r[["hook_name"]]),
            DARK_TEXT, r[["fires_24h"]],
            f7_col, r[["fires_7d"]],
            DARK_MUTED, r[["last_fired_at"]] %||% "never"
          )
        }), collapse = "\n")

        paste0(
          sprintf(
            '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead><tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">Hook</th>
<th style="padding:5px 10px;text-align:right;">Fires 24h</th>
<th style="padding:5px 10px;text-align:right;">Fires 7d</th>
<th style="padding:5px 10px;text-align:left;">Last fired</th>
</tr></thead><tbody>%s</tbody></table>',
            DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, rows_html
          ),
          sprintf(
            '<p style="color:%s;font-size:%s;margin-top:8px;">
%d/%d registered hooks silent (0 fires) in the last 7 days. Some guards only emit
on their own BLOCK path and only when not in an off/log mode (e.g.
compound_command_guard under COMPOUND_GUARD_MODE=log) — a persistent zero there
reflects configuration, not a dead hook. Cross-check the guard\'s own
~/.claude/logs/*.log before filing an issue. Emitter: hook_event_emit.sh ·
Loader: hook_events_load.sh · llm#950.</p>',
            if (n_silent > 0L) "#ff5252" else DARK_MUTED, EMAIL_FONT_SUBTITLE,
            n_silent, length(registered)
          )
        )
      }
    }
  }
}, error = function(e) {
  sprintf('<p style="color:#ff5252;">hook liveness section failed: %s</p>',
          htmlEscape(conditionMessage(e)))
})

hook_liveness_summary <- tryCatch({
  registered <- .hook_liveness_registered
  if (length(registered) == 0L) {
    "settings.json not found or no hook scripts registered"
  } else {
    fc <- safe_query("
      SELECT hook_name,
             SUM(CASE WHEN fired_at >= current_timestamp::TIMESTAMP - INTERVAL '7' DAY THEN 1 ELSE 0 END) AS fires_7d
      FROM hook_events GROUP BY hook_name
    ")
    silent <- sum(!(registered %in% fc$hook_name[fc$fires_7d > 0L]))
    sprintf("%d registered · %d silent 7d", length(registered), silent)
  }
}, error = function(e) "unavailable")

sec_hooks_block <- collapsible_block(
  "Hook liveness (registered vs firing)",
  hook_liveness_summary,
  hook_liveness_block
)

# ── Section: Secret-exposure scan (llm#951) ───────────────────────────────────
# secret_exposure_scan.sh runs nightly at 03:40 (com.claude.secret-exposure-
# scan.plist) and writes one housekeeping_runs row per invocation (task=
# 'secret_exposure_scan') plus one secret_scan_findings row per finding,
# batched. Placed adjacent to the hook-liveness section above -- both exist
# for the same reason (zero-metric-evidence-or-defect, llm#913/#695/#950):
# without a heartbeat, a scanner that stopped firing is indistinguishable
# from a scanner reporting zero findings, and "0 findings" is exactly the
# number this scan would most like readers to trust blindly. Shows findings
# by detector for the latest run, the delta vs the PREVIOUS run (the
# actionable signal -- a rise in detector 2 means a new plaintext credential
# appeared on disk since yesterday), and when the scanner last fired, with a
# loud line if that is over 48h ago.
secret_scan_section <- tryCatch({
  # Deliberately does NOT use %||% here for the same reason
  # derive_registered_hooks() above avoids it: %||% calls is.na()/nzchar() on
  # a[[1L]], which is only safe for a length-1 scalar. latest_runs$started_at
  # etc. below are data.frame columns pulled via `[[i]]` (already scalar), so
  # %||% IS safe for those -- but the query result itself (0 vs >=1 rows)
  # is a structural branch, checked with nrow()/is.null(), not %||%.
  latest_runs <- safe_query("
    SELECT id, started_at, ended_at, status, rows_written
    FROM housekeeping_runs
    WHERE task = 'secret_exposure_scan'
    ORDER BY started_at DESC
    LIMIT 2
  ")

  if (is.null(latest_runs) || nrow(latest_runs) == 0L) {
    list(
      body    = sprintf('<p style="color:%s;">No secret_exposure_scan runs recorded yet -- expected nightly at 03:40.</p>', DARK_MUTED),
      summary = "no runs recorded yet"
    )
  } else {
    latest_id      <- latest_runs$id[[1]]
    latest_status  <- latest_runs$status[[1]]
    latest_n       <- suppressWarnings(as.integer(latest_runs$rows_written[[1]]))
    if (is.na(latest_n)) latest_n <- 0L
    latest_started <- latest_runs$started_at[[1]]

    has_prev <- nrow(latest_runs) >= 2L
    prev_n <- if (has_prev) suppressWarnings(as.integer(latest_runs$rows_written[[2]])) else NA_integer_

    # Freshness uses the LATEST run regardless of status -- a stuck or
    # failed scanner should still surface here, not just a successful one.
    hours_since <- if (!is.null(latest_started) && !is.na(latest_started)) {
      as.numeric(difftime(Sys.time(), as.POSIXct(latest_started, tz = "UTC"), units = "hours"))
    } else {
      NA_real_
    }

    stale_note <- if (!is.na(hours_since) && hours_since > 48) {
      sprintf(
        '<p style="color:#ff5252;font-size:%s;margin-bottom:8px;">
  &#9888; secret_exposure_scan has not run in %.0fh (last: %s) -- expected nightly
  at 03:40. Check com.claude.secret-exposure-scan.plist via launchd_health_audit.sh.</p>',
        EMAIL_FONT_SUBTITLE, hours_since, latest_started
      )
    } else {
      ""
    }

    by_detector <- safe_query(sprintf("
      SELECT detector, severity, count(*) AS n
      FROM secret_scan_findings
      WHERE run_id = '%s'
      GROUP BY detector, severity
      ORDER BY detector
    ", latest_id))

    detector_table <- if (nrow(by_detector) > 0L) {
      rows_html <- paste(apply(by_detector, 1, function(r) {
        sprintf(
          '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-family:monospace;">det %s</td>
<td style="padding:5px 10px;">%s</td>
<td style="padding:5px 10px;text-align:right;font-weight:bold;">%s</td>
</tr>',
          DARK_CARD, htmlEscape(r[["detector"]]), severity_badge(r[["severity"]]), r[["n"]]
        )
      }), collapse = "\n")
      sprintf(
        '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead><tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">Detector</th>
<th style="padding:5px 10px;text-align:left;">Severity</th>
<th style="padding:5px 10px;text-align:right;">Count</th>
</tr></thead><tbody>%s</tbody></table>',
        DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, rows_html
      )
    } else {
      sprintf('<p style="color:%s;font-size:%s;">0 findings on the latest run.</p>', ACCENT_GREEN, EMAIL_FONT_BODY)
    }

    delta_html <- if (!has_prev || is.na(prev_n)) {
      '<span style="color:#888;">no previous run to compare</span>'
    } else {
      delta <- latest_n - prev_n
      if (delta > 0L) {
        sprintf('<span style="color:#ff5252;font-weight:bold;">+%d vs previous run (%d &rarr; %d)</span>', delta, prev_n, latest_n)
      } else if (delta < 0L) {
        sprintf('<span style="color:%s;">%d vs previous run (%d &rarr; %d)</span>', ACCENT_GREEN, delta, prev_n, latest_n)
      } else {
        sprintf('<span style="color:%s;">unchanged vs previous run (%d)</span>', DARK_MUTED, latest_n)
      }
    }

    status_col <- if (identical(latest_status, "ok")) ACCENT_GREEN else "#ff5252"

    body <- paste0(
      stale_note,
      sprintf(
        '<p style="font-size:%s;color:%s;margin:4px 0 8px 0;">Latest run: <b style="color:%s;">%s</b>
&nbsp;&middot;&nbsp; %d finding(s) &nbsp;&middot;&nbsp; %s &nbsp;&middot;&nbsp; fired %s</p>',
        EMAIL_FONT_SUBTITLE, DARK_TEXT, status_col, latest_status, latest_n, delta_html,
        if (!is.null(latest_started) && !is.na(latest_started)) latest_started else "unknown"
      ),
      detector_table
    )

    list(
      body    = body,
      summary = sprintf(
        "%d finding(s) · %s · last run %s",
        latest_n, latest_status,
        if (!is.na(hours_since)) sprintf("%.0fh ago", hours_since) else "unknown"
      )
    )
  }
}, error = function(e) {
  list(
    body    = sprintf('<p style="color:#ff5252;">secret-exposure-scan section failed: %s</p>', htmlEscape(conditionMessage(e))),
    summary = "error"
  )
})

sec_secret_scan_block <- collapsible_block(
  "Secret-exposure scan (nightly, 03:40)",
  secret_scan_section$summary,
  secret_scan_section$body
)

# ── Section: Agent failed with empty stdout — cause unknown (llm#954) ────────
# roborev's own error message for this failure class is FABRICATED: when an
# agent process exits non-zero with EMPTY stdout, roborev cannot parse the
# stream-json response it expected and reports
#   "agent: <agent> failed: exit status N (parse error: no valid stream-json)"
# -- describing its OWN parsing step, not the agent's actual failure. The
# real cause (e.g. a missing/expired API key) is on the agent's STDERR, which
# roborev discards. See roborev-resolution.md's "no valid stream-json" note
# for the diagnostic procedure (run the agent's command manually, read
# stderr).
#
# Consecutive failures from ONE agent are the signal worth alerting on --
# sporadic single failures are noise (transient network blip, rate limit);
# an unbroken run means the agent is wholly broken for every job it claims.
# Reads ~/.roborev/reviews.db (SQLite, read-only) via DuckDB's bundled sqlite
# extension -- same ROBOREV_DB env var + LOAD-then-INSTALL-fallback pattern
# as roborev_metrics_etl.R.
AGENT_FAILURE_STREAK_ALERT_THRESHOLD <- 3L  # consecutive failures -> loud alert (llm#954)

# Gaps-and-islands: within the window, order each agent's jobs by
# enqueued_at and flag ones matching the failure signature; the difference
# between two ROW_NUMBER()s (overall vs within-flag) is constant across a
# contiguous run of the same flag value, so grouping on it isolates runs.
# `max_streak` is HISTORICAL (the longest run anywhere in the window) and is
# NOT sufficient to alert on: a run that ended days ago is a resolved
# incident, not a live one (llm#(this fix) -- caught when a fixed 2026-08-06
# -> 08-14 gemini episode kept alerting after the daemon restart because the
# 7-day window still contained the old streak). `current_streak` is the run
# ending at the agent's MOST RECENT job -- counted back from the newest row
# until the first non-failure -- and is 0 whenever that latest job did not
# match the failure signature, however large the historical max was.
# `latest_status`/`latest_enqueued_at` (the newest job's status and
# timestamp, regardless of is_sig) are what let a reader tell live from
# resolved at a glance.
agent_failure_stats <- function(con, interval_sql) {
  sql <- sprintf("
    WITH ordered AS (
      SELECT agent, enqueued_at::TIMESTAMP AS enqueued_at, status,
        CASE WHEN status = 'failed' AND error LIKE '%%no valid stream-json%%'
             THEN 1 ELSE 0 END AS is_sig
      FROM roborev_src.review_jobs
      WHERE enqueued_at::TIMESTAMP >= current_timestamp::TIMESTAMP - INTERVAL %s
    ),
    ranked AS (
      SELECT agent, enqueued_at, status, is_sig,
        ROW_NUMBER() OVER (PARTITION BY agent ORDER BY enqueued_at DESC) AS rn_desc,
        ROW_NUMBER() OVER (PARTITION BY agent ORDER BY enqueued_at) AS rn_asc
      FROM ordered
    ),
    grp AS (
      SELECT agent, is_sig, rn_asc,
        rn_asc - ROW_NUMBER() OVER (PARTITION BY agent, is_sig ORDER BY rn_asc) AS grp_id
      FROM ranked
    ),
    runs AS (
      SELECT agent, grp_id, COUNT(*) AS run_length
      FROM grp
      WHERE is_sig = 1
      GROUP BY agent, grp_id
    ),
    streaks AS (
      SELECT agent, MAX(run_length) AS max_streak
      FROM runs
      GROUP BY agent
    ),
    counts AS (
      SELECT agent, SUM(is_sig) AS n_failures
      FROM ordered
      GROUP BY agent
      HAVING SUM(is_sig) > 0
    ),
    latest AS (
      -- the newest job per agent, any status -- the one fact that
      -- distinguishes 'broken now' from 'was broken'
      SELECT agent, status AS latest_status, enqueued_at AS latest_enqueued_at
      FROM ranked
      WHERE rn_desc = 1
    ),
    first_nonfail AS (
      -- counting back from the newest job (rn_desc = 1), the first row that
      -- is NOT the failure signature; everything newer than it (rn_desc 1..
      -- first_ok_rn-1) is the current unbroken run
      SELECT agent, MIN(rn_desc) AS first_ok_rn
      FROM ranked
      WHERE is_sig = 0
      GROUP BY agent
    ),
    agent_totals AS (
      SELECT agent, COUNT(*) AS n_total
      FROM ranked
      GROUP BY agent
    ),
    current_streak AS (
      -- no non-failure row in the window at all -> the whole window is the
      -- current streak (COALESCE falls back to n_total)
      SELECT t.agent,
        COALESCE(f.first_ok_rn - 1, t.n_total) AS current_streak
      FROM agent_totals t
      LEFT JOIN first_nonfail f USING (agent)
    )
    SELECT c.agent, c.n_failures, COALESCE(s.max_streak, 0) AS max_streak,
           COALESCE(cs.current_streak, 0) AS current_streak,
           l.latest_status, l.latest_enqueued_at
    FROM counts c
    LEFT JOIN streaks s USING (agent)
    LEFT JOIN current_streak cs USING (agent)
    LEFT JOIN latest l USING (agent)
    ORDER BY c.n_failures DESC
  ", interval_sql)
  DBI::dbGetQuery(con, sql)
}

agent_failure_section <- tryCatch({
  roborev_db_path <- Sys.getenv("ROBOREV_DB",
                                 file.path(Sys.getenv("HOME"), ".roborev", "reviews.db"))
  if (!file.exists(roborev_db_path)) {
    list(
      body    = sprintf('<p style="color:%s;">reviews.db not found at %s.</p>',
                        DARK_MUTED, htmlEscape(roborev_db_path)),
      summary = "reviews.db not found"
    )
  } else {
    # Independent :memory: DuckDB connection (not the main `con`) so this
    # section's ATTACH/LOAD activity cannot interact with the unified.duckdb
    # read-only connection above -- matches roborev_metrics_etl.R.
    roborev_con <- DBI::dbConnect(duckdb::duckdb(), ":memory:")
    on.exit(tryCatch(DBI::dbDisconnect(roborev_con, shutdown = TRUE),
                      error = function(e) NULL), add = TRUE)

    tryCatch({
      invisible(DBI::dbExecute(roborev_con, "LOAD sqlite"))
    }, error = function(e_load) {
      invisible(DBI::dbExecute(roborev_con, "INSTALL sqlite"))
      invisible(DBI::dbExecute(roborev_con, "LOAD sqlite"))
    })
    invisible(DBI::dbExecute(roborev_con, sprintf(
      "ATTACH '%s' AS roborev_src (TYPE sqlite, READ_ONLY)", roborev_db_path
    )))

    stats_24h <- agent_failure_stats(roborev_con, "'24' HOUR")
    stats_7d  <- agent_failure_stats(roborev_con, "'7' DAY")

    if (is.null(stats_7d) || nrow(stats_7d) == 0L) {
      list(
        body    = sprintf('<p style="color:%s;">No agent-failed-with-empty-stdout signature in the last 7 days.</p>',
                          ACCENT_GREEN),
        summary = "0 in last 7d"
      )
    } else {
      merged <- merge(stats_7d, stats_24h, by = "agent", all.x = TRUE,
                       suffixes = c("_7d", "_24h"))
      merged$n_failures_24h <- ifelse(is.na(merged$n_failures_24h), 0L, merged$n_failures_24h)
      merged$max_streak_24h <- ifelse(is.na(merged$max_streak_24h), 0L, merged$max_streak_24h)
      # The 7-day window is the widest we retain, so its current_streak /
      # latest_status / latest_enqueued_at are the authoritative "is this
      # agent broken RIGHT NOW" facts -- the 24h-window versions of the same
      # columns (now suffixed _24h by merge()) are not used below.
      merged <- merged[order(-merged$current_streak_7d, -merged$max_streak_7d), , drop = FALSE]

      max_streak_overall <- max(merged$max_streak_7d, na.rm = TRUE)
      # CRITICAL: alert on the CURRENT streak (the run ending at each agent's
      # most recent job), never the historical max_streak. A max streak that
      # ended before the agent's latest job is a RESOLVED incident -- alerting
      # on it fires for days after a fix lands (the daemon-restart fix in
      # llm#936 left gemini's 7-day max_streak at 62 for a week even though
      # the very next job after the restart succeeded).
      alert_agents <- merged$agent[merged$current_streak_7d >= AGENT_FAILURE_STREAK_ALERT_THRESHOLD]

      fmt_last_job_ts <- function(ts) {
        if (is.null(ts) || is.na(ts) || !nzchar(ts)) return("—")
        substr(ts, 1, 16)  # "YYYY-MM-DD HH:MM", drop seconds
      }

      rows_html <- paste(apply(merged, 1, function(r) {
        is_alert   <- as.integer(r[["current_streak_7d"]]) >= AGENT_FAILURE_STREAK_ALERT_THRESHOLD
        row_bg     <- if (is_alert) "#2a0a0a" else DARK_CARD
        streak_col <- if (is_alert) "#ff5252" else DARK_TEXT
        last_job   <- sprintf("%s @ %s",
                               r[["latest_status_7d"]] %||% "—",
                               fmt_last_job_ts(r[["latest_enqueued_at_7d"]]))
        sprintf(
          '<tr style="background-color:%s;">
<td style="padding:5px 10px;font-family:monospace;">%s</td>
<td style="padding:5px 10px;text-align:right;">%s</td>
<td style="padding:5px 10px;text-align:right;">%s</td>
<td style="padding:5px 10px;text-align:right;">%s</td>
<td style="padding:5px 10px;text-align:right;">%s</td>
<td style="padding:5px 10px;text-align:right;color:%s;font-weight:bold;">%s</td>
<td style="padding:5px 10px;">%s</td>
</tr>',
          row_bg, htmlEscape(r[["agent"]]),
          r[["n_failures_24h"]], r[["max_streak_24h"]],
          r[["n_failures_7d"]], r[["max_streak_7d"]],
          streak_col, r[["current_streak_7d"]],
          htmlEscape(last_job)
        )
      }), collapse = "\n")

      table_html <- sprintf(
        '<table style="width:auto;border-collapse:collapse;color:%s;font-size:%s;">
<thead><tr style="background-color:%s;">
<th style="padding:5px 10px;text-align:left;">Agent</th>
<th style="padding:5px 10px;text-align:right;">Failures 24h</th>
<th style="padding:5px 10px;text-align:right;">Max streak 24h (history)</th>
<th style="padding:5px 10px;text-align:right;">Failures 7d</th>
<th style="padding:5px 10px;text-align:right;">Max streak 7d (history)</th>
<th style="padding:5px 10px;text-align:right;">Current streak</th>
<th style="padding:5px 10px;text-align:left;">Last job</th>
</tr></thead><tbody>%s</tbody></table>',
        DARK_TEXT, EMAIL_FONT_BODY, DARK_ROW_ALT, rows_html
      )

      # Per-agent prose so a reader can tell live vs resolved at a glance
      # without cross-referencing table columns -- the historical max_streak
      # figure is preserved here (never dropped) so the evidence that an
      # episode happened is not lost, it is just labelled as history.
      per_agent_lines <- paste(apply(merged, 1, function(r) {
        cur      <- as.integer(r[["current_streak_7d"]])
        is_alert <- cur >= AGENT_FAILURE_STREAK_ALERT_THRESHOLD
        status_note <- if (is_alert) {
          sprintf("CURRENT STREAK: %d consecutive failures ongoing", cur)
        } else {
          "no current streak"
        }
        sprintf(
          '<li style="color:%s;">%s: %s such failures in the last 7&nbsp;d (max run %s); most recent job: %s @ %s &mdash; %s</li>',
          if (is_alert) "#ff5252" else DARK_TEXT,
          htmlEscape(r[["agent"]]),
          r[["n_failures_7d"]], r[["max_streak_7d"]],
          htmlEscape(r[["latest_status_7d"]] %||% "—"),
          htmlEscape(fmt_last_job_ts(r[["latest_enqueued_at_7d"]])),
          status_note
        )
      }), collapse = "\n")
      per_agent_html <- sprintf(
        '<ul style="font-size:%s;margin-top:6px;padding-left:20px;">%s</ul>',
        EMAIL_FONT_BODY, per_agent_lines
      )

      alert_html <- if (length(alert_agents) > 0L) {
        sprintf(
          '<p style="color:#ff5252;font-size:%s;margin-top:8px;font-weight:bold;">
  &#9888; %s: CURRENT streak &ge; %d consecutive agent failures with empty
  stdout, including the most recent job -- this is happening NOW, not a past
  episode. CAUSE UNKNOWN, NOT a parse error (roborev\'s own message is
  fabricated -- see roborev-resolution.md). Run the agent\'s command manually
  with the same flags and read stderr.</p>',
          EMAIL_FONT_SUBTITLE, paste(alert_agents, collapse = ", "),
          AGENT_FAILURE_STREAK_ALERT_THRESHOLD
        )
      } else {
        ""
      }

      list(
        body    = paste0(table_html, per_agent_html, alert_html),
        summary = if (length(alert_agents) > 0L) {
          sprintf("%d agent(s) with history · %d CURRENTLY alerting (threshold %d)",
                  nrow(merged), length(alert_agents), AGENT_FAILURE_STREAK_ALERT_THRESHOLD)
        } else {
          sprintf("%d agent(s) with history (max streak %d) · none currently alerting",
                  nrow(merged), max_streak_overall)
        }
      )
    }
  }
}, error = function(e) {
  list(
    body    = sprintf('<p style="color:#ff5252;">agent-failed-empty-stdout section failed: %s</p>',
                      htmlEscape(conditionMessage(e))),
    summary = "error"
  )
})

sec_agent_failure_block <- collapsible_block(
  "Agent failed with empty stdout (cause unknown, llm#954)",
  agent_failure_section$summary,
  agent_failure_section$body
)

email_body <- paste0(
  sprintf('<div style="background-color:%s;color:%s;font-family:Arial,sans-serif;
padding:20px;max-width:800px;margin:0 auto;">', DARK_BG, DARK_TEXT),
  header_html,
  sec1_block, "\n",
  sec2_block, "\n",
  sec_staleness_block, "\n",
  sec3_block, "\n",
  sec3b_block, "\n",
  sec3c_block, "\n",
  sec3d_block, "\n",
  sec3e_block, "\n",
  sec3f_block, "\n",
  oversized_block, "\n",
  sec_hooks_block, "\n",
  sec_secret_scan_block, "\n",
  sec_agent_failure_block, "\n",
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
