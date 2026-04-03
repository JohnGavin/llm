# Adversarial QA: Boundary Attacks Example

Demonstrates 8 attack categories from the adversarial-qa skill against a simple `safe_divide()` function.

## Files

- `safe_divide.R` — Function under test (validates inputs with cli_abort)
- `test-adversarial-safe_divide.R` — 8 test blocks covering 7 attack categories + numerical stability
- `run_tests.R` — Runner that produces summary output
- `output/test_results.txt` — Expected: `[ FAIL 0 | WARN 0 | SKIP 0 | PASS 8 ]`

## Run

```bash
cd examples/boundary-attacks
Rscript run_tests.R
```

## Verify

```bash
diff output/test_results.txt <(tail -1 actual_output.txt)
```

Expected: all 8 tests pass, 0 failures.

## Attack Categories Demonstrated

| # | Category | What It Tests |
|---|----------|--------------|
| 1 | Boundary | 0, Inf, -Inf, 1e308 |
| 2 | NA | NA, NA_real_, NA in numerator |
| 3 | Type | character, logical, list inputs |
| 4 | Structure | vector x, vector y, empty y |
| 5 | Zero division | y=0, both=0 |
| 6 | Idempotency | f(f(x)) consistency |
| 7 | Determinism | same input → same output |
| 11 | Numerical stability | floating-point edge cases |
