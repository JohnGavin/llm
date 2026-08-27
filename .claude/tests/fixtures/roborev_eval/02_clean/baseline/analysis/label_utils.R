#' Format a percentage label
#'
#' @param x Numeric fraction (0-1).
#' @return Character string.
format_pct_label <- function(x) {
  paste0(round(x * 100, 1), "%")
}
