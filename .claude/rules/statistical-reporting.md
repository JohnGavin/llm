---
paths:
  - "R/**"
  - "vignettes/**"
  - "*.qmd"
---
# Statistical Reporting Standards

Mandatory standards for reporting statistical results. Prevents p-hacking, ensures reproducibility of inference, and enforces honest uncertainty quantification.

## 1. Effect Sizes BEFORE p-values (MANDATORY)

Every statistical test MUST report:
1. **Effect size** with confidence interval (primary result)
2. **p-value** (secondary, for convention only)
3. **Sample size** (always)

```r
# WRONG: p-value only
t.test(x, y)$p.value  # 0.023

# RIGHT: effect size + CI + p-value + n
result <- t.test(x, y)
list(
  mean_diff = diff(result$estimate),
  ci_95 = result$conf.int,
  p_value = result$p.value,
  n = length(x) + length(y)
)
```

## 2. Multiple Comparisons (MANDATORY)

When testing >1 hypothesis on the same data, MUST adjust p-values:

| Method | When | R Function |
|--------|------|-----------|
| Bonferroni | Conservative, few tests | `p.adjust(p, "bonferroni")` |
| Holm | Default choice | `p.adjust(p, "holm")` |
| BH (FDR) | Many tests, discovery focus | `p.adjust(p, "BH")` |

**FORBIDDEN:** Reporting unadjusted p-values from multiple tests without disclosure.

## 3. Numeric Precision (MANDATORY)

| Statistic | Decimal Places | Example |
|-----------|---------------|---------|
| p-value | 3 (or "< 0.001") | p = 0.023 |
| Effect size | 2 | d = 0.45 |
| Percentage | 1 | 73.2% |
| Confidence interval | 2 | [0.12, 0.78] |
| Correlation | 2 | r = 0.67 |
| Count | 0 | N = 1,247 |

**FORBIDDEN:** `p = 0.0000234` (use `p < 0.001`). `r = 0.6666666667` (use `r = 0.67`).

## 4. Exploratory vs Confirmatory (MANDATORY)

Every analysis vignette MUST label sections as:
- **Confirmatory:** Pre-specified hypothesis, defined before seeing data
- **Exploratory:** Generated after seeing data, hypothesis-generating

**FORBIDDEN:** Presenting exploratory findings as confirmatory without disclosure.

## 5. Model Reporting Checklist

Every fitted model MUST report:
- [ ] Sample size (total and per group if applicable)
- [ ] Model specification (formula, family, link)
- [ ] Effect sizes with CIs (not just coefficients)
- [ ] Goodness of fit (R², AIC, deviance — as appropriate)
- [ ] Assumption checks (residual plots, overdispersion, VIF)
- [ ] Sensitivity analysis or robustness check (at least one)

## 6. Dynamic Values Only (see `reproducible-visualization` rule)

All reported numbers MUST come from code, never hardcoded:
```r
# WRONG: "The mean was 42.3"
# RIGHT: paste0("The mean was ", round(mean(x), 1))
```

## 7. Structured Experiment Commit Messages (MANDATORY for modelling)

When committing model experiments, use a machine-parseable format so progress can be tracked programmatically via `git log --grep`:

```
experiment: <short description>

metric: <value> +/- <std> (prev: <prev_value> +/- <std>)
delta: <signed change>
phase: <1-hyperparams|2-mechanism|3-architecture|4-advanced>
changed: <param>=<new> (was <old>)
verdict: COMMIT|REVERT
```

Example:
```
experiment: increase projection dim 256→512

metric: mean_rank 157.4 +/- 8.2 (prev: 187.1 +/- 9.5)
delta: -29.7
phase: 3-architecture
changed: PROJ_DIM=512 (was 256)
verdict: COMMIT
```

**Parse with:** `git log --grep="^metric:" --format="%s%n%b" | grep "^metric:\|^delta:"`

## 8. False Positive Risk (MANDATORY when reporting p-values)

A p-value is P(data | H₀). What you want is P(H₀ | data). These are NOT the same — confusing them is the "transposed conditional" error (Colquhoun 2019).

**p = 0.05 does NOT mean 5% false positive risk.** At a 50/50 prior, p = 0.05 corresponds to a **26–30% false positive risk** (FPR). At a low prior (implausible hypothesis), it's **76%**.

| Observed p-value | FPR (prior = 0.5) | FPR (prior = 0.1) | Likelihood ratio |
|---|---|---|---|
| 0.05 | 26–30% | 76% | ~3 |
| 0.01 | ~11% | ~50% | ~10 |
| 0.001 | ~1% | ~8% | ~100 |

### Required reporting format

When a p-value is reported, ALSO state the false positive risk:

```r
# RIGHT:
# "The increase was 1.88 ± 0.85 (SEM), CI [0.06, 3.7], p = 0.043.
#  This implies FPR ≈ 18% (prior = 0.5), so the result is suggestive
#  rather than conclusive."

# WRONG:
# "The result was statistically significant (p < 0.05)."
```

### Tools

- **Web calculator**: http://www.onemol.org.uk/?page_id=456
- **R scripts**: provided with Colquhoun (2014, 2017, 2019) papers
- **Formula**: FPR = 1 / (1 + likelihood_ratio × prior_odds)

### References

- Colquhoun D (2019). "The False Positive Risk: A Proposal Concerning What to Do About p-Values." *The American Statistician* 73(sup1).
- Sellke T, Bayarri MJ, Berger JO (2001). "Calibration of p Values for Testing Precise Null Hypotheses." *The American Statistician* 55:62–71.
- Benjamin D & Berger JO (2018). "Three Recommendations for Improving the Use of p-Values." *The American Statistician*.

## 9. Never Say "Significant" (MANDATORY)

**FORBIDDEN** in all prose (vignettes, captions, commit messages, issues, emails):
- "statistically significant"
- "non-significant"
- "significant at p < 0.05"
- Asterisks for significance levels (*, **, ***)

**Required instead**: Report the p-value, effect size with CI, and FPR. Replace "significant at p < 0.05" with "p = 0.03 (FPR ≈ 22% at equipoise prior, suggestive)".

**Why**: The word "significant" implies clinical/practical importance, which p-values do not measure. A significant result (p < 0.05) can have a 30% chance of being false. An insignificant result (p = 0.08) may reflect a real but underpowered effect. The word obscures both failure modes.

**Exception**: When quoting another author's text verbatim (use `> "text"` blockquote format).

## 10. High-Power Tests Make Borderline p-Values WEAKER Evidence (Jeffreys-Lindley)

In high-power studies (large N, long time series, many observations), observing p ≈ 0.05 is actually evidence AGAINST the alternative hypothesis — because if the effect were real, high power would produce p << 0.05.

This is NOT a paradox: with 99% power, nearly all real effects produce very low p-values. Observing p = 0.05 means you're in the rare tail where real effects don't land — so the observation is more consistent with noise.

**Implication for backtesting**: A strategy tested on 20 years of daily data (very high power) that shows p = 0.04 provides WEAKER evidence of real alpha than the same p-value from 2 years of data. If alpha were real with that much data, you'd see p < 0.001.

**Implication for large-N sports modelling**: footbet has thousands of matches. A feature that shows p = 0.03 in a dataset with N = 10,000 is less convincing than the same p-value at N = 200. Report the effect size and FPR, not just the p-value.

## Checklist

- [ ] Effect sizes reported before p-values with CIs
- [ ] Multiple comparisons adjusted (or single pre-specified test)
- [ ] Numeric precision follows table above
- [ ] Exploratory vs confirmatory clearly labelled
- [ ] Model assumptions checked and reported
- [ ] All numbers from code (no hardcoded statistics)
- [ ] False positive risk reported alongside any p-value
- [ ] Word "significant" not used (replaced with p-value + FPR + effect size)
- [ ] High-power borderline-p caveat noted where applicable

## Related

- `half-life-decay` — time-decay weighting (common in backtesting)
- `robust-statistics` — MAD over SD for outlier-prone data
- `composite-alert-scoring` — uses scoring where FPR reasoning also applies
- `deslop` — catches "significant" in prose review
