# Adversarial QA Skill

**MANDATORY: Must be run as part of Step 4 for every PR.**
**This skill is NOT optional. Skipping it is a workflow violation.**

Generate attack vectors and stress tests for R package functions.

## The Critic-Fixer Loop

```
┌─────────────────────────────────────────────────────────────────┐
│                    ADVERSARIAL QA LOOP                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   DISCOVER ────► GENERATE ────► ATTACK ────► RECORD              │
│       │                                         │                │
│       │                                         │                │
│       │         ┌───────────────────────────────┘                │
│       │         │                                                │
│       │         ▼                                                │
│       │       FIX ────► RE-ATTACK ────► VERDICT                  │
│       │         │                          │                     │
│       │         │     (loop until          │                     │
│       │         │      all pass)           │                     │
│       │         └──────────────────────────┘                     │
│       │                                                          │
│       └──► APPROVE if all pass, BLOCK if failures remain         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Phase 1: DISCOVER

Identify exported functions to test:

```r
discover_attack_targets <- function(pkg = ".") {
  ns <- devtools::parse_ns_file(pkg)
  exports <- ns$exports

  # For each export, analyze signature
  targets <- purrr::map(exports, ~{
    fn <- get(.x, envir = asNamespace(basename(normalizePath(pkg))))
    args <- formals(fn)

    list(
      name = .x,
      args = names(args),
      defaults = purrr::map(args, ~if (missing(.x)) NA else deparse(.x)),
      has_dots = "..." %in% names(args)
    )
  })

  names(targets) <- exports
  targets
}
```

## Phase 2: GENERATE Attack Vectors

### Input Validation Attacks

```r
generate_null_attacks <- function(target) {
  # Attack each argument with NULL
  purrr::map(target$args, ~{
    list(
      category = "null_input",
      arg = .x,
      value = "NULL",
      expected = "error",
      rationale = "NULL should be rejected with clear message"
    )
  })
}

generate_empty_attacks <- function(target) {
  list(
    list(category = "empty_vector", value = "numeric(0)", expected = "error_or_empty"),
    list(category = "empty_df", value = "data.frame()", expected = "error_or_empty"),
    list(category = "empty_string", value = '""', expected = "error_or_handle"),
    list(category = "empty_list", value = "list()", expected = "error_or_handle")
  )
}
```

### Type Coercion Attacks

```r
generate_type_attacks <- function(target, arg_name, expected_type) {
  wrong_types <- list(
    numeric = c('"string"', 'TRUE', 'list(1)', 'factor(1)'),
    character = c('123', 'TRUE', 'list("a")', 'factor("a")'),
    logical = c('1', '"TRUE"', 'list(TRUE)'),
    data.frame = c('list(a=1)', 'matrix(1:4, 2)', '"data"', '1:10')
  )

  purrr::map(wrong_types[[expected_type]] %||% wrong_types$numeric, ~{
    list(
      category = "type_coercion",
      arg = arg_name,
      value = .x,
      expected = "error",
      rationale = sprintf("Wrong type for %s should error with type info", arg_name)
    )
  })
}
```

### Boundary Attacks

```r
generate_boundary_attacks <- function(target, numeric_args) {
  boundaries <- list(
    zero = 0,
    negative = -1,
    large = 1e10,
    small = 1e-10,
    infinity = "Inf",
    neg_infinity = "-Inf",
    nan = "NaN"
  )

  purrr::map(numeric_args, \(arg) {
    purrr::map(boundaries, ~{
      list(
        category = "boundary",
        arg = arg,
        value = as.character(.x),
        expected = "error_or_handle",
        rationale = sprintf("Boundary value %s should be handled", .x)
      )
    })
  }) |> purrr::flatten()
}
```

### NA/Missing Attacks

```r
generate_na_attacks <- function(target) {
  list(
    list(category = "na_scalar", value = "NA", expected = "error_or_handle"),
    list(category = "na_numeric", value = "NA_real_", expected = "error_or_handle"),
    list(category = "na_character", value = "NA_character_", expected = "error_or_handle"),
    list(category = "na_in_vector", value = "c(1, NA, 3)", expected = "error_or_handle"),
    list(category = "all_na", value = "c(NA, NA, NA)", expected = "error_or_handle")
  )
}
```

### Data Structure Attacks

```r
generate_structure_attacks <- function(target) {
  list(
    list(category = "tibble_vs_df", value = "tibble::tibble(x=1)", expected = "handle"),
    list(category = "single_row", value = "data.frame(x=1)", expected = "handle"),
    list(category = "single_column", value = "data.frame(x=1:10)", expected = "handle"),
    list(category = "data.table", value = "data.table::data.table(x=1)", expected = "handle"),
    list(category = "matrix", value = "matrix(1:9, 3)", expected = "error_or_coerce"),
    list(category = "nested_list", value = "list(a=list(b=1))", expected = "error")
  )
}
```

### Idempotency Attacks

```r
generate_idempotency_attacks <- function(target) {
  list(
    list(
      category = "idempotent",
      test_code = "identical(f(x), f(f(x)))",
      expected = "true_or_false",
      rationale = "Repeated application should be predictable"
    ),
    list(
      category = "deterministic",
      test_code = "identical(f(x), f(x))",
      expected = "true",
      rationale = "Same input should give same output"
    )
  )
}
```

## Phase 3: ATTACK (Generate Tests)

```r
generate_attack_test <- function(target_name, attack) {
  test_name <- sprintf(
    "%s defends against %s (%s)",
    target_name,
    attack$category,
    attack$arg %||% "general"
  )

  test_code <- switch(attack$expected,
    "error" = sprintf(
      'test_that("%s", {
  expect_error(%s(%s = %s), class = "rlang_error")
})',
      test_name, target_name, attack$arg, attack$value
    ),

    "error_or_handle" = sprintf(
      'test_that("%s", {
  result <- tryCatch(
    %s(%s = %s),
    error = function(e) "caught_error"
  )
  expect_true(
    identical(result, "caught_error") ||
    !is.null(result)
  )
})',
      test_name, target_name, attack$arg, attack$value
    ),

    "handle" = sprintf(
      'test_that("%s", {
  expect_no_error(%s(%s = %s))
})',
      test_name, target_name, attack$arg, attack$value
    )
  )

  list(
    name = test_name,
    code = test_code,
    attack = attack
  )
}
```

## Phase 4: RECORD Results

```r
run_attack_suite <- function(pkg, targets, attacks_per_target) {
  results <- purrr::map(names(targets), \(target_name) {
    attacks <- generate_all_attacks(targets[[target_name]])

    purrr::map(attacks, \(attack) {
      test <- generate_attack_test(target_name, attack)

      # Run the test
      result <- tryCatch({
        eval(parse(text = test$code))
        list(status = "PASS", error = NULL)
      }, error = function(e) {
        list(status = "FAIL", error = conditionMessage(e))
      })

      list(
        target = target_name,
        attack = attack,
        test = test,
        result = result
      )
    })
  }) |> purrr::flatten()

  # Summarize
  summary <- tibble::tibble(
    target = purrr::map_chr(results, "target"),
    category = purrr::map_chr(results, \(r) r$attack$category),
    status = purrr::map_chr(results, \(r) r$result$status),
    error = purrr::map_chr(results, \(r) r$result$error %||% "")
  )

  list(
    results = results,
    summary = summary,
    pass_rate = mean(summary$status == "PASS"),
    failures = dplyr::filter(summary, status == "FAIL")
  )
}
```

## Phase 5: FIX

When attacks reveal vulnerabilities:

```r
suggest_fix <- function(failure) {
  fixes <- list(
    null_input = 'Add: if (is.null({arg})) cli::cli_abort("{.arg {arg}} cannot be NULL")',
    type_coercion = 'Add: if (!is.{type}({arg})) cli::cli_abort("{.arg {arg}} must be {type}")',
    boundary = 'Add: if ({arg} {op} {val}) cli::cli_abort("{.arg {arg}} must be {constraint}")',
    na_scalar = 'Add: if (is.na({arg})) cli::cli_abort("{.arg {arg}} cannot be NA")',
    empty_vector = 'Add: if (length({arg}) == 0) cli::cli_abort("{.arg {arg}} cannot be empty")'
  )

  fix_template <- fixes[[failure$category]] %||%
    "Add appropriate input validation for {category}"

  glue::glue(fix_template, .envir = as.environment(failure))
}
```

## Phase 6: VERDICT

```markdown
## Adversarial QA Verdict

### Summary
- Functions tested: 5
- Attack vectors: 47
- Passed: 42 (89%)
- Failed: 5 (11%)

### Verdict: CONDITIONAL APPROVE ⚠

### Failures Requiring Attention

| Function | Attack | Category | Issue |
|----------|--------|----------|-------|
| analyze_data | NULL input | null_input | No error raised |
| process_metrics | -1 value | boundary | Silent wrong result |

### Suggested Fixes

1. **analyze_data**: Add NULL check
   ```r
   if (is.null(data)) cli::cli_abort("{.arg data} cannot be NULL")
   ```

2. **process_metrics**: Add boundary validation
   ```r
   if (n < 0) cli::cli_abort("{.arg n} must be non-negative")
   ```

### Tests Generated

The following test file was created:
`tests/testthat/test-adversarial.R`

Run with: `testthat::test_file("tests/testthat/test-adversarial.R")`
```

## Attack Categories Reference

| Category | Tests | Expected Behavior |
|----------|-------|-------------------|
| null_input | NULL for each arg | Error with arg name |
| empty_vector | numeric(0), character(0) | Error or empty result |
| type_coercion | Wrong types | Error with type info |
| boundary | 0, -1, Inf, NaN | Error or graceful handling |
| na_input | NA, NA_real_ | Error or NA handling |
| single_row | 1-row data frame | Work correctly |
| data_structure | tibble vs df | Work with both |
| idempotency | f(f(x)) vs f(x) | Predictable result |
| determinism | f(x) == f(x) | Same result |

## Integration with Quality Gates

Add adversarial pass rate to quality metrics:

```r
calculate_adversarial_score <- function(pkg = ".") {
  results <- run_attack_suite(pkg)

  # Score based on pass rate
  score <- results$pass_rate * 100

  list(
    metric = "adversarial",
    raw_value = results$pass_rate,
    score = score,
    weight = 0,  # Informational, not weighted
    weighted_score = 0,
    details = sprintf("%d/%d attacks defended (%.0f%%)",
                      sum(results$summary$status == "PASS"),
                      nrow(results$summary),
                      results$pass_rate * 100),
    failures = results$failures
  )
}
```

## Usage

### Via Command
```
/qa-package
```

### Programmatic
```r
# Run full adversarial suite
results <- run_adversarial_qa(".")

# Generate test file
write_adversarial_tests(results, "tests/testthat/test-adversarial.R")

# Add to CI
# In test-adversarial.R, tests are standard testthat tests
```
