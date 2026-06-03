---
name: survival-analysis
description: "Use when performing time-to-event analysis where censoring matters: PR merge time, issue close time, finding resolution, CI recovery. Triggers: survival analysis, KM curve, Kaplan-Meier, hazard ratio, censored data, time-to-event, TTE, coxph, flexsurv, ggsurvplot."
metadata:
  type: skill
---
# Survival Analysis

## When to use this skill

Use when the outcome is the **time until an event** and some observations may never
experience that event (censored). The classic failure mode is analysing censored
times as if they were fully observed — this biases every summary statistic downward.

**Apply this skill when:**

- Computing time-to-PR-merge, time-to-issue-close, time-to-finding-resolution
- Comparing resolution rates across repos, agent types, or severity tiers
- Asking "what fraction never resolve?" or "when does the median tail thin out?"
- Fitting parametric models to describe hazard shape over time

**Do NOT use when:**

- Every observation experiences the event before the analysis window closes (no censoring)
- The "time" variable is a fixed period (e.g. daily count, not a duration to event)
- You only care about proportions, not timing

---

## Baseline-first workflow

Mirror the `modeling-baselines` principle: always fit the simplest adequate model
before reaching for complexity.

### Step 1 — Kaplan-Meier (non-parametric baseline)

KM makes no distributional assumptions. Always start here.

```r
library(survival)
library(survminer)

# Build the Surv object — event column is 1 = event occurred, 0 = censored
surv_obj <- Surv(time = df$days_to_close, event = df$closed)

# Overall KM curve
km_fit <- survfit(surv_obj ~ 1, data = df)

# Stratified KM
km_strat <- survfit(surv_obj ~ repo, data = df)

# Plot with CI band + at-risk table + censoring marks (all three are mandatory)
ggsurvplot(
  km_strat,
  data        = df,
  conf.int    = TRUE,
  conf.type   = "log-log",   # log-log transformation respects (0,1) boundaries
  risk.table  = TRUE,
  censor      = TRUE,
  palette     = PALETTE,     # use project palette — narrative-colour-persistence rule
  xlab        = "Days",
  ylab        = "Probability of remaining open",
  legend.labs = levels(df$repo)
)
```

`conf.type = "log-log"` is the default for `ggsurvplot` in recent survminer. Prefer
it over `"plain"` because plain CIs can exceed (0, 1) near boundaries.

### Step 2 — Cox proportional hazards (semi-parametric)

Cox requires no shape assumption for the baseline hazard. It IS parametric in the
covariate effects (linear log-hazard). Fit it before any fully parametric model.

```r
cox_fit <- coxph(
  Surv(days_to_close, closed) ~ repo + severity + agent_type,
  data = df,
  ties = "efron"   # Efron is preferred for tied event times
)

summary(cox_fit)  # reports HR + CI + Wald test for each covariate

# MANDATORY: test the proportional hazards assumption
cox_zph_result <- cox.zph(cox_fit)
print(cox_zph_result)       # global test + per-covariate test
plot(cox_zph_result)        # Schoenfeld residuals — should be flat over time
```

If `cox.zph()` global p < 0.05, the proportional hazards assumption is violated.
Options: stratify by the offending variable, add a time-interaction term, or switch
to a parametric model.

### Step 3 — Parametric models (when shape matters)

Fit parametric models when you need to extrapolate beyond observed follow-up, or
when the hazard shape itself is of interest.

```r
library(flexsurv)

# Start with simplest: exponential (constant hazard)
fit_exp  <- flexsurvreg(Surv(days_to_close, closed) ~ repo, data = df,
                        dist = "exponential")

# Weibull allows monotone increasing/decreasing hazard
fit_wb   <- flexsurvreg(Surv(days_to_close, closed) ~ repo, data = df,
                        dist = "weibull")

# Gompertz allows accelerating hazard (common in biological/organisational processes)
fit_gomp <- flexsurvreg(Surv(days_to_close, closed) ~ repo, data = df,
                        dist = "gompertz")

# Compare by AIC (lower = better fit penalised for complexity)
AIC(fit_exp, fit_wb, fit_gomp)

# Overlay parametric fits on KM curve to check visual agreement
plot(km_fit)
lines(fit_wb, col = "steelblue", lty = 2)
```

Pick the parametric distribution with the lowest AIC **and** a plausible hazard
shape for your domain. For software events (issues, PRs), a Weibull with decreasing
hazard (shape < 1) often fits — early-stage items close fast; long-running ones slow.

---

## Confidence intervals — three flavours

| Type | What it covers | Recommended for |
|------|---------------|-----------------|
| **Pointwise** | S(t) at each time point separately | Dashboards, single-arm curves |
| **Hall-Wellner band** | Entire curve simultaneously | Formal inference, regulatory |
| **Equal-precision band** | Curve simultaneously, narrower near median | Publication figures |

For dashboards: pointwise CIs (`conf.type = "log-log"` in `survfit`). For formal
reporting where you claim anything about the whole curve shape, use simultaneous bands
via `km.ci::km.ci()`.

---

## Group comparisons

Log-rank test compares survival curves across groups. ALWAYS pair it with a hazard
ratio.

```r
# Log-rank test
survdiff(Surv(days_to_close, closed) ~ repo, data = df)

# Hazard ratio (from Cox, one covariate)
cox_single <- coxph(Surv(days_to_close, closed) ~ repo, data = df)
exp(coef(cox_single))          # HR
exp(confint(cox_single))       # 95% CI on HR
```

Report both: "Log-rank p = 0.02; HR for `llmtelemetry` vs `llm` = 1.4 (95% CI 1.1–1.9)".
A log-rank p without an HR is uninterpretable for effect size.

Multiple comparisons: if you compare > 2 groups, adjust log-rank p-values via
`p.adjust(ps, "holm")` before reporting.

---

## Visual checks

Every survival analysis requires at minimum:

1. **KM curve with CI band and at-risk table** — see Step 1 above
2. **Schoenfeld residuals** — confirms proportional hazards for any Cox model
3. **Parametric overlay on KM** — confirms chosen distribution fits

For the hazard function directly:

```r
library(muhaz)

# Kernel-smoothed hazard estimate
haz <- muhaz(df$days_to_close, df$closed)
plot(haz)
```

---

## Visual predictive checks for parametric models

When you fit a parametric model, overlay simulated survival curves from the fitted
distribution on the observed KM curve. If the model fits, they should track closely.

```r
# flexsurv provides this directly
plot(fit_wb, ci = TRUE, col = "steelblue")
lines(km_fit, conf.int = FALSE, col = "black", lty = 1)
legend("topright", c("Kaplan-Meier", "Weibull fit"),
       col = c("black", "steelblue"), lty = c(1, 2))
```

For parametric TTE models, `vpc::vpc_tte()` produces a VPC with prediction
intervals. Use it when extrapolating beyond the observation window.

---

## Censoring discipline

Careless censoring encoding is the most common TTE data quality failure.

**Mandatory column convention:**

| Column | Type | Meaning |
|--------|------|---------|
| `time_to_event` | numeric (days/hours) | Duration from origin to event or censoring |
| `event` | integer 0/1 | 1 = event occurred; 0 = censored |
| `censor_reason` | character | Why censored: `"still_open"`, `"snapshot_date"`, `"deleted"` |

**Never:**
- Combine event and censor reason in a single coded column
- Impute a censoring time (e.g. assign `time_to_event = max_follow_up` for open items without recording why)
- Drop censored observations (this is NOT how you "clean" TTE data)

```r
# WRONG: drop open items
df |> filter(closed == 1)  # discards all right-censored observations

# RIGHT: include all rows, set event = 0 for open items
df |>
  mutate(
    event        = as.integer(!is.na(closed_at)),
    time_days    = coalesce(
      as.numeric(closed_at - created_at, units = "days"),
      as.numeric(snapshot_date - created_at, units = "days")
    ),
    censor_reason = if_else(event == 1L, NA_character_, "still_open_at_snapshot")
  )
```

---

## Reporting checklist

For every survival result published in a vignette, dashboard, or PR:

- [ ] KM curve shown with 95% CI band (not just the median line)
- [ ] At-risk table beneath the curve
- [ ] Censoring tick marks visible on the curve
- [ ] Median survival + 95% CI stated; "not reached" when curve does not cross 0.5
- [ ] For any group comparison: log-rank p AND HR + 95% CI
- [ ] Reference category named explicitly when reporting HR
- [ ] Schoenfeld residuals checked (and result noted) for any Cox model
- [ ] Units stated (days, hours, etc.)

See `survival-reporting` rule for the full mandatory table.

---

## llmtelemetry use cases

Five TTE outcomes in llmtelemetry data with natural survival framing:

| Outcome | Origin | Event | Censoring |
|---------|--------|-------|-----------|
| PR merge time | `created_at` | `merged_at` set | PR still open |
| Issue close time | `created_at` | `closed_at` set | Issue still open |
| Finding resolution | `found_at` | `resolved_at` set | Finding still open |
| CI fix after failure | First red build | Next green build | Branch still red |
| Session completion | Session start | `/bye` event | Context-compacted |

Sketch for PR merge time survival curve:

```r
# Assumes df has columns: pr_number, created_at, merged_at, repo, snapshot_date
pr_surv <- df |>
  mutate(
    event     = as.integer(!is.na(merged_at)),
    time_days = coalesce(
      as.numeric(merged_at - created_at, units = "days"),
      as.numeric(snapshot_date - created_at, units = "days")
    )
  )

km_pr <- survfit(Surv(time_days, event) ~ repo, data = pr_surv)

ggsurvplot(
  km_pr, data = pr_surv,
  conf.int = TRUE, conf.type = "log-log",
  risk.table = TRUE, censor = TRUE,
  xlab = "Days since PR opened", ylab = "Probability unmerged",
  palette = PALETTE
)
```

The y-axis label "Probability unmerged" is deliberately informative — it reads as
"what fraction are still unmerged at day X", which is what 1 − S(t) answers from the
analyst's perspective when S(t) is the survival function.

---

## Related

- `modeling-baselines` — the parallel "baseline-first" principle; KM is the TTE baseline
- `model-evaluation-calibration` — would extend with concordance index (C-statistic) for Cox
- `survival-reporting` rule — mandatory reporting table for every published survival result
- `narrative-colour-persistence` — same arm MUST use same colour across all survival panels
- `hover-popup-standard` — arm-level tooltips showing N, events, censored
- `accessibility` — survival curves with CI bands require 4.5:1 contrast; arms differentiated
  by BOTH line type AND colour, never colour alone
- `statistical-reporting` rule — parent rule covering effect size, multiple comparisons
