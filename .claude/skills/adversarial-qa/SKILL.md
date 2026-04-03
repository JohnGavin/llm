---
name: adversarial-qa
description: Use when performing attack-based testing on R package exported functions, running adversarial QA before PRs, or stress-testing edge cases, invalid inputs, and boundary conditions in R code. Triggers: adversarial testing, QA review, attack vectors, fuzz testing, edge cases, PR quality gate.
---
# Adversarial QA Skill

Attack-based testing for R package exported functions. MANDATORY for Step 4 of every PR.

## When to Use

- Step 4 of the 9-step workflow (before commit)
- After adding or modifying any exported function
- Run with `devtools::test(filter = "adversarial")`

## File Naming Convention

```
tests/testthat/test-adversarial-{module}.R
```

Examples: `test-adversarial.R`, `test-adversarial-wave-model.R`, `test-adversarial-email.R`, `test-adversarial-gdc.R`

## Attack Categories

See [attack-examples.md](references/attack-examples.md) for full code examples of every category.

### 1. Boundary Attacks
Test `Inf`, `-Inf`, `NaN`, `0`, extreme values, `.Machine$double.xmin/xmax`.

### 2. NA Attacks
Test all typed NAs (`NA`, `NA_integer_`, `NA_real_`, `NA_character_`, `NA_complex_`, `as.Date(NA_character_)`), embedded NAs (first/middle/last), all-NA vectors, NA in data frames, NA type preservation, and NA propagation behavior.

### 3. Type Attacks
Test wrong types R might silently coerce: character for numeric, numeric for logical, list for vector, factor inputs.

### 4. Structure Attacks
Test tibble vs data.frame, single-row, empty (0 rows), minimal columns, extra columns, wrong column names.

### 5. Injection Attacks
For DB/HTML functions: SQL injection, XSS, path traversal.

### 6. Idempotency
`my_func(my_func(input))` should equal `my_func(input)`.

### 7. Determinism
Same inputs must produce same outputs (for non-random functions).

### 8. Domain Hallucination Guards
Verify known-correct mappings (ground truth), category completeness, no hallucinated categories. Critical for data pipelines where wrong mappings silently produce plausible-but-wrong results.

### 9. Data Sanity Attacks
For time-series/panel data functions. Test: temporal coverage vs expected frequency, duplicate detection, monotonicity, data freshness, entity completeness, aggregation arithmetic (`sum(parts) == total`), schema stability.

### 10. Data Ingestion Attacks
For CSV/file parsers. Test: BOM prefix, encoding (latin1), NA string variants (`""`, `"NA"`, `"N/A"`, `"-"`, `"NULL"`), whitespace trimming, quoted fields with embedded commas, type coercion warnings, missing/extra columns, empty files, ambiguous date formats.

### 11. Numerical Stability Attacks
For functions performing arithmetic on floating-point values. Test:
- **Equality traps:** `==` on doubles (use `all.equal(x, y, tolerance = 1e-8)`)
- **Accumulation errors:** `sum()` on 1M values vs Kahan summation
- **Catastrophic cancellation:** `(x + epsilon) - x` for large x, small epsilon
- **Order dependence:** `sum(sort(x))` vs `sum(rev(sort(x)))` for ill-conditioned sums
- **Tolerance propagation:** downstream functions inheriting upstream rounding

```r
test_that("function handles floating-point edge cases", {
  # Equality trap
  expect_true(all.equal(0.1 + 0.2, 0.3))  # NOT: expect_equal(0.1+0.2, 0.3)

  # Accumulation
  x <- rep(1e-10, 1e6)
  expect_equal(my_sum(x), 1e-4, tolerance = 1e-8)

  # Order independence
  big <- c(1e15, 1, -1e15, 1)
  expect_equal(my_func(big), my_func(rev(big)), tolerance = 1e-8)
})
```

**MANDATORY** for: risk calculations (micromort), financial aggregations (crypto), model scoring (football), any pipeline producing summary statistics.

## Template Test File

```r
# tests/testthat/test-adversarial-{module}.R
# Adversarial tests for {module} functions
# Attack vectors: boundary, NA, type, structure, injection, idempotency, determinism

test_that("{function_name} handles boundary attacks", {
  # Inf, -Inf, NaN, extreme values
})

test_that("{function_name} handles NA attacks", {
  # NA, NA_real_, embedded NAs, all-NA
})

test_that("{function_name} rejects wrong types", {
  # Character for numeric, list for vector, factor
})

test_that("{function_name} handles structure attacks", {
  # Empty, single-row, tibble vs df, extra/missing columns
})

test_that("{function_name} is deterministic", {
  # Same input -> same output
})
```

## Code Review Severity Assessment

See [severity-tiers.md](references/severity-tiers.md) for the full severity tier definitions and red flag checklists.

**Quick reference:** 4 tiers (Blocking > Required > Strong Suggestion > Noted). Mindset: "Guilty until proven exceptional."

**Key R red flags:** `T`/`F` instead of `TRUE`/`FALSE`, partial argument matching, vectorized conditions in `if`, `<<-` without justification, `suppressWarnings(as.integer(...))` anti-pattern.

## Coverage Requirement

- >= 95% of attack vectors must be defended
- Every exported function must have at least boundary + NA + type attacks
- Functions touching databases must have injection attacks
- Functions producing HTML must have XSS attacks
- Data pipeline functions must have domain hallucination guards
- **Every data pipeline function MUST have data sanity attacks (Category 9)**
- **Every function returning aggregated summaries MUST have aggregation arithmetic checks**
- **Every data ingestion function MUST have data ingestion attacks (Category 10)**
- **Every CSV/file parser MUST test: BOM, encoding, NA variants, whitespace, quoted fields**
- **Every function doing floating-point arithmetic MUST have numerical stability attacks (Category 11)**
- **Every function using `==` on doubles MUST be flagged — use `all.equal()` with explicit tolerance**

## Pipeline Integration

Adversarial tests run automatically via `plan_qa_gates.R`:

```r
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
    list(passed = n_pass, failed = n_fail, timestamp = Sys.time())
  },
  cue = targets::tar_cue(mode = "always")
)
```

## Reference Implementations

| Project | File | Lines | Tests | Focus |
|---------|------|-------|-------|-------|
| coMMpass | `test-adversarial.R` | 462 | 35+ | Boundary, NA, type, structure |
| coMMpass | `test-adversarial-gdc.R` | 239 | 35 | Domain hallucination (7 areas) |
| irishbuoys | `test-adversarial-wave-model.R` | 421 | Wave model edge cases |
| irishbuoys | `test-adversarial-email.R` | 580 | Email/HTML injection, XSS |
| micromort | `test-adversarial.R` | - | Risk calculation edge cases |
| football | `test-adversarial.R` | - | Match data edge cases |
