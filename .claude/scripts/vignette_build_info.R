# vignette_build_info.R
# Render-time helpers for the mandatory build-info block.
# Sourced by _includes/build-info.qmd at render time.
# All helpers return "—" on any error — never prevent a render from completing.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

.safe <- function(expr, fallback = "—") {
  tryCatch(
    force(expr),
    error   = function(e) fallback,
    warning = function(w) fallback
  )
}

# Return current YAML metadata list (works with both knitr and quarto execution)
.yaml_meta <- function() {
  .safe({
    if (exists("rmarkdown") && isNamespace(asNamespace("rmarkdown"))) {
      m <- rmarkdown::metadata
      if (is.list(m)) return(m)
    }
    list()
  }, list())
}

# ---------------------------------------------------------------------------
# 1. Word count and length label
# ---------------------------------------------------------------------------

#' Count words in the rendered or source vignette
#'
#' Tries (in order):
#'   1. Read rendered HTML (input_path `.qmd` → `.html`) and strip tags.
#'   2. Read source `.qmd` body (text between the second `---` and EOF).
#'   3. Return 0.
#'
#' @param input_path Path to the `.qmd` source. Defaults to knitr's current
#'   input file (available during render). Falls back gracefully when absent.
#' @return Integer word count.
vignette_word_count <- function(input_path = NULL) {
  .safe({
    # Try to locate the source .qmd
    if (is.null(input_path)) {
      input_path <- tryCatch(
        knitr::current_input(dir = TRUE),
        error = function(e) NULL
      )
    }

    if (!is.null(input_path) && nzchar(input_path)) {
      # Prefer rendered HTML if it exists
      html_path <- sub("\\.qmd$", ".html", input_path)
      if (file.exists(html_path)) {
        raw <- paste(readLines(html_path, warn = FALSE), collapse = " ")
        # Strip all HTML tags and decode common entities
        text <- gsub("<[^>]+>", " ", raw)
        text <- gsub("&[a-z]+;",  " ", text)
        text <- gsub("\\s+",       " ", trimws(text))
        return(length(strsplit(text, "\\s+")[[1L]]))
      }

      # Fall back to counting words in the source body
      if (file.exists(input_path)) {
        lines <- readLines(input_path, warn = FALSE)
        # Find second `---` to skip YAML front-matter
        dashes <- which(lines == "---")
        start  <- if (length(dashes) >= 2L) dashes[[2L]] + 1L else 1L
        body   <- paste(lines[start:length(lines)], collapse = " ")
        # Strip Quarto chunk fences, HTML comments, code fences
        body   <- gsub("```\\{[^}]*\\}[\\s\\S]*?```", " ", body, perl = TRUE)
        body   <- gsub("<!--[\\s\\S]*?-->",            " ", body, perl = TRUE)
        body   <- gsub("[`*#_>|\\[\\](){}]",           " ", body)
        body   <- gsub("\\s+",                         " ", trimws(body))
        return(length(strsplit(body, "\\s+")[[1L]]))
      }
    }

    0L
  }, 0L)
}

#' Human-readable length label
#'
#' @return Character string like "2054 words · 9 min read".
vignette_length_label <- function() {
  .safe({
    n <- vignette_word_count()
    if (n == 0L) return("—")
    mins <- ceiling(n / 230L)
    paste0(
      format(n, big.mark = ","), " word", if (n != 1L) "s" else "",
      " · ", mins, " min read"
    )
  })
}

# ---------------------------------------------------------------------------
# 2. YAML-sourced fields
# ---------------------------------------------------------------------------

#' Comma-joined YAML categories
build_info_categories <- function() {
  .safe({
    cats <- .yaml_meta()[["categories"]]
    if (is.null(cats) || length(cats) == 0L) return("—")
    paste(cats, collapse = ", ")
  })
}

#' Comma-joined YAML tags
build_info_tags <- function() {
  .safe({
    tags <- .yaml_meta()[["tags"]]
    if (is.null(tags) || length(tags) == 0L) return("—")
    paste(tags, collapse = ", ")
  })
}

#' See-also links as an HTML comma list
#'
#' Expects YAML `see-also:` as a character vector of `[title](path)` entries.
#' Returns them as an HTML inline list. Unlinked strings are returned as-is.
build_info_see_also <- function() {
  .safe({
    sa <- .yaml_meta()[["see-also"]]
    if (is.null(sa) || length(sa) == 0L) return("—")
    # Convert "[title](path)" markdown links to <a> tags
    converted <- vapply(sa, function(item) {
      m <- regmatches(item, regexec("^\\[(.+?)\\]\\((.+?)\\)$", item))[[1L]]
      if (length(m) == 3L) {
        sprintf('<a href="%s">%s</a>', m[[3L]], m[[2L]])
      } else {
        item
      }
    }, character(1L))
    paste(converted, collapse = ", ")
  })
}

# ---------------------------------------------------------------------------
# 3. Computed fields
# ---------------------------------------------------------------------------

#' Git short SHA + permalink to the source .qmd on main
#'
#' Builds https://github.com/<owner>/<repo>/blob/<sha>/<rel-path>
build_info_source_link <- function() {
  .safe({
    sha <- tryCatch(
      system("git rev-parse --short HEAD 2>/dev/null", intern = TRUE),
      error = function(e) character(0L)
    )
    if (length(sha) == 0L || !nzchar(sha[[1L]])) return("—")
    sha <- sha[[1L]]

    # Determine repo name from git remote origin
    remote <- tryCatch(
      system("git remote get-url origin 2>/dev/null", intern = TRUE),
      error = function(e) character(0L)
    )
    repo_slug <- if (length(remote) > 0L && nzchar(remote[[1L]])) {
      m <- regmatches(
        remote[[1L]],
        regexec("github\\.com[:/]([^/]+/[^/.]+)", remote[[1L]])
      )[[1L]]
      if (length(m) == 2L) m[[2L]] else "JohnGavin/llm"
    } else {
      "JohnGavin/llm"
    }

    # Source .qmd path relative to repo root
    input_path <- tryCatch(
      knitr::current_input(dir = TRUE),
      error = function(e) NULL
    )
    rel_path <- if (!is.null(input_path) && nzchar(input_path)) {
      root <- tryCatch(
        system("git rev-parse --show-toplevel 2>/dev/null", intern = TRUE),
        error = function(e) character(0L)
      )
      if (length(root) > 0L && nzchar(root[[1L]])) {
        sub(paste0("^", root[[1L]], "/?"), "", input_path)
      } else {
        basename(input_path)
      }
    } else {
      "vignettes/unknown.qmd"
    }

    url <- sprintf(
      "https://github.com/%s/blob/%s/%s",
      repo_slug, sha, rel_path
    )
    sprintf('<a href="%s">%s</a>', url, sha)
  })
}

#' R version + key package versions + Nix pin date
#'
#' Returns a short single-line string suitable for the Render env field.
build_info_render_env <- function() {
  .safe({
    r_ver <- paste0("R ", paste(R.version[c("major", "minor")], collapse = "."))

    # Key package versions — missing packages silently omitted
    pkgs <- c("bslib", "quarto", "targets", "knitr", "rmarkdown")
    pkg_strs <- vapply(pkgs, function(p) {
      v <- tryCatch(
        as.character(utils::packageVersion(p)),
        error = function(e) NULL
      )
      if (is.null(v)) NA_character_ else paste0(p, " ", v)
    }, character(1L))
    pkg_strs <- pkg_strs[!is.na(pkg_strs)]

    # Nix pin date from default.nix: line matching `date = "YYYY-MM-DD"`
    nix_pin <- tryCatch({
      root <- system("git rev-parse --show-toplevel 2>/dev/null", intern = TRUE)
      nix_path <- if (length(root) > 0L) file.path(root[[1L]], "default.nix") else "default.nix"
      if (file.exists(nix_path)) {
        nix_lines <- readLines(nix_path, warn = FALSE)
        date_line <- grep('date\\s*=\\s*"[0-9]{4}-[0-9]{2}-[0-9]{2}"', nix_lines, value = TRUE)
        if (length(date_line) > 0L) {
          m <- regmatches(date_line[[1L]], regexec('"([0-9]{4}-[0-9]{2}-[0-9]{2})"', date_line[[1L]]))[[1L]]
          if (length(m) == 2L) paste0("nix-pin ", m[[2L]]) else NULL
        } else NULL
      } else NULL
    }, error = function(e) NULL)

    parts <- c(r_ver, pkg_strs, nix_pin)
    paste(Filter(Negate(is.null), parts), collapse = " · ")
  })
}
