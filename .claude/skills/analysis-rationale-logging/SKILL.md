# Analysis Rationale Logging

## Description

Document *why* analysis decisions were made, not just *what* was done. This skill addresses the "garden of forking paths" problem by creating an audit trail of modeling choices, alternatives considered, and rationale. Our existing logging (`project-telemetry`) captures technical execution; this captures scientific reasoning.

## Purpose

Use this skill when:
- Making decisions during statistical analysis
- Choosing between modeling approaches
- Handling data issues (outliers, missingness, transformations)
- Separating exploratory from confirmatory analysis
- Preparing analysis for peer review or replication

## Why This Matters

From Gelman's workflow: "Practical workflow includes all sorts of things that aren't written down."

The problem: You can perfectly document *what* commands ran while hiding *why* you chose that path over alternatives. Retrospective rationalization is easy; prospective documentation is hard but valuable.

**Goal:** If someone asks "why did you do X instead of Y?", the answer is already written down—ideally *before* you saw the results of X.

## The Rationale Log Structure

### File Location

```
project/
├── analysis/
│   ├── 01_eda.qmd
│   ├── 02_models.qmd
│   └── rationale/           # Decision logs
│       ├── DECISIONS.md     # Master decision log
│       ├── 2026-01-08_outlier_handling.md
│       └── 2026-01-09_model_selection.md
└── _targets.R
```

### Master Decision Log (DECISIONS.md)

```markdown
# Analysis Decision Log

## Project: [Name]
## Analysis Goal: [One sentence]

---

## Decision Index

| # | Date | Decision | Category | Rationale Link |
|---|------|----------|----------|----------------|
| 1 | 2026-01-08 | Drop 3 outliers | Data cleaning | [Link](#d1) |
| 2 | 2026-01-08 | Log-transform outcome | Transformation | [Link](#d2) |
| 3 | 2026-01-09 | Use mixed model | Model selection | [Link](#d3) |
| 4 | 2026-01-09 | Include interaction | Model specification | [Link](#d4) |

---

## Decisions

### D1: Outlier Handling {#d1}

**Date:** 2026-01-08
**Status:** Confirmed (sensitivity analysis done)

**Decision:** Remove 3 observations with income > $10M

**Alternatives Considered:**
1. Keep all data (rejected: likely data entry errors)
2. Winsorize at 99th percentile (rejected: still influential)
3. Robust regression (considered but outliers are errors, not real)

**Rationale:**
- Values are 100x larger than next highest
- Checked source: confirmed transcription errors
- Domain expert confirms these are implausible

**Sensitivity:** Results qualitatively similar with/without (see `sensitivity/outliers.R`)

**Decided BEFORE seeing:** Main regression results
**Decided AFTER seeing:** EDA plots showing extreme values

---

### D2: Log Transformation {#d2}

**Date:** 2026-01-08
**Status:** Confirmed

**Decision:** Log-transform income (outcome variable)

**Alternatives Considered:**
1. No transformation (rejected: severe right skew)
2. Square root (rejected: still skewed)
3. Box-Cox optimal (λ ≈ 0, so log is appropriate)

**Rationale:**
- Income is multiplicative (% changes meaningful)
- Log-normality is common assumption for income
- Residuals more homoscedastic after transform

**Decided BEFORE seeing:** Regression coefficients
**Decided AFTER seeing:** Distribution plots in EDA

---

### D3: Model Selection {#d3}

**Date:** 2026-01-09
**Status:** Confirmed

**Decision:** Use mixed-effects model with random intercepts by region

**Alternatives Considered:**
1. OLS with clustered SEs (rejected: ignores structure)
2. Fixed effects by region (rejected: too many parameters)
3. Bayesian hierarchical (considered: similar results, chose frequentist for audience)

**Rationale:**
- Data has clear hierarchical structure (people nested in regions)
- ICC = 0.15 suggests meaningful clustering
- Mixed model appropriately partitions variance

**Pre-registered:** No
**Exploratory:** Yes—this emerged from EDA, not planned

---
```

## Decision Categories

### 1. Data Cleaning Decisions

```markdown
### Template: Data Cleaning Decision

**Decision:** [What you did]
**Variable(s) affected:** [Which columns]
**Rows affected:** [N rows, % of data]

**Alternatives Considered:**
1. [Alternative 1] - [Why rejected]
2. [Alternative 2] - [Why rejected]

**Rationale:** [Why this choice]
**Domain justification:** [Expert input if any]
**Sensitivity check:** [Did results change?]
```

### 2. Transformation Decisions

```markdown
### Template: Transformation Decision

**Decision:** [Transform applied]
**Variable(s):** [Which columns]

**Diagnostic that motivated this:**
- [Plot/test that showed need for transform]

**Alternatives Considered:**
1. [No transform] - [Why rejected: residual plots]
2. [Other transform] - [Why rejected]

**Interpretation impact:** [How coefficients now interpreted]
```

### 3. Model Specification Decisions

```markdown
### Template: Model Specification Decision

**Decision:** [Model form chosen]

**Specification:** `outcome ~ predictor + covariate + (1|group)`

**Alternatives Considered:**
1. [Simpler model] - [Why rejected: poor fit]
2. [More complex model] - [Why rejected: overfit/convergence]
3. [Different functional form] - [Why rejected]

**Selection criteria used:**
- [ ] AIC/BIC: [Values]
- [ ] Cross-validation: [Results]
- [ ] Residual diagnostics: [Assessment]
- [ ] Domain knowledge: [Justification]

**This decision was:**
- [ ] Pre-registered
- [ ] Planned but not registered
- [ ] Exploratory (emerged from data)
```

### 4. Subgroup/Interaction Decisions

```markdown
### Template: Subgroup Decision

**Decision:** [Include/exclude interaction or subgroup analysis]

**Motivated by:**
- [ ] Pre-specified hypothesis
- [ ] EDA suggested heterogeneity
- [ ] Reviewer requested
- [ ] Post-hoc exploration

**If exploratory:**
- Multiple comparison adjustment: [Method used]
- Interpretation caveat: [Added to manuscript]

**Alternatives:**
1. [No subgroup] - [Why insufficient]
2. [Different subgroups] - [Why not chosen]
```

## Integration with R Workflow

### Logging Decisions in Code

```r
# R/analysis/helpers.R

#' Log an analysis decision
#'
#' @param decision Short description
#' @param category One of: cleaning, transform, model, subgroup, other
#' @param rationale Why this choice
#' @param alternatives Named list of alternatives considered
#' @param decided_before What you knew when deciding
#' @param decided_after What you saw that prompted the decision
log_decision <- function(
  decision,
  category = c("cleaning", "transform", "model", "subgroup", "other"),
  rationale,
  alternatives = list(),
  decided_before = NULL,
  decided_after = NULL,
  file = "analysis/rationale/DECISIONS.md"
) {
  category <- match.arg(category)
  timestamp <- Sys.time()

entry <- glue::glue("
### {decision}

**Date:** {format(timestamp, '%Y-%m-%d %H:%M')}
**Category:** {category}

**Rationale:** {rationale}

**Alternatives Considered:**
{paste(names(alternatives), alternatives, sep = ': ', collapse = '\n')}

**Decided BEFORE seeing:** {decided_before %||% 'Not recorded'}
**Decided AFTER seeing:** {decided_after %||% 'Not recorded'}

---
")

  cat(entry, file = file, append = TRUE)
  invisible(entry)
}
```
### Usage in Analysis Script

```r
# analysis/02_models.R

library(logger)

# Log the decision BEFORE running the analysis
log_decision(
  decision = "Use robust standard errors",
  category = "model",
  rationale = "Residual plots show heteroscedasticity",
  alternatives = list(
    "WLS" = "Rejected: weight function unclear",
    "Transform Y" = "Rejected: already log-transformed",
    "Bootstrap" = "Considered: similar results, chose robust for speed"
  ),
  decided_before = "Coefficient estimates",
  decided_after = "Residual vs fitted plot"
)

# NOW run the analysis
model <- lm(log_income ~ education + experience, data = clean_data)
robust_se <- sandwich::vcovHC(model, type = "HC3")
coeftest(model, vcov = robust_se)
```

### Integration with targets

```r
# _targets.R
library(targets)

list(
  # EDA phase - decisions logged here
  tar_target(eda_decisions, {
    log_decision(
      "Remove income outliers > $10M",
      category = "cleaning",
      rationale = "Confirmed data entry errors",
      alternatives = list(
        "Keep" = "Rejected: 100x larger than plausible",
        "Winsorize" = "Rejected: errors should be removed not trimmed"
      ),
      decided_after = "EDA boxplot and source verification"
    )
  }),

  # Data cleaning - implements logged decisions
  tar_target(clean_data, {
    raw_data |>
      filter(income < 10e6)  # Decision D1
  }),

  # Model - decision logged before fitting
  tar_target(model_decision, {
    log_decision(
      "Mixed model with random intercepts",
      category = "model",
      rationale = "ICC = 0.15 indicates clustering",
      alternatives = list(
        "OLS + cluster SE" = "Rejected: doesn't model structure",
        "Fixed effects" = "Rejected: 50 regions, too many params"
      ),
      decided_before = "Model coefficients",
      decided_after = "ICC calculation"
    )
  }),

  tar_target(model, {
    lme4::lmer(log_income ~ education + (1|region), data = clean_data)
  })
)
```

## Pre-Registration Integration

```markdown
## Pre-Registered vs Exploratory Analysis

### Pre-Registered (from registration document)

| Analysis | Registration | Decision Log Entry |
|----------|--------------|-------------------|
| Primary outcome: income | PAP Section 3.1 | D2 (confirmed) |
| Main predictor: education | PAP Section 3.2 | D3 (confirmed) |
| Covariates: age, gender | PAP Section 3.3 | D5 (confirmed) |

### Exploratory (emerged from data)

| Analysis | Motivation | Decision Log Entry | Multiple Testing |
|----------|------------|-------------------|------------------|
| Region interaction | EDA showed heterogeneity | D7 | Bonferroni adjusted |
| Nonlinear age effect | Residual patterns | D8 | Noted as exploratory |

### Deviations from Pre-Registration

| Original Plan | Actual | Rationale | Decision Log |
|---------------|--------|-----------|--------------|
| OLS regression | Mixed model | Clustering discovered | D3 |
| Complete cases | Multiple imputation | 15% missing, not MCAR | D4 |
```

## Anti-Patterns

```r
# ❌ NO RATIONALE: Just do things
data_clean <- data |> filter(income < 1e6)  # Why 1e6?

# ✅ LOGGED RATIONALE
log_decision("Cap income at $1M", rationale = "99th percentile, reduces influence")
data_clean <- data |> filter(income < 1e6)

# ❌ RETROSPECTIVE RATIONALIZATION
# (After seeing results favor your hypothesis)
# "We chose robust SE because of heteroscedasticity"

# ✅ PROSPECTIVE DOCUMENTATION
# (Before seeing results)
log_decision(..., decided_before = "coefficient p-values")
# THEN run analysis

# ❌ HIDDEN FORKING PATHS
# Try 5 models, report the one that "worked"

# ✅ DOCUMENTED EXPLORATION
log_decision("Model 3 (with interaction)",
  alternatives = list(
    "Model 1 (main effects)" = "AIC: 1234, poor fit",
    "Model 2 (quadratic)" = "AIC: 1230, convergence issues",
    "Model 4 (three-way)" = "AIC: 1228, overfit"
  ))
```

## Related Skills

- `eda-workflow` - EDA decisions feed into this log
- `project-telemetry` - Technical logging (complements rationale logging)
- `r-package-workflow` - Step 9 logs commands; this logs reasoning
- `verification-before-completion` - Evidence before claims

## Resources

- [Garden of Forking Paths (Gelman & Loken)](http://www.stat.columbia.edu/~gelman/research/unpublished/forking.pdf)
- [Pre-registration templates](https://osf.io/registries)
- [Multiverse analysis](https://journals.sagepub.com/doi/10.1177/1745691616658637)
- [Specification curve analysis](https://www.nature.com/articles/s41562-020-0912-z)
