#' Hover-Popup Helper: generate a Tippy.js span
#'
#' Produces an HTML `<span>` element that Tippy.js will turn into a styled
#' hover popup when the page includes `_includes/hover-popups.qmd`.
#'
#' The `body` argument is HTML-escaped so that double-quotes inside the
#' tooltip content do not break the `data-tippy-content` attribute. Authors
#' may include HTML tags (`<b>`, `<a href="...">`, etc.) — Tippy renders them
#' because `allowHTML: true` is set in the shared partial's init script.
#'
#' @param term  Character scalar. The visible text the reader hovers over.
#'   Not HTML-escaped — may itself contain Markdown or inline HTML that
#'   knitr/Quarto processes before `cat()`.
#' @param body  Character scalar. HTML body for the tooltip. MUST contain
#'   at least two sentences and at least one `<a href="...">` anchor.
#'   Double-quotes in `body` are escaped automatically (U+0022 → `&quot;`).
#'   Ampersands are also escaped (`&` → `&amp;`), so pre-escaped entities
#'   such as `&lt;` should be passed as literal `<` — `tt()` will
#'   re-escape them for the attribute context.
#'
#' @return Character scalar. An HTML string suitable for passing to
#'   `cat()` or `htmltools::HTML()` inside a knitr chunk with
#'   `results = "asis"`.
#'
#' @examples
#' # Basic usage — output via cat() in a chunk with results = "asis"
#' cat(tt(
#'   "LLM",
#'   paste0(
#'     "<b>Large Language Model</b>. A neural network trained on large text ",
#'     "corpora to generate, summarise, and classify text. See ",
#'     "<a href='https://en.wikipedia.org/wiki/Large_language_model'>",
#'     "Wikipedia</a>."
#'   )
#' ))
#'
#' # Inline use with htmltools::HTML()
#' htmltools::HTML(tt("QA", "Quality assurance. Systematic checks applied to
#' pipeline outputs. See <a href='https://r-pkgs.org/testing-basics.html'>
#' R packages testing guide</a>."))
#'
#' @seealso [_includes/hover-popups.qmd] for the Tippy.js init partial.
#' @seealso `.claude/rules/hover-popup-standard.md` for authoring rules.
#'
#' @export
tt <- function(term, body) {
  checkmate::assert_string(term, min.chars = 1L)
  checkmate::assert_string(body, min.chars = 1L)

  # Escape for HTML attribute value context:
  # 1. & must come first (avoid double-escaping)
  # 2. " breaks the double-quoted attribute value
  escaped_body <- gsub("&", "&amp;", body, fixed = TRUE)
  escaped_body <- gsub('"', "&quot;", escaped_body, fixed = TRUE)

  sprintf(
    '<span class="tt" data-tippy-content="%s" tabindex="0">%s</span>',
    escaped_body,
    term
  )
}
