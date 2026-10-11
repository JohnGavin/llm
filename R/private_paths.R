# Private path prefixes (llm#1382)
#
# Claude Code names its per-session directories after the working-directory
# path, so a private folder name flows into ccusage project slugs and from
# there into published telemetry. This repo is public, so NO private path
# literal may live here. The prefixes are read at runtime from a LOCAL,
# uncommitted file instead.
#
# File: ~/.config/private_paths.txt (override with env var
# LLM_PRIVATE_PATHS_FILE). One prefix per line; blank lines and lines
# starting with `#` are ignored. A line may be a real directory path
# (with a trailing slash) or a Claude Code dash-mangled slug (with a
# trailing dash); both are normalised the same way.

#' Alias used in place of any slug that sits under a private path prefix
#' @keywords internal
PRIVATE_PROJECT_ALIAS <- "private-project"

#' Location of the local private-path config file
#'
#' @return Single character path (may not exist).
#' @keywords internal
private_paths_file <- function() {
  f <- Sys.getenv("LLM_PRIVATE_PATHS_FILE", "")
  if (nzchar(f)) return(f)
  file.path(Sys.getenv("HOME"), ".config", "private_paths.txt")
}

#' Normalise a path or slug the way Claude Code mangles directory names
#'
#' Every character outside `[A-Za-z0-9]` becomes `-`, so
#' `"/a/_b.c/"` and `"-a--b-c-"` compare equal.
#'
#' @param x Character vector of paths or slugs.
#' @return Character vector of dash-mangled slugs.
#' @keywords internal
normalize_path_slug <- function(x) {
  gsub("[^A-Za-z0-9]", "-", x)
}

#' Read the private path prefixes from the local config file
#'
#' A missing or empty config is NOT silent: a warning is raised, and an
#' empty vector is returned (callers then leave nothing un-aliased only if
#' the config is genuinely absent, which the warning makes visible).
#'
#' @param file Config file path; defaults to [private_paths_file()].
#' @return Character vector of normalised slug prefixes (possibly empty).
#' @keywords internal
private_path_prefixes <- function(file = private_paths_file()) {
  if (!file.exists(file)) {
    cli::cli_warn(c(
      "!" = "Private path config not found: {.file {file}}.",
      "i" = "Slugs under private paths cannot be aliased until it exists.",
      "i" = "One path or slug prefix per line; see {.code ?private_path_prefixes}."
    ))
    return(character(0))
  }
  lines <- trimws(readLines(file, warn = FALSE))
  lines <- lines[nzchar(lines) & !startsWith(lines, "#")]
  if (length(lines) == 0L) {
    cli::cli_warn(c(
      "!" = "Private path config {.file {file}} has no prefixes."
    ))
    return(character(0))
  }
  unique(normalize_path_slug(lines))
}

#' Alias project slugs that sit under a private path prefix
#'
#' @param x Character vector of raw project slugs / paths.
#' @param prefixes Normalised prefixes; defaults to [private_path_prefixes()].
#' @return `x` with every element under a private prefix replaced by
#'   `"private-project"`. `NA` stays `NA`.
#' @keywords internal
alias_private_slug <- function(x, prefixes = private_path_prefixes()) {
  checkmate::assert_character(x, null.ok = TRUE)
  if (length(x) == 0L || length(prefixes) == 0L) return(x)
  norm <- normalize_path_slug(x)
  hit <- rep(FALSE, length(x))
  for (p in prefixes) hit <- hit | startsWith(norm, p)
  hit[is.na(x)] <- FALSE
  x[hit] <- PRIVATE_PROJECT_ALIAS
  x
}

#' Sanitise a ccusage JSON file so no private slug survives
#'
#' Replaces every string token beginning with a private prefix (up to the
#' next quote, slash or whitespace) by `"private-project"`. Text-level, so
#' it covers project keys, session ids and `projectPath` values alike.
#'
#' @param path Input JSON file.
#' @param out Output file; defaults to rewriting `path` in place.
#' @param prefixes Normalised prefixes; defaults to [private_path_prefixes()].
#' @return Invisibly, the number of tokens replaced.
#' @export
sanitize_ccusage_json <- function(path, out = path,
                                  prefixes = private_path_prefixes()) {
  checkmate::assert_file_exists(path)
  if (length(prefixes) == 0L) {
    cli::cli_abort(c(
      "x" = "No private path prefixes configured; refusing to write unsanitised output.",
      "i" = "Create {.file {private_paths_file()}} first."
    ))
  }
  txt <- paste(readLines(path, warn = FALSE), collapse = "\n")
  n <- 0L
  for (p in prefixes) {
    # prefixes are normalised to [A-Za-z0-9-], so need no regex escaping
    re <- paste0(p, "[^\"/[:space:]]*")
    n <- n + lengths(regmatches(txt, gregexpr(re, txt)))
    txt <- gsub(re, PRIVATE_PROJECT_ALIAS, txt)
  }
  writeLines(txt, out)
  invisible(n)
}
