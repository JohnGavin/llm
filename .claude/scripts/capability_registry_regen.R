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

query_duckdb <- function(sql, db_path) {
  # system2() with stdout=TRUE builds and runs the command through a shell
  # (see ?system2), so arguments containing shell metacharacters (SQL has
  # parens/quotes) MUST be shQuote()'d -- unlike a raw execve() call.
  result <- tryCatch(
    system2("duckdb", args = c(shQuote(db_path), "-readonly", "-json", "-c", shQuote(sql)),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0)
  )
  # duckdb CLI emits "loaded <ext> ;" / "unified: ..." status lines on stdout
  # ahead of the JSON payload when extensions autoload; keep only the JSON
  # array, which starts with '[' (or is empty '[]\n' for zero rows).
  json_lines <- result[grepl("^\\s*[\\[\\{]", result) | grepl("^\\s*[\\]\\},\"]", result)]
  json_text <- paste(json_lines, collapse = "\n")
  if (!nzchar(trimws(json_text))) return(list())
  tryCatch(jsonlite::fromJSON(json_text, simplifyVector = FALSE), error = function(e) list())
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
  out <- list()
  for (r in rows) {
    if (is.null(r$agent_type)) next
    out[[r$agent_type]] <- list(inv = as.integer(r$inv %||% 0L), last_used = r$last_used)
  }
  out
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# ── Build DATA object ─────────────────────────────────────────────────────────

skills <- collect_skills(REPO_ROOT)
agents <- collect_agents(REPO_ROOT)
rules  <- collect_rules(REPO_ROOT)

skill_usage <- fetch_skill_usage(cfg$db)
agent_usage <- fetch_agent_usage(cfg$db)

annotate <- function(item, usage_map) {
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

skills_with_usage <- sum(vapply(skills, function(x) (x$invocations %||% 0L) > 0L, logical(1)))
agents_with_usage <- sum(vapply(agents, function(x) (x$invocations %||% 0L) > 0L, logical(1)))

firable <- c(skills, agents)
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

DATA <- list(
  generated_note = "usage from unified.duckdb (skill_usage, agent_runs); rules are always-on/path-scoped and carry no invocation count",
  counts = list(
    skills = length(skills),
    agents = length(agents),
    rules  = length(rules),
    total  = length(all_items)
  ),
  usage_coverage = list(
    skills_with_any_usage = skills_with_usage,
    agents_with_any_usage = agents_with_usage
  ),
  top_5_by_invocations = top5_out,
  items = items_out
)

data_json <- jsonlite::toJSON(DATA, auto_unbox = TRUE, null = "null", na = "null", pretty = TRUE)

# ── Render template ────────────────────────────────────────────────────────────

template_text <- paste(readLines(cfg$template, warn = FALSE), collapse = "\n")

generated_date <- format(Sys.Date(), "%Y-%m-%d")

html_out <- template_text
html_out <- sub("__CAPABILITY_REGISTRY_DATA_JSON__", data_json, html_out, fixed = TRUE)
html_out <- sub("__CAPABILITY_REGISTRY_GENERATED__", generated_date, html_out, fixed = TRUE)

dir.create(dirname(cfg$out), showWarnings = FALSE, recursive = TRUE)
writeLines(html_out, cfg$out)

summary_msg <- sprintf(
  "capability_registry_regen.R: wrote %s | skills=%d agents=%d rules=%d total=%d | skills_with_usage=%d agents_with_usage=%d",
  cfg$out, length(skills), length(agents), length(rules), length(all_items),
  skills_with_usage, agents_with_usage
)
message(summary_msg)

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

invisible(cfg$out)
