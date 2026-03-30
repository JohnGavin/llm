#' Function Call Analysis — Static AST Analysis
#'
#' Extract function calls and definitions from R source files.
#' Used by plan_telemetry.R for function frequency tables and call network graphs.
#'
#' @family telemetry

#' Extract all function calls from parsed R expressions
#' @param file Path to an R file
#' @return tibble with columns: file, call, has_namespace
#' @export
extract_file_calls <- function(file) {
  # Top-level parse failure: warn so caller knows the file was skipped
  parsed <- tryCatch(parse(file), error = function(e) {
    cli::cli_warn("Failed to parse {file}: {conditionMessage(e)}")
    NULL
  })
  if (is.null(parsed)) return(tibble::tibble(
    file = character(), call = character(), has_namespace = logical()  ))

  calls <- character()

  skip_ops <- c("<-", "<<-", "=", "{", "(", "if", "for",
                "while", "repeat", "function", "~", "!",
                "&&", "||", "&", "|", "+", "-", "*", "/",
                "^", "%%", "%>%", "|>", "$", "@", "[",
                "[[", "c", "list", "return")

  walk_ast <- function(node) {
    if (missing(node) || is.null(node)) return()
    if (is.call(node)) {
      fn_name <- tryCatch(deparse(node[[1]], width.cutoff = 500L), error = function(e) "")
      if (nzchar(fn_name) && !fn_name %in% skip_ops) {
        calls <<- c(calls, fn_name)
      }
      for (i in seq_along(node)[-1]) {
        tryCatch(walk_ast(node[[i]]), error = function(e) NULL)
      }
    } else if (is.recursive(node)) {
      for (i in seq_along(node)) {
        tryCatch(walk_ast(node[[i]]), error = function(e) NULL)
      }
    }
  }

  walk_ast(parsed)

  if (length(calls) == 0L) return(tibble::tibble(
    file = character(), call = character(), has_namespace = logical()  ))

  tibble::tibble(
    file = basename(file),
    call = calls,
    has_namespace = grepl("::", calls, fixed = TRUE)  )
}

#' Extract function definitions from R source files
#' @param r_dir Path to R/ directory
#' @return Named list: function_name -> function body (as expression)
#' @export
extract_function_defs <- function(r_dir = "R") {
  r_files <- list.files(r_dir, pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
  defs <- list()

  for (file in r_files) {
    parsed <- tryCatch(parse(file), error = function(e) {
      cli::cli_warn("Failed to parse {file}: {conditionMessage(e)}")
      NULL
    })
    if (is.null(parsed)) next

    for (expr in parsed) {
      # Match: fn_name <- function(...) { ... }
      if (is.call(expr) && length(expr) >= 3 &&
          identical(expr[[1]], as.name("<-")) &&
          is.name(expr[[2]]) &&
          is.call(expr[[3]]) && identical(expr[[3]][[1]], as.name("function"))) {
        fn_name <- as.character(expr[[2]])
        defs[[fn_name]] <- list(body = body(eval(expr[[3]])), file = basename(file))
      }
    }
  }
  defs
}

#' Classify a function call as package::func, base, or internal
#' @param call_name Character string of the function call
#' @param our_functions Character vector of functions defined in R/
#' @return Character: the package name or "base" or "internal"
#' @export
classify_call <- function(call_name, our_functions = character()) {
  if (grepl("::", call_name, fixed = TRUE)) {
    sub("::.*", "", call_name)
  } else if (call_name %in% our_functions) {
    "internal"
  } else if (exists(call_name, envir = baseenv(), inherits = FALSE)) {
    "base"
  } else {
    # Check common packages via search path
    for (pkg in c("utils", "stats", "grDevices", "graphics", "methods")) {
      ns <- tryCatch(getNamespace(pkg), error = function(e) NULL)
      if (!is.null(ns) && exists(call_name, envir = ns, inherits = FALSE)) {
        return(pkg)
      }
    }
    "unknown"
  }
}

#' Build function frequency table
#' @param r_dir Path to R/ directory
#' @return data.frame with columns: call, package, n_calls, n_files
#' @export
build_frequency_table <- function(r_dir = "R") {
  r_files <- list.files(r_dir, pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
  all_calls <- do.call(rbind, lapply(r_files, extract_file_calls))
  if (nrow(all_calls) == 0L) return(tibble::tibble())

  our_fns <- names(extract_function_defs(r_dir))

  all_calls$package <- vapply(all_calls$call, classify_call,
                              character(1), our_functions = our_fns)

  # Frequency table
  freq <- all_calls |>
    dplyr::count(call, package, name = "n_calls") |>
    dplyr::mutate(
      n_files = vapply(call, function(fn) {
        length(unique(all_calls$file[all_calls$call == fn]))
      }, integer(1))
    ) |>
    dplyr::arrange(dplyr::desc(n_calls))

  freq
}

#' Build call network (one level deep: our functions -> what they call)
#' @param r_dir Path to R/ directory
#' @return data.frame with columns: from, to, to_package
#' @export
build_call_network <- function(r_dir = "R") {
  defs <- extract_function_defs(r_dir)
  if (length(defs) == 0L) return(tibble::tibble(
    from = character(), to = character(), to_package = character()  ))

  our_fn_names <- names(defs)

  edges <- lapply(names(defs), function(fn_name) {
    # Write body to temp file so we can parse it
    body_text <- tryCatch(deparse(defs[[fn_name]]$body), error = function(e) NULL)
    if (is.null(body_text)) return(tibble::tibble())

    tf <- tempfile(fileext = ".R")
    writeLines(body_text, tf)
    on.exit(unlink(tf))

    calls <- extract_file_calls(tf)
    if (nrow(calls) == 0L) return(tibble::tibble())

    # Classify and deduplicate
    calls$package <- vapply(calls$call, classify_call,
                            character(1), our_functions = our_fn_names)
    # Keep only external calls (not internal to our package)
    external <- calls[calls$package != "internal", ]
    if (nrow(external) == 0L) return(tibble::tibble())

    unique_calls <- unique(external[, c("call", "package")])
    tibble::tibble(
      from = fn_name,
      to = unique_calls$call,
      to_package = unique_calls$package    )
  })

  do.call(rbind, edges)
}
