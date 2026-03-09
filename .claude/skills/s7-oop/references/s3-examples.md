# S3 Class Examples

Simple S3 patterns for when S7 is overkill.

## Basic Constructor Pattern

```r
# Low-level constructor (fast, no validation)
new_simple <- function(x, label = "") {
  structure(x, label = label, class = "simple")
}

# User-facing constructor (validates)
simple <- function(x, label = "") {
  if (!is.numeric(x)) {
    cli::cli_abort("{.arg x} must be numeric, not {.cls {class(x)}}")
  }
  if (!is.character(label) || length(label) != 1L) {
    cli::cli_abort("{.arg label} must be a single string")
  }
  new_simple(x, label = label)
}

# Type check
is_simple <- function(x) inherits(x, "simple")
```

## Essential Methods

```r
# Print: user-friendly display
#' @export
print.simple <- function(x, ...) {
  label <- attr(x, "label")
  if (nzchar(label)) cli::cli_text("{label}: ")
  cli::cli_text("Simple({.val {unclass(x)}})")
  invisible(x)
}

# Format: element-wise string representation
#' @export
format.simple <- function(x, ...) {
  paste0("Simple(", unclass(x), ")")
}

# Summary: overview
#' @export
summary.simple <- function(object, ...) {
  cli::cli_text("A simple object")
  cli::cli_ul(c(
    "Value: {.val {unclass(object)}}",
    "Label: {.val {attr(object, 'label')}}"
  ))
  invisible(object)
}
```

## Subset and Assignment

```r
#' @export
`[.simple` <- function(x, i) {
  new_simple(unclass(x)[i], label = attr(x, "label"))
}

#' @export
c.simple <- function(...) {
  pieces <- lapply(list(...), unclass)
  new_simple(do.call(c, pieces))
}
```

## When S3 Is Enough

- Internal helper classes (not exported)
- Classes with 0-2 attributes
- Extending existing S3 generics (print, plot, summary)
- Quick prototyping before upgrading to S7
- Performance-critical code (S3 dispatch is ~3x faster)

## When to Upgrade to S7

- You need property validation
- You want formal typed properties
- You need multiple dispatch
- You want `method_explain()` for debugging
- The class will be exported and used by other packages
