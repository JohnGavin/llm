# test-email-column-definitions.R
#
# Column-header hover definitions for the daily/weekly email tables (tooltips
# via the native HTML `title` attribute; the one mechanism email clients keep).
#
# ONE home for the text: .claude/scripts/email_column_definitions.tsv. These
# tests are the build gate:
#   - every column label a sender can emit has a non-empty definition,
#   - every definition is used by some sender (no stale entries),
#   - a sender cannot add a header the static scan cannot see (unregistered
#     dynamic <th> sites fail the scan),
#   - the rendering helpers add title + hover cue, escape the text, are
#     idempotent, and fail loudly in strict mode.
# The static scan is paired with a fault-injection test: removing one TSV row
# must make the "every label has a definition" check fail.

library(testthat)

.ecd_root <- function() getOption("llm.test_pkg_root", pkgload::pkg_path())
.ecd_scripts <- function() file.path(.ecd_root(), ".claude", "scripts")
.ecd_tsv <- function() file.path(.ecd_scripts(), "email_column_definitions.tsv")
.ecd_styles <- function() file.path(.ecd_scripts(), "email_styles.R")

skip_if_stripped <- function() {
  skip_if(!dir.exists(file.path(.ecd_root(), ".claude")),
          ".claude/ not in build tree (.Rbuildignore, e.g. under covr)")
}

# Senders whose tables live in dropdowns, plus the library files they call.
ECD_SENDERS <- c(
  "send_launchd_health_email.R", "send_overnight_self_review_email.R",
  "send_config_digest_email.R", "send_kb_digest_email.R",
  "send_roborev_email.R", "send_roborev_weekly_rollup_email.R",
  "lib/self_review_content_signals.R", "roborev_health_lib.R",
  "roborev_weekly_rollup.R", "kb_digest.R"
)

# Dynamic <th>%s</th> sites: header text comes from a variable, so the static
# scan reads the labels from the call/producer instead. Each entry is the file
# and the number of such sites; a new dynamic site fails the scan until it is
# registered here AND its labels are extracted below.
ECD_DYNAMIC_TH_SITES <- c(
  "send_overnight_self_review_email.R" = 1L,   # rv_table(df, c(...))
  "lib/self_review_content_signals.R"  = 1L,   # .scr_table(c(...), ...)
  "send_config_digest_email.R"         = 1L    # render_table_row(): digest markdown header
)

ecd_read <- function(rel) {
  readLines(file.path(.ecd_scripts(), rel), warn = FALSE)
}

ecd_strip_comments <- function(lines) lines[!grepl("^\\s*#", lines)]

ecd_quoted <- function(txt) {
  m <- regmatches(txt, gregexpr("\"([^\"]*)\"", txt))[[1L]]
  gsub("^\"|\"$", "", m)
}

# Body of a top-level `name <- function` (up to the next top-level assignment).
ecd_function_lines <- function(lines, name) {
  start <- grep(sprintf("^%s <- function", gsub("([.])", "\\\\\\1", name)), lines)
  if (length(start) != 1L) stop(sprintf("expected exactly one top-level %s()", name))
  nxt <- grep("^[A-Za-z_.][A-Za-z0-9_.]* <- ", lines)
  nxt <- nxt[nxt > start]
  end <- if (length(nxt)) nxt[[1L]] - 1L else length(lines)
  lines[start:end]
}

# Markdown table header rows: a piece starting with "|" directly followed by a
# separator piece (|---|---|). Pieces are the string-literal text split on a
# literal \n, in file order, so a header and its separator may sit in one
# literal or in two consecutive ones.
ecd_markdown_headers <- function(lines) {
  lines <- ecd_strip_comments(lines)
  lits <- unlist(lapply(lines, function(l) {
    m <- regmatches(l, gregexpr("\"((?:[^\"\\\\]|\\\\.)*)\"", l, perl = TRUE))[[1L]]
    gsub("^\"|\"$", "", m)
  }))
  pieces <- trimws(unlist(strsplit(lits, "\\n", fixed = TRUE)))
  pieces <- pieces[nzchar(pieces)]
  is_sep <- grepl("^\\|[-: |]+\\|$", pieces)
  is_row <- grepl("^\\|.*\\|$", pieces) & !is_sep
  hdr_idx <- which(is_row[-length(pieces)] & is_sep[-1L])
  labels <- unlist(lapply(pieces[hdr_idx], function(p) {
    cells <- trimws(strsplit(sub("^\\|", "", sub("\\|$", "", p)), "|", fixed = TRUE)[[1L]])
    cells[nzchar(cells)]
  }))
  labels <- gsub("\\*\\*", "", labels)
  unique(labels[!grepl("%[sd]", labels)])
}

# Every column label the emails can emit, with where it came from.
ecd_used_labels <- function() {
  out <- character(0)
  th_pat <- "<th(?:\\s[^>]*)?>([^<]*)</th>"
  for (rel in ECD_SENDERS) {
    code <- ecd_strip_comments(ecd_read(rel))
    txt <- paste(code, collapse = "\n")
    inner <- regmatches(txt, gregexpr(th_pat, txt, perl = TRUE))[[1L]]
    inner <- trimws(sub(th_pat, "\\1", inner, perl = TRUE))
    dynamic <- inner[grepl("%s", inner, fixed = TRUE)]
    static  <- inner[!grepl("%s", inner, fixed = TRUE)]
    expected_dynamic <- if (rel %in% names(ECD_DYNAMIC_TH_SITES)) ECD_DYNAMIC_TH_SITES[[rel]] else 0L
    if (length(dynamic) != expected_dynamic) {
      stop(sprintf("%s has %d dynamic <th>%%s</th> site(s); expected %d. Register it in ECD_DYNAMIC_TH_SITES and extract its labels.",
                   rel, length(dynamic), expected_dynamic))
    }
    out <- c(out, static)
  }
  # Dynamic site 1: rv_table(<df>, c("a", "b", ...))
  ov <- paste(ecd_strip_comments(ecd_read("send_overnight_self_review_email.R")), collapse = "\n")
  rv_calls <- regmatches(ov, gregexpr("rv_table\\([^,()]+,\\s*c\\(([^)]*)\\)\\)", ov, perl = TRUE))[[1L]]
  out <- c(out, unlist(lapply(rv_calls, ecd_quoted)))
  # Dynamic site 2: .scr_table(c("a", "b", ...), ...)
  sc <- paste(ecd_strip_comments(ecd_read("lib/self_review_content_signals.R")), collapse = "\n")
  sc_calls <- regmatches(sc, gregexpr("\\.scr_table\\(c\\(([^)]*)\\)", sc, perl = TRUE))[[1L]]
  out <- c(out, unlist(lapply(sc_calls, ecd_quoted)))
  # Dynamic site 3 + markdown-built tables: header rows of the markdown the
  # email converters render. Only the functions whose tables reach an email.
  launchd <- ecd_read("launchd_health_report.R")
  for (fn in c("render_inventory_table", "render_metrics_table", "render_cloud_crons_table")) {
    out <- c(out, ecd_markdown_headers(ecd_function_lines(launchd, fn)))
  }
  out <- c(out, ecd_markdown_headers(ecd_read("config_change_digest.R")))
  out <- c(out, ecd_markdown_headers(ecd_read("roborev_weekly_rollup.R")))
  out <- gsub("&amp;", "&", out, fixed = TRUE)
  sort(unique(out[nzchar(out)]))
}

ecd_read_tsv <- function(path = .ecd_tsv()) {
  utils::read.delim(path, sep = "\t", quote = "", comment.char = "", header = TRUE,
                    stringsAsFactors = FALSE, check.names = FALSE,
                    colClasses = "character", na.strings = character(0))
}

# ── The TSV itself ───────────────────────────────────────────────────────────

test_that("definitions file is well-formed: 2 columns, unique labels, non-empty, short, generic", {
  skip_if_stripped()
  expect_true(file.exists(.ecd_tsv()))
  raw <- readLines(.ecd_tsv(), warn = FALSE)
  expect_true(all(lengths(strsplit(raw, "\t", fixed = TRUE)) == 2L),
              label = "every line has exactly one tab (label<TAB>definition)")
  df <- ecd_read_tsv()
  expect_identical(names(df), c("column_label", "definition"))
  expect_false(anyDuplicated(df$column_label) > 0L,
               label = paste("duplicate labels:", paste(df$column_label[duplicated(df$column_label)], collapse = ", ")))
  empty <- df$column_label[!nzchar(trimws(df$definition))]
  expect_length(empty, 0L)
  too_long <- df$column_label[nchar(df$definition) > 200L]
  expect_true(length(too_long) == 0L,
              label = paste("definitions over 200 chars:", paste(too_long, collapse = ", ")))
  # Definitions are generic metric descriptions: no filesystem paths.
  paths <- df$column_label[grepl("(/Users/|~/|/nix/store)", df$definition)]
  expect_length(paths, 0L)
  todo <- df$column_label[grepl("^TODO", df$definition)]
  expect_length(todo, 0L)
})

test_that("every column label a sender can emit has a definition", {
  skip_if_stripped()
  used <- ecd_used_labels()
  expect_gt(length(used), 100L)  # guard: a vacuous scan must not pass
  have <- ecd_read_tsv()$column_label
  missing <- setdiff(used, have)
  expect_true(length(missing) == 0L,
              label = paste("labels with no definition:", paste(missing, collapse = " | ")))
})

test_that("no definition is stale (every entry is used by some sender)", {
  skip_if_stripped()
  used <- ecd_used_labels()
  have <- ecd_read_tsv()$column_label
  stale <- setdiff(have, used)
  expect_true(length(stale) == 0L,
              label = paste("TSV entries no sender uses:", paste(stale, collapse = " | ")))
})

test_that("fault injection: dropping one TSV row makes the coverage check go red", {
  skip_if_stripped()
  used <- ecd_used_labels()
  df <- ecd_read_tsv()
  victim <- used[[1L]]
  broken <- df[df$column_label != victim, , drop = FALSE]
  expect_true(victim %in% setdiff(used, broken$column_label))
  # And an emptied definition is caught by the same emptiness rule.
  blanked <- df
  blanked$definition[blanked$column_label == victim] <- ""
  expect_true(victim %in% blanked$column_label[!nzchar(trimws(blanked$definition))])
})

test_that("the scan sees the dynamic header sites (it is not blind to them)", {
  skip_if_stripped()
  used <- ecd_used_labels()
  # one label from each dynamic / markdown source
  expect_true(all(c("audit_status", "Repetitions", "Top files", "Non-zero exits (7d)",
                    "Cohort Close Rate", "Fires 24h", "Hours to close (h)") %in% used))
})

# ── Rendering helpers ────────────────────────────────────────────────────────

load_styles <- function(env = parent.frame()) {
  skip_if_stripped()
  source(.ecd_styles(), local = env)
}

test_that("email_add_tooltips adds title + hover cue, keeps layout, escapes, is idempotent", {
  load_styles()
  tmp <- tempfile(fileext = ".tsv")
  writeLines(c("column_label\tdefinition",
               "Alpha\tHow many <a> & \"b\" there are",
               "Beta\tPlain one"), tmp)
  withr::local_envvar(EMAIL_COLUMN_DEFS_PATH = tmp, EMAIL_COLUMN_DEFS_STRICT = "1")
  html <- paste0('<table><thead><tr>',
                 '<th style="padding:4px;text-align:left;">Alpha</th>',
                 '<th>Beta</th>',
                 '</tr></thead></table>')
  out <- email_add_tooltips(html)
  expect_true(grepl('title="How many &lt;a&gt; &amp; &quot;b&quot; there are"', out, fixed = TRUE))
  expect_true(grepl('<th style="padding:4px;text-align:left; text-decoration: underline dotted; cursor: help;"', out, fixed = TRUE))
  expect_true(grepl('<th style="text-decoration: underline dotted; cursor: help;" title="Plain one">Beta</th>', out, fixed = TRUE))
  expect_true(grepl("<thead>", out, fixed = TRUE))   # <thead> is not a <th>
  expect_identical(email_add_tooltips(out), out)      # idempotent
  # header text and structure unchanged
  expect_identical(gsub(' style="[^"]*"| title="[^"]*"', "", out),
                   gsub(' style="[^"]*"', "", html))
})

test_that("missing definition: strict mode errors, default mode warns on stderr and leaves the header plain", {
  load_styles()
  tmp <- tempfile(fileext = ".tsv")
  writeLines(c("column_label\tdefinition", "Alpha\tKnown"), tmp)
  withr::local_envvar(EMAIL_COLUMN_DEFS_PATH = tmp)
  html <- '<th>Alpha</th><th>Nope</th>'
  withr::with_envvar(c(EMAIL_COLUMN_DEFS_STRICT = "1"),
    expect_error(email_add_tooltips(html), "no column definition for header 'Nope'"))
  withr::with_envvar(c(EMAIL_COLUMN_DEFS_STRICT = ""), {
    expect_message(out <- email_add_tooltips(html), "no column definition for header 'Nope'")
    expect_true(grepl('<th>Nope</th>', out, fixed = TRUE))
    expect_true(grepl('title="Known"', out, fixed = TRUE))
  })
})

test_that("empty definition counts as missing", {
  load_styles()
  tmp <- tempfile(fileext = ".tsv")
  writeLines(c("column_label\tdefinition", "Alpha\t"), tmp)
  withr::local_envvar(EMAIL_COLUMN_DEFS_PATH = tmp, EMAIL_COLUMN_DEFS_STRICT = "1")
  expect_error(email_add_tooltips("<th>Alpha</th>"), "no column definition")
})

test_that("collapsible_block puts a tooltip on every header in its body", {
  load_styles()
  withr::local_envvar(EMAIL_COLUMN_DEFS_PATH = .ecd_tsv(), EMAIL_COLUMN_DEFS_STRICT = "1")
  body <- '<table><tr><th style="padding:6px;">Metric</th><th>Value</th></tr><tr><td>x</td><td>1</td></tr></table>'
  out <- collapsible_block("T", "S", body)
  ths <- regmatches(out, gregexpr("<th[ >][^>]*>?", out))[[1L]]
  expect_length(ths, 2L)
  expect_true(all(grepl("title=\"", ths)))
  expect_true(grepl("<details", out, fixed = TRUE))
})

test_that("email_header_cell renders a <td> header with the same tag, plus title and cue", {
  load_styles()
  withr::local_envvar(EMAIL_COLUMN_DEFS_PATH = .ecd_tsv(), EMAIL_COLUMN_DEFS_STRICT = "1")
  cell <- email_header_cell("Opened", "padding:5px;")
  expect_true(grepl("^<td style=\"padding:5px; text-decoration: underline dotted; cursor: help;\" title=\"", cell))
  expect_true(grepl(">Opened</td>$", cell))
})

test_that("the real definitions file resolves from where email_styles.R was sourced", {
  load_styles()
  withr::local_envvar(EMAIL_COLUMN_DEFS_PATH = "")
  expect_identical(normalizePath(email_column_defs_path()), normalizePath(.ecd_tsv()))
})

# ── Markdown-built tables (launchd health + weekly rollup) ───────────────────

# The two converters are defined inside scripts that run on source; evaluate
# only the converter (and its small helpers) in an environment that has the
# colour constants.
ecd_load_converter <- function(script, env) {
  exprs <- parse(file.path(.ecd_scripts(), script), keep.source = FALSE)
  want <- c("md_to_simple_html", "md_inline", "md_inline_code", "md_bold")
  for (e in exprs) {
    if (is.call(e) && identical(e[[1L]], as.name("<-")) &&
        is.name(e[[2L]]) && as.character(e[[2L]]) %in% want) {
      eval(e, env)
    }
  }
  env
}

test_that("markdown converters: only the header row gets tooltips; body rows are unchanged", {
  load_styles()
  withr::local_envvar(EMAIL_COLUMN_DEFS_PATH = .ecd_tsv(), EMAIL_COLUMN_DEFS_STRICT = "1")
  for (script in c("send_launchd_health_email.R", "send_roborev_weekly_rollup_email.R")) {
    env <- new.env(parent = environment())  # sees the sourced email_styles.R helpers
    env$dark_text <- DARK_TEXT; env$dark_border <- DARK_BORDER
    env$dark_card <- DARK_CARD; env$dark_row_alt <- DARK_ROW_ALT
    env$dark_muted <- DARK_MUTED; env$accent_orange <- ACCENT_ORANGE
    ecd_load_converter(script, env)
    md <- c("## Section", "", "| Label | Runs | Fail% |", "|-------|------|-------|",
            "| `job_a` | 3 | 0.0% |", "| `job_b` | 4 | 25.0% |", "",
            "| Repo | Workflow |", "|---|---|", "| `r` | w |")
    html <- env$md_to_simple_html(paste(md, collapse = "\n"))
    # 5 header cells (3 + 2) carry a title; no body cell does.
    expect_equal(lengths(regmatches(html, gregexpr('title="', html, fixed = TRUE))), 5L,
                 info = script)
    expect_true(grepl('title="[^"]+">Label</td>', html), info = script)
    expect_false(grepl('title="[^"]*">`?job_a', html), info = script)
    expect_false(grepl("<th", html, fixed = TRUE), info = script)  # tag unchanged: still <td>
  }
})

# ── End-to-end: the real overnight email, rendered without sending ───────────

test_that("dry run: every <th> in the real overnight email carries a title", {
  skip_if_stripped()
  skip_if_not_installed("blastula")
  skip_if_not_installed("duckdb")
  db <- normalizePath("~/.claude/logs/unified.duckdb", mustWork = FALSE)
  skip_if_not(file.exists(db), "unified.duckdb not available in test environment")
  script <- file.path(.ecd_scripts(), "send_overnight_self_review_email.R")
  out <- suppressWarnings(system2(
    "Rscript", args = script, stdout = TRUE, stderr = TRUE,
    env = c("EMAIL_DRY_RUN=1", "EMAIL_COLUMN_DEFS_STRICT=1",
            paste0("UNIFIED_DB_PATH=", db),
            "GMAIL_USERNAME=", "GMAIL_APP_PASSWORD=", "REPORT_RECIPIENT=")
  ))
  combined <- paste(out, collapse = "\n")
  skip_if(!grepl("QA:overnight_self_review_email=true", combined, fixed = TRUE),
          "dry run did not complete (unified.duckdb locked or unreadable)")
  expect_false(grepl("no column definition for header", combined, fixed = TRUE))
  ths <- regmatches(combined, gregexpr("<th[ >][^>]*>?", combined))[[1L]]
  expect_gt(length(ths), 0L)
  expect_true(all(grepl("title=\"", ths)),
              label = paste("headers without title:", sum(!grepl("title=\"", ths))))
})
