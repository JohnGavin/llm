---
paths:
  - "R/**"
  - "vignettes/**"
  - "tests/**"
  - "inst/**"
---
# Rule: Portable File Paths

## When This Applies
Any R code in `R/`, `tests/`, `vignettes/`, or `inst/` that references files on disk.

## CRITICAL: Use here::here() for All Paths

Absolute paths break on other machines. Use `here::here()` to construct paths relative to the project root.

```r
# WRONG
data <- read.csv("/Users/johngavin/docs_gh/llm/inst/extdata/data.csv")
source("~/docs_gh/llm/R/utils.R")

# RIGHT
data <- read.csv(here::here("inst/extdata/data.csv"))
source(here::here("R/utils.R"))
```

## Exception

Scripts in `~/.claude/scripts/` and `~/.claude/hooks/` are personal tooling (not shared code) and may use absolute paths for system integration.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `/Users/johngavin/...` in R files | Breaks on other machines | `here::here("...")` |
| `~/docs_gh/...` in R files | `~` expands unpredictably | `here::here("...")` |
| `setwd()` | Global state, breaks tests | Use `here::here()` for paths |
| `source("/absolute/path")` | Not portable | `source(here::here("R/file.R"))` |
| `"../data/file"` relative paths | Breaks when cwd changes | `here::here("data/file")` |
