#!/usr/bin/env Rscript
# launchd_health_report.R — Generate weekly scheduled-task health report.
#
# Parses ~/Library/LaunchAgents/*.plist files, reads the launchd_runs ledger,
# enumerates GitHub Actions cloud crons, and emits a Markdown report suitable
# for embedding in an HTML email.
#
# Args (command-line):
#   --out PATH      Write markdown to PATH (default: stdout)
#   --dry-run       Alias for --out /dev/stdout; also skips ledger write
#
# Env:
#   LAUNCHD_LEDGER   Path to DuckDB ledger (default: ~/.claude/logs/launchd_runs.duckdb)
#   CLOUD_REPOS      Comma-separated list of GitHub repos to inspect (default: see below)
#
# Tracked in llm#300.

# ── Arg parsing ────────────────────────────────────────────────────────────────
args <- commandArgs(trailingOnly = TRUE)

out_path <- NULL
dry_run  <- FALSE

i <- 1L
while (i <= length(args)) {
  switch(args[i],
    "--out"     = { out_path <- args[i + 1L]; i <- i + 2L },
    "--dry-run" = { dry_run <- TRUE; i <- i + 1L },
    { i <- i + 1L }
  )
}

if (dry_run && is.null(out_path)) out_path <- "/dev/stdout"
if (is.null(out_path)) out_path <- "/dev/stdout"

# ── Dependencies ───────────────────────────────────────────────────────────────
suppressPackageStartupMessages({
  library(jsonlite)
})

# Optional DuckDB for ledger reads (graceful fallback if absent)
has_duckdb <- requireNamespace("duckdb", quietly = TRUE)

# ── Configuration ─────────────────────────────────────────────────────────────

LAUNCH_AGENTS_DIR <- file.path(Sys.getenv("HOME"), "Library", "LaunchAgents")

LEDGER_PATH <- Sys.getenv(
  "LAUNCHD_LEDGER",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "launchd_runs.duckdb")
)

CLOUD_REPOS_RAW <- Sys.getenv("CLOUD_REPOS", "JohnGavin/llm,JohnGavin/llmtelemetry")
CLOUD_REPOS     <- trimws(strsplit(CLOUD_REPOS_RAW, ",")[[1]])

REPORT_WINDOW_DAYS <- 7L

# ── Section 1: plist inventory ─────────────────────────────────────────────────

#' Parse a single LaunchAgents plist into a tidy list.
#' Returns NULL if the file cannot be parsed.
parse_plist <- function(path) {
  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp))
  ret <- system2("/usr/bin/plutil", c("-convert", "json", "-o", tmp, path),
                 stdout = FALSE, stderr = FALSE)
  if (ret != 0L) return(NULL)
  tryCatch(
    jsonlite::fromJSON(tmp, simplifyVector = TRUE),
    error = function(e) NULL
  )
}

#' Extract canonical schedule info from a parsed plist.
#' Returns a named list: type, display, raw (for cadence math).
extract_schedule <- function(pl) {
  sci <- pl[["StartCalendarInterval"]]
  si  <- pl[["StartInterval"]]
  ral <- isTRUE(pl[["RunAtLoad"]])

  if (!is.null(sci)) {
    # May be a single dict (list) or list of dicts (array)
    if (is.data.frame(sci)) {
      # Multiple calendar intervals — take first for display
      rows <- sci
      times <- apply(rows, 1, function(r) {
        h <- if (!is.na(r[["Hour"]])) as.integer(r[["Hour"]]) else NA_integer_
        m <- if (!is.na(r[["Minute"]])) as.integer(r[["Minute"]]) else 0L
        sprintf("%02d:%02d", h, m)
      })
      list(type = "calendar", display = paste(times, collapse = ", "), raw = sci)
    } else if (is.list(sci) && !is.data.frame(sci)) {
      h <- sci[["Hour"]]
      m <- if (!is.null(sci[["Minute"]])) sci[["Minute"]] else 0L
      wd <- sci[["Weekday"]]
      display <- if (!is.null(wd)) {
        wd_names <- c("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
        sprintf("%s %02d:%02d", wd_names[wd + 1L], as.integer(h), as.integer(m))
      } else {
        if (!is.null(h)) sprintf("%02d:%02d", as.integer(h), as.integer(m)) else "run-at-load"
      }
      list(type = "calendar", display = display, raw = sci)
    } else {
      list(type = "calendar", display = "custom", raw = sci)
    }
  } else if (!is.null(si)) {
    secs <- as.integer(si)
    display <- if (secs < 120L) {
      sprintf("every %ds", secs)
    } else if (secs < 3600L) {
      sprintf("every %dm", secs %/% 60L)
    } else {
      sprintf("every %.1fh", secs / 3600)
    }
    list(type = "interval", display = display, raw = list(seconds = secs))
  } else if (ral) {
    list(type = "daemon", display = "daemon/run-at-load", raw = NULL)
  } else {
    list(type = "unknown", display = "unknown", raw = NULL)
  }
}

#' Classify a plist into a priority tier.
#'
#' Tier rules (in priority order):
#'  1. Label contains keywords: roborev-metrics-etl, self-review, duckdb-backup,
#'     codex-overnight → High (overnight data-integrity chain; fires 02:00–08:00)
#'  2. Label contains: pulse, project-backlog, chrome-tab, roborev-autoclose,
#'     roborev-severity, wiki-health, or fires 09:00–21:00 → Medium
#'  3. Interval ≤ 1800s, daemon, or fires <08:00 and not in High keywords → Low
classify_tier <- function(label, sched) {
  high_keywords <- c(
    "roborev-metrics-etl", "self-review", "unified-duckdb-backup",
    "codex-overnight-learning", "roborev-metrics"
  )
  medium_keywords <- c(
    "pulse", "project-backlog", "chrome-tab", "roborev-autoclose",
    "roborev-severity", "wiki-health", "pr-status", "roborev-poll",
    "knowledge-pulse", "config-pulse"
  )

  lbl_lower <- tolower(label)

  # High: keyword match
  if (any(vapply(high_keywords, function(k) grepl(k, lbl_lower, fixed = TRUE), logical(1L)))) {
    return("High")
  }

  # Check hour for calendar jobs
  if (!is.null(sched$raw) && sched$type == "calendar") {
    raw <- sched$raw
    # Extract first Hour value — raw may be a list (single interval) or data.frame (multi)
    hour <- if (is.data.frame(raw)) {
      raw[["Hour"]][1L]
    } else if (is.list(raw)) {
      raw[["Hour"]]
    } else {
      NA
    }
    # hour may still be a vector (e.g. named list with vector value) — take first scalar
    if (!is.null(hour) && length(hour) >= 1L) {
      h_val <- suppressWarnings(as.integer(hour[[1L]]))
      if (!is.na(h_val)) {
        if (h_val < 8L) return("High")
        if (h_val >= 8L && h_val <= 21L) {
          if (any(vapply(medium_keywords, function(k) grepl(k, lbl_lower, fixed = TRUE), logical(1L)))) {
            return("Medium")
          }
          return("Medium")
        }
      }
    }
  }

  if (any(vapply(medium_keywords, function(k) grepl(k, lbl_lower, fixed = TRUE), logical(1L)))) {
    return("Medium")
  }

  if (sched$type == "interval") {
    secs <- sched$raw[["seconds"]]
    if (!is.null(secs) && secs <= 1800L) return("Low")
    return("Medium")
  }

  "Low"
}

#' Enumerate all owned LaunchAgents plists, returning a data.frame.
collect_inventory <- function(launch_dir = LAUNCH_AGENTS_DIR) {
  plists <- list.files(
    launch_dir,
    pattern = "^(com\\.claude\\.|com\\.johngavin\\.|com\\.roborev\\.|com\\.llmtelemetry\\.)",
    full.names = TRUE
  )
  # Exclude backups
  plists <- plists[!grepl("\\.bak-", plists)]

  rows <- lapply(plists, function(path) {
    pl <- parse_plist(path)
    if (is.null(pl)) return(NULL)

    label    <- pl[["Label"]] %||% basename(path)
    sched    <- extract_schedule(pl)
    tier     <- classify_tier(label, sched)
    prog_raw <- pl[["ProgramArguments"]]
    program  <- if (is.null(prog_raw)) pl[["Program"]] %||% "(none)"
                else paste(prog_raw, collapse = " ")
    timeout  <- pl[["TimeOut"]]
    std_out  <- pl[["StandardOutPath"]]
    std_err  <- pl[["StandardErrorPath"]]

    # Derive script path for GitHub URL (heuristic: last element that ends in .sh or .R or .py)
    script_path <- NA_character_
    if (!is.null(prog_raw) && length(prog_raw) > 0L) {
      for (arg in rev(prog_raw)) {
        if (grepl("\\.(sh|R|py)$", arg)) { script_path <- arg; break }
      }
    }

    list(
      label       = label,
      tier        = tier,
      schedule    = sched$display,
      program     = program,
      script_path = script_path,
      timeout_s   = if (!is.null(timeout)) as.integer(timeout) else NA_integer_,
      std_out     = std_out %||% NA_character_,
      std_err     = std_err %||% NA_character_,
      plist_path  = path
    )
  })

  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0L) {
    return(data.frame(
      label = character(), tier = character(), schedule = character(),
      program = character(), script_path = character(),
      timeout_s = integer(), std_out = character(),
      std_err = character(), plist_path = character(),
      stringsAsFactors = FALSE
    ))
  }

  do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))
}

# ── Section 2: run metrics from ledger ─────────────────────────────────────────

#' Read per-job run metrics from the DuckDB ledger.
#' Returns a data.frame with one row per label, or a special "empty" data.frame.
read_run_metrics <- function(ledger = LEDGER_PATH, window_days = REPORT_WINDOW_DAYS) {
  if (!has_duckdb) {
    message("launchd_health_report.R: duckdb not available — section 2 skipped")
    return(NULL)
  }
  if (!file.exists(ledger)) {
    message(sprintf("launchd_health_report.R: ledger not found at %s — first run", ledger))
    return(data.frame(empty = TRUE, stringsAsFactors = FALSE))
  }

  con <- duckdb::dbConnect(duckdb::duckdb(), dbdir = ledger, read_only = TRUE)
  on.exit(duckdb::dbDisconnect(con, shutdown = FALSE))

  tables <- DBI::dbListTables(con)
  if (!"runs" %in% tables) {
    message("launchd_health_report.R: 'runs' table not found in ledger — first run")
    return(data.frame(empty = TRUE, stringsAsFactors = FALSE))
  }

  cutoff <- format(Sys.time() - window_days * 86400, "%Y-%m-%d %H:%M:%S")

  query <- sprintf(
    "SELECT
       label,
       COUNT(*) AS run_count,
       SUM(CASE WHEN exit_code != 0 THEN 1 ELSE 0 END) AS failures,
       ROUND(100.0 * SUM(CASE WHEN exit_code != 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS failure_pct,
       ROUND(MEDIAN(EPOCH(finished_at) - EPOCH(started_at)), 1) AS median_duration_s,
       ROUND(MAX(EPOCH(finished_at) - EPOCH(started_at)), 1)    AS max_duration_s,
       ROUND(MEDIAN(peak_rss_mb), 1) AS median_rss_mb,
       ROUND(MAX(peak_rss_mb), 1)    AS max_rss_mb,
       MAX(exit_code)                AS last_exit_code,
       MAX(finished_at)              AS last_run
     FROM runs
     WHERE started_at >= TIMESTAMPTZ '%s'
     GROUP BY label
     ORDER BY label",
    cutoff
  )

  tryCatch(
    DBI::dbGetQuery(con, query),
    error = function(e) {
      message("launchd_health_report.R: ledger query error — ", conditionMessage(e))
      data.frame(empty = TRUE, stringsAsFactors = FALSE)
    }
  )
}

# ── Section 3: auto-generated suggestions ─────────────────────────────────────

#' Compute peak-contention: jobs firing at the same clock minute.
#' Returns a data.frame with columns: time_slot, count, labels.
detect_contention <- function(inventory, threshold = 3L) {
  # Only calendar-type rows with numeric Hour
  cal_rows <- inventory[grepl("^\\d{2}:\\d{2}", inventory$schedule), ]
  if (nrow(cal_rows) == 0L) return(data.frame(
    time_slot = character(), count = integer(), labels = character(),
    stringsAsFactors = FALSE
  ))

  # Extract first HH:MM token
  slots <- regmatches(cal_rows$schedule, regexpr("^\\d{2}:\\d{2}", cal_rows$schedule))
  tbl <- table(slots)
  hot <- names(tbl)[tbl >= threshold]

  rows <- lapply(hot, function(slot) {
    idx <- which(startsWith(cal_rows$schedule, slot))
    list(
      time_slot = slot,
      count     = length(idx),
      labels    = paste(cal_rows$label[idx], collapse = ", ")
    )
  })

  if (length(rows) == 0L) return(data.frame(
    time_slot = character(), count = integer(), labels = character(),
    stringsAsFactors = FALSE
  ))
  do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))
}

#' Build suggestion bullets from inventory + metrics.
build_suggestions <- function(inventory, metrics) {
  suggestions <- character(0L)

  # Peak contention
  contention <- detect_contention(inventory, threshold = 3L)
  if (nrow(contention) > 0L) {
    for (i in seq_len(nrow(contention))) {
      r <- contention[i, ]
      suggestions <- c(suggestions, sprintf(
        "**Peak contention** at %s: %d jobs fire simultaneously (%s). Consider staggering by 2–5 minutes.",
        r$time_slot, r$count, r$labels
      ))
    }
  }

  # High failure rate
  if (!is.null(metrics) && nrow(metrics) > 0L && !"empty" %in% names(metrics)) {
    fail_jobs <- metrics[!is.na(metrics$failure_pct) & metrics$failure_pct > 10, ]
    if (nrow(fail_jobs) > 0L) {
      for (i in seq_len(nrow(fail_jobs))) {
        r <- fail_jobs[i, ]
        suggestions <- c(suggestions, sprintf(
          "**High failure rate** for `%s`: %.0f%% failures (%d/%d runs), last exit %s.",
          r$label, r$failure_pct, r$failures, r$run_count,
          if (!is.na(r$last_exit_code)) as.character(r$last_exit_code) else "?"
        ))
      }
    }
  }

  if (length(suggestions) == 0L) {
    suggestions <- "_No issues detected. All systems nominal._"
  }

  suggestions
}

# ── Section 4: cloud crons ─────────────────────────────────────────────────────

#' Enumerate GitHub Actions workflows for a repo.
#'
#' Primary: reads local filesystem (more robust in Nix shells where gh may not be in PATH).
#' Fallback: calls gh API if local clone not found.
enumerate_workflows <- function(repo) {
  repo_name  <- sub(".*/", "", repo)
  local_root <- file.path(Sys.getenv("HOME"), "docs_gh", repo_name)
  wf_dir     <- file.path(local_root, ".github", "workflows")

  if (dir.exists(wf_dir)) {
    yml_files <- list.files(wf_dir, pattern = "\\.(yml|yaml)$", full.names = FALSE)
    lapply(yml_files, function(f) {
      list(
        name     = sub("\\.(yml|yaml)$", "", f),
        path     = file.path(".github", "workflows", f),
        html_url = sprintf(
          "https://github.com/%s/blob/main/.github/workflows/%s", repo, f
        )
      )
    })
  } else {
    # Fallback: gh API (try common locations for gh binary)
    gh_bin <- Sys.which("gh")
    if (!nzchar(gh_bin)) {
      gh_candidates <- c(
        "/nix/var/nix/profiles/default/bin/gh",
        "/usr/local/bin/gh",
        "/opt/homebrew/bin/gh"
      )
      gh_bin <- gh_candidates[file.exists(gh_candidates)][1L]
    }
    if (is.na(gh_bin) || !nzchar(gh_bin)) return(list())

    api_path <- sprintf("/repos/%s/actions/workflows", repo)
    result <- tryCatch(
      system2(gh_bin,
              c("api", api_path, "--jq",
                ".workflows[] | {name: .name, path: .path, html_url: .html_url}"),
              stdout = TRUE, stderr = FALSE),
      error = function(e) character(0L)
    )
    if (length(result) == 0L) return(list())
    parsed <- lapply(result, function(line) {
      tryCatch(jsonlite::fromJSON(line), error = function(e) NULL)
    })
    Filter(Negate(is.null), parsed)
  }
}

#' Read a workflow YAML from disk (if local clone exists) or skip.
#' Returns named list: has_schedule, crons, dispatch_only.
parse_workflow_triggers <- function(repo, workflow_path) {
  # Derive local path heuristic
  repo_name <- sub(".*/", "", repo)
  local_root <- file.path(Sys.getenv("HOME"), "docs_gh", repo_name)
  local_file <- file.path(local_root, workflow_path)

  if (!file.exists(local_file)) return(list(has_schedule = NA, crons = NA, dispatch_only = NA))

  content <- readLines(local_file, warn = FALSE)
  has_schedule  <- any(grepl("schedule:", content))
  dispatch_only <- any(grepl("workflow_dispatch:", content)) && !has_schedule

  cron_lines <- content[grepl("cron:", content)]
  crons <- if (length(cron_lines) > 0L) {
    # Strip everything up to and including "cron:" + optional quote chars
    cleaned <- trimws(sub(".*cron:[[:space:]]*['\"]?", "", cron_lines))
    # Strip trailing quote, whitespace, or comment
    cleaned <- sub("['\"].*$", "", cleaned)
    cleaned <- trimws(cleaned)
    paste(cleaned[nzchar(cleaned)], collapse = "; ")
  } else {
    NA_character_
  }

  list(has_schedule = has_schedule, crons = crons, dispatch_only = dispatch_only)
}

collect_cloud_crons <- function(repos = CLOUD_REPOS) {
  rows <- list()
  for (repo in repos) {
    wfs <- enumerate_workflows(repo)
    for (wf in wfs) {
      triggers <- parse_workflow_triggers(repo, wf[["path"]])
      if (is.na(triggers$has_schedule) && is.na(triggers$dispatch_only)) next
      if (!isTRUE(triggers$has_schedule) && !isTRUE(triggers$dispatch_only)) next

      rows <- c(rows, list(list(
        repo           = repo,
        name           = wf[["name"]],
        path           = wf[["path"]],
        html_url       = wf[["html_url"]],
        has_schedule   = isTRUE(triggers$has_schedule),
        cron           = if (!is.null(triggers$crons)) triggers$crons else NA_character_,
        dispatch_only  = isTRUE(triggers$dispatch_only)
      )))
    }
  }

  if (length(rows) == 0L) return(data.frame(
    repo = character(), name = character(), path = character(),
    html_url = character(), has_schedule = logical(),
    cron = character(), dispatch_only = logical(),
    stringsAsFactors = FALSE
  ))
  do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))
}

# ── Markdown rendering ─────────────────────────────────────────────────────────

`%||%` <- function(a, b) if (!is.null(a)) a else b

fmt_val <- function(x) if (is.null(x) || (length(x) == 1L && is.na(x))) "—" else as.character(x)

render_inventory_table <- function(inventory) {
  tiers <- c("High", "Medium", "Low")
  tier_emoji <- c(High = "\U1F534", Medium = "\U1F7E0", Low = "\U1F7E2")

  lines <- character(0L)
  for (tier in tiers) {
    sub <- inventory[inventory$tier == tier, ]
    if (nrow(sub) == 0L) next

    lines <- c(lines, sprintf("\n### %s %s Tier", tier_emoji[tier], tier), "")
    lines <- c(lines,
      "| Label | Schedule | Program | Timeout |",
      "|-------|----------|---------|---------|"
    )
    for (i in seq_len(nrow(sub))) {
      r <- sub[i, ]
      prog_short <- if (nchar(r$program) > 80) paste0(substr(r$program, 1L, 77L), "...") else r$program
      timeout_s <- if (!is.na(r$timeout_s)) sprintf("%ds", r$timeout_s) else "—"
      lines <- c(lines, sprintf("| `%s` | %s | `%s` | %s |",
        r$label, r$schedule, prog_short, timeout_s
      ))
    }
  }
  paste(lines, collapse = "\n")
}

render_metrics_table <- function(metrics) {
  if (is.null(metrics)) {
    return("\n> _duckdb not available — section 2 skipped._\n")
  }
  if ("empty" %in% names(metrics)) {
    return(paste0(
      "\n> **No run data yet.** The ledger (`~/.claude/logs/launchd_runs.duckdb`) ",
      "has not been populated yet.\n> Wrap plist commands with `bin/launchd_run_record.sh` ",
      "to start collecting metrics. Data will appear here after the first runs.\n"
    ))
  }
  if (nrow(metrics) == 0L) {
    return("\n> _No runs recorded in the past 7 days._\n")
  }

  lines <- c(
    "",
    "| Label | Runs | Failures | Fail% | Median Duration (s) | Max Duration (s) | Median RSS (MB) | Max RSS (MB) | Last Exit | Last Run |",
    "|-------|------|----------|-------|---------------------|------------------|-----------------|--------------|-----------|----------|"
  )
  for (i in seq_len(nrow(metrics))) {
    r <- metrics[i, ]
    lines <- c(lines, sprintf(
      "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s |",
      r$label,
      fmt_val(r$run_count),
      fmt_val(r$failures),
      if (!is.na(r$failure_pct)) sprintf("%.1f%%", r$failure_pct) else "—",
      fmt_val(r$median_duration_s),
      fmt_val(r$max_duration_s),
      fmt_val(r$median_rss_mb),
      fmt_val(r$max_rss_mb),
      fmt_val(r$last_exit_code),
      fmt_val(r$last_run)
    ))
  }
  paste(lines, collapse = "\n")
}

render_suggestions <- function(suggestions) {
  paste(paste0("- ", suggestions), collapse = "\n")
}

render_cloud_crons_table <- function(cloud) {
  if (nrow(cloud) == 0L) {
    return("\n> _No scheduled/dispatch-only workflows found in configured repos._\n")
  }

  lines <- c(
    "",
    "| Repo | Workflow | Cron | Type | Link |",
    "|------|----------|------|------|------|"
  )
  for (i in seq_len(nrow(cloud))) {
    r <- cloud[i, ]
    type_label <- if (isTRUE(r$dispatch_only)) "dispatch-only" else "scheduled"
    cron_display <- if (!is.na(r$cron) && nzchar(r$cron)) r$cron else "—"
    link <- if (!is.null(r$html_url) && !is.na(r$html_url)) {
      sprintf("[workflow](%s)", r$html_url)
    } else {
      r$path
    }
    lines <- c(lines, sprintf(
      "| `%s` | %s | `%s` | %s | %s |",
      r$repo, r$name, cron_display, type_label, link
    ))
  }
  paste(lines, collapse = "\n")
}

# ── Main (skipped when sourced with option launchd_health_source_only=TRUE) ────

if (isTRUE(getOption("launchd_health_source_only"))) {
  # sourced for testing — definitions loaded, main body skipped
  invisible(NULL)
} else {

message("launchd_health_report.R: collecting inventory from ", LAUNCH_AGENTS_DIR)
inventory <- collect_inventory(LAUNCH_AGENTS_DIR)
message(sprintf("  found %d owned plists", nrow(inventory)))

message("launchd_health_report.R: reading run metrics from ", LEDGER_PATH)
metrics <- read_run_metrics(LEDGER_PATH, REPORT_WINDOW_DAYS)

message("launchd_health_report.R: building suggestions")
suggestions <- build_suggestions(inventory, metrics)

message("launchd_health_report.R: enumerating cloud crons")
cloud_crons <- collect_cloud_crons(CLOUD_REPOS)

# ── Assemble report ────────────────────────────────────────────────────────────

now_utc <- format(Sys.time(), "%Y-%m-%d %H:%M UTC", tz = "UTC")

report_md <- paste0(
  "# Weekly Scheduled-Task Health Report\n\n",
  "_Generated: ", now_utc, "_\n\n",
  "---\n\n",
  "## 1. Inventory — Priority × Time-of-Day\n",
  render_inventory_table(inventory),
  "\n\n---\n\n",
  "## 2. Per-Job Run Metrics (Rolling ", REPORT_WINDOW_DAYS, " Days)\n",
  render_metrics_table(metrics),
  "\n\n---\n\n",
  "## 3. Auto-Generated Improvement Suggestions\n\n",
  render_suggestions(suggestions),
  "\n\n---\n\n",
  "## 4. Related Cloud Crons (GitHub Actions)\n",
  render_cloud_crons_table(cloud_crons),
  "\n"
)

# ── Write output ───────────────────────────────────────────────────────────────

if (out_path == "/dev/stdout") {
  cat(report_md)
} else {
  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
  writeLines(report_md, out_path)
  message(sprintf("launchd_health_report.R: report written to %s", out_path))
}

} # end if (!isTRUE(getOption("launchd_health_source_only")))
