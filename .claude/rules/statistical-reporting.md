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

## Checklist

- [ ] Effect sizes reported before p-values with CIs
- [ ] Multiple comparisons adjusted (or single pre-specified test)
- [ ] Numeric precision follows table above
- [ ] Exploratory vs confirmatory clearly labelled
- [ ] Model assumptions checked and reported
- [ ] All numbers from code (no hardcoded statistics)
