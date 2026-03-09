# Code Folding Rules: Detailed Examples

Extracted from SKILL.md. Contains full code examples for Rules 2-6 and Best Practices.

## RULE 2: All Outputs Must Display (REQUIRED)

**Every code chunk that produces output (graphs, tables, text) must show the output.**

### Correct: Show Output

```{r load-data}
# This code loads data
data <- read.csv("data.csv")
# Output will be shown
head(data)
```

```{r plot-example}
# Code is hidden by default, but plot ALWAYS shows
library(ggplot2)
ggplot(data, aes(x = var1, y = var2)) +
  geom_point() +
  theme_minimal()
# Plot is ALWAYS visible to users
```

### Correct: Table Output Always Visible

```{r summary-table}
library(knitr)
summary_stats <- data.frame(
  Variable = names(data),
  Mean = colMeans(data),
  SD = apply(data, 2, sd)
)
kable(summary_table, digits = 2)
# Table is ALWAYS visible to users
```

### INCORRECT: Hiding Outputs

```{r hidden-plot, echo=FALSE, results='hide'}
# WRONG! Plot won't display
plot(data)
```

```{r silent-compute, include=FALSE}
# WRONG! Results are hidden
x <- mean(data$var1)
```

## RULE 3: Default Code Hidden (REQUIRED)

**Code must be hidden by default. Users click "Show code" to see implementation.**

### Correct Implementation

```yaml
---
format:
  html:
    code-fold: true  # Code hidden by default
---
```

Result: Users see narrative and outputs first. Code is accessible via collapsible section.

### INCORRECT Implementation

```yaml
---
format:
  html:
    code-fold: false  # WRONG! Code always visible
---
```

Result: Code clutters the reading experience.

## RULE 4: Selective Code Display (OPTIONAL)

**In specific cases, you may show code by default for a chunk:**

```{r key-function, code-fold=false}
# This is essential code users MUST see
# Use only for critical examples
library(package)
essential_function()
```

**When to use `code-fold=false`:**
- Core tutorial examples where understanding implementation is the goal
- Step-by-step walkthroughs with minimal code
- API usage demonstrations

**Default behavior:** All chunks should use document-level `code-fold: true` setting

## RULE 5: Output Display Control (REQUIRED)

**Always display outputs using correct options:**

### For Graphs/Plots (ALWAYS SHOW)

```{r plot-name}
# Code: hidden by default
# Output: ALWAYS shows

library(ggplot2)
ggplot(mtcars, aes(x = wt, y = mpg)) +
  geom_point() +
  labs(title = "Weight vs MPG")
# Plot displays automatically
```

### For Tables (ALWAYS SHOW)

```{r table-name}
# Code: hidden by default
# Output: ALWAYS shows

library(knitr)
summary_table <- data.frame(
  Metric = c("Mean", "SD", "N"),
  Value = c(23.5, 6.0, 32)
)
kable(summary_table)
# Table displays automatically
```

### For Console Output (Show/Hide as Needed)

```{r analysis-results}
# Show console results
mean_value <- mean(data$x)
print(paste("Mean:", round(mean_value, 2)))
# Output: Shows with results
```

```{r silent-calc, results='hide'}
# Hide intermediate calculations
temp <- complex_calculation()
# No console output shown
```

## RULE 6: Code Folding in GitHub/pkgdown Display (REQUIRED)

**Code folding works consistently across:**

- GitHub README (if vignette is rendered as HTML)
- pkgdown website articles
- Local HTML builds
- Quarto Dashboards

### Verification Checklist

After adding code folding to a vignette:

1. Render locally: `quarto render` or `devtools::build_vignettes()`
2. Open in browser: Look for "Show code" button
3. Click button: Code should expand/collapse smoothly
4. Check outputs: All graphs, tables, and results display
5. Test in pkgdown: `pkgdown::build_site()`
6. Verify on GitHub: Rendered vignette displays correctly

## Best Practices

### 1. Structure Narrative First

```yaml
---
format:
  html:
    code-fold: true
---

# Users see this first
## Introduction

This vignette demonstrates...

## Key Concepts

Explanation of what you'll learn.

## Analysis

[Visible outputs]

Click "Show code" to see the implementation.
```

### 2. Label Chunks Meaningfully

```{r bad-name}
# Unclear what this does
x <- mean(data)
```

```{r calculate-average-height}
# Clear, descriptive name
avg_height <- mean(data$height)
```

### 3. Use Code Descriptions

Quarto supports code block titles:

```{r}
#| code-fold: true
#| code-summary: "Load and explore data"

library(readr)
data <- read_csv("dataset.csv")
str(data)
```

### 4. Group Related Code

```{r setup-libraries}
library(ggplot2)
library(dplyr)
library(tidyr)
```

```{r prepare-data}
clean_data <- data %>%
  filter(!is.na(value)) %>%
  mutate(group = factor(group))
```

### 5. Separate Computation from Display

```{r compute-summary}
# Computation code (hidden)
summary_stats <- data %>%
  group_by(group) %>%
  summarise(mean = mean(value))
```

```{r display-summary}
# Display code (hidden)
knitr::kable(summary_stats)
```
