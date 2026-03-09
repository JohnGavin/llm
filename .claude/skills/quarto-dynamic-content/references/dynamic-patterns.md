# Dynamic Content Patterns - Detailed Examples

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
