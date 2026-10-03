# roborev_health_lib.R — pure helpers for the roborev daily-email health block
# (llm#984 item 2, llm#1044 items 2+3, llm#1123 addendum 1).
#
# Sourced by send_roborev_email.R (next to email_styles.R). Every function is
# side-effect free EXCEPT rh_history_write() and rh_config_record(), which only
# ever write under a caller-supplied state path. REPORT-ONLY: nothing here
# closes, re-queues, reaps or edits roborev config.
#
# checks-must-distinguish-unknown: every reader returns an explicit
# "unknown"/NA state when its input could not be read, never a 0 / "no change"
# / "none". Callers render that state; they must not collapse it.

# ── Shared normalisation ──────────────────────────────────────────────────────
# Same normalisation the per-agent table uses, so over-timeout counts and
# the not-reviewed rates land on the same row.
rh_agent_key <- function(agent, model) {
  a <- if (is.null(agent) || length(agent) != 1L || is.na(agent) || !nzchar(agent)) "(unknown)" else agent
  m <- if (is.null(model) || length(model) != 1L || is.na(model) || !nzchar(model)) "(unspecified)" else model
  paste(a, m, sep = "␟")
}

# ── Minimal TOML top-level scalar reader ──────────────────────────────────────
# Reads `key = value` lines BEFORE the first [section] header. Returns a named
# character vector (quotes stripped), or NULL when the file is missing or
# unreadable. NULL means "could not read", an empty character(0) means "read,
# no matching keys".
rh_toml_top_level <- function(path, key_regex = ".*") {
  if (is.null(path) || length(path) != 1L || is.na(path) || !nzchar(path)) return(NULL)
  if (!file.exists(path)) return(NULL)
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) NULL)
  if (is.null(lines)) return(NULL)
  out <- character(0)
  for (ln in lines) {
    if (grepl("^\\s*\\[", ln)) break
    m <- regmatches(ln, regexec("^\\s*([A-Za-z0-9_.-]+)\\s*=\\s*(.*?)\\s*$", ln, perl = TRUE))[[1L]]
    if (length(m) != 3L) next
    key <- m[2L]
    if (!grepl(key_regex, key)) next
    val <- m[3L]
    if (grepl("^'", val)) {
      val <- sub("^'([^']*)'.*$", "\\1", val)
    } else if (grepl('^"', val)) {
      val <- sub('^"([^"]*)".*$', "\\1", val)
    } else {
      val <- trimws(sub("\\s+#.*$", "", val))
    }
    out[[key]] <- val
  }
  out
}

# ── llm#984 item 2: completed jobs that exceeded the effective timeout ───────
# Global limit: top-level job_timeout_minutes in the roborev config. Per-repo
# override: same key in <repo root>/.roborev.toml. A value <= 0 or non-numeric
# means "no usable limit" -> NA (cannot judge), never "0 minutes".
# Explicit validation instead of coercing and swallowing the warning: only a
# plain decimal literal is accepted, anything else is NA ("cannot judge").
rh_as_number <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) return(NA_real_)
  txt <- trimws(as.character(x))
  if (!grepl("^-?[0-9]+(\\.[0-9]+)?$", txt)) return(NA_real_)
  as.numeric(txt)
}

rh_parse_minutes <- function(x) {
  v <- rh_as_number(x)
  if (is.na(v) || v <= 0) NA_real_ else v
}

rh_global_timeout_min <- function(config_path) {
  kv <- rh_toml_top_level(config_path, "^job_timeout_minutes$")
  if (is.null(kv) || !("job_timeout_minutes" %in% names(kv))) return(NA_real_)
  rh_parse_minutes(kv[["job_timeout_minutes"]])
}

# Effective limit for one repo. Repo file absent or key absent -> inherit
# global. Key present -> that value (NA if unusable, i.e. cannot judge).
# Repo file present but unreadable -> NA (cannot judge), not the global.
rh_effective_timeout_min <- function(root_path, global_min) {
  if (is.null(root_path) || length(root_path) != 1L || is.na(root_path) || !nzchar(root_path)) {
    return(global_min)
  }
  f <- file.path(root_path, ".roborev.toml")
  if (!file.exists(f)) return(global_min)
  kv <- rh_toml_top_level(f, "^job_timeout_minutes$")
  if (is.null(kv)) return(NA_real_)
  if (!("job_timeout_minutes" %in% names(kv))) return(global_min)
  rh_parse_minutes(kv[["job_timeout_minutes"]])
}

# jobs: list of rows with agent, model, root_path, minutes (numeric/NULL).
# Returns a named list keyed by rh_agent_key(): list(over = n, unknown = k,
# total = n_jobs). `unknown` = jobs whose duration or effective limit could
# not be determined.
rh_count_over_timeout <- function(jobs, global_min) {
  out <- list()
  limit_cache <- list()
  for (j in jobs) {
    key <- rh_agent_key(j[["agent"]], j[["model"]])
    if (is.null(out[[key]])) out[[key]] <- list(over = 0L, unknown = 0L, total = 0L)
    rp <- j[["root_path"]]
    rp_path <- if (is.null(rp) || length(rp) != 1L || is.na(rp)) "" else rp
    # a "" list name is not retrievable in R -- key the cache on a sentinel
    rp_key <- if (nzchar(rp_path)) rp_path else "<no-repo-root>"
    if (is.null(limit_cache[[rp_key]])) {
      limit_cache[[rp_key]] <- list(v = rh_effective_timeout_min(rp_path, global_min))
    }
    limit <- limit_cache[[rp_key]]$v
    mins <- rh_as_number(j[["minutes"]])
    out[[key]]$total <- out[[key]]$total + 1L
    if (is.na(limit) || is.na(mins)) {
      out[[key]]$unknown <- out[[key]]$unknown + 1L
    } else if (mins > limit) {
      out[[key]]$over <- out[[key]]$over + 1L
    }
  }
  out
}

# Cell text for the per-agent table. `entry` = one element of
# rh_count_over_timeout() or NULL (no completed jobs seen for this row);
# `jobs_available` FALSE = the jobs query itself failed.
rh_over_timeout_cell <- function(entry, jobs_available = TRUE) {
  if (!isTRUE(jobs_available)) return("unknown")
  if (is.null(entry)) return("0")
  if (entry$unknown > 0L && entry$over == 0L) return("unknown")
  if (entry$unknown > 0L) return(sprintf("%d (+%d unknown)", entry$over, entry$unknown))
  as.character(entry$over)
}

# ── llm#1044 item 2: reviewer-config fingerprint ──────────────────────────────
RH_CONFIG_KEY_REGEX <- paste0(
  "^(default_(backup_)?(agent|model)",
  "|review_(backup_)?(agent|model)(_[a-z]+)?",
  "|(backup_)?(agent|model))$"
)

# Returns list(status = "ok"|"unknown", hash, text). "unknown" when the GLOBAL
# config cannot be read (a missing repo override file is normal, not unknown).
rh_config_fingerprint <- function(config_path, repo_roots = character(0)) {
  g <- rh_toml_top_level(config_path, RH_CONFIG_KEY_REGEX)
  if (is.null(g)) return(list(status = "unknown", hash = NA_character_, text = NA_character_))
  lines <- if (length(g)) sort(sprintf("global:%s=%s", names(g), g)) else character(0)
  for (rp in sort(unique(repo_roots[!is.na(repo_roots) & nzchar(repo_roots)]))) {
    f <- file.path(rp, ".roborev.toml")
    if (!file.exists(f)) next
    r <- rh_toml_top_level(f, RH_CONFIG_KEY_REGEX)
    if (is.null(r)) {
      lines <- c(lines, sprintf("repo:%s=UNREADABLE", rp))
    } else if (length(r)) {
      lines <- c(lines, sort(sprintf("repo:%s:%s=%s", rp, names(r), r)))
    }
  }
  txt <- paste(c(lines, ""), collapse = "\n")
  tmp <- tempfile("rh_cfg_")
  on.exit(unlink(tmp), add = TRUE)
  writeLines(txt, tmp, sep = "")
  h <- unname(tools::md5sum(tmp))
  list(status = "ok", hash = h, text = txt)
}

# Compares a fingerprint with the recorded one. Never writes.
#   status: "unknown" (fingerprint unreadable -> no false change),
#           "first" (nothing recorded yet), "changed", "same".
rh_config_change <- function(fp, state_path) {
  if (!identical(fp$status, "ok")) return(list(status = "unknown", prev = NA_character_, cur = NA_character_))
  prev <- if (!is.null(state_path) && file.exists(state_path)) {
    tryCatch(trimws(readLines(state_path, n = 1L, warn = FALSE)), error = function(e) character(0))
  } else character(0)
  if (!length(prev) || !nzchar(prev)) return(list(status = "first", prev = NA_character_, cur = fp$hash))
  list(status = if (identical(prev, fp$hash)) "same" else "changed", prev = prev, cur = fp$hash)
}

rh_config_record <- function(fp, state_path) {
  if (!identical(fp$status, "ok")) return(invisible(FALSE))
  dir.create(dirname(state_path), recursive = TRUE, showWarnings = FALSE)
  ok <- tryCatch({ writeLines(fp$hash, state_path); TRUE }, error = function(e) FALSE)
  invisible(ok)
}

# ── llm#1044 item 3: daily per-agent quality history + jump flag ─────────────
# One JSONL row per (date, agent, model): reviews, not_reviewed, rate. Local
# file owned by the email script (see the PR body for why not unified.duckdb).
rh_history_read <- function(path) {
  if (is.null(path) || !file.exists(path)) return(list(rows = list(), status = "missing", skipped = 0L))
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) NULL)
  if (is.null(lines)) return(list(rows = list(), status = "unreadable", skipped = 0L))
  rows <- list(); skipped <- 0L
  for (ln in lines[nzchar(trimws(lines))]) {
    r <- tryCatch(jsonlite::fromJSON(ln, simplifyVector = TRUE), error = function(e) NULL)
    ok <- is.list(r) && !is.null(r$date) && !is.null(r$agent) &&
      !is.null(r$reviews) && !is.null(r$not_reviewed) &&
      !is.na(suppressWarnings(as.Date(r$date)))
    if (ok) rows[[length(rows) + 1L]] <- list(
      date = as.character(r$date), agent = as.character(r$agent),
      model = if (is.null(r$model)) "" else as.character(r$model),
      reviews = as.integer(r$reviews), not_reviewed = as.integer(r$not_reviewed))
    else skipped <- skipped + 1L
  }
  list(rows = rows, status = if (skipped > 0L) "partial" else "ok", skipped = skipped)
}

rh_row_key <- function(r) paste(r$date, r$agent, r$model, sep = "␟")

# New rows override history rows with the same (date, agent, model).
rh_history_merge <- function(hist_rows, new_rows) {
  m <- list()
  for (r in hist_rows) m[[rh_row_key(r)]] <- r
  for (r in new_rows) m[[rh_row_key(r)]] <- r
  unname(m[order(vapply(m, rh_row_key, ""))])
}

rh_history_write <- function(path, rows) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  lines <- vapply(rows, function(r) {
    as.character(jsonlite::toJSON(list(
      date = r$date, agent = r$agent, model = r$model,
      reviews = r$reviews, not_reviewed = r$not_reviewed,
      rate = if (r$reviews > 0L) round(r$not_reviewed / r$reviews, 4) else NA_real_
    ), auto_unbox = TRUE, na = "null"))
  }, "")
  tmp <- paste0(path, ".tmp")
  ok <- tryCatch({ writeLines(lines, tmp); file.rename(tmp, path) }, error = function(e) FALSE)
  invisible(isTRUE(ok))
}

# Jump rule (report-only). For each agent/model, compare YESTERDAY (the last
# complete UTC day; `today` is partial and never judged) with the nearest
# earlier day within 3 days. Flag only when ALL hold:
#   * both days have >= min_reviews reviews          (rate is meaningful)
#   * yesterday has >= min_events not-reviewed       (one stray failure is not a trend)
#   * rate rose by >= jump_pts percentage points
# Fewer reviews, or no baseline, is "not judged" -- it produces NO flag, and
# is never reported as a clean pass either (callers see $judged_n).
rh_quality_jump_flags <- function(rows, today, min_reviews = 5L, min_events = 2L, jump_pts = 10) {
  today <- as.Date(today)
  yday <- today - 1L
  keys <- unique(vapply(rows, function(r) paste(r$agent, r$model, sep = "␟"), ""))
  flags <- list(); judged <- 0L
  for (k in keys) {
    rs <- Filter(function(r) paste(r$agent, r$model, sep = "␟") == k, rows)
    dates <- as.Date(vapply(rs, function(r) r$date, ""))
    i_last <- which(dates == yday)
    if (!length(i_last)) next
    prior <- which(dates < yday & dates >= yday - 3L)
    if (!length(prior)) next
    i_prev <- prior[which.max(dates[prior])]
    last <- rs[[i_last[1L]]]; prev <- rs[[i_prev]]
    if (last$reviews < min_reviews || prev$reviews < min_reviews) next
    judged <- judged + 1L
    r_last <- last$not_reviewed / last$reviews
    r_prev <- prev$not_reviewed / prev$reviews
    delta_pts <- (r_last - r_prev) * 100
    if (last$not_reviewed >= min_events && delta_pts >= jump_pts - 1e-9) {
      flags[[length(flags) + 1L]] <- list(
        agent = last$agent, model = last$model,
        last_date = as.character(yday), prev_date = as.character(dates[i_prev]),
        last_n = last$reviews, last_nr = last$not_reviewed, last_rate = r_last,
        prev_n = prev$reviews, prev_nr = prev$not_reviewed, prev_rate = r_prev,
        delta_pts = delta_pts
      )
    }
  }
  list(flags = flags, judged_n = judged)
}

# ── llm#1123 addendum 1: acknowledged triage decisions ───────────────────────
# ~/.roborev/acks.jsonl is written by roborev_ack.sh, one JSON object per line,
# {"id": <reviews.id>, "reason": ..., "acked_at": ...}. `id` is reviews.id (the
# same id the email's open-findings query selects as review_id), NOT the job id.
# status: "ok" | "missing" (no file: nothing acknowledged) |
#         "unparseable" (file exists but zero usable ids from >0 lines) |
#         "partial" (some lines skipped). Never raises.
rh_read_acks <- function(path) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) {
    return(list(ids = integer(0), status = "missing", skipped = 0L))
  }
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) NULL)
  if (is.null(lines)) return(list(ids = integer(0), status = "unparseable", skipped = 0L))
  lines <- lines[nzchar(trimws(lines))]
  ids <- integer(0); skipped <- 0L
  for (ln in lines) {
    r <- tryCatch(jsonlite::fromJSON(ln, simplifyVector = TRUE), error = function(e) NULL)
    idn <- if (is.list(r) && length(r$id) == 1L) rh_as_number(r$id) else NA_real_
    id <- if (!is.na(idn) && idn == round(idn) && idn > 0) as.integer(idn) else NA_integer_
    if (is.na(id)) skipped <- skipped + 1L else ids <- c(ids, id)
  }
  status <- if (length(lines) > 0L && length(ids) == 0L) "unparseable"
            else if (skipped > 0L) "partial" else "ok"
  list(ids = unique(ids), status = status, skipped = skipped)
}
