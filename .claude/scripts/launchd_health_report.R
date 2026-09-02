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
#   LAUNCHD_LEDGER   Path to DuckDB ledger providing per-run metrics
#                    (default: ~/.claude/logs/unified.duckdb, table housekeeping_runs)
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

# Route (b): launchd_runs.duckdb is never populated (no plist wraps
# launchd_run_record.sh), so per-run metrics are read from the already-populated
# unified.duckdb ledger instead — table `housekeeping_runs` has one row per
# script invocation (task, source_script, started_at, ended_at, status).
LEDGER_PATH <- Sys.getenv(
  "LAUNCHD_LEDGER",
  file.path(Sys.getenv("HOME"), ".claude", "logs", "unified.duckdb")
)

CLOUD_REPOS_RAW <- Sys.getenv("CLOUD_REPOS", "JohnGavin/llm,JohnGavin/llmtelemetry")
CLOUD_REPOS     <- trimws(strsplit(CLOUD_REPOS_RAW, ",")[[1]])

# MANUAL: no source (see llm#1090) — rolling report window is a judgement
# call about how much history a weekly-cadence health report should
# surface; no machine-readable source possible (llm#793 item 6).
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

#' Format a (possibly very long, duplicated) vector of "HH:MM" time strings
#' into a compact display string.
#'  - Dedupe identical times first (plists often carry duplicate
#'    StartCalendarInterval entries for the same clock time).
#'  - If the deduped times are all on the hour and form a contiguous run,
#'    render as a range: "hourly HH:00–HH:00 (N×/day)".
#'  - Else if there are more than 6 distinct times, summarise as
#'    "N times/day (first–last)" rather than listing every one.
#'  - Otherwise render the plain sorted comma list.
format_calendar_times <- function(times) {
  uniq <- sort(unique(times))
  n <- length(uniq)
  if (n == 0L) return("")
  if (n == 1L) return(uniq)

  is_on_hour <- all(grepl(":00$", uniq)) && !any(grepl("^NA", uniq))
  if (is_on_hour) {
    hours <- suppressWarnings(as.integer(substr(uniq, 1L, 2L)))
    if (!anyNA(hours)) {
      hours_sorted <- sort(hours)
      if (all(diff(hours_sorted) == 1L)) {
        return(sprintf(
          "hourly %02d:00–%02d:00 (%d×/day)",
          hours_sorted[1L], hours_sorted[length(hours_sorted)], n
        ))
      }
    }
  }

  if (n > 6L) {
    return(sprintf("%d times/day (%s–%s)", n, uniq[1L], uniq[n]))
  }

  paste(uniq, collapse = ", ")
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
      list(type = "calendar", display = format_calendar_times(times), raw = sci)
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
    # Some ProgramArguments (e.g. `/bin/sh -c <multi-line script>`) embed raw
    # newlines/tabs — collapse to single spaces so this stays a one-line
    # markdown table cell (a literal newline splits the row across multiple
    # raw text lines and breaks table parsing downstream).
    program  <- trimws(gsub("[\r\n\t]+", " ", program))
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

#' Read per-job run metrics from the unified DuckDB ledger's `housekeeping_runs`
#' table (one row per script invocation, written by the housekeeping-framework
#' start/end pattern — see `.claude/rules/_companions/housekeeping-framework-details.md`).
#' Returns a data.frame with one row per task label, or a special "empty" data.frame.
read_run_metrics <- function(ledger = LEDGER_PATH, window_days = REPORT_WINDOW_DAYS) {
  if (!has_duckdb) {
    message("launchd_health_report.R: duckdb not available — section 2 skipped")
    return(NULL)
  }
  if (!file.exists(ledger)) {
    message(sprintf("launchd_health_report.R: unified ledger not found at %s", ledger))
    return(data.frame(empty = TRUE, stringsAsFactors = FALSE))
  }

  con <- duckdb::dbConnect(duckdb::duckdb(), dbdir = ledger, read_only = TRUE)
  on.exit(duckdb::dbDisconnect(con, shutdown = FALSE))

  tables <- DBI::dbListTables(con)
  if (!"housekeeping_runs" %in% tables) {
    message("launchd_health_report.R: 'housekeeping_runs' table not found in unified ledger")
    return(data.frame(empty = TRUE, stringsAsFactors = FALSE))
  }

  cutoff <- format(Sys.time() - window_days * 86400, "%Y-%m-%d %H:%M:%S")

  # status NOT IN ('ok', 'deferred'): 'deferred' (llm#947, llm#970) means the
  # job declined to run because DNS was not up within the bound -- NOT a
  # failure. Bucketing it as a failure here would exactly reproduce the
  # "8 partial / 0 ok" misleading-signal problem this change set out to fix
  # (same rationale as 'unknown' in launchd_health_events.state, llm#962).
  query <- sprintf(
    "SELECT
       task AS label,
       COUNT(*) AS run_count,
       SUM(CASE WHEN status NOT IN ('ok', 'deferred') THEN 1 ELSE 0 END) AS failures,
       ROUND(100.0 * SUM(CASE WHEN status NOT IN ('ok', 'deferred') THEN 1 ELSE 0 END) / COUNT(*), 1) AS failure_pct,
       ROUND(MEDIAN(EPOCH(ended_at) - EPOCH(started_at)), 1) AS median_duration_s,
       ROUND(MAX(EPOCH(ended_at) - EPOCH(started_at)), 1)    AS max_duration_s,
       arg_max(status, started_at)   AS last_status,
       MAX(started_at)               AS last_run
     FROM housekeeping_runs
     WHERE started_at >= TIMESTAMPTZ '%s'
     GROUP BY task
     ORDER BY task",
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

#' Read per-script run/failure counts from the ledger, keyed by
#' `source_script` (the full path recorded by the housekeeping-framework
#' start/end pattern). This is the join key used to attach counts to the
#' plist inventory's `script_path` column — `housekeeping_runs$task` is a
#' short slug (e.g. "worktree_gc") that does not match a launchd Label, so
#' `read_run_metrics()`'s task-keyed rows cannot be used for that join.
#' Returns NULL if duckdb/the ledger/the table are unavailable.
read_run_counts_by_script <- function(ledger = LEDGER_PATH, window_days = REPORT_WINDOW_DAYS) {
  if (!has_duckdb) return(NULL)
  if (!file.exists(ledger)) return(NULL)

  con <- duckdb::dbConnect(duckdb::duckdb(), dbdir = ledger, read_only = TRUE)
  on.exit(duckdb::dbDisconnect(con, shutdown = FALSE))

  tables <- DBI::dbListTables(con)
  if (!"housekeeping_runs" %in% tables) return(NULL)

  cutoff <- format(Sys.time() - window_days * 86400, "%Y-%m-%d %H:%M:%S")

  # status NOT IN ('ok', 'deferred'): see the matching comment in
  # read_run_metrics() above -- 'deferred' (llm#947, llm#970) is not a failure.
  query <- sprintf(
    "SELECT
       source_script,
       COUNT(*) AS n_runs,
       SUM(CASE WHEN status IS NULL OR status NOT IN ('ok', 'deferred') THEN 1 ELSE 0 END) AS n_fail
     FROM housekeeping_runs
     WHERE started_at >= TIMESTAMPTZ '%s'
       AND source_script IS NOT NULL
     GROUP BY source_script",
    cutoff
  )

  result <- tryCatch(
    DBI::dbGetQuery(con, query),
    error = function(e) {
      message("launchd_health_report.R: script-count ledger query error — ", conditionMessage(e))
      NULL
    }
  )
  if (!is.null(result) && nrow(result) > 0L) {
    # Some ledger rows carry a path separator recorded as an embedded
    # newline/tab instead of "/" (a known upstream data-quality issue, e.g.
    # worktree_gc's writer produces ".../scripts\nworktree_gc.sh") — repair
    # it to "/" (the same defensive-normalisation spirit as `program`'s
    # `trimws(gsub("[\r\n\t]+", " ", program))` above, but path-shaped) so
    # the basename join in attach_run_counts() isn't silently defeated.
    result$source_script <- gsub("/+", "/", gsub("[\r\n\t]+", "/", trimws(result$source_script)))
  }
  result
}

#' Attach n_runs/n_fail columns to the plist inventory by matching
#' `script_path` against the ledger's `source_script` — full-path match
#' first, falling back to a basename match (worktree-prefixed source_script
#' values, e.g. a run captured from an agent worktree, won't full-path-match
#' the canonical plist Program path but do share the script's basename).
#' Jobs with no matching ledger rows keep NA (rendered as "—", not 0, so
#' "no telemetry" stays distinct from "0 failures").
attach_run_counts <- function(inventory, script_counts) {
  inventory$n_runs <- NA_integer_
  inventory$n_fail <- NA_integer_
  if (is.null(script_counts) || nrow(script_counts) == 0L) return(inventory)

  sc_basename <- basename(script_counts$source_script)

  for (i in seq_len(nrow(inventory))) {
    sp <- inventory$script_path[i]
    if (is.na(sp)) next

    idx <- which(script_counts$source_script == sp)
    if (length(idx) == 0L) {
      idx <- which(sc_basename == basename(sp))
    }
    if (length(idx) > 0L) {
      inventory$n_runs[i] <- sum(script_counts$n_runs[idx])
      inventory$n_fail[i] <- sum(script_counts$n_fail[idx])
    }
  }
  inventory
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
  #
  # llm#1145: this referenced r$last_exit_code, a column read_run_metrics()
  # never selects (its query returns last_status, not last_exit_code). `$`
  # on a missing column returns NULL, `is.na(NULL)` is `logical(0)`, and
  # `if (logical(0))` throws "argument is of length zero" -- deterministically,
  # every time ANY task's rolling-window failure_pct exceeded 10%. Confirmed
  # via ~/.claude/logs/launchd_health_weekly.log: this exact error, at this
  # exact call site, on every daily run since 2026-08-07 (27 consecutive
  # runs) -- the day some task's 7-day failure rate first crossed 10%. Both
  # Step 1 (this script) and Step 2 (send_launchd_health_email.R, which
  # invokes the same aggregation code as a subprocess) crashed identically,
  # which is why housekeeping_runs.status has read 'partial' for a job whose
  # actual bug was a stale column reference, not a genuine health problem.
  if (!is.null(metrics) && nrow(metrics) > 0L && !"empty" %in% names(metrics)) {
    fail_jobs <- metrics[!is.na(metrics$failure_pct) & metrics$failure_pct > 10, ]
    if (nrow(fail_jobs) > 0L) {
      for (i in seq_len(nrow(fail_jobs))) {
        r <- fail_jobs[i, ]
        suggestions <- c(suggestions, sprintf(
          "**High failure rate** for `%s`: %.0f%% failures (%d/%d runs), last status %s.",
          r$label, r$failure_pct, r$failures, r$run_count,
          if (!is.null(r$last_status) && !is.na(r$last_status)) as.character(r$last_status) else "?"
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

# ── Section 5: stale/wedged process detection (llm#957) ───────────────────────
#
# A process invoked as `timeout <N> <cmd>...` (optionally `timeout -k <grace>
# <N> ...`) that is still alive well past N seconds is definitionally wedged:
# plain `timeout N cmd` sends SIGTERM once and returns even if the child
# ignores it. This is exactly how a `timeout 30 signal-cli ... receive`
# process survived for ~40 hours holding the signal-cli config lock
# (llm#937/#957 — signal-cli logs "Shutdown - Received SIGTERM signal,
# shutting down ..." and then does not exit). The rule generalises beyond
# Signal to any `timeout`-wrapped invocation and needs no per-tool allowlist.
# This is additive to the existing report — no second health system.

#' Parse a `ps` "etime"/"etimes" style elapsed-time string into seconds.
#' Handles the BSD/macOS `[[dd-]hh:]mm:ss` form as well as a bare integer
#' (GNU `etimes`, already in seconds).
parse_etime_to_seconds <- function(etime) {
  etime <- trimws(as.character(etime))
  if (is.na(etime) || !nzchar(etime)) return(NA_integer_)
  if (grepl("^[0-9]+$", etime)) return(as.integer(etime))

  dd <- 0L
  rest <- etime
  if (grepl("-", etime, fixed = TRUE)) {
    parts <- strsplit(etime, "-", fixed = TRUE)[[1L]]
    dd <- suppressWarnings(as.integer(parts[1L]))
    if (is.na(dd)) dd <- 0L
    rest <- parts[2L]
  }
  hms <- suppressWarnings(as.integer(strsplit(rest, ":", fixed = TRUE)[[1L]]))
  hms[is.na(hms)] <- 0L
  secs <- switch(as.character(length(hms)),
    "1" = hms[1L],
    "2" = hms[1L] * 60L + hms[2L],
    "3" = hms[1L] * 3600L + hms[2L] * 60L + hms[3L],
    0L
  )
  dd * 86400L + secs
}

#' Redact phone numbers embedded in a command line (llm#946 — PII exposure).
#' The Signal account number (e.g. "+15550001111") must never appear
#' unredacted in a generated report. Matches a leading "+" followed by 6+
#' digits, which also covers any other E.164-style number that might show up
#' in a future `timeout`-wrapped command line.
redact_phone_numbers <- function(x) {
  gsub("\\+[0-9]{6,}", "+[REDACTED]", x)
}

#' Extract the declared timeout budget (in seconds) from a `timeout <N> ...`
#' or `timeout -k <grace> <N> ...` invocation embedded in a command string.
#' Returns NA_integer_ if the command does not contain a `timeout`/`gtimeout`
#' invocation followed by a numeric budget.
extract_timeout_budget <- function(command) {
  m <- regmatches(command, regexpr(
    "(^|[/[:space:]])(g?timeout)[[:space:]]+(-k[[:space:]]+[0-9]+[[:space:]]+)?[0-9]+",
    command
  ))
  if (length(m) == 0L || !nzchar(m)) return(NA_integer_)
  nums <- regmatches(m, gregexpr("[0-9]+", m))[[1L]]
  if (length(nums) == 0L) return(NA_integer_)
  as.integer(nums[length(nums)])
}

#' Detect stale/wedged processes from a process table.
#'
#' @param proc_table data.frame with columns pid (integer), etime (character,
#'   ps-style elapsed time or bare seconds), command (character, full command
#'   line). Pass a synthetic data.frame in tests; production use goes through
#'   collect_process_table().
#' @param slack_multiplier numeric — a process is flagged only once its
#'   elapsed time exceeds `slack_multiplier * declared_timeout_budget`
#'   (default 2x — tolerates the -k grace window plus ordinary scheduling
#'   jitter without false-flagging a process that is merely finishing up).
#' @return data.frame: pid, elapsed_s, budget_s, command (phone-redacted).
#'   Zero rows (not NULL) when nothing is flagged.
detect_stale_processes <- function(proc_table, slack_multiplier = 2) {
  empty <- data.frame(
    pid = integer(), elapsed_s = integer(), budget_s = integer(),
    command = character(), stringsAsFactors = FALSE
  )
  if (is.null(proc_table) || nrow(proc_table) == 0L) return(empty)

  budgets <- vapply(proc_table$command, extract_timeout_budget, integer(1L))
  elapsed <- vapply(proc_table$etime, parse_etime_to_seconds, integer(1L))

  flagged <- !is.na(budgets) & !is.na(elapsed) & elapsed > (budgets * slack_multiplier)
  if (!any(flagged)) return(empty)

  data.frame(
    pid       = proc_table$pid[flagged],
    elapsed_s = elapsed[flagged],
    budget_s  = budgets[flagged],
    command   = redact_phone_numbers(proc_table$command[flagged]),
    stringsAsFactors = FALSE
  )
}

#' Collect the live process table via `ps -eo pid=,etime=,command=`.
#' Returns a data.frame shaped for detect_stale_processes(), or NULL if `ps`
#' is unavailable or returns nothing (never errors — this must never break
#' the rest of the report).
collect_process_table <- function() {
  out <- tryCatch(
    system2("ps", c("-eo", "pid=,etime=,command="), stdout = TRUE, stderr = FALSE),
    error = function(e) character(0L)
  )
  if (length(out) == 0L) return(NULL)

  rows <- lapply(out, function(line) {
    m <- regmatches(line, regexpr("^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+", line))
    if (length(m) == 0L || !nzchar(m)) return(NULL)
    parts <- strsplit(trimws(m), "[[:space:]]+")[[1L]]
    pid   <- suppressWarnings(as.integer(parts[1L]))
    etime <- parts[2L]
    cmd   <- trimws(sub("^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]*", "", line))
    if (is.na(pid)) return(NULL)
    list(pid = pid, etime = etime, command = cmd)
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0L) return(NULL)
  do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))
}

render_stale_processes_table <- function(stale) {
  if (is.null(stale) || nrow(stale) == 0L) {
    return("\n_No stale/wedged `timeout`-wrapped processes detected._\n")
  }
  lines <- c(
    "",
    "| PID | Elapsed | Budget | Command |",
    "|-----|---------|--------|---------|"
  )
  for (i in seq_len(nrow(stale))) {
    r <- stale[i, ]
    cmd_short <- if (nchar(r$command) > 100) {
      paste0(substr(r$command, 1L, 97L), "...")
    } else {
      r$command
    }
    lines <- c(lines, sprintf("| %d | %ds | %ds | `%s` |", r$pid, r$elapsed_s, r$budget_s, cmd_short))
  }
  paste(lines, collapse = "\n")
}

# ── Section 6: braindumps freshness alarm (llm#937 fix 5) ─────────────────────
#
# llm#937 documented five fixes for the Signal-note-capture outage (a
# version-pinned binary path stopped existing after a Homebrew upgrade,
# degrading "command not found" into an empty message list, indistinguishable
# from "no new messages" for three months). Fixes 1-4 (un-pin the binary path,
# SIGKILL-escalating timeouts, stale-process guards — see detect_stale_processes
# above, daemon/direct-receive race fixes) have all landed. Fix 5, "freshness
# alarm", had not: signal_braindump_handler.sh calls etl_freshness_upsert.sh to
# RECORD facts into the (legacy, pre-#893) `etl_freshness` table, but nothing
# ever reads that table to raise an alarm — and even if something did, a check
# invoked from *inside* the writer's own script only ever runs when the writer
# itself successfully runs, which is exactly the failure mode this exists to
# catch (see `.claude/memory/probe-must-not-share-writer-path.md` /
# `checks-must-distinguish-unknown` rule). This report is a genuinely separate
# trigger class — its own weekly launchd cron — so it still runs and still
# sees the true row age even if the Signal capture pipeline has been silently
# dead for months.

#' Detect braindumps table staleness directly from the unified DuckDB ledger.
#'
#' Deliberately does NOT reuse any liveness signal recorded by the writer
#' (signal_notes_sync.sh / signal_braindump_handler.sh / etl_freshness) — it
#' queries `braindumps` itself, from a separate script on a separate cron
#' trigger, so a dead writer cannot also silence its own alarm.
#'
#' @param con An open DBI connection to the unified DuckDB ledger (read-only
#'   is fine). Production callers pass the same connection used elsewhere in
#'   this script; tests pass an in-memory duckdb connection with a synthetic
#'   `braindumps` table.
#' @param threshold_hours Numeric — newest-row age beyond this many hours is
#'   reported as 'stale'. Default 72h (3 days): this is a personal
#'   note-capture pipeline expected to receive input at least every few
#'   days, so 72h tolerates a quiet weekend without a false alarm while
#'   still catching a dead pipeline at ~4% of the ~104-day (2492h) silence
#'   in the motivating llm#937 incident.
#' @return A one-row data.frame with columns: status
#'   ('fresh'|'stale'|'indeterminate'), hours_since_newest (NA for
#'   indeterminate), newest_captured_at (NA for indeterminate),
#'   threshold_hours, detail (NA except for indeterminate, where it carries
#'   a human-readable reason). Never NULL, never errors — mirrors the
#'   zero-metric-evidence-or-defect discipline: a query that cannot run
#'   returns 'indeterminate', never a value that would render the same as
#'   'fresh' or 'stale' (checks-must-distinguish-unknown).
detect_braindumps_staleness <- function(con, threshold_hours = 72) {
  indeterminate <- function(detail) {
    data.frame(
      status = "indeterminate",
      hours_since_newest = NA_real_,
      newest_captured_at = NA_character_,
      threshold_hours = threshold_hours,
      detail = detail,
      stringsAsFactors = FALSE
    )
  }

  if (is.null(con)) return(indeterminate("no DB connection available"))

  tryCatch({
    tables <- DBI::dbListTables(con)
    if (!"braindumps" %in% tables) {
      return(indeterminate("'braindumps' table not found in ledger"))
    }

    row <- DBI::dbGetQuery(con, "SELECT MAX(captured_at) AS newest FROM braindumps")
    newest <- row$newest[[1L]]
    if (is.null(newest) || length(newest) == 0L || is.na(newest)) {
      return(indeterminate("'braindumps' table exists but has zero rows"))
    }

    newest_posix <- as.POSIXct(newest, tz = "UTC")
    hours_since  <- as.numeric(difftime(Sys.time(), newest_posix, units = "hours"))
    status <- if (hours_since > threshold_hours) "stale" else "fresh"

    data.frame(
      status = status,
      hours_since_newest = round(hours_since, 1),
      newest_captured_at = format(newest_posix, "%Y-%m-%d %H:%M UTC"),
      threshold_hours = threshold_hours,
      detail = NA_character_,
      stringsAsFactors = FALSE
    )
  }, error = function(e) indeterminate(conditionMessage(e)))
}

#' Render the braindumps staleness row as a markdown block. Each of the
#' three states is textually and visually distinct — 'indeterminate' is
#' never allowed to look like a smaller/quieter version of 'fresh' or
#' 'stale' (checks-must-distinguish-unknown).
render_braindumps_staleness <- function(staleness) {
  if (is.null(staleness) || nrow(staleness) == 0L) {
    return(paste0(
      "\n> \U26A0\UFE0F **INDETERMINATE** — the braindumps staleness check ",
      "produced no result at all (unexpected — this is itself a defect).\n"
    ))
  }

  r <- staleness[1L, ]

  if (identical(r$status, "fresh")) {
    return(sprintf(
      "\nbraindumps: fresh (newest row %.1fh ago, captured_at %s; threshold %gh).\n",
      r$hours_since_newest, r$newest_captured_at, r$threshold_hours
    ))
  }

  if (identical(r$status, "stale")) {
    return(sprintf(paste0(
      "\n> \U26A0\UFE0F **STALE** — braindumps: newest row is %.1fh old ",
      "(captured_at %s), past the %gh threshold. The Signal capture ",
      "pipeline may be dead — see llm#937.\n"
    ), r$hours_since_newest, r$newest_captured_at, r$threshold_hours))
  }

  # status == "indeterminate" (or any unrecognised value) — loud AND
  # distinct from both fresh and stale, never silently treated as fine.
  sprintf(paste0(
    "\n> \U26A0\UFE0F **INDETERMINATE** — the braindumps staleness check ",
    "could not run: %s. This is NOT the same as 'fresh' — it means the ",
    "check itself is broken and braindumps freshness is currently unknown.\n"
  ), r$detail)
}

#' Production entry point: open a fresh short-lived connection to the
#' unified ledger, run detect_braindumps_staleness() against it, and always
#' close the connection again — mirrors the connect/query/disconnect
#' lifecycle already used by read_run_metrics()/read_run_counts_by_script()
#' above, kept separate from detect_braindumps_staleness() itself so that
#' function stays a pure, easily-testable query against a caller-supplied
#' connection. Never errors — any failure to even open the connection is
#' itself an 'indeterminate' result, not a crash of the whole report.
collect_braindumps_staleness <- function(ledger = LEDGER_PATH, threshold_hours = 72) {
  indeterminate <- function(detail) {
    data.frame(
      status = "indeterminate", hours_since_newest = NA_real_,
      newest_captured_at = NA_character_, threshold_hours = threshold_hours,
      detail = detail, stringsAsFactors = FALSE
    )
  }

  if (!has_duckdb) return(indeterminate("duckdb R package not available"))
  if (!file.exists(ledger)) return(indeterminate(sprintf("ledger not found at %s", ledger)))

  con <- tryCatch(
    duckdb::dbConnect(duckdb::duckdb(), dbdir = ledger, read_only = TRUE),
    error = function(e) NULL
  )
  if (is.null(con)) return(indeterminate("could not open a connection to the unified ledger"))
  on.exit(duckdb::dbDisconnect(con, shutdown = FALSE), add = TRUE)

  detect_braindumps_staleness(con, threshold_hours = threshold_hours)
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

    tier_runs <- if ("n_runs" %in% names(sub)) sum(sub$n_runs, na.rm = TRUE) else 0L
    tier_fail <- if ("n_fail" %in% names(sub)) sum(sub$n_fail, na.rm = TRUE) else 0L
    lines <- c(lines, sprintf(
      "\n### %s %s Tier — %d jobs · %d runs · %d fails (7d)",
      tier_emoji[tier], tier, nrow(sub), tier_runs, tier_fail
    ), "")
    lines <- c(lines,
      "| Label | Schedule | Runs (7d) | Fails (7d) | Program | Timeout |",
      "|-------|----------|-----------|------------|---------|---------|"
    )
    for (i in seq_len(nrow(sub))) {
      r <- sub[i, ]
      prog_short <- if (nchar(r$program) > 80) paste0(substr(r$program, 1L, 77L), "...") else r$program
      timeout_s <- if (!is.na(r$timeout_s)) sprintf("%ds", r$timeout_s) else "—"
      lines <- c(lines, sprintf("| `%s` | %s | %s | %s | `%s` | %s |",
        r$label, r$schedule, fmt_val(r$n_runs), fmt_val(r$n_fail), prog_short, timeout_s
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
      "\n> **No run data yet.** The unified ledger (`~/.claude/logs/unified.duckdb`) has ",
      "no `housekeeping_runs` rows in the reporting window.\n> Run data is written by ",
      "housekeeping-framework scripts at invocation start/end. Data will appear here ",
      "after the next scheduled runs.\n"
    ))
  }
  if (nrow(metrics) == 0L) {
    return("\n> _No runs recorded in the past 7 days._\n")
  }

  lines <- c(
    "",
    "| Label | Runs | Failures | Fail% | Median Duration (s) | Max Duration (s) | Last Status | Last Run |",
    "|-------|------|----------|-------|---------------------|-------------------|-------------|----------|"
  )
  for (i in seq_len(nrow(metrics))) {
    r <- metrics[i, ]
    lines <- c(lines, sprintf(
      "| `%s` | %s | %s | %s | %s | %s | %s | %s |",
      r$label,
      fmt_val(r$run_count),
      fmt_val(r$failures),
      if (!is.na(r$failure_pct)) sprintf("%.1f%%", r$failure_pct) else "—",
      fmt_val(r$median_duration_s),
      fmt_val(r$max_duration_s),
      fmt_val(r$last_status),
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

message("launchd_health_report.R: reading per-script run/fail counts from ", LEDGER_PATH)
script_counts <- read_run_counts_by_script(LEDGER_PATH, REPORT_WINDOW_DAYS)
inventory <- attach_run_counts(inventory, script_counts)

message("launchd_health_report.R: reading run metrics from ", LEDGER_PATH)
metrics <- read_run_metrics(LEDGER_PATH, REPORT_WINDOW_DAYS)

message("launchd_health_report.R: building suggestions")
suggestions <- build_suggestions(inventory, metrics)

message("launchd_health_report.R: enumerating cloud crons")
cloud_crons <- collect_cloud_crons(CLOUD_REPOS)

message("launchd_health_report.R: scanning for stale/wedged timeout-wrapped processes")
stale_processes <- detect_stale_processes(collect_process_table())

message("launchd_health_report.R: checking braindumps freshness (llm#937 fix 5)")
braindumps_staleness <- collect_braindumps_staleness(LEDGER_PATH)

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
  "\n\n---\n\n",
  "## 5. Stale/Wedged Processes\n",
  render_stale_processes_table(stale_processes),
  "\n\n---\n\n",
  "## 6. Braindumps Freshness (llm#937 fix 5)\n",
  render_braindumps_staleness(braindumps_staleness),
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
