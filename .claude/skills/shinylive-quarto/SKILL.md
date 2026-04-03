---
name: shinylive-quarto
description: Use when embedding Shinylive apps in Quarto documents, deploying server-free Shiny dashboards via Quarto and GitHub Pages, or building interactive Quarto pages with Shiny. Triggers: Shinylive Quarto, Quarto Shiny, WebR Shiny, interactive Quarto.
---
# Shinylive for R with Quarto Dashboard

## Description

Deploy Shiny apps that run entirely in the browser via WebAssembly through Shinylive for R within Quarto documents. Apps run without a server, making them easy to deploy and share via GitHub Pages.

## Reference Files

| Topic | File |
|-------|------|
| Package loading approaches (GitHub Release vs R-Universe) | `references/package-loading.md` |
| Deployment, CI/CD, pkgdown, and testing | `references/deployment-testing.md` |
| WASM limitations, performance, troubleshooting | `references/wasm-limitations-troubleshooting.md` |

## Purpose

Use this skill when:
- Creating interactive R dashboards that run in the browser
- Building package vignettes with interactive Shiny components
- Deploying Shiny apps without server infrastructure
- Creating portable, shareable R applications
- Publishing interactive tutorials or demonstrations

## Key Principles

### Two Approaches for Loading Packages

**Approach 1: GitHub Release + webr::mount() (Recommended for most cases)**
- Use `r-wasm/actions` workflow to build WebAssembly file system image
- Attach `library.data` to GitHub releases
- Dashboard mounts directly via `webr::mount()`
- Simpler: one workflow file, versioned, no external services
- See `references/package-loading.md` for full setup

**Approach 2: R-Universe (For public package distribution)**
- R-Universe compiles packages to WebAssembly automatically
- Browser loads packages via `options(repos = ...)`
- Good for distributing packages to others with CRAN-like experience
- See `references/package-loading.md` for full setup

### Architecture

```
Your Package (GitHub)
    |
WebAssembly Build (GitHub Release or R-Universe)
    |
Shinylive Dashboard (Quarto vignette)
    |
pkgdown build -> GitHub Pages
    |
User's Browser: WebR + your package + Shiny, entirely client-side
```

### Separation of Concerns

- Core logic lives in R/ as regular package functions
- Shinylive app code only handles UI and calls package functions
- Test package code independently of the GUI
- Pre-compute heavy data in the package, not in the browser

## Quick Start

### 1. Install Quarto Extension

```bash
quarto add quarto-ext/shinylive
```

### 2. Minimal Quarto Document

```yaml
---
title: "Interactive Dashboard"
format: html
filters:
  - shinylive
---
```

````
```{shinylive-r}
#| standalone: true
#| viewerHeight: 600

library(shiny)

ui <- fluidPage(
  sliderInput("bins", "Number of bins:", 10, 50, 30),
  plotOutput("histogram")
)

server <- function(input, output) {
  output$histogram <- renderPlot({
    hist(rnorm(1000), breaks = input$bins)
  })
}

shinyApp(ui, server)
```
````

### 3. Load Your Package (GitHub Release approach)

````
```{shinylive-r}
#| standalone: true

webr::mount(
  mountpoint = "/mypackage-lib",
  source = "https://github.com/username/mypackage/releases/latest/download/library.data"
)
.libPaths(c("/mypackage-lib", .libPaths()))
library(mypackage)

# ... your shiny UI and server
```
````

### 4. Load Your Package (R-Universe approach)

````
```{shinylive-r}
#| standalone: true

options(repos = c(
  yourusername = 'https://yourusername.r-universe.dev',
  CRAN = 'https://cloud.r-project.org'
))
library(mypackage)

# ... your shiny UI and server
```
````

## Essential Patterns

### Pattern: Full App with Package Functions

````
```{shinylive-r}
#| standalone: true

options(repos = c(
  johngavin = 'https://johngavin.r-universe.dev',
  CRAN = 'https://cloud.r-project.org'
))

library(shiny)
library(randomwalk)

ui <- fluidPage(
  titlePanel("Random Walk Simulation"),
  sidebarLayout(
    sidebarPanel(
      numericInput("grid_size", "Grid Size:", 20, 5, 100),
      numericInput("n_walkers", "Walkers:", 8, 1, 50),
      selectInput("neighborhood", "Neighborhood:",
                  choices = c("4-hood", "8-hood")),
      selectInput("boundary", "Boundary:",
                  choices = c("terminate", "wrap")),
      actionButton("run_sim", "Run Simulation", class = "btn-primary")
    ),
    mainPanel(
      tabsetPanel(
        tabPanel("Grid", plotOutput("grid_plot")),
        tabPanel("Paths", plotOutput("paths_plot")),
        tabPanel("Statistics", verbatimTextOutput("stats_output"))
      )
    )
  )
)

server <- function(input, output, session) {
  sim_result <- eventReactive(input$run_sim, {
    run_simulation(
      grid_size = input$grid_size,
      n_walkers = input$n_walkers,
      neighborhood = input$neighborhood,
      boundary = input$boundary
    )
  })

  output$grid_plot <- renderPlot({ req(sim_result()); plot_grid(sim_result()) })
  output$paths_plot <- renderPlot({ req(sim_result()); plot_walker_paths(sim_result()) })
  output$stats_output <- renderPrint({ req(sim_result()); sim_result()$statistics })
}

shinyApp(ui, server)
```
````

## File Structure

```
package/
├── vignettes/
│   └── dashboard.qmd          # Shinylive dashboard vignette
├── R/
│   ├── simulation.R           # Core package logic
│   ├── plotting.R             # Plotting functions
│   └── shiny_module.R         # Shiny modules (optional)
├── tests/
│   └── testthat/
│       ├── test-simulation.R  # Test core logic
│       └── test-shiny.R       # Test Shiny components
└── _pkgdown.yml               # Configure website
```

## Key WASM Constraints

```r
# These DON'T WORK in Shinylive:
crew::crew_controller_local()  # No background processes
DBI::dbConnect(...)            # No database connections
httr::GET(...)                 # Limited HTTP (CORS)

# These WORK:
dplyr::mutate(), filter()
plotly::plot_ly()              # Use plotly, NOT ggplot2 (munsell breaks)
stats::lm(), t.test()
shiny::reactive()
```

See `references/wasm-limitations-troubleshooting.md` for full constraints and troubleshooting.

## Deployment Summary

1. Add `wasm-release.yaml` workflow (or configure R-Universe)
2. Build pkgdown site: `pkgdown::build_site()`
3. Push to trigger GitHub Actions
4. Enable GitHub Pages (Settings > Pages > gh-pages branch)
5. Dashboard live at: `https://yourusername.github.io/yourpackage/articles/dashboard.html`

See `references/deployment-testing.md` for full CI/CD workflow and testing patterns.

## Best Practices

1. Separate package logic from UI — core functions in R/, UI in vignettes
2. Test package functions independently — don't rely on Shinylive for testing
3. Use plotly instead of ggplot2 — avoids munsell WebAssembly breakage
4. Keep apps focused — one clear purpose per dashboard
5. Pre-compute heavy data in package — minimize browser-side computation
6. Keep bundles small — avoid heavy packages like tidyverse
7. Version control — commit Quarto source, not rendered HTML

## Resources

- Shinylive for R: https://posit-dev.github.io/r-shinylive/
- Quarto Shinylive: https://quarto-ext.github.io/shinylive/
- WebR: https://docs.r-wasm.org/webr/latest/
- R-Universe: https://docs.r-universe.dev/
- shinytest2: https://rstudio.github.io/shinytest2/
- r-wasm/actions: https://github.com/r-wasm/actions
- Demo repo: https://github.com/coatless-quarto/r-shinylive-demo

## Related Skills

- r-package-workflow
- nix-rix-r-environment
- targets-vignettes
- shinylive-deployment (GitHub Actions automation)
- shiny-async-patterns (for server-side Shiny, not WASM)
- quarto-dynamic-content (dynamic tabsets, parameterized reports)
