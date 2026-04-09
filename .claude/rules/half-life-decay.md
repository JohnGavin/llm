---
paths:
  - "R/**"
  - "src/**"
  - "**/*.py"
---
# Rule: True Half-Life Decay

## When This Applies
Any code that applies time-based exponential decay — recency weighting, reputation scoring, cache eviction, reactive smoothing, A/B test decay windows, exponentially-weighted moving averages.

## CRITICAL: `exp(-d/h)` is NOT a half-life

A very common bug: writing `exp(-days / half_life)` and believing the half-life parameter means "weight halves after this many days". It doesn't.

| Formula | At one half-life | What it actually is |
|---|---|---|
| `exp(-d/h)` | `exp(-1) ≈ 0.368` | Time constant (1/e decay), NOT half-life |
| `2^(-d/h)` | `2^(-1) = 0.500` | **True half-life** |
| `exp(-d × ln(2) / h)` | `exp(-ln(2)) = 0.500` | Equivalent to `2^(-d/h)` |

If you pass `half_life = 30` into `exp(-d/30)`, a 30-day-old reading gets weight 0.368, not 0.5, and the user's mental model of "half-life" is silently wrong.

## Required Pattern

```r
# R
recency_weight <- function(date, reference_date = Sys.Date(), half_life = 30) {
  days <- as.numeric(reference_date - date)
  2^(-days / half_life)                       # or: exp(-days * log(2) / half_life)
}
```

```python
# Python
def recency_weight(date, reference_date, half_life_days=30):
    days = (reference_date - date).days
    return 2 ** (-days / half_life_days)
```

## Decay Curve (half-life = 30 days)

| Days ago | `exp(-d/30)` (wrong) | `2^(-d/30)` (correct) |
|---:|---:|---:|
| 0 | 1.000 | 1.000 |
| 7 | 0.792 | 0.851 |
| 30 | 0.368 | **0.500** |
| 60 | 0.135 | **0.250** |
| 90 | 0.050 | **0.125** |
| 180 | 0.002 | **0.016** |

## When You Actually Want `exp(-d/τ)`

Use `exp(-d/τ)` when your parameter is a **time constant τ** (tau), not a half-life. Name it `tau` or `time_constant`, not `half_life`. Document the distinction. Common in physics (radioactive decay, RC circuits), less common in product analytics where users think in half-lives.

## Verification Test (MANDATORY)

Any function named `*half_life*` or `half_life` parameter MUST have a test that verifies the weight is exactly 0.5 at one half-life period:

```r
test_that("recency_weight gives exactly 0.5 at half-life", {
  today <- as.Date("2026-01-01")
  thirty_days_ago <- today - 30
  expect_equal(
    recency_weight(thirty_days_ago, reference_date = today, half_life = 30),
    0.5,
    tolerance = 1e-10
  )
})

test_that("recency_weight uses 2^-x not exp(-x)", {
  today <- as.Date("2026-01-01")
  result <- recency_weight(today - 30, today, 30)
  # Explicitly check we are NOT using exp
  expect_false(abs(result - exp(-1)) < 0.01)
  expect_equal(result, 0.5, tolerance = 1e-10)
})
```

## Red Flags in Code Review

1. **`exp(-days / half_life)`** — almost always a bug. Ask: is the parameter really a time constant, or was it labelled "half_life"?
2. **Comment saying "half-life of X days" next to `exp(-d/X)`** — comment contradicts the code.
3. **No test verifying 0.5 at the half-life period** — the parameter meaning is unverified.
4. **A user-facing slider labelled "Half-life (days)" wired to `exp(-d/slider)`** — the UI lies to the user.

## Related
- `statistical-reporting` — effect sizes, uncertainty quantification
- `snapshot-tests-mandatory` — 30% snapshot ratio including decay curves
