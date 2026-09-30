#!/usr/bin/env Rscript
# capability_registry_regen.R — Regenerate the "Capability Registry — Own Your
# Context" self-contained HTML file from the current skill/agent/rule
# inventory and unified.duckdb usage counters.
#
# IMPORTANT — republish boundary:
#   Republishing to the LIVE claude.ai artifact URL is a session-only step
#   (the Artifact tool, which requires a Claude Code session + claude.ai
#   auth). A launchd cron CANNOT do that. This script only regenerates the
#   self-contained HTML FILE on disk at .claude/reports/capability-registry.html.
#   To push a fresh render live, a session must: open this file, call the
#   Artifact tool with the SAME artifact URL used previously (see the `url`
#   parameter of the Artifact tool), which redeploys to the existing page.
#
# Usage:
#   Rscript .claude/scripts/capability_registry_regen.R \
#     [--out PATH] [--db PATH] [--template PATH] [--dry-run]
#
# Defaults:
#   --out       .claude/reports/capability-registry.html (repo-relative)
#   --db        ~/.claude/logs/unified.duckdb
#   --template  .claude/reports/capability_registry_template.html (repo-relative)
#   --dry-run   print summary counts to stdout only, still writes --out
#
# Exit codes: 0 ok; 1 error (missing template, hand-typed literal); 3
# INDETERMINATE -- unified.duckdb unreadable (llm#1304): the page is still
# written with every usage figure shown as an em dash (unknown, never 0) and a
# visible banner; lock errors are retried 3x (REGISTRY_DB_RETRY_SLEEP secs).
#
# SELFTEST=1 env var: runs against the real duckdb (read-only) into a /tmp
# output path and validates the result is non-empty + well-formed, then exits.
#
# Data sources:
#   Filesystem inventory: .claude/skills/*/SKILL.md (excluding .system,
#     generated), .claude/agents/*.md, .claude/rules/*.md (top-level only,
#     excludes _companions/).
#   Usage counters: skill_usage, agent_runs tables in unified.duckdb.
#     Rules have no usage table (they are always-on / path-scoped, not
#     invoked on demand) — invocations/last_used are emitted as null,
#     matching the template's "always-on" rendering path.
#
# Tables written: housekeeping_runs (heartbeat only; no dedicated events
# table — this task has no per-item event stream, just a full-inventory
# regeneration each run).
#
# See: housekeeping-framework rule, cron-auto-pull-discipline rule.

suppressPackageStartupMessages({
  library(jsonlite)
})

# ── Argument parsing ──────────────────────────────────────────────────────────

args <- commandArgs(trailingOnly = TRUE)

parse_args <- function(args) {
  out <- list(
    out      = NULL,
    db       = Sys.getenv("UNIFIED_DB_PATH", file.path(Sys.getenv("HOME"), ".claude/logs/unified.duckdb")),
    template = NULL,
    dry_run  = FALSE
  )
  i <- 1L
  while (i <= length(args)) {
    if (args[i] == "--out" && i + 1L <= length(args)) {
      out$out <- args[i + 1L]; i <- i + 2L
    } else if (args[i] == "--db" && i + 1L <= length(args)) {
      out$db <- args[i + 1L]; i <- i + 2L
    } else if (args[i] == "--template" && i + 1L <= length(args)) {
      out$template <- args[i + 1L]; i <- i + 2L
    } else if (args[i] == "--dry-run") {
      out$dry_run <- TRUE; i <- i + 1L
    } else {
      i <- i + 1L
    }
  }
  out
}

cfg <- parse_args(args)

# ── Locate repo root ──────────────────────────────────────────────────────────

find_repo_root <- function() {
  env_root <- Sys.getenv("LLM_REPO_ROOT", unset = "")
  if (nzchar(env_root) && file.exists(file.path(env_root, ".git"))) {
    return(normalizePath(env_root))
  }
  start <- tryCatch(
    dirname(normalizePath(sys.frame(0)$ofile, mustWork = FALSE)),
    error = function(e) getwd()
  )
  path <- start
  for (i in seq_len(10L)) {
    if (file.exists(file.path(path, ".git"))) return(path)
    parent <- dirname(path)
    if (parent == path) break
    path <- parent
  }
  getwd()
}

REPO_ROOT <- find_repo_root()

if (is.null(cfg$out)) {
  cfg$out <- file.path(REPO_ROOT, ".claude/reports/capability-registry.html")
}
if (is.null(cfg$template)) {
  cfg$template <- file.path(REPO_ROOT, ".claude/reports/capability_registry_template.html")
}

# ── SELFTEST override ─────────────────────────────────────────────────────────

SELFTEST <- identical(Sys.getenv("SELFTEST"), "1")
if (SELFTEST) {
  cfg$out <- file.path(tempdir(), sprintf("capability_registry_selftest_%s.html", format(Sys.time(), "%Y%m%d%H%M%S")))
  message(sprintf("capability_registry_regen.R: SELFTEST=1 -- writing to %s", cfg$out))
}

# ── duckdb-absent guard ───────────────────────────────────────────────────────

duckdb_ok <- nzchar(Sys.which("duckdb")) && file.exists(cfg$db)
if (!duckdb_ok) {
  message(sprintf(
    "capability_registry_regen.R: duckdb not available (binary on PATH: %s, db exists: %s) -- exiting cleanly, no file written",
    nzchar(Sys.which("duckdb")), file.exists(cfg$db)
  ))
  quit(status = 0L)
}

if (!file.exists(cfg$template)) {
  message(sprintf("capability_registry_regen.R: ERROR template not found at %s", cfg$template))
  quit(status = 1L)
}

# ── duckdb query helper (read-only, JSON output) ──────────────────────────────

# Failure contract (llm#1304, checks-must-distinguish-unknown): a query that
# could not be answered returns NULL and records why in DB_ERRORS; a query that
# ran and matched nothing returns list(). Callers MUST NOT collapse the two.
# Lock errors (another writer holds unified.duckdb) are retried briefly.
DB_ERRORS <- character(0)
DB_RETRIES <- 3L
DB_RETRY_SLEEP <- suppressWarnings(as.numeric(Sys.getenv("REGISTRY_DB_RETRY_SLEEP", "2")))
if (is.na(DB_RETRY_SLEEP) || DB_RETRY_SLEEP < 0) DB_RETRY_SLEEP <- 2

query_duckdb <- function(sql, db_path) {
  # system2() with stdout=TRUE builds and runs the command through a shell
  # (see ?system2), so arguments containing shell metacharacters (SQL has
  # parens/quotes) MUST be shQuote()'d -- unlike a raw execve() call.
  err_file <- tempfile("duckdb_stderr_")
  on.exit(unlink(err_file), add = TRUE)
  fail_msg <- NULL
  for (attempt in seq_len(DB_RETRIES)) {
    failed <- NULL
    result <- tryCatch(
      suppressWarnings(system2("duckdb",
        args = c(shQuote(db_path), "-readonly", "-json", "-c", shQuote(sql)),
        stdout = TRUE, stderr = err_file)),
      error = function(e) { failed <<- conditionMessage(e); character(0) }
    )
    status <- attr(result, "status")
    if (is.null(failed) && !is.null(status) && !identical(as.integer(status), 0L)) {
      err_txt <- trimws(paste(readLines(err_file, warn = FALSE), collapse = " "))
      failed <- sprintf("duckdb exited %s: %s", status, if (nzchar(err_txt)) err_txt else "(no stderr)")
    }
    if (is.null(failed)) { fail_msg <- NULL; break }
    fail_msg <- failed
    retryable <- grepl("lock|conflict|busy|could not set", failed, ignore.case = TRUE)
    if (!retryable || attempt == DB_RETRIES) break
    Sys.sleep(DB_RETRY_SLEEP)
  }
  if (!is.null(fail_msg)) {
    DB_ERRORS <<- c(DB_ERRORS, sprintf("%s [query: %s]", fail_msg, gsub("[[:space:]]+", " ", trimws(sql))))
    return(NULL)
  }
  # duckdb CLI emits "loaded <ext> ;" / "unified: ..." status lines on stdout
  # ahead of the JSON payload when extensions autoload; keep only the JSON
  # array, which starts with '[' (or is empty '[]\n' for zero rows).
  json_lines <- result[grepl("^\\s*[\\[\\{]", result) | grepl("^\\s*[\\]\\},\"]", result)]
  json_text <- paste(json_lines, collapse = "\n")
  if (!nzchar(trimws(json_text))) return(list())
  parsed <- tryCatch(jsonlite::fromJSON(json_text, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(parsed)) {
    DB_ERRORS <<- c(DB_ERRORS, sprintf("unparseable duckdb JSON [query: %s]", gsub("[[:space:]]+", " ", trimws(sql))))
  }
  parsed
}

# ── Filesystem inventory ──────────────────────────────────────────────────────

# YAML frontmatter `description:` extractor. Handles quoted and unquoted
# single-line values; multi-line/folded YAML descriptions are truncated to
# their first line (adequate for a registry blurb).
extract_frontmatter_description <- function(path) {
  lines <- tryCatch(readLines(path, warn = FALSE, n = 40L), error = function(e) character(0))
  if (length(lines) == 0L || !identical(trimws(lines[1L]), "---")) return("")
  end_idx <- which(trimws(lines[-1L]) == "---")
  if (length(end_idx) == 0L) return("")
  fm <- lines[2L:end_idx[1L]]
  desc_line <- grep("^description:\\s*", fm, value = TRUE)
  if (length(desc_line) == 0L) return("")
  val <- sub("^description:\\s*", "", desc_line[1L])
  val <- trimws(val)
  val <- gsub('^"(.*)"$', "\\1", val)
  val <- gsub("^'(.*)'$", "\\1", val)
  val
}

collect_skills <- function(repo_root) {
  skills_dir <- file.path(repo_root, ".claude/skills")
  if (!dir.exists(skills_dir)) return(list())
  subdirs <- list.dirs(skills_dir, recursive = FALSE, full.names = FALSE)
  subdirs <- setdiff(subdirs, c(".system", "generated"))
  out <- list()
  for (nm in subdirs) {
    skill_md <- file.path(skills_dir, nm, "SKILL.md")
    if (!file.exists(skill_md)) next
    out[[length(out) + 1L]] <- list(
      kind = "skill",
      name = nm,
      description = extract_frontmatter_description(skill_md)
    )
  }
  out
}

collect_agents <- function(repo_root) {
  agents_dir <- file.path(repo_root, ".claude/agents")
  if (!dir.exists(agents_dir)) return(list())
  files <- list.files(agents_dir, pattern = "\\.md$", full.names = FALSE)
  out <- list()
  for (f in files) {
    nm <- sub("\\.md$", "", f)
    out[[length(out) + 1L]] <- list(
      kind = "agent",
      name = nm,
      description = extract_frontmatter_description(file.path(agents_dir, f))
    )
  }
  out
}

collect_rules <- function(repo_root) {
  rules_dir <- file.path(repo_root, ".claude/rules")
  if (!dir.exists(rules_dir)) return(list())
  # Top-level only: excludes _companions/ (cross-referenced, not independently loaded)
  files <- list.files(rules_dir, pattern = "\\.md$", full.names = FALSE, recursive = FALSE)
  out <- list()
  for (f in files) {
    nm <- sub("\\.md$", "", f)
    out[[length(out) + 1L]] <- list(
      kind = "rule",
      name = nm,
      description = extract_frontmatter_description(file.path(rules_dir, f))
    )
  }
  out
}

# ── Usage counters from unified.duckdb ────────────────────────────────────────

fetch_skill_usage <- function(db_path) {
  rows <- query_duckdb(
    "SELECT skill_name, SUM(invocations) AS inv, MAX(ts) AS last_used
     FROM skill_usage GROUP BY skill_name",
    db_path
  )
  if (is.null(rows)) return(NULL)  # unreadable: unknown, not empty
  # named list keyed by skill_name -> list(inv=, last_used=)
  out <- list()
  for (r in rows) {
    if (is.null(r$skill_name)) next
    out[[r$skill_name]] <- list(inv = as.integer(r$inv %||% 0L), last_used = r$last_used)
  }
  out
}

fetch_agent_usage <- function(db_path) {
  rows <- query_duckdb(
    "SELECT agent_type, COUNT(*) AS inv, MAX(started_at) AS last_used
     FROM agent_runs GROUP BY agent_type",
    db_path
  )
  if (is.null(rows)) return(NULL)  # unreadable: unknown, not empty
  out <- list()
  for (r in rows) {
    if (is.null(r$agent_type)) next
    out[[r$agent_type]] <- list(inv = as.integer(r$inv %||% 0L), last_used = r$last_used)
  }
  out
}

fetch_row_count <- function(db_path, table) {
  rows <- query_duckdb(sprintf("SELECT COUNT(*) AS n FROM %s", table), db_path)
  if (is.null(rows) || length(rows) == 0L || is.null(rows[[1L]]$n)) return(NULL)  # unknown
  as.integer(rows[[1L]]$n)
}

# Slash-command usage, most-used first (name ties broken alphabetically so the
# render is deterministic).
fetch_command_usage <- function(db_path) {
  rows <- query_duckdb(
    "SELECT command_name, COUNT(*) AS n FROM command_usage
     WHERE command_name IS NOT NULL GROUP BY command_name",
    db_path
  )
  if (is.null(rows)) return(NULL)  # unreadable: unknown, not empty
  out <- lapply(rows, function(r) list(name = r$command_name, count = as.integer(r$n %||% 0L)))
  if (length(out) == 0L) return(out)
  ord <- order(-vapply(out, function(x) x$count, integer(1)),
               vapply(out, function(x) x$name, character(1)))
  out[ord]
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# ── Build DATA object ─────────────────────────────────────────────────────────

skills <- collect_skills(REPO_ROOT)
agents <- collect_agents(REPO_ROOT)
rules  <- collect_rules(REPO_ROOT)

skill_usage <- fetch_skill_usage(cfg$db)
agent_usage <- fetch_agent_usage(cfg$db)
SKILLS_OK <- !is.null(skill_usage)
AGENTS_OK <- !is.null(agent_usage)

annotate <- function(item, usage_map) {
  if (is.null(usage_map)) {  # usage unreadable: NA (unknown), never 0L
    item$invocations <- NA_integer_
    item$last_used <- NULL
    return(item)
  }
  u <- usage_map[[item$name]]
  item$invocations <- if (is.null(u)) 0L else u$inv
  item$last_used    <- if (is.null(u)) NULL else u$last_used
  item
}

skills <- lapply(skills, annotate, usage_map = skill_usage)
agents <- lapply(agents, annotate, usage_map = agent_usage)
rules  <- lapply(rules, function(item) {
  item$invocations <- NA  # NA -> null in JSON; matches template's "always-on" path
  item$last_used <- NULL
  item
})

all_items <- c(skills, agents, rules)

skills_with_usage <- if (SKILLS_OK) sum(vapply(skills, function(x) (x$invocations %||% 0L) > 0L, logical(1))) else NA_integer_
agents_with_usage <- if (AGENTS_OK) sum(vapply(agents, function(x) (x$invocations %||% 0L) > 0L, logical(1))) else NA_integer_

# Top 5 ranks only items whose usage is actually known (NA is not 0).
firable <- Filter(function(x) !is.na(x$invocations %||% NA_integer_), c(skills, agents))
inv_vals <- vapply(firable, function(x) as.integer(x$invocations %||% 0L), integer(1))
ord <- order(inv_vals, decreasing = TRUE)
top5 <- firable[ord][seq_len(min(5L, length(firable)))]
top5_out <- lapply(top5, function(x) list(name = x$name, kind = x$kind, invocations = as.integer(x$invocations %||% 0L)))

items_out <- lapply(all_items, function(x) {
  list(
    kind = x$kind,
    name = x$name,
    description = x$description,
    invocations = if (is.na(x$invocations %||% NA)) NULL else as.integer(x$invocations),
    last_used = x$last_used
  )
})

# ── Facts: the single home for every count quoted in the page prose ──────────
# Template prose never hand-types these (llm#1294, dynamic-prose-values rule):
# it carries <span data-fact="key"></span> and the values below are filled in.

commands <- fetch_command_usage(cfg$db)
CMDS_OK <- !is.null(commands)
if (!CMDS_OK) commands <- list()
skill_rows <- fetch_row_count(cfg$db, "skill_usage")
cmd_rows   <- fetch_row_count(cfg$db, "command_usage")

# A usage-derived fact whose source could not be read renders as UNKNOWN, never
# 0 (llm#1304). Inventory facts (n_*) come from the filesystem and always render.
UNKNOWN <- "\u2014"  # em dash
agent_inv_vals <- if (AGENTS_OK) vapply(agents, function(x) as.integer(x$invocations %||% 0L), integer(1)) else integer(0)
agent_inv_total <- sum(agent_inv_vals)
top_agent_idx <- if (AGENTS_OK && length(agents) > 0L) {
  order(-agent_inv_vals, vapply(agents, function(x) x$name, character(1)))[1L]
} else NA_integer_
FACTS <- list(
  n_skills  = length(skills),
  n_agents  = length(agents),
  n_rules   = length(rules),
  n_total   = length(all_items),
  agents_fired = if (AGENTS_OK) agents_with_usage else UNKNOWN,
  agents_idle  = if (AGENTS_OK) length(agents) - agents_with_usage else UNKNOWN,
  top_agent = if (!AGENTS_OK) UNKNOWN else if (is.na(top_agent_idx)) "none" else agents[[top_agent_idx]]$name,
  top_agent_share_pct = if (!AGENTS_OK) UNKNOWN else if (agent_inv_total > 0L) {
    as.integer(round(100 * agent_inv_vals[top_agent_idx] / agent_inv_total))
  } else 0L,
  skill_invocations_total = if (SKILLS_OK) sum(vapply(skills, function(x) as.integer(x$invocations %||% 0L), integer(1))) else UNKNOWN,
  cmd_total = if (CMDS_OK) sum(vapply(commands, function(x) x$count, integer(1))) else UNKNOWN,
  skill_usage_rows   = if (is.null(skill_rows)) UNKNOWN else skill_rows,
  command_usage_rows = if (is.null(cmd_rows)) UNKNOWN else cmd_rows
)
USAGE_UNREADABLE <- length(DB_ERRORS) > 0L ||
  !(SKILLS_OK && AGENTS_OK && CMDS_OK) || is.null(skill_rows) || is.null(cmd_rows)

DATA <- list(
  generated_note = "usage from unified.duckdb (skill_usage, agent_runs); rules are always-on/path-scoped and carry no invocation count",
  counts = list(
    skills = length(skills),
    agents = length(agents),
    rules  = length(rules),
    total  = length(all_items)
  ),
  usage_coverage = list(
    skills_with_any_usage = if (SKILLS_OK) skills_with_usage else NULL,
    agents_with_any_usage = if (AGENTS_OK) agents_with_usage else NULL
  ),
  usage_unreadable = USAGE_UNREADABLE,
  top_5_by_invocations = top5_out,
  commands = commands,
  facts = FACTS,
  items = items_out
)

data_json <- jsonlite::toJSON(DATA, auto_unbox = TRUE, null = "null", na = "null", pretty = TRUE)

# ── Render template ────────────────────────────────────────────────────────────

template_text <- paste(readLines(cfg$template, warn = FALSE), collapse = "\n")

generated_date <- format(Sys.Date(), "%Y-%m-%d")

# ── Literal gate (llm#1294) ───────────────────────────────────────────────────
# Every number in the template's prose and JS strings must come from FACTS (via
# a data-fact span) or carry an explicit reason (data-fixed="<reason>"). Zero
# tolerance, no category exempt: counts, dates, percentages, phase labels.
# A violation fails the build BEFORE anything is written.

check_template_literals <- function(tpl, facts) {
  viol <- character(0)
  flag <- function(kind, tok, ctx) {
    homes <- names(facts)[vapply(facts, function(v) identical(as.character(v), tok), logical(1))]
    hint <- if (length(homes)) sprintf(" (equals home value %s)", paste(homes, collapse = "/")) else ""
    viol <<- c(viol, sprintf("  [%s] literal '%s'%s in: ...%s...", kind, tok, hint, trimws(ctx)))
  }
  scan_digits <- function(text, kind) {
    m <- gregexpr("[0-9]+([.,][0-9]+)*", text, perl = TRUE)[[1L]]
    if (m[1L] == -1L) return(invisible())
    lens <- attr(m, "match.length")
    for (i in seq_along(m)) {
      tok <- substr(text, m[i], m[i] + lens[i] - 1L)
      ctx <- substr(text, max(1L, m[i] - 40L), min(nchar(text), m[i] + lens[i] + 30L))
      flag(kind, tok, gsub("[\r\n]+", " ", ctx))
    }
  }

  prose <- tpl
  # JS / CSS / comments are not prose (JS strings are scanned separately below).
  scripts <- regmatches(prose, gregexpr("(?s)<script[^>]*>.*?</script>", prose, perl = TRUE))[[1L]]
  prose <- gsub("(?s)<script[^>]*>.*?</script>", " ", prose, perl = TRUE)
  prose <- gsub("(?s)<style[^>]*>.*?</style>", " ", prose, perl = TRUE)
  prose <- gsub("(?s)<!--.*?-->", " ", prose, perl = TRUE)

  # data-fixed without a reason is itself a violation.
  if (grepl("data-fixed=(\"\"|'')|data-fixed([[:space:]]|>|/)", prose, perl = TRUE)) {
    viol <- c(viol, "  [data-fixed] an element has data-fixed with no reason; the escape hatch is data-fixed=\"<reason>\"")
  }
  prose <- gsub("(?s)<(\\w+)\\b[^>]*\\bdata-fixed=\"[^\"]+\"[^>]*>.*?</\\1>", " ", prose, perl = TRUE)
  # A data-fact span must be EMPTY in the template; typed content inside one is
  # just a literal wearing a costume.
  typed <- regmatches(prose, gregexpr("<span data-fact=\"[A-Za-z0-9_]+\">[^<]+</span>", prose, perl = TRUE))[[1L]]
  for (t in typed) viol <- c(viol, sprintf("  [data-fact] span is not empty (hand-typed value): %s", t))
  prose <- gsub("(?s)<span data-fact=\"[A-Za-z0-9_]+\">.*?</span>", " ", prose, perl = TRUE)
  prose <- gsub("(?s)<[^>]+>", " ", prose, perl = TRUE)
  prose <- gsub("&[a-z]+;", " ", prose)
  scan_digits(prose, "prose")

  # JS string literals (single- or double-quoted). Numeric code (thresholds,
  # animation timings) is not prose and is not scanned.
  js_str_re <- "'([^'\\\\\n]|\\\\.)*'|\"([^\"\\\\\n]|\\\\.)*\""
  for (sc in scripts) {
    sc <- sub("(?s)^<script[^>]*>", "", sc, perl = TRUE)
    sc <- sub("(?s)</script>$", "", sc, perl = TRUE)
    sc <- gsub("__CAPABILITY_REGISTRY_DATA_JSON__", "null", sc, fixed = TRUE)
    sc <- gsub("(?m)^[[:space:]]*//[^\n]*$", "", sc, perl = TRUE)
    strs <- regmatches(sc, gregexpr(js_str_re, sc, perl = TRUE))[[1L]]
    for (st in strs) scan_digits(st, "js-string")
  }

  # Every data-fact key used must exist in FACTS.
  used <- regmatches(tpl, gregexpr("data-fact=\"[A-Za-z0-9_]+\"", tpl))[[1L]]
  keys <- unique(sub("^data-fact=\"([^\"]+)\"$", "\\1", used))
  unknown <- setdiff(keys, names(facts))
  if (length(unknown)) {
    viol <- c(viol, sprintf("  [data-fact] unknown fact key(s): %s", paste(unknown, collapse = ", ")))
  }
  viol
}

literal_violations <- check_template_literals(template_text, FACTS)
if (length(literal_violations) > 0L) {
  message(sprintf(
    "capability_registry_regen.R: ERROR %d hand-typed literal(s) in %s -- every value has ONE home (dynamic-prose-values); use <span data-fact=\"key\"></span> or data-fixed=\"<reason>\":",
    length(literal_violations), cfg$template))
  for (v in literal_violations) message(v)
  quit(status = 1L)
}

fill_facts <- function(tpl, facts) {
  for (k in names(facts)) {
    tpl <- gsub(sprintf("<span data-fact=\"%s\"></span>", k),
                sprintf("<span data-fact=\"%s\">%s</span>", k, as.character(facts[[k]])),
                tpl, fixed = TRUE)
  }
  tpl
}

html_out <- fill_facts(template_text, FACTS)
html_out <- sub("__CAPABILITY_REGISTRY_DATA_JSON__", data_json, html_out, fixed = TRUE)
html_out <- sub("__CAPABILITY_REGISTRY_GENERATED__", generated_date, html_out, fixed = TRUE)

# Visible degraded-mode banner (added after the literal gate: it is generated,
# not template prose). No background colour -> nothing for the dark-mode
# contrast gate to flag.
if (USAGE_UNREADABLE) {
  esc_html <- function(x) gsub(">", "&gt;", gsub("<", "&lt;", gsub("&", "&amp;", x, fixed = TRUE), fixed = TRUE), fixed = TRUE)
  banner <- sprintf(
    paste0("<div role=\"alert\" data-usage-unreadable style=\"border:2px solid #c0392b;padding:10px 14px;margin:12px;font-weight:600\">",
           "Usage tables unreadable: every usage figure below is shown as \u2014 (unknown), not 0. ",
           "The inventory (skills, agents, rules) is unaffected.",
           "<div style=\"font-weight:400;font-size:0.85em\">%s</div></div>"),
    esc_html(paste(unique(DB_ERRORS), collapse = " | ")))
  # The template is a fragment (no <body>; the Artifact wrapper adds it), so
  # prepend; if a <body> is ever added, insert after it.
  if (grepl("<body[^>]*>", html_out, perl = TRUE)) {
    html_out <- sub("(<body[^>]*>)", paste0("\\1\n", gsub("\\", "\\\\", banner, fixed = TRUE)), html_out, perl = TRUE)
  } else {
    html_out <- paste0(banner, "\n", html_out)
  }
}

dir.create(dirname(cfg$out), showWarnings = FALSE, recursive = TRUE)
writeLines(html_out, cfg$out)

summary_msg <- sprintf(
  "capability_registry_regen.R: wrote %s | skills=%d agents=%d rules=%d total=%d | skills_with_usage=%d agents_with_usage=%d",
  cfg$out, length(skills), length(agents), length(rules), length(all_items),
  if (SKILLS_OK) skills_with_usage else -1L, if (AGENTS_OK) agents_with_usage else -1L
)
message(summary_msg)

if (USAGE_UNREADABLE) {
  message("capability_registry_regen.R: WARNING usage tables unreadable -- usage figures rendered as unknown (-1 above = unknown); the inventory is correct")
  for (e in unique(DB_ERRORS)) message("  duckdb: ", e)
}

if (cfg$dry_run) {
  message("capability_registry_regen.R: --dry-run (file still written; no downstream publish step exists for this script)")
}

if (SELFTEST) {
  ok <- TRUE
  if (!file.exists(cfg$out) || file.info(cfg$out)$size == 0L) {
    message("SELFTEST FAIL: output file missing or empty")
    ok <- FALSE
  }
  written <- paste(readLines(cfg$out, warn = FALSE), collapse = "\n")
  if (!grepl("const DATA = ", written, fixed = TRUE)) {
    message("SELFTEST FAIL: DATA blob placeholder was not substituted")
    ok <- FALSE
  }
  if (grepl("__CAPABILITY_REGISTRY_", written, fixed = TRUE)) {
    message("SELFTEST FAIL: unsubstituted placeholder(s) remain")
    ok <- FALSE
  }
  parsed <- tryCatch({
    m <- regmatches(written, regexpr("(?s)const DATA = (\\{.*?\\});", written, perl = TRUE))
    json_only <- sub("^const DATA = ", "", sub(";$", "", m))
    jsonlite::fromJSON(json_only, simplifyVector = FALSE)
  }, error = function(e) NULL)
  if (is.null(parsed)) {
    message("SELFTEST FAIL: embedded DATA JSON did not parse")
    ok <- FALSE
  } else if (is.null(parsed$counts) || is.null(parsed$items)) {
    message("SELFTEST FAIL: parsed DATA missing counts/items")
    ok <- FALSE
  }
  if (ok) {
    message(sprintf("SELFTEST PASS: %s is well-formed (counts: skills=%s agents=%s rules=%s total=%s)",
                     cfg$out, parsed$counts$skills, parsed$counts$agents, parsed$counts$rules, parsed$counts$total))
  } else {
    quit(status = 1L)
  }
}

# Exit 3 = INDETERMINATE (exit-code-conventions, checks-must-distinguish-unknown):
# the file IS written (inventory correct, usage explicitly unknown), but a
# caller must not read this run as a clean 0.
if (USAGE_UNREADABLE) quit(status = 3L)

invisible(cfg$out)
