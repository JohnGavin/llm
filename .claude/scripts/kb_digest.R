#!/usr/bin/env Rscript
# kb_digest.R — Privacy-first daily knowledge-base digest aggregator.
#
# Analyses git history of the local knowledge/ repo and emits a sanitised
# markdown digest containing ONLY: counts, page titles, theme labels,
# commit-message subjects. NO raw page content is ever emitted.
#
# Args (parsed from command line):
#   --since  YYYY-MM-DDTHH:MM:SS  Cutoff timestamp (default: 24h ago)
#   --knowledge-repo  PATH        Path to local knowledge repo
#                                 (default: ~/docs_gh/llm/knowledge)
#   --out    PATH                 Write digest to file (default: stdout)
#   --dry-run                     Print to stdout without writing --out file
#
# Privacy contract:
#   - NEVER emit lines matching any wiki page body text
#   - Emit only: counts, file basenames (titles), folder names (themes),
#     commit subjects (first line only), confidence-marker COUNTS
#   - Use sanitise_text() on every candidate string before output
#
# Usage:
#   Rscript .claude/scripts/kb_digest.R --since 2026-05-28T00:00:00
#   EMAIL_DRY_RUN=1 Rscript .claude/scripts/kb_digest.R
#
# Tracked in llm#298.

suppressPackageStartupMessages(library(methods))

# ── Argument parsing ──────────────────────────────────────────────────────────

parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  defaults <- list(
    since          = format(Sys.time() - 86400, "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
    knowledge_repo = file.path(Sys.getenv("HOME"), "docs_gh", "llm", "knowledge"),
    out            = "",
    dry_run        = FALSE
  )

  i <- 1L
  while (i <= length(argv)) {
    arg <- argv[[i]]
    if (arg == "--since"          && i < length(argv)) { defaults$since          <- argv[[i + 1L]]; i <- i + 2L }
    else if (arg == "--knowledge-repo" && i < length(argv)) { defaults$knowledge_repo <- argv[[i + 1L]]; i <- i + 2L }
    else if (arg == "--out"            && i < length(argv)) { defaults$out            <- argv[[i + 1L]]; i <- i + 2L }
    else if (arg == "--dry-run") { defaults$dry_run <- TRUE; i <- i + 1L }
    else { i <- i + 1L }
  }

  # EMAIL_DRY_RUN env override
  if (identical(Sys.getenv("EMAIL_DRY_RUN"), "1")) defaults$dry_run <- TRUE

  defaults
}

args <- parse_args()

# ── Validation ────────────────────────────────────────────────────────────────

if (!dir.exists(args$knowledge_repo)) {
  message(sprintf("kb_digest.R: knowledge repo not found: %s", args$knowledge_repo))
  quit(status = 1L)
}

git_dir <- file.path(args$knowledge_repo, ".git")
if (!dir.exists(git_dir)) {
  message(sprintf("kb_digest.R: not a git repo: %s (expected .git/)", args$knowledge_repo))
  quit(status = 1L)
}

# ── Privacy: sanitisation ─────────────────────────────────────────────────────
#
# CRITICAL: This function is the privacy boundary. Any string that could
# contain page body content must pass through here before being emitted.
# Rules:
#   (a) Trim to filename / basename / subject (no multi-sentence prose)
#   (b) Strip anything longer than MAX_LEN characters
#   (c) Replace inline brackets, backticks, special chars
#   (d) Return NA_character_ if the result is still suspicious
#
MAX_SAFE_LEN <- 120L  # characters — long enough for a page title, short for prose

sanitise_text <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) return(NA_character_)
  x <- trimws(x)
  # Strip markdown emphasis
  x <- gsub("[`*_~]", "", x)
  # Strip anything that looks like a URL
  x <- gsub("https?://\\S+", "<url>", x)
  # Strip anything that looks like a file path
  x <- gsub("~/[^\\s]+", "<path>", x)
  # Truncate to MAX_SAFE_LEN
  if (nchar(x) > MAX_SAFE_LEN) x <- paste0(substr(x, 1L, MAX_SAFE_LEN - 3L), "...")
  x
}

# ── Git helpers ───────────────────────────────────────────────────────────────

git_run <- function(args_vec, repo = args$knowledge_repo, ...) {
  # suppressWarnings: git exits non-zero (e.g. 128) for root commits when
  # asked to diff SHA^ — this is expected and handled by fallback logic.
  result <- tryCatch(
    suppressWarnings(
      system2("git", c("-C", repo, args_vec), stdout = TRUE, stderr = FALSE, ...)
    ),
    error = function(e) character(0L)
  )
  if (!is.null(attr(result, "status")) && attr(result, "status") != 0L) {
    character(0L)
  } else {
    result
  }
}

# Commits since the cutoff
# Use %x01 (ASCII SOH) as separator — safe in shell, never in email/subjects
COMMIT_SEP <- "\x01"
# Normalise timestamp to YYYY-MM-DD for git --after.
# git can parse YYYY-MM-DD reliably without shell-quoting issues.
# YYYY-MM-DDTHH:MM:SS or YYYY-MM-DD HH:MM:SS are passed through
# system2 in a way that breaks git's date parser (the T/space is
# treated as argument boundary), so we always reduce to the date part.
ts_to_date <- function(ts) {
  # Extract YYYY-MM-DD prefix — works for ISO 8601 and space-separated
  m <- regmatches(ts, regexpr("^[0-9]{4}-[0-9]{2}-[0-9]{2}", ts))
  if (length(m) == 0L || !nzchar(m)) return(ts)
  m
}
get_commits_since <- function(since_ts) {
  date_arg <- sprintf("--after=%s", ts_to_date(since_ts))
  git_run(c("log", "--format=%H\x01%s\x01%ae", date_arg))
}

# numstat for a commit: lines of filenames and +/- counts
# For the root commit (no parent), use diff-tree --root instead
get_numstat <- function(sha) {
  # Try parent diff first
  result <- git_run(c("diff", "--numstat", paste0(sha, "^"), sha))
  if (length(result) > 0L) return(result)
  # Root commit: diff-tree --root gives the initial tree
  git_run(c("diff-tree", "--root", "--numstat", sha))
}

# ── Parse numstat line ────────────────────────────────────────────────────────

parse_numstat_line <- function(line) {
  # Format: "added\tdeleted\tfilepath"
  parts <- strsplit(line, "\t")[[1L]]
  if (length(parts) < 3L) return(NULL)
  list(
    added   = suppressWarnings(as.integer(parts[[1L]])),
    deleted = suppressWarnings(as.integer(parts[[2L]])),
    path    = parts[[3L]]
  )
}

# ── Category classification ───────────────────────────────────────────────────

classify_path <- function(path) {
  if (grepl("^wiki/", path))    return("wiki")
  if (grepl("^raw/", path))     return("raw")
  if (grepl("^outputs/", path)) return("outputs")
  "other"
}

# ── Extract first H1 from a wiki file (safe: returns basename if absent) ─────

extract_title <- function(repo, path) {
  full_path <- file.path(repo, path)
  if (!file.exists(full_path)) return(tools::file_path_sans_ext(basename(path)))
  lines <- readLines(full_path, n = 20L, warn = FALSE)
  h1 <- grep("^#\\s+", lines, value = TRUE)
  if (length(h1) == 0L) return(tools::file_path_sans_ext(basename(path)))
  # Strip the leading '# '
  title <- sub("^#+\\s+", "", h1[[1L]])
  sanitise_text(title)
}

# ── Theme: folder-based (first segment after category/) ──────────────────────

extract_theme <- function(path) {
  # e.g. "wiki/qis-strategies/something.md" → "qis-strategies"
  #       "wiki/roborev.md"                 → "wiki"  (flat)
  parts <- strsplit(path, "/")[[1L]]
  if (length(parts) >= 3L) {
    sanitise_text(parts[[2L]])
  } else if (length(parts) >= 2L) {
    sanitise_text(parts[[1L]])  # category folder itself
  } else {
    sanitise_text(path)
  }
}

# ── Count [[topic]] links in a diff chunk ────────────────────────────────────

count_new_wikilinks <- function(diff_lines) {
  if (length(diff_lines) == 0L) return(0L)
  added <- grep("^\\+", diff_lines, value = TRUE)
  if (length(added) == 0L) return(0L)
  # gregexpr returns a list (one element per input string); unlist to count all matches
  matches <- regmatches(added, gregexpr("\\[\\[[^\\]]+\\]\\]", added))
  length(unlist(matches))
}

# ── Detect confidence-marker changes ─────────────────────────────────────────

count_marker_delta <- function(diff_lines, marker) {
  added   <- length(grep(paste0("^\\+.*", marker), diff_lines))
  removed <- length(grep(paste0("^-.*", marker),  diff_lines))
  list(added = added, removed = removed)
}

# ── Check if a page has ## Sources section ───────────────────────────────────

has_sources_section <- function(repo, path) {
  full_path <- file.path(repo, path)
  if (!file.exists(full_path)) return(FALSE)
  any(grepl("^## Sources", readLines(full_path, warn = FALSE)))
}

# ── Collect per-file statistics from commits ─────────────────────────────────

collect_stats <- function(commits) {
  file_stats   <- list()  # path → aggregated stats
  commit_info  <- list()  # for theme/lesson detection

  for (commit_line in commits) {
    parts <- strsplit(commit_line, COMMIT_SEP, fixed = TRUE)[[1L]]
    if (length(parts) < 2L) next
    sha     <- parts[[1L]]
    subject <- sanitise_text(parts[[2L]])
    # author email: we keep this only for de-duplication, never emit
    # ae      <- parts[[3L]]

    # Collect numstat
    numstat_lines <- get_numstat(sha)
    if (length(numstat_lines) == 0L) next

    # Per-file in this commit
    for (ns_line in numstat_lines) {
      rec <- parse_numstat_line(ns_line)
      if (is.null(rec)) next
      path <- rec$path
      cat_name <- classify_path(path)

      if (is.null(file_stats[[path]])) {
        file_stats[[path]] <- list(
          path      = path,
          category  = cat_name,
          theme     = extract_theme(path),
          added     = 0L,
          deleted   = 0L,
          modified  = FALSE
        )
      }
      prev <- file_stats[[path]]
      file_stats[[path]]$added   <- prev$added   + max(0L, rec$added,   na.rm = TRUE)
      file_stats[[path]]$deleted <- prev$deleted + max(0L, rec$deleted, na.rm = TRUE)
      file_stats[[path]]$modified <- TRUE
    }

    commit_info[[sha]] <- list(sha = sha, subject = subject)
  }

  list(file_stats = file_stats, commit_info = commit_info)
}

# ── Compute orphan count ──────────────────────────────────────────────────────
# A page is "orphaned" if it has no inbound [[title]] link from any other page.

compute_orphan_count <- function(repo) {
  wiki_dir <- file.path(repo, "wiki")
  if (!dir.exists(wiki_dir)) return(0L)

  wiki_files <- list.files(wiki_dir, pattern = "\\.md$", full.names = TRUE,
                            recursive = TRUE)
  if (length(wiki_files) == 0L) return(0L)

  # All [[topic]] targets across all pages
  all_targets <- character(0L)
  for (f in wiki_files) {
    lines <- readLines(f, warn = FALSE)
    m     <- regmatches(lines, gregexpr("\\[\\[([^\\]]+)\\]\\]", lines))
    targets <- unlist(lapply(m, function(x) gsub("\\[\\[|\\]\\]", "", x)))
    all_targets <- c(all_targets, tolower(targets))
  }

  # Page names (without extension)
  page_names <- tolower(tools::file_path_sans_ext(basename(wiki_files)))

  orphans <- sum(!page_names %in% all_targets)
  orphans
}

# ── Compute missing-Sources count ─────────────────────────────────────────────

compute_missing_sources <- function(repo, changed_wiki_paths) {
  wiki_dir <- file.path(repo, "wiki")
  if (!dir.exists(wiki_dir)) return(list(count = 0L, titles = character(0L)))

  # Check ALL wiki pages (not just changed ones)
  all_wiki <- list.files(wiki_dir, pattern = "\\.md$", full.names = TRUE,
                          recursive = TRUE)
  missing_titles <- character(0L)
  for (f in all_wiki) {
    if (!any(grepl("^## Sources", readLines(f, warn = FALSE)))) {
      title <- tools::file_path_sans_ext(basename(f))
      missing_titles <- c(missing_titles, sanitise_text(title))
    }
  }
  list(count = length(missing_titles), titles = missing_titles)
}

# ── Compute confidence-marker stats from recent diffs ────────────────────────

# Helper: get unified diff for a commit, falling back to diff-tree for root commits
get_diff_lines <- function(sha, repo) {
  lines <- tryCatch(
    suppressWarnings(
      system2("git", c("-C", repo, "diff", paste0(sha, "^"), sha, "--unified=0"),
              stdout = TRUE, stderr = FALSE)
    ),
    error = function(e) character(0L)
  )
  if (!is.null(attr(lines, "status")) && attr(lines, "status") != 0L) {
    lines <- character(0L)
  }
  # For root commit (no parent): use diff-tree --root --unified=0
  if (length(lines) == 0L) {
    lines <- tryCatch(
      suppressWarnings(
        system2("git", c("-C", repo, "diff-tree", "--root", "--unified=0", sha),
                stdout = TRUE, stderr = FALSE)
      ),
      error = function(e) character(0L)
    )
    if (!is.null(attr(lines, "status")) && attr(lines, "status") != 0L) {
      lines <- character(0L)
    }
  }
  lines
}

compute_marker_stats <- function(commits, repo) {
  ai_added   <- 0L
  ai_removed <- 0L

  for (commit_line in commits) {
    sha <- strsplit(commit_line, COMMIT_SEP, fixed = TRUE)[[1L]][[1L]]
    diff_lines <- get_diff_lines(sha, repo)
    if (length(diff_lines) == 0L) next
    delta <- count_marker_delta(diff_lines, "⚠ AI-inferred:")
    ai_added   <- ai_added   + delta$added
    ai_removed <- ai_removed + delta$removed
  }

  list(ai_added = ai_added, ai_removed = ai_removed)
}

# ── Count new [[topic]] links in changed wiki files ──────────────────────────

compute_new_wikilinks <- function(commits, repo) {
  total <- 0L
  for (commit_line in commits) {
    sha <- strsplit(commit_line, COMMIT_SEP, fixed = TRUE)[[1L]][[1L]]
    diff_lines <- get_diff_lines(sha, repo)
    total <- total + count_new_wikilinks(diff_lines)
  }
  total
}

# ── Build per-category summary ────────────────────────────────────────────────

summarise_category <- function(file_stats, category) {
  recs <- Filter(function(x) x$category == category, file_stats)
  if (length(recs) == 0L) {
    return(list(n_files = 0L, lines_added = 0L, lines_deleted = 0L,
                titles = character(0L), themes = character(0L)))
  }

  list(
    n_files      = length(recs),
    lines_added  = sum(vapply(recs, `[[`, integer(1L), "added")),
    lines_deleted = sum(vapply(recs, `[[`, integer(1L), "deleted")),
    titles = unique(vapply(recs, function(r) {
      tools::file_path_sans_ext(basename(r$path))
    }, character(1L))),
    themes = unique(vapply(recs, `[[`, character(1L), "theme"))
  )
}

# ── Main ──────────────────────────────────────────────────────────────────────

message(sprintf("kb_digest.R: analysing %s since %s", args$knowledge_repo, args$since))

commits <- get_commits_since(args$since)

if (length(commits) == 0L) {
  message("kb_digest.R: no commits found in the specified window")
  digest_md <- sprintf(
    "## Knowledge Base Digest — %s\n\n_No changes in the last 24 hours._\n",
    format(Sys.Date())
  )
} else {
  message(sprintf("kb_digest.R: found %d commits", length(commits)))

  collected  <- collect_stats(commits)
  file_stats <- collected$file_stats
  commit_info <- collected$commit_info

  # Per-category summaries
  wiki_summary    <- summarise_category(file_stats, "wiki")
  raw_summary     <- summarise_category(file_stats, "raw")
  outputs_summary <- summarise_category(file_stats, "outputs")

  # Cross-link signals
  new_wikilinks <- compute_new_wikilinks(commits, args$knowledge_repo)
  orphan_count  <- compute_orphan_count(args$knowledge_repo)
  missing_src   <- compute_missing_sources(args$knowledge_repo,
                                            Filter(function(x) x$category == "wiki",
                                                   file_stats))

  # Confidence marker deltas
  marker_stats <- compute_marker_stats(commits, args$knowledge_repo)

  # Commit subjects (sanitised — no bodies)
  subjects <- unique(vapply(commit_info, `[[`, character(1L), "subject"))
  subjects <- subjects[!is.na(subjects)]

  # Unique themes touched
  all_themes <- unique(unlist(lapply(file_stats, `[[`, "theme")))
  all_themes <- all_themes[!is.na(all_themes)]

  # Build markdown ─────────────────────────────────────────────────────────────

  date_str <- format(Sys.Date(), "%Y-%m-%d")
  n_commits <- length(commits)

  # Header
  digest_parts <- c(
    sprintf("## Knowledge Base Digest — %s", date_str),
    "",
    sprintf(
      "_%d commit%s since %s_",
      n_commits, if (n_commits == 1L) "" else "s", args$since
    ),
    ""
  )

  # §1 Per-category table
  digest_parts <- c(digest_parts,
    "### Changes by Category",
    "",
    "| Category | Files changed | Lines + | Lines − |",
    "|----------|:-------------:|--------:|--------:|",
    sprintf("| wiki     | %d | +%d | −%d |",
            wiki_summary$n_files, wiki_summary$lines_added, wiki_summary$lines_deleted),
    sprintf("| raw      | %d | +%d | −%d |",
            raw_summary$n_files, raw_summary$lines_added, raw_summary$lines_deleted),
    sprintf("| outputs  | %d | +%d | −%d |",
            outputs_summary$n_files, outputs_summary$lines_added, outputs_summary$lines_deleted),
    ""
  )

  # §2 Wiki page titles touched (sanitised basenames)
  if (wiki_summary$n_files > 0L) {
    digest_parts <- c(digest_parts,
      "### Wiki Pages Touched",
      ""
    )
    for (t in sort(wiki_summary$titles)) {
      digest_parts <- c(digest_parts, sprintf("- %s", t))
    }
    digest_parts <- c(digest_parts, "")
  }

  # §3 Raw sources added
  if (raw_summary$n_files > 0L) {
    digest_parts <- c(digest_parts,
      "### Raw Sources Added",
      ""
    )
    for (t in sort(raw_summary$titles)) {
      digest_parts <- c(digest_parts, sprintf("- %s", t))
    }
    digest_parts <- c(digest_parts, "")
  }

  # §4 Themes touched
  if (length(all_themes) > 0L) {
    digest_parts <- c(digest_parts,
      "### Themes Touched",
      "",
      paste(sort(all_themes), collapse = " · "),
      ""
    )
  }

  # §5 Cross-link + provenance signals
  digest_parts <- c(digest_parts,
    "### Cross-Link & Provenance Signals",
    "",
    "| Signal | Value |",
    "|--------|------:|",
    sprintf("| New `[[topic]]` links added | %d |", new_wikilinks),
    sprintf("| Pages currently orphaned (no inbound links) | %d |", orphan_count),
    sprintf("| Pages missing `## Sources` | %d |", missing_src$count),
    sprintf("| `⚠ AI-inferred:` markers added | %d |", marker_stats$ai_added),
    sprintf("| `⚠ AI-inferred:` markers removed | %d |", marker_stats$ai_removed),
    ""
  )

  # Show titles of pages missing Sources (sanitised)
  if (missing_src$count > 0L && length(missing_src$titles) > 0L) {
    digest_parts <- c(digest_parts,
      "_Pages missing `## Sources`:_",
      ""
    )
    for (t in sort(missing_src$titles)) {
      digest_parts <- c(digest_parts, sprintf("- %s", t))
    }
    digest_parts <- c(digest_parts, "")
  }

  # §6 Confidence-marker lessons (downgrade signals)
  if (marker_stats$ai_removed > 0L) {
    digest_parts <- c(digest_parts,
      "### Lessons Learnt — Confidence Downgrades",
      "",
      sprintf(
        "_%d AI-inferred claim%s retracted or demoted in this period._",
        marker_stats$ai_removed,
        if (marker_stats$ai_removed == 1L) "" else "s"
      ),
      ""
    )
  }

  # §7 Commit subjects (sanitised first-lines only)
  if (length(subjects) > 0L) {
    digest_parts <- c(digest_parts,
      "### Commit Subjects",
      ""
    )
    for (s in subjects) {
      digest_parts <- c(digest_parts, sprintf("- %s", s))
    }
    digest_parts <- c(digest_parts, "")
  }

  # Footer
  digest_parts <- c(digest_parts,
    "---",
    sprintf(
      "_Computed locally by `kb_digest.R` at %s UTC. No raw KB content was transmitted._",
      format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    )
  )

  digest_md <- paste(digest_parts, collapse = "\n")
}

# ── Output ────────────────────────────────────────────────────────────────────

if (args$dry_run || !nzchar(args$out)) {
  cat(digest_md, "\n")
  message("kb_digest.R: digest complete (stdout mode)")
} else {
  dir.create(dirname(args$out), recursive = TRUE, showWarnings = FALSE)
  writeLines(digest_md, args$out)
  message(sprintf("kb_digest.R: digest written to %s", args$out))
}
