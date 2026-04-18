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

Format: `experiment: <desc>` subject, body with `metric:`, `delta:`, `phase:`, `changed:`, `verdict: COMMIT|REVERT`. Parse: `git log --grep="^metric:"`.

Example: `experiment: increase projection dim 256→512` / `metric: mean_rank 157.4 ± 8.2 (prev: 187.1)` / `verdict: COMMIT`

## 8. False Positive Risk (MANDATORY when reporting p-values)

p = 0.05 does NOT mean 5% false positive risk. At equipoise prior, FPR ≈ 26–30% (Colquhoun 2019). When reporting any p-value, ALSO state FPR: "p = 0.043, FPR ≈ 18% at equipoise, suggestive."

| p-value | FPR (prior=0.5) | FPR (prior=0.1) | LR |
|---|---|---|---|
| 0.05 | 26–30% | 76% | ~3 |
| 0.01 | ~11% | ~50% | ~10 |
| 0.001 | ~1% | ~8% | ~100 |

Formula: FPR = 1 / (1 + LR × prior_odds). Refs: Colquhoun 2019, Sellke 2001, Benjamin 2018.

## 9. Never Say "Significant" (MANDATORY)

**FORBIDDEN** in all prose (vignettes, captions, commit messages, issues, emails):
- "statistically significant"
- "non-significant"
- "significant at p < 0.05"
- Asterisks for significance levels (*, **, ***)

**Required instead**: Report the p-value, effect size with CI, and FPR. Replace "significant at p < 0.05" with "p = 0.03 (FPR ≈ 22% at equipoise prior, suggestive)".

**Why**: The word "significant" implies clinical/practical importance, which p-values do not measure. A significant result (p < 0.05) can have a 30% chance of being false. An insignificant result (p = 0.08) may reflect a real but underpowered effect. The word obscures both failure modes.

**Exception**: When quoting another author's text verbatim (use `> "text"` blockquote format).

## 10. High-Power Borderline p-Values Are WEAKER Evidence (Jeffreys-Lindley)

With high power (large N), observing p ≈ 0.05 is evidence AGAINST the alternative — if the effect were real, you'd see p << 0.05. A strategy on 20 years of data showing p = 0.04 is LESS convincing than p = 0.04 from 2 years. Report effect size and FPR, not just p.

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
