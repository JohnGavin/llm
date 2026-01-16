# Quarto Dynamic Content Generation

## Description

Patterns for generating dynamic content in Quarto documents including tabsets from data, parameterized sections, and programmatically created R chunks. Essential for reports, dashboards, and documentation that adapt to data.

## Purpose

Use this skill when:
- Creating tabsets dynamically from data (one tab per category)
- Generating parameterized report sections
- Building multi-page reports from templates
- Creating slides or sections that vary by input
- Rendering computed content that includes R code

## Key Concepts

### Why Standard Approaches Fail

```r
# ❌ DOESN'T WORK: results="asis" with embedded R code
```{r}
#| results: asis
cat("```{r}\nplot(1:10)\n```")  # R code NOT executed
```

# Problem: Quarto renders the chunk output, then moves on.
# Any R code in the output is treated as plain text.
```

### The Solution: Pre-render with knitr

```r
# ✅ WORKS: Inline knitr::knit() forces evaluation
`r knitr::knit(text = your_generated_markdown)`
```

## Pattern 1: Dynamic Tabsets

### Basic Tabset Generation

Create child template `_child.qmd`:

```markdown
## `r hw`
This section is about `r hw`.

```{r}
#| echo: false
library(dplyr)
starwars |>
  filter(homeworld == hw) |>
  select(name, height, mass) |>
  knitr::kable()
```
```

Main document:

```markdown
---
title: "Star Wars Characters by Homeworld"
---

::: {.panel-tabset}

```{r}
#| results: asis
#| echo: false

library(dplyr)
library(purrr)

# Get unique homeworlds
homeworlds <- starwars |>
  filter(!is.na(homeworld)) |>
  distinct(homeworld) |>
  pull()

# Generate one tab per homeworld
res <- map_chr(homeworlds, \(hw) {
  knitr::knit_child(
    input = "_child.qmd",
    envir = environment(),  # Share variables
    quiet = TRUE
  )
})

cat(res, sep = "\n")
```

:::
```

### Inline Tabset (No Child File)

```markdown
::: {.panel-tabset}

```{r}
#| results: asis
#| echo: false

library(purrr)

categories <- c("setosa", "versicolor", "virginica")

res <- map_chr(categories, \(species) {
  glue::glue("
## {species}

```{{r}}
#| echo: false
iris |>
  dplyr::filter(Species == '{species}') |>
  head() |>
  knitr::kable()
```

", .open = "{{", .close = "}}")
})

cat(res, sep = "\n")
```

:::
```

**Note:** Use `{{` and `}}` delimiters with glue to avoid conflicts with R code fences.

## Pattern 2: Inline Knitting

For generated content that includes R chunks:

```markdown
```{r}
#| include: false

# Generate markdown with R chunks
generated <- glue::glue("
## Analysis for Group A

```<<r>>
summary(mtcars)
```

## Analysis for Group B

```<<r>>
summary(iris)
```
", .open = "<<", .close = ">>")
```

`r knitr::knit(text = generated)`
```

**Critical:** The inline `` `r knitr::knit(...)` `` forces Quarto to evaluate the generated R chunks.

## Pattern 3: Data-Driven Sections

### Using Nested Data Frames

```r
```{r}
#| include: false

library(tidyr)
library(purrr)
library(ggplot2)

# Create nested data with plots
analysis_data <- mtcars |>
  group_by(cyl) |>
  nest() |>
  mutate(
    plot = map(data, \(d) {
      ggplot(d, aes(mpg, hp)) + geom_point()
    }),
    summary_text = map_chr(data, \(d) {
      paste("N =", nrow(d), "Mean MPG =", round(mean(d$mpg), 1))
    })
  )

# Generate markdown for each group
sections <- pmap_chr(analysis_data, \(cyl, data, plot, summary_text) {
  # Save plot to temp file
  plot_file <- tempfile(fileext = ".png")
  ggsave(plot_file, plot, width = 6, height = 4)

  glue::glue("
## {cyl} Cylinder Cars

{summary_text}

![Plot for {cyl} cylinders]({plot_file})

", .open = "{{", .close = "}}")
})
```

`r knitr::knit(text = paste(sections, collapse = "\n"))`
```

## Pattern 4: Parameterized Reports

### Template Function Approach

```r
```{r}
#| include: false

generate_section <- function(region, data) {
  regional_data <- data |> filter(region == !!region)

  glue::glue("
## Region: {region}

### Summary Statistics

```<<r>>
#| echo: false
regional_summary <- data |>
  filter(region == '{region}') |>
  summarize(
    total = sum(sales),
    avg = mean(sales)
  )
knitr::kable(regional_summary)
```

### Trend Plot

```<<r>>
#| echo: false
#| fig-width: 8
data |>
  filter(region == '{region}') |>
  ggplot(aes(date, sales)) +
  geom_line() +
  labs(title = 'Sales Trend: {region}')
```

---

", .open = "<<", .close = ">>")
}

# Generate all sections
all_sections <- map_chr(unique(sales_data$region), \(r) {
  generate_section(r, sales_data)
})
```

`r knitr::knit(text = paste(all_sections, collapse = "\n"))`
```

## Execution Contexts (Shiny in Quarto)

For Quarto documents with Shiny components:

### Context Types

```yaml
```{r}
#| context: setup
# Runs in BOTH render and serve
# Use for: libraries, shared data loading
library(shiny)
library(ggplot2)
```

```{r}
#| context: server
# Runs ONLY when served (not during render)
# Use for: reactive logic, server functions
output$plot <- renderPlot({
  plot(rnorm(input$n))
})
```

```{r}
#| context: data
# Runs during render, saves to .RData for server
# Use for: expensive data loading (load once, use in server)
big_data <- readRDS("large_dataset.rds")
```

```{r}
#| context: server-start
# Runs ONCE when Shiny doc starts
# Use for: database connections shared across sessions
con <- DBI::dbConnect(...)
```
```

### Context Decision Tree

```
Need to load libraries?
  → context: setup (runs in both phases)

Need reactive server logic?
  → context: server (runs only when served)

Loading large data used by server?
  → context: data (pre-loads, saves to .RData)

Opening shared connection (DB, API)?
  → context: server-start (once at startup)
```

## Common Gotchas

### 1. Delimiter Conflicts

```r
# ❌ PROBLEM: Triple backticks inside glue
glue("```{r}\ncode\n```")  # Breaks!

# ✅ SOLUTION: Change glue delimiters
glue("
```{r}
code
```
", .open = "<<", .close = ">>")
```

### 2. Environment Isolation

```r
# ❌ PROBLEM: Variable not found in child
hw <- "Tatooine"
knitr::knit_child("_child.qmd")  # hw not available!

# ✅ SOLUTION: Pass environment explicitly
knitr::knit_child(
  "_child.qmd",
  envir = environment()  # Share current environment
)
```

### 3. Chunk Ordering

```r
# ❌ PROBLEM: Generated chunks not executed
```{r}
#| results: asis
cat("```{r}\nplot(1:10)\n```")
```
# Quarto already moved past this chunk!

# ✅ SOLUTION: Use inline knitr::knit()
`r knitr::knit(text = "```{r}\nplot(1:10)\n```")`
```

### 4. IDE Syntax Highlighting

Complex nested backticks confuse editors. Strategies:
- Split templates into multiple glue() calls
- Use child .qmd files
- Accept broken highlighting in complex sections

## Advanced: knitr::knit_expand()

For simple variable substitution without chunks:

```markdown
Template file `_template.qmd`:
## Report for {{region}}
Sales total: {{total}}
Generated: {{Sys.Date()}}
```

```r
```{r}
#| results: asis
cat(knitr::knit_expand(
  file = "_template.qmd",
  region = "North",
  total = "$1.2M"
))
```
```

## Real-World Example: Election Results

From Andrew Heiss's blog - generating 100+ race sections:

```r
```{r}
#| include: false

# Data with one row per race
races <- tibble(
  race_id = 1:100,
  race_name = paste("Race", 1:100),
  candidates = list(...)  # Nested data
)

# Template function
generate_race_section <- function(race_id, race_name, candidates) {
  glue::glue("
## {race_name}

```<<r>>
#| echo: false
#| label: fig-race-{race_id}
candidates <- races$candidates[[{race_id}]]
ggplot(candidates, aes(name, votes)) +
  geom_col() +
  labs(title = '{race_name}')
```

", .open = "<<", .close = ">>")
}

# Generate all sections
all_races <- pmap_chr(races, generate_race_section)
```

`r knitr::knit(text = paste(all_races, collapse = "\n"))`
```

## Best Practices

1. **Use child documents** for complex templates (better syntax highlighting)
2. **Always pass `envir = environment()`** to knit_child
3. **Change glue delimiters** when generating code fences
4. **Pre-compute expensive objects** before template generation
5. **Test templates individually** before scaling to full data
6. **Use meaningful chunk labels** for cross-references

## Resources

- [R Markdown Cookbook - Child Documents](https://bookdown.org/yihui/rmarkdown-cookbook/child-document.html)
- [Andrew Heiss - Dynamic Chunks](https://www.andrewheiss.com/blog/2024/11/04/render-generated-r-chunks-quarto/)
- [Quarto Tabsets Example](https://github.com/quarto-dev/quarto-examples/blob/main/tabsets/tabsets-from-r-chunks/)
- [Quarto Execution Contexts](https://quarto.org/docs/interactive/shiny/execution.html)
- [knitr::knit_expand()](https://bookdown.org/yihui/rmarkdown-cookbook/knit-expand.html)

## Related Skills

- targets-vignettes (pre-calculate objects for vignettes)
- shinylive-quarto (Shiny in Quarto)
- pkgdown-deployment (building package websites)
