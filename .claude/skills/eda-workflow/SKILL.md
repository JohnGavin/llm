# Exploratory Data Analysis Workflow

## Description

Systematic exploratory data analysis (EDA) that complements automated tools. This skill covers *what to look for* in data, not just *how to query it*. EDA is the critical human step that AI cannot automate—understanding data quality, identifying issues, and validating assumptions before modeling.

## Purpose

Use this skill when:
- Starting analysis of a new dataset
- Preparing data for statistical modeling
- Validating assumptions before fitting models
- Debugging unexpected model results
- AI has executed analysis but you need to verify data understanding

## Why This Matters

From Gelman's workflow discussion: AI handles execution well but fails at understanding data and specifying assumptions. Dale Lehman's insight: "The workflow I used with the AI consisted of the prompts I applied due to my prior analysis of the data."

**EDA is the critical path that remains human.**

## The EDA Checklist

### Phase 1: Data Structure

```r
library(dplyr)
library(skimr)
library(visdat)

# 1. First look
glimpse(data)
skim(data)

# 2. Visual overview of types and missingness
vis_dat(data)
vis_miss(data)

# 3. Check for structural issues
# - Duplicate rows
data |> duplicated() |> sum()

# - Unexpected factor levels
data |> select(where(is.factor)) |> sapply(levels)

# - Date parsing issues
data |> select(where(is.Date)) |> summary()
```

**Questions to answer:**
- [ ] What is each variable measuring?
- [ ] Are types correct (numeric vs character vs factor)?
- [ ] What's the grain of the data (one row = what)?
- [ ] Are there duplicates that shouldn't exist?

### Phase 2: Univariate Distributions

```r
library(ggplot2)

# Numeric variables
data |>
  select(where(is.numeric)) |>
  pivot_longer(everything()) |>
  ggplot(aes(value)) +
  geom_histogram(bins = 30) +
  facet_wrap(~name, scales = "free")

# Check for:
# - Unexpected zeros or negative values
# - Ceiling/floor effects
# - Multimodality
# - Heavy tails

# Categorical variables
data |>
  select(where(is.character)) |>
  pivot_longer(everything()) |>
  count(name, value) |>
  ggplot(aes(n, value)) +
  geom_col() +
  facet_wrap(~name, scales = "free")
```

**Questions to answer:**
- [ ] Any impossible values (negative ages, percentages > 100)?
- [ ] Suspicious spikes at round numbers?
- [ ] Expected range based on domain knowledge?
- [ ] Are categorical levels as expected?

### Phase 3: Missingness Patterns

```r
library(naniar)

# Missingness by variable
gg_miss_var(data)

# Missingness patterns (which variables are missing together)
gg_miss_upset(data)

# Is missingness related to other variables?
data |>
  mutate(outcome_missing = is.na(outcome)) |>
  group_by(treatment) |>
  summarise(pct_missing = mean(outcome_missing))
```

**Questions to answer:**
- [ ] Is missingness random or systematic?
- [ ] Does missingness correlate with key variables?
- [ ] Can missing values be imputed or must rows be dropped?
- [ ] What's the analysis sample after exclusions?

### Phase 4: Bivariate Relationships

```r
library(GGally)

# Correlation matrix for numeric variables
data |>
  select(where(is.numeric)) |>
  ggpairs()

# Key relationship: outcome vs predictors
ggplot(data, aes(x = predictor, y = outcome)) +
  geom_point(alpha = 0.3) +
  geom_smooth(method = "loess")

# Categorical predictors
ggplot(data, aes(x = group, y = outcome)) +
  geom_boxplot() +
  geom_jitter(alpha = 0.2, width = 0.2)
```

**Questions to answer:**
- [ ] Are relationships linear or nonlinear?
- [ ] Any obvious outliers driving correlations?
- [ ] Multicollinearity among predictors?
- [ ] Unexpected relationships that need explanation?

### Phase 5: Outliers and Influential Points

```r
library(performance)

# Statistical outliers
data |>
  select(where(is.numeric)) |>
  summarise(across(everything(), ~sum(abs(scale(.)) > 3, na.rm = TRUE)))

# Visual inspection
ggplot(data, aes(x = predictor, y = outcome)) +
  geom_point() +
  geom_text(
    data = data |> filter(abs(scale(outcome)) > 3),
    aes(label = id),
    hjust = -0.2
  )

# After fitting model: influential points
model <- lm(outcome ~ predictor, data = data)
check_outliers(model)
```

**Questions to answer:**
- [ ] Are outliers data errors or real extreme values?
- [ ] Do results change meaningfully if outliers removed?
- [ ] Are influential points driving the main finding?

### Phase 6: Assumption Checks (Pre-Modeling)

```r
# For linear regression
# - Normality of outcome (or residuals)
shapiro.test(data$outcome)
ggplot(data, aes(sample = outcome)) + stat_qq() + stat_qq_line()

# - Homoscedasticity preview
ggplot(data, aes(x = predictor, y = outcome)) +
  geom_point() +
  geom_smooth(method = "lm")

# For count data
# - Check for overdispersion
mean(data$count)
var(data$count)  # If var >> mean, overdispersed

# For time series
# - Autocorrelation
acf(data$outcome)
```

**Questions to answer:**
- [ ] What model family is appropriate?
- [ ] Are standard assumptions plausible?
- [ ] Do we need robust methods or transformations?

## EDA with DuckDB (Large Data)

```r
library(duckdb)
library(dplyr)
library(dbplyr)

con <- dbConnect(duckdb())

# Quick summaries without loading into memory
tbl(con, sql("SELECT * FROM read_parquet('large_data.parquet')")) |>
  summarise(
    n = n(),
    n_missing = sum(as.integer(is.null(outcome))),
    mean_outcome = mean(outcome, na.rm = TRUE),
    sd_outcome = sd(outcome, na.rm = TRUE),
    min_outcome = min(outcome, na.rm = TRUE),
    max_outcome = max(outcome, na.rm = TRUE)
  ) |>
  collect()

# Sample for detailed EDA
sample_data <- tbl(con, sql("
  SELECT * FROM read_parquet('large_data.parquet')
  USING SAMPLE 10000
")) |> collect()

# Now apply full EDA to sample
```

## Integration with targets

```r
# _targets.R
library(targets)

list(
  # Phase 1: Load and structure check
  tar_target(raw_data, read_data("data/raw.csv")),
  tar_target(data_summary, skimr::skim(raw_data)),


  # Phase 2-3: EDA report
  tar_target(
    eda_report,
    {
      rmarkdown::render(
        "analysis/01_eda.Rmd",
        params = list(data = raw_data)
      )
    },
    format = "file"
  ),

  # Phase 4: Document decisions
  tar_target(
    clean_data,
    raw_data |>
      filter(!is.na(outcome)) |>       # Decision: complete cases
      filter(age >= 18, age <= 100) |>  # Decision: plausible range
      mutate(income = winsorize(income, probs = c(0.01, 0.99)))
  ),

  # Continue to modeling...
  tar_target(model, fit_model(clean_data))
)
```

## Anti-Patterns

```r
# ❌ SKIP EDA: Jump straight to modeling
model <- lm(y ~ x, data = data)
summary(model)
# "Looks significant!"

# ✅ EDA FIRST: Understand before modeling
skim(data)
ggplot(data, aes(x, y)) + geom_point()
# "Wait, there's a ceiling effect at y = 100..."

# ❌ TRUST AI OUTPUT: Accept analysis without data checks
# AI: "The regression shows significant effect of X on Y"
# You: "Great, publish it!"

# ✅ VERIFY DATA UNDERSTANDING
# You: "What's the distribution of Y? Any missing data?
#       How did you handle the outliers I see in row 47?"

# ❌ ONE-SHOT EDA: Do EDA once at start, never revisit
# Model doesn't converge... debug for hours

# ✅ ITERATIVE EDA: Return to data when problems arise
# Model doesn't converge... check if weird values in that subset
```

## EDA Documentation Template

```markdown
## EDA Summary: [Dataset Name]

**Date:** YYYY-MM-DD
**Analyst:** [Name]

### Data Source
- File: `path/to/data.csv`
- N rows: X, N columns: Y
- Grain: One row = [what]

### Key Findings

1. **Missingness:** [X% missing in outcome, pattern is...]
2. **Outliers:** [Found N outliers in variable Z, decision: ...]
3. **Distributions:** [Variable W is bimodal, suggesting...]
4. **Relationships:** [X and Y correlated at r=0.8, possible confounder]

### Data Decisions Made

| Decision | Rationale | Rows Affected |
|----------|-----------|---------------|
| Drop rows with missing outcome | MCAR assumption reasonable | 5% |
| Winsorize income at 1%/99% | Extreme values likely errors | 2% |
| Log-transform Y | Right-skewed, variance stabilization | All |

### Assumptions for Planned Analysis

- [ ] Linearity: Checked via scatterplots, appears reasonable
- [ ] Normality: Outcome approximately normal after transform
- [ ] Independence: Time series—will need to check autocorrelation

### Open Questions

1. Why is missingness higher in treatment group?
2. Should we stratify by region given heterogeneity?
```

## Related Skills

- `data-wrangling-duckdb` - Tools for querying data (complements this skill)
- `analysis-rationale-logging` - Documenting decisions made during EDA
- `systematic-debugging` - Scientific method when EDA reveals problems
- `targets-vignettes` - Reproducible EDA pipelines

## Resources

- [R for Data Science: EDA](https://r4ds.hadley.nz/eda)
- [Exploratory Data Analysis (Tukey, 1977)](https://www.amazon.com/Exploratory-Data-Analysis-John-Tukey/dp/0201076160)
- [naniar package](https://naniar.njtierney.com/) - Missing data visualization
- [visdat package](https://docs.ropensci.org/visdat/) - Data structure visualization
- [skimr package](https://docs.ropensci.org/skimr/) - Quick summaries
