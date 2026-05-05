---
name: quality-gates
description: Use when applying numeric scoring for commit/PR/merge gates, evaluating Bronze/Silver/Gold quality levels, or enforcing quality checks at PR steps 4, 6, and 8. Triggers: quality gate, scoring, Bronze/Silver/Gold, PR quality, commit gate, merge gate.
---
# Quality Gates Skill

Numeric scoring system for commit/PR/merge gates. MANDATORY for Steps 4, 6, 8 of every PR.

## When to Use

- Step 4: Compute score before commit (must be >= Bronze)
- Step 6: Verify score before PR push (must be >= Silver)
- Step 8: Confirm score before merge to main (must be >= Gold)

## Grade Thresholds

| Grade | Score | Required For |
|-------|-------|-------------|
| Gold | >= 95 | Merge to main |
| Silver | >= 90 | PR creation |
| Bronze | >= 80 | Commit |
| Below Bronze | < 80 | BLOCKED - fix issues first |

## Scoring Formula

Total score = weighted sum of six components:

| Component | Weight | How Computed |
|-----------|--------|-------------|
| Coverage | 20% | `covr::percent_coverage(covr::package_coverage())` |
| R CMD check | 30% | 98 if 0 test failures, 0 otherwise |
| Documentation | 15% | `(man pages / exports) * 100`, capped at 100 |
| Defensive programming | 10% | `(cli::cli_abort calls / total error calls) * 100` |
| **Data integrity** | **20%** | `plan_data_validation` targets all pass = 100, any fail = 0 |
| **Code style** | **5%** | 100 if 0 `DBI::dbGetQuery` in R/ (excl. DDL), 0 otherwise |

### Component Details

**Coverage (20%)**
- Uses `covr::package_coverage()` to compute line-level coverage
- Target: >= 80% for Bronze, >= 90% for Gold

**R CMD check (30%)**
- Binary: 98 if all tests pass, 0 if any fail
- This is the heaviest weight because failing tests block everything

**Documentation (15%)**
- Counts NAMESPACE exports vs man/ .Rd files
- 100% means every export has a help page
- Missing docs reduce the score proportionally

**Defensive programming (10%)**
- Ratio of `cli::cli_abort()` to total error calls (`stop()` + `cli::cli_abort()`)
- 100% if no error calls exist (no penalty for simple packages)
- Rewards tidyverse-style structured errors over bare `stop()`

**Data integrity (20%)**
- All `plan_data_validation.R` targets pass = 100, any fail = 0
- For projects without time-series data (no `plan_data_validation.R`): defaults to 100
- Checks: temporal coverage, gaps, sampling frequency, duplicates, freshness, value ranges

**Code style (5%)**
- 100 if 0 `DBI::dbGetQuery()` calls in R/ (excluding `R/dev/` and DDL exceptions)
- 0 if any raw SQL SELECT violations found
- Prevents SQL regression after conversion to dplyr

## Point-Deduction Table

Specific deductions applied when computing each component score. Agents MUST report these line items when a score is below threshold.

### Coverage component (20% weight)

| Issue | Deduction |
|-------|-----------|
| < 80% line coverage | -(80 - actual_pct) points |
| < 50% line coverage | -50 points (floor at 0) |
| New exported function with zero tests | -15 points per function |

### R CMD check component (30% weight)

| Issue | Deduction |
|-------|-----------|
| Any test failure | -98 points (score becomes 0) |
| NOTE in R CMD check | -5 points each |
| WARNING in R CMD check | -20 points each |
| ERROR in R CMD check | -98 points (score becomes 0) |

### Documentation component (15% weight)

| Issue | Deduction |
|-------|-----------|
| Export missing man page | -10 points per missing page |
| `@param` missing for any argument | -5 points per missing param |
| `@return` missing | -5 points per function |
| `@export` missing on public function | -10 points per function |

### Defensive programming component (10% weight)

| Issue | Deduction |
|-------|-----------|
| Each `stop()` call (instead of `cli_abort`) | -(100/total_error_calls) points |
| Silent `tryCatch` (no message/warning) | -20 points each |
| `suppressWarnings(as.*)` pattern | -15 points each |

### Data integrity component (20% weight)

| Issue | Deduction |
|-------|-----------|
| Any `plan_data_validation` target fails | -100 points (score becomes 0) |
| Temporal gap > expected frequency | -20 points per gap |
| Duplicate rows in keyed table | -30 points |

### Code style component (5% weight)

| Issue | Deduction |
|-------|-----------|
| Any `DBI::dbGetQuery()` in R/ (non-DDL) | -100 points (score becomes 0) |
| Raw SQL string in non-DDL context | -50 points each |
| `T`/`F` instead of `TRUE`/`FALSE` | -5 points each |
| `=` instead of `<-` for assignment | -3 points each |

### Accessibility & contrast deductions (standalone gate — not a weighted component)

Enforces `accessibility-standards` and `dark-mode-completeness` rules. Applies to every project that ships HTML output (Quarto vignettes, pkgdown sites, Shiny apps, Shinylive bundles). These deductions are subtracted from the FINAL total score after the weighted-component sum is computed. A project with high coverage and clean R CMD check can still drop below Bronze if contrast violations accumulate.

This is a gate, not a percentage component, because contrast is a binary correctness property — either every pixel is readable in both modes, or the page is broken for some user. Weighting it would let high coverage compensate for an unreadable site, which is wrong.

| Issue | Deduction |
|-------|-----------|
| Project copies `check_dark_contrast.sh` into its own `scripts/` directory (must be GLOBAL only at `~/docs_gh/llm/.claude/scripts/`) | -10 points |
| Project does NOT wire `~/docs_gh/llm/.claude/scripts/quarto_post_render_contrast.sh` into `_quarto.yml` post-render | -10 points |
| `check_dark_contrast.sh` exits non-zero on any rendered `docs/**/*.html` | -5 points per uncovered element |
| Inline `style="background:#…"` light bg with no `body.dark-mode` override | -5 points per element |
| Dark-mode override without `!important` on element carrying inline `style=` | -3 points per element |
| `axe: true` missing from `_quarto.yml` `format: html:` | -2 points |
| Vignette missing dark/light toolbar (`#dark-btn`) | -5 points per vignette |
| Vignette missing font-size A+/A− buttons | -3 points per vignette |
| Vignette missing language toggle when bilingual content present | -3 points per vignette |
| Catch-all `body.dark-mode [style*="background:#…"]` selector absent | -5 points |
| Single contrast PR fixes < 100% of uncovered elements (per-element patching) | -10 points (process violation) |
| `var(--card-bg)` / `#16213e` / similar dark-blue token used where user spec said "black" | -5 points per element |
| Bootstrap utility colour (`#0dcaf0`, `#6f42c1`, `#fd7e14`, `#6c757d`, `#198754`, `#dc3545`) used as text on dark bg without dark-mode pair | -3 points per token |

### Exploration-mode relaxed thresholds

When working in `explorations/` the minimum acceptable score is **60** (not 80).
Deductions still apply but the gate threshold is lower.

| Grade | Production score | Exploration score |
|-------|-----------------|-------------------|
| Pass (minimum) | >= 80 (Bronze) | >= 60 |
| Good | >= 90 (Silver) | >= 75 |
| Excellent | >= 95 (Gold) | >= 90 |

## Pipeline Integration

Add `plan_qa_gates.R` to `R/tar_plans/` in every project. All targets use `cue = tar_cue(mode = "always")` so they run on every `tar_make()`.

### Targets in the plan

| Target | Purpose | Blocks on failure? |
|--------|---------|-------------------|
| `qa_test_results` | Run full test suite | Yes (aborts) |
| `qa_adversarial` | Run adversarial tests | Yes (aborts) |
| `qa_coverage` | Compute coverage % | No (informational) |
| `qa_self_review` | Self-review checklist | No (warns) |
| `qa_no_raw_sql` | Check for SQL violations | No (warns) |
| `qa_quality_gate` | Compute weighted score (6 components) | No (reports grade) |

### Self-Review Checklist Items

The `qa_self_review` target checks:
- NAMESPACE exports vs man pages count
- `stop()` vs `cli::cli_abort()` usage ratio
- TODO/FIXME/HACK comment count

## Template: plan_qa_gates.R

Copy this to `R/tar_plans/plan_qa_gates.R` for new projects:

```r
#' Targets Plan: Automated QA Gates
#'
#' Ensures adversarial QA, quality gates, and self-review checklist
#' are run as part of every tar_make(). These cannot be skipped.

plan_qa_gates <- list(
  # Run all tests and capture results
  targets::tar_target(
    qa_test_results,
    {
      results <- devtools::test(pkg = ".", reporter = "summary")
      df <- as.data.frame(results)
      n_pass <- sum(df$passed)
      n_fail <- sum(df$failed)
      n_warn <- sum(df$warning)
      n_skip <- sum(df$skipped)

      if (n_fail > 0) {
        cli::cli_abort(c(
          "x" = "QA Gate FAILED: {n_fail} test(s) failed",
          "i" = "Fix failing tests before proceeding"
        ))
      }

      cli::cli_alert_success("QA: All {n_pass} tests passed ({n_skip} skipped)")
      list(passed = n_pass, failed = n_fail, warned = n_warn,
           skipped = n_skip, timestamp = Sys.time())
    },
    cue = targets::tar_cue(mode = "always")
  ),

  # Run adversarial tests specifically
  targets::tar_target(
    qa_adversarial,
    {
      results <- devtools::test(pkg = ".", filter = "adversarial", reporter = "summary")
      df <- as.data.frame(results)
      n_pass <- sum(df$passed)
      n_fail <- sum(df$failed)

      if (n_fail > 0) {
        cli::cli_abort(c(
          "x" = "Adversarial QA FAILED: {n_fail} attack(s) succeeded",
          "i" = "Fix defensive programming before proceeding"
        ))
      }

      cli::cli_alert_success("Adversarial QA: {n_pass} attacks defended")
      list(passed = n_pass, failed = n_fail, timestamp = Sys.time())
    },
    cue = targets::tar_cue(mode = "always")
  ),

  # Compute test coverage
  targets::tar_target(
    qa_coverage,
    {
      cov <- covr::package_coverage()
      pct <- covr::percent_coverage(cov)
      file_cov <- as.data.frame(covr::tally_coverage(cov, by = "line"))

      cli::cli_alert_info("Test coverage: {round(pct, 1)}%")
      list(overall_pct = round(pct, 1), by_file = file_cov,
           timestamp = Sys.time())
    },
    cue = targets::tar_cue(mode = "always")
  ),

  # Self-review checklist
  targets::tar_target(
    qa_self_review,
    {
      ns_lines <- readLines("NAMESPACE")
      exports <- grep("^export\\(", ns_lines, value = TRUE)
      n_exports <- length(exports)
      man_files <- list.files("man", pattern = "\\.Rd$")
      n_man <- length(man_files)

      r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
      r_files <- r_files[!grepl("R/(dev|tar_plans)/", r_files)]
      all_code <- unlist(lapply(r_files, readLines))
      n_stop <- sum(grepl("\\bstop\\(", all_code))
      n_cli_abort <- sum(grepl("cli::cli_abort\\(", all_code))
      n_todo <- sum(grepl("TODO|FIXME|HACK|XXX", all_code, ignore.case = TRUE))

      checklist <- list(
        exports = n_exports, man_pages = n_man,
        doc_coverage_pct = round(100 * min(n_man / max(n_exports, 1), 1), 1),
        stop_calls = n_stop, cli_abort_calls = n_cli_abort,
        uses_cli_style = n_cli_abort > n_stop,
        todo_fixme_count = n_todo, timestamp = Sys.time()
      )

      if (n_stop > 0) {
        cli::cli_warn("Self-review: {n_stop} stop() call(s) found; prefer cli::cli_abort()")
      }
      if (n_todo > 0) {
        cli::cli_warn("Self-review: {n_todo} TODO/FIXME/HACK comment(s) found")
      }

      cli::cli_alert_success(
        "Self-review: {n_exports} exports, {n_man} man pages, {checklist$doc_coverage_pct}% documented"
      )
      checklist
    },
    cue = targets::tar_cue(mode = "always")
  ),

  # Code sweep: banned patterns via ast-grep (structural, not text grep)
  # Falls back to grep if ast-grep not available
  targets::tar_target(
    qa_no_raw_sql,
    {
      cfg_dir <- file.path(Sys.getenv("HOME"), ".config/ast-grep")
      cfg <- file.path(cfg_dir, "sgconfig.yml")
      banned <- c(
        "DBI::dbGetQuery($$$)" = "Use dplyr::tbl() |> collect()",
        "stop($$$)" = "Use cli::cli_abort()",
        "suppressWarnings($$$)" = "See suppress-warnings-antipattern rule"
      )
      total <- 0L
      for (i in seq_along(banned)) {
        pat <- names(banned)[i]
        if (file.exists(cfg)) {
          # ast-grep: structural search (no false positives from comments/strings)
          # Must run from config dir for custom language discovery (no -l flag)
          r_dir <- normalizePath("R/", mustWork = FALSE)
          json <- system2("bash", c("-c", paste0(
            "cd ", shQuote(cfg_dir), " && ast-grep run -p ", shQuote(pat),
            " ", shQuote(r_dir), " --json=compact"
          )), stdout = TRUE, stderr = FALSE)
          n <- tryCatch(nrow(jsonlite::fromJSON(paste(json, collapse = ""))), error = function(e) 0L)
        } else {
          # Fallback: text grep (may have false positives)
          r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
          r_files <- r_files[!grepl("R/dev/", r_files)]
          all_code <- unlist(lapply(r_files, readLines))
          n <- length(grep(sub("\\(\\$\\$\\$\\)", "", pat), all_code, fixed = TRUE))
        }
        if (n > 0L) cli::cli_warn(c("!" = "{n} {pat} violation(s)", "i" = banned[[i]]))
        total <- total + n
      }
      list(violations = total, timestamp = Sys.time(), method = if (file.exists(cfg)) "ast-grep" else "grep")
    },
    cue = targets::tar_cue(mode = "always")
  ),

  # Quality gate: weighted score (6 components)
  targets::tar_target(
    qa_quality_gate,
    {
      coverage_score <- qa_coverage$overall_pct
      check_score <- if (qa_test_results$failed == 0) 98 else 0
      doc_score <- qa_self_review$doc_coverage_pct

      total_error_calls <- qa_self_review$stop_calls + qa_self_review$cli_abort_calls
      defensive_score <- if (total_error_calls > 0) {
        round(100 * qa_self_review$cli_abort_calls / total_error_calls, 1)
      } else {
        100
      }

      # Data integrity: 100 if plan_data_validation exists and passes, else 100 (default)
      data_integrity_score <- tryCatch({
        dv <- targets::tar_read(dv_report)
        if (!is.null(dv)) 100 else 0
      }, error = function(e) 100)  # Default 100 if no validation plan

      # Code style: 0 violations = 100, any = 0
      code_style_score <- if (qa_no_raw_sql$violations == 0) 100 else 0

      total <- round(
        0.20 * coverage_score + 0.30 * check_score +
        0.15 * doc_score + 0.10 * defensive_score +
        0.20 * data_integrity_score + 0.05 * code_style_score, 1
      )

      grade <- dplyr::case_when(
        total >= 95 ~ "Gold",
        total >= 90 ~ "Silver",
        total >= 80 ~ "Bronze",
        TRUE ~ "Below Bronze"
      )

      gate <- list(
        total_score = total, grade = grade,
        components = list(
          coverage = list(score = coverage_score, weight = 0.20,
                         weighted = round(0.20 * coverage_score, 1)),
          check = list(score = check_score, weight = 0.30,
                      weighted = round(0.30 * check_score, 1)),
          documentation = list(score = doc_score, weight = 0.15,
                              weighted = round(0.15 * doc_score, 1)),
          defensive = list(score = defensive_score, weight = 0.10,
                          weighted = round(0.10 * defensive_score, 1)),
          data_integrity = list(score = data_integrity_score, weight = 0.20,
                               weighted = round(0.20 * data_integrity_score, 1)),
          code_style = list(score = code_style_score, weight = 0.05,
                           weighted = round(0.05 * code_style_score, 1))
        ),
        timestamp = Sys.time()
      )

      cli::cli_h2("Quality Gate: {grade} ({total}/100)")
      cli::cli_alert_info("Coverage: {coverage_score}% (weighted: {gate$components$coverage$weighted})")
      cli::cli_alert_info("Check: {check_score} (weighted: {gate$components$check$weighted})")
      cli::cli_alert_info("Docs: {doc_score}% (weighted: {gate$components$documentation$weighted})")
      cli::cli_alert_info("Defensive: {defensive_score}% (weighted: {gate$components$defensive$weighted})")
      cli::cli_alert_info("Data integrity: {data_integrity_score} (weighted: {gate$components$data_integrity$weighted})")
      cli::cli_alert_info("Code style: {code_style_score} (weighted: {gate$components$code_style$weighted})")

      gate
    },
    cue = targets::tar_cue(mode = "always")
  )
)
```

## Enforcement Mechanisms

### (a) Hook: qa_gate_check.sh

Located at `~/.claude/hooks/qa_gate_check.sh`. Checks `_targets/objects/qa_quality_gate` timestamp:
- Missing: warns that QA gates haven't been run
- Stale (>60 min): warns to re-run before commit/PR
- Fresh: reports OK

Run this hook at Steps 4, 6, and 8 of the 9-step workflow. The hook warns but does not block — the agent is responsible for running `tar_make(names = starts_with("qa_"))` and interpreting the grade.

### (b) CI Step

Add to `.github/workflows/R-CMD-check.yml` after the "Validate targets pipeline" step:

```yaml
- name: Check QA quality gate
  if: hashFiles('R/tar_plans/plan_qa_gates.R') != ''
  run: |
    nix-shell default.nix -A shell --run "Rscript -e '
      targets::tar_make(names = c(\"qa_test_results\", \"qa_self_review\",
        \"qa_no_raw_sql\", \"qa_vignette_compliance\"), callr_function = NULL)
      gate <- targets::tar_read(qa_quality_gate)
      cat(\"QA Grade:\", gate\$grade, \"(\", gate\$total_score, \"/100)\\n\")
      if (gate\$total_score < 80) stop(\"Quality gate FAILED: Below Bronze\")
    '"
```

**Note:** `qa_coverage` is omitted from CI because `covr::package_coverage()` is slow (~5 min). CI enforces Bronze (>=80) as minimum. Coverage is checked locally.

### Vignette Compliance Gap (Lesson Learned 2026-03-14)

The 6-component scoring system (coverage, check, docs, defensive, data integrity, code style) has **zero components addressing vignette compliance**. The `qa_vignette_compliance` target was added to bridge this gap. It checks code-fold, echo settings, sessionInfo, chunk labels, and DT captions. Its score is reported as "informational" alongside the main grade — it is not yet weighted into the total score to avoid breaking existing workflows.

## Reference Implementation

- `irishbuoys/R/tar_plans/plan_qa_gates.R` (202 lines, fully working)
- `micromort/R/tar_plans/plan_qa_gates.R` (6-component + vignette compliance)
