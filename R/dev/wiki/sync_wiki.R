# Sync repo `WIKI_CONTENT/` pages to the GitHub wiki and keep `README.md` updated.
#
# Usage (from repo root):
#   Rscript R/dev/wiki/sync_wiki.R
#
# Requirements:
# - `gert` installed
# - `GITHUB_PAT` set with repo + wiki write access
#
# Notes:
# - GitHub wikis live in a separate git repo (`llm.wiki.git`). This script keeps
#   the wiki readable while keeping canonical markdown reviewable in this repo.

suppressPackageStartupMessages({
  library(gert)
})

repo_root <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
wiki_content_dir <- file.path(repo_root, "WIKI_CONTENT")

if (!dir.exists(wiki_content_dir)) {
  stop("Expected `WIKI_CONTENT/` in repo root: ", wiki_content_dir, call. = FALSE)
}

github_pat <- Sys.getenv("GITHUB_PAT")
if (!nzchar(github_pat)) {
  stop("Set `GITHUB_PAT` before running this script.", call. = FALSE)
}

wiki_git_url <- "https://JohnGavin@github.com/JohnGavin/llm.wiki.git"
wiki_base_url <- "https://github.com/JohnGavin/llm/wiki"
repo_base_url <- "https://github.com/JohnGavin/llm"

slugify <- function(x) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9 -]", "", x)
  x <- gsub(" +", "-", x)
  x <- gsub("-+", "-", x)
  x
}

read_title <- function(path) {
  lines <- readLines(path, warn = FALSE)
  h1 <- grep("^#\\s+", lines, value = TRUE)[1]
  if (is.na(h1)) stop("No H1 found in: ", path, call. = FALSE)
  sub("^#\\s+", "", h1)
}

read_first_h2 <- function(path) {
  lines <- readLines(path, warn = FALSE)
  h2 <- grep("^##\\s+", lines, value = TRUE)[1]
  if (is.na(h2)) return(NA_character_)
  sub("^##\\s+", "", h2)
}

read_summary <- function(path) {
  lines <- readLines(path, warn = FALSE)
  if (!length(lines)) return("")

  # Find first H1, then look for the first non-empty paragraph *after* any
  # optional "Links:" block.
  h1_idx <- grep("^#\\s+", lines)[1]
  if (is.na(h1_idx)) return("")

  i <- h1_idx + 1
  while (i <= length(lines) && trimws(lines[i]) == "") i <- i + 1

  if (i <= length(lines) && trimws(lines[i]) == "Links:") {
    i <- i + 1
    while (i <= length(lines) && trimws(lines[i]) != "") i <- i + 1
    while (i <= length(lines) && trimws(lines[i]) == "") i <- i + 1
  }

  while (i <= length(lines)) {
    line <- trimws(lines[i])
    if (line != "" && !grepl("^(-\\s|```|#|---$)", line)) {
      line <- sub("^>\\s*", "", line)
      line <- gsub("\\*\\*", "", line)
      return(line)
    }
    i <- i + 1
  }

  ""
}

wiki_page_name_from_source <- function(src_path) {
  base <- sub("\\.md$", "", basename(src_path))
  gsub("_", "-", base)
}

wiki_page_url <- function(page_name) paste0(wiki_base_url, "/", page_name)

list_wiki_sources <- function() {
  files <- list.files(wiki_content_dir, pattern = "\\.md$", full.names = TRUE)
  files <- sort(files)
  if (!length(files)) stop("No markdown files found under `WIKI_CONTENT/`.", call. = FALSE)

  lapply(files, function(src) {
    page_name <- wiki_page_name_from_source(src)
    list(
      src = src,
      src_rel = file.path("WIKI_CONTENT", basename(src)),
      page_name = page_name,
      wiki_file = paste0(page_name, ".md"),
      title = read_title(src),
      summary = read_summary(src),
      first_h2 = read_first_h2(src)
    )
  })
}

update_readme_docs_block <- function(pages) {
  readme_path <- file.path(repo_root, "README.md")
  if (!file.exists(readme_path)) stop("Missing README.md at repo root.", call. = FALSE)

  begin <- "<!-- BEGIN WIKI_CONTENT_DOCS -->"
  end <- "<!-- END WIKI_CONTENT_DOCS -->"

  lines <- readLines(readme_path, warn = FALSE)
  begin_idx <- match(begin, lines)
  end_idx <- match(end, lines)

  if (is.na(begin_idx) || is.na(end_idx) || end_idx <= begin_idx) {
    stop(
      "README.md is missing the docs markers.\n",
      "Expected lines:\n",
      "- ", begin, "\n",
      "- ", end,
      call. = FALSE
    )
  }

  entry_lines <- unlist(lapply(pages, function(p) {
    key_section <- if (!is.na(p$first_h2)) paste0(wiki_page_url(p$page_name), "#", slugify(p$first_h2)) else wiki_page_url(p$page_name)
    c(
      paste0("- **", p$title, "**  "),
      paste0("  Summary: ", p$summary, "  "),
      paste0("  Source: `", p$src_rel, "`  "),
      paste0("  Wiki: ", wiki_page_url(p$page_name)),
      paste0("  Key section: ", key_section),
      ""
    )
  }))

  new_block <- c(begin, entry_lines, end)
  updated <- c(lines[seq_len(begin_idx - 1)], new_block, lines[seq(from = end_idx + 1, to = length(lines))])
  writeLines(updated, readme_path)
  readme_path
}

sync_to_wiki_repo <- function(pages) {
  tmp_root <- tempfile("llm-wiki-sync-")
  dir.create(tmp_root, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(tmp_root, recursive = TRUE, force = TRUE), add = TRUE)

  wiki_path <- file.path(tmp_root, "llm.wiki")
  cat("Cloning wiki repo -> ", wiki_path, "\n", sep = "")
  git_clone(url = wiki_git_url, path = wiki_path, password = github_pat, verbose = interactive())

  for (p in pages) {
    dest <- file.path(wiki_path, p$wiki_file)
    writeLines(readLines(p$src, warn = FALSE), dest)
  }

  home <- file.path(wiki_path, "Home.md")
  if (!file.exists(home)) writeLines(c("# Home", ""), home)

  home_lines <- readLines(home, warn = FALSE)
  section_header <- "## Documentation"

  if (!any(trimws(home_lines) == section_header)) {
    home_lines <- c(home_lines, "", section_header, "")
  }

  links <- vapply(pages, function(p) paste0("- [[", p$title, "|", p$page_name, "]]"), character(1))
  readme_line <- paste0("- Repo README (overview): ", repo_base_url)

  # Remove previous exact lines and reinsert after the last "## Documentation".
  home_lines <- home_lines[!(home_lines %in% c(links, readme_line))]
  idx <- max(which(trimws(home_lines) == section_header))
  home_lines <- append(home_lines, values = c(readme_line, links), after = idx)
  writeLines(home_lines, home)

  # Commit + push only if there are changes.
  st <- git_status(repo = wiki_path)
  if (!nrow(st)) {
    cat("Wiki repo is already up to date.\n")
    return(invisible(NULL))
  }

  cat("Wiki changes:\n")
  print(st)

  git_add(repo = wiki_path, files = c("Home.md", vapply(pages, `[[`, character(1), "wiki_file")))
  git_commit(repo = wiki_path, message = "Docs: sync WIKI_CONTENT pages")
  git_push(repo = wiki_path, password = github_pat, verbose = interactive())

  cat("Wiki synced.\n")
  invisible(NULL)
}

pages <- list_wiki_sources()

cat("Updating README.md from WIKI_CONTENT...\n")
update_readme_docs_block(pages)

cat("Syncing WIKI_CONTENT -> GitHub wiki...\n")
sync_to_wiki_repo(pages)

cat("Done.\n")
