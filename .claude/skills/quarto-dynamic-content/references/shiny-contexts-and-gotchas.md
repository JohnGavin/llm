# Shiny Execution Contexts and Common Gotchas

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
  -> context: setup (runs in both phases)

Need reactive server logic?
  -> context: server (runs only when served)

Loading large data used by server?
  -> context: data (pre-loads, saves to .RData)

Opening shared connection (DB, API)?
  -> context: server-start (once at startup)
```

## Common Gotchas

### 1. Delimiter Conflicts

```r
# PROBLEM: Triple backticks inside glue
glue("```{r}\ncode\n```")  # Breaks!

# SOLUTION: Change glue delimiters
glue("
```{r}
code
```
", .open = "<<", .close = ">>")
```

### 2. Environment Isolation

```r
# PROBLEM: Variable not found in child
hw <- "Tatooine"
knitr::knit_child("_child.qmd")  # hw not available!

# SOLUTION: Pass environment explicitly
knitr::knit_child(
  "_child.qmd",
  envir = environment()  # Share current environment
)
```

### 3. Chunk Ordering

```r
# PROBLEM: Generated chunks not executed
```{r}
#| results: asis
cat("```{r}\nplot(1:10)\n```")
```
# Quarto already moved past this chunk!

# SOLUTION: Use inline knitr::knit()
`r knitr::knit(text = "```{r}\nplot(1:10)\n```")`
```

### 4. IDE Syntax Highlighting (Triple-Backtick Splitting)

Complex nested backticks confuse RStudio/Positron parsing. The concrete fix:
split builder output into multiple variables, each containing **at most one** code fence pair, then combine:

```r
build_section <- function(i) {
  # Part 1: markdown only (no code fences)
  part_header <- glue("
  ### <<title>>

  `r data$description[[<<i>>]]`
  ", .open = "<<", .close = ">>")

  # Part 2: one code fence
  part_plot <- glue('
  ```{r}
  #| label: plot-<<i>>
  #| echo: false
  data$plot[[<<i>>]]
  ```', .open = "<<", .close = ">>")

  # Part 3: another code fence
  part_code <- glue('
  ```r
  `r data$code_text[[<<i>>]]`
  ```', .open = "<<", .close = ">>")

  # Combine
  glue("{part_header}\n\n{part_plot}\n\n{part_code}")
}
```

Other strategies: use child `.qmd` files, or accept broken highlighting in complex sections.

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
