#' Safe division — the function under test
#' @param x Numeric numerator
#' @param y Numeric denominator
#' @return Numeric result, or cli_abort on invalid input
safe_divide <- function(x, y) {
  if (!is.numeric(x) || is.logical(x) || !is.numeric(y) || is.logical(y)) {
    cli::cli_abort(c("x" = "Both {.arg x} and {.arg y} must be numeric",
                      "i" = "Got: x={.cls {class(x)}}, y={.cls {class(y)}}"))
  }
  if (length(y) != 1L) {
    cli::cli_abort("{.arg y} must be length 1, got {length(y)}")
  }
  if (is.na(y) || isTRUE(y == 0)) {
    cli::cli_abort("{.arg y} must not be 0 or NA")
  }
  x / y
}
