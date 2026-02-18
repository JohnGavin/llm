# Quality Gates Skill

**MANDATORY: Must be computed as part of Step 4 for every PR.**
**This skill is NOT optional. Skipping it is a workflow violation.**

Numeric scoring system for R package quality with gate levels.

## Gate Levels

| Level | Score | Required For | Color |
|-------|-------|--------------|-------|
| Bronze | >= 80 | Commit | 🥉 |
| Silver | >= 90 | PR creation | 🥈 |
| Gold | >= 95 | Merge to main | 🥇 |

## Quality Metrics

### 1. Test Coverage (25% weight)

```r
calculate_coverage_score <- function(pkg = ".") {
  cov <- covr::package_coverage(pkg)
  pct <- covr::percent_coverage(cov)

  # Score: percentage directly
  score <- min(100, pct)

  list(
    metric = "coverage",
    raw_value = pct,
    score = score,
    weight = 0.25,
    weighted_score = score * 0.25,
    details = sprintf("%.1f%% line coverage", pct)
  )
}
```

### 2. R CMD Check (40% weight)

```r
calculate_check_score <- function(pkg = ".") {
  check <- devtools::check(pkg, args = "--as-cran", quiet = TRUE)

  errors <- length(check$errors)
  warnings <- length(check$warnings)
  notes <- length(check$notes)

  # Score: 100 - penalties
  # Errors: -30 each, Warnings: -10 each, Notes: -2 each
  score <- max(0, 100 - errors * 30 - warnings * 10 - notes * 2)

  list(
    metric = "check",
    raw_value = list(errors = errors, warnings = warnings, notes = notes),
    score = score,
    weight = 0.40,
    weighted_score = score * 0.40,
    details = sprintf("%d errors, %d warnings, %d notes", errors, warnings, notes)
  )
}
```

### 3. Documentation Score (20% weight)

```r
calculate_doc_score <- function(pkg = ".") {
  # Get exported functions
  ns <- devtools::parse_ns_file(pkg)
  exports <- ns$exports

  # Check documentation
  man_files <- list.files(file.path(pkg, "man"), pattern = "\\.Rd$")
  documented <- gsub("\\.Rd$", "", man_files)

  # Check for examples
  has_examples <- purrr::map_lgl(exports, ~{
    rd_file <- file.path(pkg, "man", paste0(.x, ".Rd"))
    if (!file.exists(rd_file)) return(FALSE)
    content <- readLines(rd_file)
    any(grepl("\\\\examples", content))
  })

  doc_coverage <- length(intersect(exports, documented)) / max(1, length(exports))
  example_coverage <- sum(has_examples) / max(1, length(exports))

  # Score: 60% doc coverage + 40% example coverage
  score <- (doc_coverage * 60 + example_coverage * 40)

  list(
    metric = "documentation",
    raw_value = list(
      exports = length(exports),
      documented = length(intersect(exports, documented)),
      with_examples = sum(has_examples)
    ),
    score = score,
    weight = 0.20,
    weighted_score = score * 0.20,
    details = sprintf("%d/%d documented, %d/%d with examples",
                      length(intersect(exports, documented)), length(exports),
                      sum(has_examples), length(exports))
  )
}
```

### 4. Code Quality via lintr (15% weight)

```r
calculate_lint_score <- function(pkg = ".") {
  lints <- lintr::lint_package(pkg)

  # Count by severity
  errors <- sum(purrr::map_chr(lints, "type") == "error")
  warnings <- sum(purrr::map_chr(lints, "type") == "warning")
  styles <- sum(purrr::map_chr(lints, "type") == "style")

  # Score: 100 - penalties
  # Errors: -10 each, Warnings: -3 each, Styles: -1 each
  score <- max(0, 100 - errors * 10 - warnings * 3 - styles * 1)

  list(
    metric = "lint",
    raw_value = list(errors = errors, warnings = warnings, styles = styles),
    score = score,
    weight = 0.15,
    weighted_score = score * 0.15,
    details = sprintf("%d errors, %d warnings, %d style issues",
                      errors, warnings, styles)
  )
}
```

### 5. Defensive Programming (Bonus, up to +5)

```r
calculate_defensive_score <- function(pkg = ".") {
  r_files <- list.files(file.path(pkg, "R"), pattern = "\\.R$", full.names = TRUE)

  good_patterns <- c(
    "cli::cli_abort",
    "rlang::check_required",
    "rlang::arg_match",
    "%\\|\\|%",
    "is\\.null\\(",
    "is\\.na\\("
  )

  bad_patterns <- c(
    "stop\\(",
    "warning\\(",
    "stopifnot\\("
  )

  good_count <- 0
  bad_count <- 0

  for (file in r_files) {
    content <- paste(readLines(file), collapse = "\n")
    good_count <- good_count + sum(purrr::map_int(good_patterns, ~{
      length(gregexpr(.x, content)[[1]])
    }))
    bad_count <- bad_count + sum(purrr::map_int(bad_patterns, ~{
      matches <- gregexpr(.x, content)[[1]]
      if (matches[1] == -1) 0 else length(matches)
    }))
  }

  # Bonus: +1 per 5 good patterns, -2 per bad pattern, max +5
  bonus <- min(5, max(-5, floor(good_count / 5) - bad_count * 2))

  list(
    metric = "defensive",
    raw_value = list(good = good_count, bad = bad_count),
    score = bonus,
    weight = 0,  # Bonus, not weighted
    weighted_score = bonus,
    details = sprintf("%d defensive patterns, %d anti-patterns (bonus: %+d)",
                      good_count, bad_count, bonus)
  )
}
```

## Overall Score Calculation

```r
assess_quality_gate <- function(pkg = ".", required_gate = "bronze") {
  metrics <- list(
    coverage = calculate_coverage_score(pkg),
    check = calculate_check_score(pkg),
    documentation = calculate_doc_score(pkg),
    lint = calculate_lint_score(pkg),
    defensive = calculate_defensive_score(pkg)
  )

  # Sum weighted scores
  weighted_sum <- sum(purrr::map_dbl(metrics, "weighted_score"))

  # Add defensive bonus (capped at 100)
  overall_score <- min(100, weighted_sum)

  # Determine gate level
  gate_level <- dplyr::case_when(
    overall_score >= 95 ~ "gold",
    overall_score >= 90 ~ "silver",
    overall_score >= 80 ~ "bronze",
    TRUE ~ "none"
  )

  # Check if required gate is met
  gate_order <- c("none" = 0, "bronze" = 1, "silver" = 2, "gold" = 3)
  gate_passed <- gate_order[gate_level] >= gate_order[required_gate]

  structure(
    list(
      overall_score = overall_score,
      gate_level = gate_level,
      required_gate = required_gate,
      gate_passed = gate_passed,
      metrics = metrics,
      timestamp = Sys.time()
    ),
    class = "quality_gate_result"
  )
}
```

## CLI Report

```r
#' @export
print.quality_gate_result <- function(x, ...) {
  gate_emoji <- c(none = "❌", bronze = "🥉", silver = "🥈", gold = "🥇")

  cli::cli_h1("Quality Gate Assessment")
  cli::cli_text("")

  # Overall score with color
  score_color <- dplyr::case_when(
    x$overall_score >= 95 ~ "green",
    x$overall_score >= 90 ~ "cyan",
    x$overall_score >= 80 ~ "yellow",
    TRUE ~ "red"
  )

  cli::cli_alert_info("Overall Score: {.val {sprintf('%.1f', x$overall_score)}}")
  cli::cli_alert_info("Gate Level: {gate_emoji[x$gate_level]} {.val {x$gate_level}}")
  cli::cli_alert_info("Required: {.val {x$required_gate}}")

  if (x$gate_passed) {
    cli::cli_alert_success("Gate PASSED")
  } else {
    cli::cli_alert_danger("Gate FAILED - need {.val {x$required_gate}}, got {.val {x$gate_level}}")
  }

  cli::cli_text("")
  cli::cli_h2("Metrics Breakdown")

  for (name in names(x$metrics)) {
    m <- x$metrics[[name]]
    cli::cli_li("{.field {name}}: {.val {sprintf('%.1f', m$score)}} ({m$details})")
  }

  invisible(x)
}
```

## Integration with /check Command

Add to the /check skill to output quality gate:

```r
# At end of /check
gate <- assess_quality_gate(".", required_gate = "silver")
print(gate)

if (!gate$gate_passed) {
  cli::cli_alert_warning("Quality gate not met. Address issues before PR.")
}
```

## History Tracking

```r
log_quality_assessment <- function(result, log_file = ".claude/quality_history.parquet") {
  entry <- tibble::tibble(
    timestamp = result$timestamp,
    overall_score = result$overall_score,
    gate_level = result$gate_level,
    coverage = result$metrics$coverage$score,
    check_score = result$metrics$check$score,
    doc_score = result$metrics$documentation$score,
    lint_score = result$metrics$lint$score,
    defensive_bonus = result$metrics$defensive$score
  )

  if (file.exists(log_file)) {
    existing <- arrow::read_parquet(log_file)
    combined <- dplyr::bind_rows(existing, entry)
  } else {
    combined <- entry
  }

  arrow::write_parquet(combined, log_file)
}
```

## Usage Examples

```r
# Quick assessment
gate <- assess_quality_gate(".")
print(gate)

# For commit (Bronze required)
gate <- assess_quality_gate(".", required_gate = "bronze")
stopifnot(gate$gate_passed)

# For PR (Silver required)
gate <- assess_quality_gate(".", required_gate = "silver")
if (!gate$gate_passed) {
  cli::cli_abort("Silver gate required for PR")
}

# For merge (Gold required)
gate <- assess_quality_gate(".", required_gate = "gold")
```

## Interpreting Scores

| Score Range | Interpretation | Action |
|-------------|----------------|--------|
| 95-100 | Gold - Excellent | Ready for release |
| 90-94 | Silver - Good | Ready for PR |
| 80-89 | Bronze - Acceptable | Ready for commit |
| 70-79 | Below Bronze | Fix major issues |
| < 70 | Poor | Significant work needed |

## Common Issues and Fixes

| Issue | Score Impact | Fix |
|-------|--------------|-----|
| Missing tests | -25 (coverage) | Add tests for uncovered code |
| R CMD check errors | -30 each | Fix all errors |
| Undocumented exports | -20 (doc) | Add roxygen2 comments |
| Many lint issues | -15 (lint) | Run styler::style_pkg() |
| Using stop() | -2 (defensive) | Replace with cli::cli_abort() |
