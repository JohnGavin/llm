# WASM Limitations, Performance, and Troubleshooting

## WASM Limitations

Shinylive runs in WebAssembly, which has restrictions:

```r
# These DON'T WORK in Shinylive:
crew::crew_controller_local()  # No background processes
future::plan(multisession)     # No multiprocessing
DBI::dbConnect(...)            # No database connections
httr::GET(...)                 # Limited HTTP (CORS restrictions)
Rcpp with system libs          # Limited C++ support

# These WORK in Shinylive:
dplyr::mutate(), filter()      # Pure R computation
ggplot2::ggplot()              # Visualization (but see note below)
stats::lm(), t.test()          # Statistics
shiny::reactive()              # Reactive programming
```

**Important:** Use `plotly` instead of `ggplot2` for Shinylive — the `munsell` dependency breaks in WebAssembly. See `memory/shinylive-issues.md`.

For long-running computations, keep calculations simple or pre-compute in your package.

---

## Performance Considerations

### Keep Apps Lightweight

```r
# Good: Load only needed packages
library(shiny)
library(ggplot2)  # Only if needed and munsell issue is resolved

# Bad: Load heavy packages unnecessarily
# library(tidyverse)  # Too heavy for WebAssembly
```

### Optimize Data Loading

Pre-process data in the package, not in Shinylive:

```r
# R/data.R - in your package
#' Pre-processed example data
#' @export
example_data <- # ... processed data ready for use

# In Shinylive:
data(example_data, package = "yourpackage")
```

### Cache Expensive Operations

```r
server <- function(input, output, session) {
  # Cache expensive computation
  cached_result <- reactive({
    expensive_computation(input$params)
  }) |> bindCache(input$params)

  output$plot <- renderPlot({
    plot(cached_result())
  })
}
```

---

## Troubleshooting

### Package Not Loading in Shinylive

**Check R-Universe build status:**
- Visit: `https://yourusername.r-universe.dev/`
- Check if WebAssembly binary is available for your package
- Initial build takes ~30-60 minutes

**Check package name in options:**
```r
# Ensure the repo key matches your R-Universe username exactly
options(repos = c(
  yourusername = 'https://yourusername.r-universe.dev',
  CRAN = 'https://cloud.r-project.org'
))
```

### Vignette Not Rendering

**Ensure Quarto extension is installed:**
```bash
quarto add quarto-ext/shinylive
```

**Verify YAML front matter:**
```yaml
---
title: "My Dashboard"
format: html
filters:
  - shinylive
---
```

### Slow App Performance

**Profile and optimize locally:**
```r
library(profvis)

profvis({
  # Your simulation code here
})
```

**Checklist:**
- [ ] Avoid `library(tidyverse)` — import only what you need
- [ ] Pre-compute heavy data in package, not at runtime
- [ ] Use `bindCache()` for repeated expensive reactives
- [ ] Minimize the number of packages loaded

### CORS Errors for HTTP Requests

WebAssembly in browsers cannot make arbitrary HTTP requests. If your app needs external data:
- Bundle data in the package itself
- Use only CORS-enabled endpoints
- Pre-fetch and include data as package data objects

### ggplot2 / munsell Error

If you see errors related to `munsell` when using ggplot2:
- Switch to `plotly` for interactive charts
- Or add `webr::install("munsell")` before loading ggplot2
- See `memory/shinylive-issues.md` for full details

---

## Quarto Execution Contexts (Server-Side Shiny Only)

**Note:** These contexts are for server-side Shiny in Quarto documents, NOT for Shinylive (which runs entirely in browser).

```r
# context: setup — runs in BOTH render and serve phases
#| context: setup
library(shiny)

# context: server — runs ONLY when document is served
#| context: server
output$plot <- renderPlot({ ... })

# context: data — runs at render time, saves to .RData for server
#| context: data
expensive_data <- readRDS("big_file.rds")

# context: server-start — runs ONCE when Shiny document starts
#| context: server-start
db_connection <- DBI::dbConnect(...)
```

---

## Modular Shiny Pattern

For complex dashboards, use Shiny modules in the package and call them from Shinylive:

```r
# R/shiny_module.R
#' Simulation control UI module
#' @export
sim_control_ui <- function(id) {
  ns <- NS(id)
  tagList(
    sliderInput(ns("grid_size"), "Grid Size:", 10, 100, 20),
    sliderInput(ns("n_walkers"), "Walkers:", 1, 50, 8),
    actionButton(ns("run"), "Run Simulation")
  )
}

#' Simulation control server module
#' @export
sim_control_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    eventReactive(input$run, {
      list(
        grid_size = input$grid_size,
        n_walkers = input$n_walkers
      )
    })
  })
}
```

```r
# In Shinylive vignette:
```{shinylive-r}
#| standalone: true
library(yourpackage)

ui <- fluidPage(
  sim_control_ui("sim"),
  plotOutput("result")
)

server <- function(input, output, session) {
  params <- sim_control_server("sim")

  output$result <- renderPlot({
    req(params())
    # use params()$grid_size, params()$n_walkers
  })
}

shinyApp(ui, server)
```
```
