---
name: survival-reporting
description: "Mandatory reporting standards for every survival curve, hazard ratio, median survival, and log-rank result published in a vignette, dashboard, or report. Extends statistical-reporting."
type: rule
paths:
  - "**/*.qmd"
  - "vignettes/**"
  - "analysis/**"
  - "explorations/**"
---
# Rule: Survival Reporting

## When This Applies

Every survival curve, hazard ratio (HR), median survival estimate, or log-rank
p-value that appears in a vignette, dashboard panel, report, or PR description.
Applies to both interactive (Shiny/Quarto) and static outputs.

Extends `statistical-reporting`. Where both rules apply, this rule is the more
specific one — follow both.

---

## CRITICAL: Effect size with every p-value

A log-rank p-value alone is uninterpretable. It answers "are the curves different?"
not "how different, and in which direction?". The hazard ratio quantifies the effect.

> Report HR + 95% CI + p-value together, always.

---

## Mandatory reporting table

| When you report | Must include |
|---|---|
| A survival curve | KM with 95% CI band; at-risk table beneath; censoring tick marks on the curve |
| A hazard ratio | HR + 95% CI + Wald p-value + reference category named explicitly + proportional-hazards check noted (Schoenfeld residuals via `cox.zph()`) |
| Median survival | Median + 95% CI; write "not reached" (not NA, not blank) when the curve does not cross 0.5 |
| Group comparison | Log-rank p-value AND HR + 95% CI — never p-value alone |
| Multiple group comparisons | Adjust log-rank p-values with `p.adjust(ps, "holm")` before reporting |

---

## Minimum figure requirements for any published survival plot

Every survival figure must have:

1. **CI band** around the survival curve (not just the point estimate line)
2. **At-risk table** immediately beneath the figure (use `risk.table = TRUE` in
   `survminer::ggsurvplot()`)
3. **Censoring tick marks** on the curve at each censored time point
4. **Units** on the x-axis label (days, hours, etc.)
5. **Caption** with dynamic values: n, events, median + CI

```r
# Compliant ggsurvplot call
ggsurvplot(
  fit,
  data        = df,
  conf.int    = TRUE,
  conf.type   = "log-log",    # respects (0,1) boundaries
  risk.table  = TRUE,
  censor      = TRUE,         # tick marks
  xlab        = "Days",
  caption     = paste0(
    "n = ", n_total, "; events = ", n_events,
    "; median = ", median_surv, " days (95% CI ", ci_lo, "–", ci_hi, ")"
  )
)
```

---

## Hazard ratio reporting format

```
HR = 1.4 (95% CI 1.1–1.9; p = 0.008; reference: llm repo)
Proportional hazards: Schoenfeld residuals global p = 0.34 (assumption met)
```

If proportional hazards is violated (global Schoenfeld p < 0.05), state this
explicitly and report the appropriate alternative (stratified Cox, time-interaction
term, or parametric model).

---

## "Not reached" convention

When a KM curve does not cross the 0.5 probability threshold, the median survival
is undefined within the follow-up window. Report it as **"not reached"**, not as
`NA`, `Inf`, or blank. Include the largest observed event time as context:

> "Median time-to-close: not reached (largest observed: 142 days; 38% of items
> still open at snapshot)"

---

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| KM curve without at-risk table | Reader cannot judge n at each time point | Add `risk.table = TRUE` |
| KM curve without CI band | Single line conceals uncertainty | Add `conf.int = TRUE` |
| HR without CI | Effect size without precision is uninterpretable | Report HR + 95% CI |
| "not significant" without effect size | Absence of evidence ≠ evidence of absence | Always report HR + CI |
| Median = `NA` or blank when curve doesn't cross 0.5 | Ambiguous — is it missing or not reached? | Write "not reached" |
| Log-rank p without HR | No effect size | Add HR from `coxph()` |
| Unadjusted p-values for >2 group comparison | Multiple testing inflation | Use `p.adjust(ps, "holm")` |
| Dropping censored rows before analysis | Biases all summary statistics downward | Include censored rows with `event = 0` |
| Colour as sole arm differentiator | Fails accessibility (colour-blind users) | Use BOTH colour AND line type |

---

## Related

- `statistical-reporting` — parent rule; effect size before p-value, numeric precision
- `survival-analysis` skill — the workflow rule implements; step-by-step code
- `narrative-evidence-block` — methodology block in vignettes must name survival data sources
- `dynamic-prose-values` — n, events, median, CI in captions must be R expressions, not hardcoded
- `accessibility` — 4.5:1 contrast for CI bands; line type + colour for arm differentiation
- `dashboard-table-styling` — at-risk tables follow right-justify, width-auto rules
