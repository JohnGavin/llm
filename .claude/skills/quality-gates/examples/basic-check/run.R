#' Quality Gates Example: Basic R Package Check
#'
#' Run this from any R package project directory to see the quality gate scoring.
#' Expected output: output/gate_result.json
#'
#' Usage: Rscript examples/basic-check/run.R

cat("=== Quality Gates: Basic Check ===\n\n")

# Verify we're in an R package
if (!file.exists("DESCRIPTION")) {
  stop("Not in an R package directory (no DESCRIPTION found)")
}

pkg_name <- read.dcf("DESCRIPTION", fields = "Package")[1, 1]
cat("Package:", pkg_name, "\n")

# Component 1: R CMD check (simplified — just tests)
cat("\n--- Tests ---\n")
test_result <- tryCatch({
  results <- devtools::test(pkg = ".", reporter = "summary")
  df <- as.data.frame(results)
  list(passed = sum(df$passed), failed = sum(df$failed), warned = sum(df$warning))
}, error = function(e) list(passed = 0, failed = 1, warned = 0))
cat(sprintf("Passed: %d | Failed: %d | Warned: %d\n",
  test_result$passed, test_result$failed, test_result$warned))
check_score <- if (test_result$failed == 0) 98 else 0

# Component 2: Documentation coverage
cat("\n--- Documentation ---\n")
ns_exports <- length(grep("^export\\(", readLines("NAMESPACE", warn = FALSE)))
man_files <- length(list.files("man", pattern = "\\.Rd$"))
doc_score <- round(100 * min(man_files / max(ns_exports, 1), 1), 1)
cat(sprintf("Exports: %d | Man pages: %d | Coverage: %s%%\n", ns_exports, man_files, doc_score))

# Component 3: Code style (no raw SQL)
cat("\n--- Code Style ---\n")
r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
r_files <- r_files[!grepl("R/dev/", r_files)]
all_code <- unlist(lapply(r_files, readLines, warn = FALSE))
sql_violations <- length(grep("DBI::dbGetQuery", all_code))
style_score <- if (sql_violations == 0) 100 else 0
cat(sprintf("DBI::dbGetQuery violations: %d | Score: %d\n", sql_violations, style_score))

# Weighted total
total <- round(0.30 * check_score + 0.15 * doc_score + 0.05 * style_score +
               0.20 * 100 + 0.20 * 100 + 0.10 * 100, 1)  # coverage/data/defensive default 100
grade <- dplyr::case_when(
  total >= 95 ~ "Gold",
  total >= 90 ~ "Silver",
  total >= 80 ~ "Bronze",
  TRUE ~ "Below Bronze"
)

cat(sprintf("\n=== Quality Gate: %s (%s/100) ===\n", grade, total))

# Save result
result <- list(
  package = pkg_name,
  total_score = total,
  grade = grade,
  components = list(check = check_score, documentation = doc_score, code_style = style_score),
  timestamp = as.character(Sys.time())
)
out_dir <- file.path(dirname(sys.frame(1)$ofile %||% "."), "output")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
jsonlite::write_json(result, file.path(out_dir, "gate_result.json"), auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("Result saved to: %s\n", file.path(out_dir, "gate_result.json")))
