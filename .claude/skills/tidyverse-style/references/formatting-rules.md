# Formatting Rules

Detailed style guide formatting rules for tidyverse-style R code.

## Naming Conventions

```r
# snake_case for everything
calculate_mean_value <- function(input_data) { }
user_age <- 25
MAX_ITERATIONS <- 100

# BAD: Other conventions
calculateMeanValue <- function(inputData) { }  # camelCase
user.age <- 25                                   # dot.case
```

## Pipe Usage

```r
# GOOD: Base pipe |> (R 4.1+)
result <- data |>
  filter(age > 18) |>
  mutate(age_group = cut(age, breaks = c(18, 30, 50, Inf))) |>
  summarise(n = n(), .by = age_group)

# ACCEPTABLE: magrittr %>% in existing codebases
result <- data %>%
filter(age > 18) %>%
  summarise(n = n())

# BAD: Nested calls
result <- summarise(filter(data, age > 18), n = n())
```

## Line Length and Breaking

```r
# GOOD: Break after pipe, indent 2 spaces
data |>
  filter(
    age > 18,
    status == "active"
  ) |>
  mutate(
    full_name = paste(first_name, last_name),
    age_group = case_when(
      age < 30 ~ "young",
      age < 50 ~ "middle",
      TRUE ~ "senior"
    )
  )

# BAD: Long lines, inconsistent breaks
data |> filter(age > 18, status == "active") |> mutate(full_name = paste(first_name, last_name))
```

## Function Arguments

```r
# GOOD: Named arguments for clarity
ggplot(data, aes(x = age, y = income)) +
  geom_point(alpha = 0.5, size = 2) +
  labs(
    title = "Income by Age",
    x = "Age (years)",
    y = "Annual Income ($)"
  )

# BAD: Positional arguments beyond first two
ggplot(data, aes(age, income)) +
  geom_point(0.5, 2)  # What do these mean?
```

## Anonymous Function Syntax

```r
# Single-line: use \() shorthand
map(items, \(x) x + 1)

# Multi-line: use function() {...}
map(items, function(x) {
  result <- process(x)
  validate(result)
  result
})
```

## Code Formatting with air

Use the `air` formatter for consistent R code style:

```bash
# Format all R files in the project
air format .

# Format a specific file
air format R/my_file.R
```

**Always run `air format .` after generating code.** The air formatter handles:
- Consistent indentation and spacing
- Line breaks at appropriate places
- Argument alignment
- Pipe chain formatting
