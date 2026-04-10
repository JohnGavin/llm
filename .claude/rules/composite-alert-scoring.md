---
paths:
  - "R/**"
  - "src/**"
  - "**/*.py"
---
# Rule: Composite Alert Scoring

## When This Applies
Any scoring function that ranks items for attention by combining multiple signals. Examples:
- Clinical: which lab result should the doctor look at first
- System monitoring: which metric deserves an alert
- Finance: which transaction might be fraud
- Ops: which log pattern is an incident
- Product: which user is about to churn

## The Core Pitfall

The naïve composite score is:

```
score = w1 × distance_from_target + w2 × surprise_vs_baseline
```

This fails because **surprise alone doesn't indicate a problem**. A metric can be:
- Normal AND bouncing around (high surprise, no problem)
- Abnormal AND stable (low surprise, definite problem)
- Abnormal AND worsening (the thing you actually want to rank highest)

Without structure, normal-but-jittery values rank higher than quietly abnormal ones, burying real problems.

## Required Structure

```
abnormal_mult = 1.0 if value outside acceptable bounds, 0.1 if within
direction_mod = 1.2 if moving away from target, 0.8 if moving toward, 1.0 otherwise
surprise_adj  = surprise × direction_mod × abnormal_mult

score = (w_distance × distance + w_surprise × surprise_adj) × recency
```

Three multiplicative structures attached to the surprise component:

### 1. Abnormality gate (MANDATORY)

**Dampen surprise when the value is within acceptable bounds.**

Default multiplier: `0.1` for in-bounds, `1.0` for out-of-bounds.

**Why:** A CPU oscillating 40–60% is noise; a CPU at 98% is an incident. Without the gate, the oscillating CPU can outrank the stuck-hot one because its variance is higher.

```r
is_abnormal <- !is.na(distance) & distance > 0
abnormal_mult <- ifelse(is_abnormal, 1.0, 0.1)
```

### 2. Direction modifier (MANDATORY when trend data exists)

**Amplify worsening trends, dampen improving trends.**

- `×1.2` if moving further from the target (worsening)
- `×0.8` if moving toward the target (improving)
- `×1.0` if stable or unknown

```r
direction_modifier <- function(latest, baseline, lower, upper) {
  if (any(is.na(c(latest, baseline, lower, upper)))) return(1.0)
  if (latest < lower) {
    if (latest < baseline) return(1.2)  # dropping further below floor
    if (latest > baseline) return(0.8)  # rising toward floor
  } else if (latest > upper) {
    if (latest > baseline) return(1.2)  # rising further above ceiling
    if (latest < baseline) return(0.8)  # falling toward ceiling
  }
  1.0
}
```

### 3. Range-width normalization (MANDATORY when combining disparate units)

**Scale distance by the width of its acceptable range** so components with different units are comparable in the same sum.

```
If value < lower:  (lower - value) / (upper - lower)
If value > upper:  (value - upper) / (upper - lower)
If within range:   0
```

Without this, `creatinine_distance` in `µmol/L` (range 60–110) can't be added to `haemoglobin_distance` in `g/L` (range 130–170) meaningfully — the units dominate.

## Worked Example

Two metrics, same latest value direction:

| Metric | Value | Range | Raw distance | Normalised | Surprise | Dir | Abnormal | Final |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| CPU % | 45 | 20–70 | 0 (in range) | 0 | 4.3 (jittery) | ×1 | ×0.1 | **0.26** |
| Disk free % | 8 | >15 | 7 | 1.0 | 1.1 | ×1.2 (worsening) | ×1.0 | **1.06** |

Disk correctly outranks CPU even though CPU has higher raw surprise.

## Weight Choices

- Start with `w_distance = 0.4`, `w_surprise = 0.6` — biases toward trend over static position
- Expose as tunable parameters; do not hardcode
- Document the choice with a rationale in the project's scoring spec

## Recency

Multiply the whole composite by a recency weight (see `half-life-decay` rule for the correct formula). Stale alerts fade.

```r
score <- (w_distance * distance + w_surprise * surprise_adj) * recency
```

## Interpretation Tiers

Once scored, bucket for triage. Typical thresholds:

| Score | Tier | Typical pattern |
|---|---|---|
| > 0.8 | High | Out of bounds AND sudden change |
| 0.4 – 0.8 | Medium | Moderately out of bounds OR moderately surprising while abnormal |
| 0 – 0.4 | Low | Mildly abnormal, stable abnormal, or in-bounds but noisy |
| 0 | Normal | In bounds, consistent with baseline |

Expose the tier as a factor column in any UI for filtering — users want "show me the high-urgency items", not "sort by score".

## Red Flags in Code Review

1. **No abnormality gate** — within-range jitter will outrank real problems
2. **Direction modifier missing or only as a tiebreaker** — should be multiplicative, not post-hoc
3. **Raw distance added across units** — apples + oranges in the same sum
4. **Weights hardcoded in the scoring function** — not tunable
5. **Score exposed to users without tier buckets** — they'll sort by score, not filter by urgency
6. **Surprise computed with SD on outlier-prone data** — see `robust-statistics` rule

## Related
- `robust-statistics` — use MAD not SD for the surprise component
- `half-life-decay` — correct recency weighting
- `data-validation-timeseries` — windowing and freshness
- `statistical-reporting` — confidence intervals on scores
