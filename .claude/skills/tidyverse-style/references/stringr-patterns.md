# stringr Patterns and Regex Reference

Practical reference for string manipulation with stringr. Covers regex debugging,
pattern modifiers, base R migration, and common data-cleaning patterns.

## Base R to stringr Migration

| Task | Base R | stringr |
|------|--------|---------|
| Detect pattern | `grepl(pat, x)` | `str_detect(x, pat)` |
| Find positions | `grep(pat, x)` | `str_which(x, pat)` |
| Extract match | `regmatches(x, regexpr(...))` | `str_extract(x, pat)` |
| Extract all | `regmatches(x, gregexpr(...))` | `str_extract_all(x, pat)` |
| Replace first | `sub(pat, rep, x)` | `str_replace(x, pat, rep)` |
| Replace all | `gsub(pat, rep, x)` | `str_replace_all(x, pat, rep)` |
| Split | `strsplit(x, pat)` | `str_split(x, pat)` |
| Concatenate | `paste0(a, b)` | `str_c(a, b)` |
| Substring | `substr(x, 1, 3)` | `str_sub(x, 1, 3)` |
| Pad | `formatC(x, width = 5)` | `str_pad(x, 5)` |
| Trim | `trimws(x)` | `str_trim(x)` |
| Count matches | `lengths(gregexpr(pat, x))` | `str_count(x, pat)` |
| To lower | `tolower(x)` | `str_to_lower(x)` |
| To upper | `toupper(x)` | `str_to_upper(x)` |

Key difference: stringr puts `x` (data) first, enabling pipes. Base R puts `pattern` first.

```r
# Base R (pattern-first, awkward in pipes)
grep("error", log_lines, value = TRUE)

# stringr (data-first, pipe-friendly)
log_lines |> str_subset("error")
```

## Regex Debugging with str_view()

Use `str_view()` to visualise what a regex matches before applying it:

```r
x <- c("2024-01-15", "Jan 15, 2024", "15/01/2024", "not-a-date")

# See what matches (and what doesn't)
str_view(x, "\\d{4}-\\d{2}-\\d{2}")

# Inspect greedy vs lazy behaviour
str_view("price: $12.50 and $3.99", "\\$\\d+\\.\\d+")

# Check boundary behaviour
str_view("cats concatenate", "\\bcat\\b")
# Matches "cat" in "cats"? No -- \b ensures word boundary

# Useful during development: view all matches in a vector
str_view(x, "\\d+", match = TRUE)  # only show elements that match
```

## Pattern Modifiers: regex(), fixed(), boundary()

### regex() -- Full regex (default)

```r
# Case-insensitive matching
str_detect(emails, regex("error", ignore_case = TRUE))

# Multiline: ^ and $ match line starts/ends
str_extract_all(log, regex("^ERROR:.*", multiline = TRUE))

# Comments mode for complex patterns
phone_pat <- regex("
  \\(?       # optional opening paren
  \\d{3}     # area code
  \\)?       # optional closing paren
  [-\\s.]?   # separator
  \\d{3}     # exchange
  [-\\s.]?   # separator
  \\d{4}     # subscriber
", comments = TRUE)
str_extract(text, phone_pat)
```

### fixed() -- Literal string (fast, no regex)

```r
# When your pattern is NOT a regex, use fixed() for speed
str_detect(html, fixed("</div>"))
str_replace_all(code, fixed("$"), "dollar")

# fixed() also avoids accidental regex interpretation
str_count(text, fixed("."))  # counts literal dots, not "any character"
```

### boundary() -- Match boundaries

```r
# Split into words (handles punctuation, whitespace)
str_split("Hello, world! How are you?", boundary("word"))
#> [["Hello", "world", "How", "are", "you"]]

# Count words
str_count("Hello, world!", boundary("word"))
#> 2

# Split into sentences
str_split(paragraph, boundary("sentence"))
```

### coll() -- Locale-aware comparison

```r
# Locale-sensitive matching (accents, case folding)
str_detect("Straße", coll("strasse", locale = "de"))
#> TRUE
```

## str_c() vs paste() / paste0()

```r
first <- c("Ada", "Grace", NA)
last <- c("Lovelace", "Hopper", "Missing")

# paste0: NA becomes literal "NA"
paste0(first, " ", last)
#> "Ada Lovelace"  "Grace Hopper"  "NA Missing"

# str_c: propagates NA (usually what you want)
str_c(first, " ", last)
#> "Ada Lovelace"  "Grace Hopper"  NA

# Collapsing a vector into one string
str_c(c("a", "b", "c"), collapse = ", ")
#> "a, b, c"

# sep vs collapse
str_c("x", "y", sep = "-")       # "x-y" (between arguments)
str_c(c("x", "y"), collapse = "-") # "x-y" (between vector elements)
```

Rule: prefer `str_c()` over `paste0()` for NA propagation. Use `glue()` for interpolation.

## str_glue() vs glue::glue()

`str_glue()` is a re-export of `glue::glue()`. They are identical:

```r
name <- "World"
str_glue("Hello, {name}!")       # from stringr
glue::glue("Hello, {name}!")     # from glue

# In package code: use whichever you already Import
# In scripts: either works

# str_glue_data() for data-frame context
df <- tibble(city = c("London", "Paris"), pop = c(9, 11))
str_glue_data(df, "{city} has {pop}M people")
```

When to use which:
- Already importing stringr? Use `str_glue()`.
- Need `glue_sql()` or `glue_collapse()`? Import glue directly.
- In dplyr `mutate()`: use `str_glue()` or `glue()` -- both work.

## str_extract() and str_extract_all()

```r
x <- "Order #12345 placed on 2024-03-15 for $99.50"

# Extract first match
str_extract(x, "\\d+")
#> "12345"

# Extract all matches
str_extract_all(x, "\\d+")
#> [["12345", "2024", "03", "15", "99", "50"]]

# Extract with a more specific pattern
str_extract(x, "#\\d+")
#> "#12345"

# In a dplyr pipeline
orders |>
  mutate(
    order_id = str_extract(description, "(?<=#)\\d+"),
    amount = str_extract(description, "(?<=\\$)[\\d.]+") |> as.double()
  )
```

## Named Capture Groups with str_match()

`str_match()` returns a matrix; column 1 is full match, subsequent columns are groups.

```r
x <- c("John Smith (42)", "Ada Lovelace (36)", "bad-input")

# Named groups with (?<name>...)
pat <- "(?<first>\\w+)\\s+(?<last>\\w+)\\s+\\((?<age>\\d+)\\)"
str_match(x, pat)
#>      [,1]                 first  last       age
#> [1,] "John Smith (42)"    "John" "Smith"    "42"
#> [2,] "Ada Lovelace (36)"  "Ada"  "Lovelace" "36"
#> [3,] NA                   NA     NA         NA

# Convert to tibble for pipelines
str_match(x, pat) |>
  as_tibble() |>
  select(first, last, age) |>
  mutate(age = as.integer(age))
```

For multiple matches per string, use `str_match_all()` (same interface, returns list of matrices).

## Common Regex Patterns for Data Cleaning

### Numbers

```r
# Integers
str_extract(x, "-?\\d+")

# Decimals (including negative)
str_extract(x, "-?\\d+\\.?\\d*")

# Numbers with commas (e.g., "1,234,567.89")
str_extract(x, "[\\d,]+\\.?\\d*") |>
  str_remove_all(fixed(",")) |>
  as.double()

# Currency
str_extract(x, "(?<=[$£€])\\s*[\\d,.]+")
```

### Dates

```r
# ISO: 2024-01-15
str_extract(x, "\\d{4}-\\d{2}-\\d{2}")

# US: 01/15/2024 or 1/15/2024
str_extract(x, "\\d{1,2}/\\d{1,2}/\\d{4}")

# Written: Jan 15, 2024
str_extract(x, "[A-Z][a-z]{2}\\s+\\d{1,2},?\\s+\\d{4}")
```

### Emails

```r
email_pat <- "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
str_extract_all(text, email_pat)
```

### Whitespace Cleanup

```r
# Trim leading/trailing whitespace
str_trim(x)

# Collapse multiple spaces to single
str_squish("  too   many   spaces  ")
#> "too many spaces"

# Remove all whitespace
str_remove_all(x, "\\s")
```

### Splitting Delimited Fields

```r
tags <- "R; python;  julia ; rust"
str_split_1(tags, "\\s*;\\s*")  # single string -> vector
#> ["R", "python", "julia", "rust"]
# str_split() for vectorised input (returns list)
```

### Extract and Transform in Pipelines

```r
# Clean messy columns in one pipeline
df |>
  mutate(
    phone = str_extract(contact, "\\d{3}[-.]\\d{3}[-.]\\d{4}"),
    phone_clean = str_remove_all(phone, "[-.]"),
    zip = str_extract(address, "\\d{5}(-\\d{4})?"),
    amount = description |>
      str_extract("[\\d,.]+") |>
      str_remove_all(fixed(",")) |>
      as.double()
  )
```

## Package Code Conventions

```r
# In package R/ files: namespace explicitly
#' @importFrom stringr str_detect str_extract str_replace_all
process_names <- function(x) {
  x |>
    stringr::str_trim() |>
    stringr::str_squish() |>
    stringr::str_to_title()
}

# In DESCRIPTION:
# Imports: stringr
# (not Suggests, if used in R/ code)
```
