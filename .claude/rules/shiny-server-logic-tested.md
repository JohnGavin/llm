---
paths: ["**/app.R", "**/inst/shiny/**", "**/R/*shiny*.R", "**/R/mod_*.R", "**/R/*module*.R"]
---

# Rule: Shiny Server Logic Is Tested

## When This Applies

Writing or reviewing a Shiny app's server side: `app.R`, `inst/shiny/**`,
module files (`R/mod_*.R`, `R/*module*.R`, `R/*shiny*.R`), or the server code
of a shinylive chunk in a `.qmd`.

## CRITICAL: Every Reactive or Server Computation Is Either a Tested Function or Covered by `testServer`

Server logic that is verified only by running the app by hand is untested: the
next edit breaks it silently, and a green test suite says nothing about it.
Each piece of server logic must satisfy ONE of:

1. It is a plain function in `R/` with its own testthat tests (see
   `domain-logic-in-package`), and the reactive or `render*()` body only calls it.
2. It lives in the module/server and a `shiny::testServer()` test exercises it
   (`session$setInputs()`, `session$flushReact()`, `output$...`,
   `session$returned()`).

Prefer option 1: it is the cheapest layer and the one that fails for the
clearest reason. Use shinytest2 only for browser-only behaviour (JavaScript,
downloads, layout), never as the sole coverage of server logic.

A `skip()` on a `testServer` block is not coverage. Diagnose the error the
test raises; do not record "doesn't work with moduleServer" as a reason.

## Required Pattern

```r
# R/filter.R  -- pure, unit-tested
filter_by_range <- function(data, range) {
  data[data$date >= range[1] & data$date <= range[2], ]
}

# server: one call, nothing to get wrong
filtered <- reactive(filter_by_range(data(), input$range))

# tests/testthat/test-filter.R -- plain testthat for the function, and
shiny::testServer(filter_server, args = list(data = reactive(sales)), {
  session$setInputs(range = c(as.Date("2026-01-01"), as.Date("2026-01-31")))
  expect_lt(nrow(session$returned()), nrow(sales))
})
```

State the expected behaviour in a plain-English sentence before writing each
test. Skill with the full workflow: `shiny-bslib` (Testing).

## Detection Heuristic

Files that define server logic but are never mentioned by any test:

```bash
for f in $(grep -rlE "moduleServer\(|function\(input, *output|shinyApp\(" \
    --include="*.R" . | grep -v "^\./tests/"); do
  base=$(basename "$f" .R)
  grep -rqE "testServer|$base" tests/ 2>/dev/null || echo "UNTESTED: $f"
done
```

Also list skipped server tests, which count as untested:

```bash
grep -rn -B3 "skip(" tests/testthat | grep "testServer"
```

The first grep is a heuristic (a test may reference a file's functions by a
different name); treat each hit as a question to answer, not a verdict.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Aggregation or filtering written inline in `render*()` / `reactive()` | Cannot be unit-tested; invisible to other consumers | Extract to `R/`, test it |
| Module with no test referencing `testServer` or its helper functions | Wiring and returned values unverified | Add a `testServer()` test of `session$returned()` |
| `skip("testServer doesn't work ...")` with no diagnosed cause | A permanent hole that reads as coverage | Reproduce the error, fix, or file an issue and link it |
| `expect_true(TRUE)` as a placeholder inside `testServer` | Passes whatever the code does | Assert a value that could differ |
| shinytest2 as the only test of a calculation | Slow, fragile, fails for unrelated reasons | Test the function; keep shinytest2 for browser behaviour |
| Testing only that the UI HTML contains an id | Checks markup, not behaviour | Add a behavioural assertion on outputs or returned values |

## Related

- `domain-logic-in-package` -- logic belongs in `R/`; the first half of this rule
- `module-isolation`, `shiny-module-data-sharing` -- module structure that makes `testServer` straightforward
- `snapshot-tests-mandatory` -- when output shape should be snapshotted
- `shiny-bslib` skill -- the "Testing" section with the workflow
- `checks-must-distinguish-unknown` -- a skipped test is indeterminate, not a pass

## Origin

[llm#1361](https://github.com/JohnGavin/llm/issues/1361): of seven dashboard
projects checked on 2026-10-11 only one used `testServer`, and there every
`testServer` block was skipped.
