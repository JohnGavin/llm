# Shinylive for R with Quarto Dashboard

## Description

This skill covers deploying Shiny apps that run entirely in the browser using WebAssembly through Shinylive for R within Quarto documents. The apps run without a server, making them easy to deploy and share via GitHub Pages.

## Purpose

Use this skill when:
- Creating interactive R dashboards that run in the browser
- Building package vignettes with interactive Shiny components
- Deploying Shiny apps without server infrastructure
- Creating portable, shareable R applications
- Publishing interactive tutorials or demonstrations

## Key Principles

### Two Approaches for Loading Packages

There are two main approaches for loading your R package in Shinylive dashboards:

#### Approach 1: GitHub Release + webr::mount() (Simpler, Recommended)

**Use when:** You control the package and can build WebAssembly files

**How it works:**
- Use `r-wasm/actions` workflow to build WebAssembly file system image
- Attach `library.data` to GitHub releases
- Dashboard mounts this directly via `webr::mount()`
- No external services needed

**Advantages:**
- Simpler setup (one workflow file)
- Direct: GitHub → Browser
- Versioned (tied to releases)
- Full control over build

#### Approach 2: R-Universe (More Complex, Use for Public Packages)

**Use when:** Publishing packages for others to use in their Shinylive apps

**How it works:**
- R-Universe compiles packages to WebAssembly
- Browser loads packages via `options(repos = ...)`
- Like CRAN but for WebAssembly

**Advantages:**
- Good for distributing packages to others
- Automatic updates
- CRAN-like experience

### WebAssembly Architecture Overview

**GitHub Pages** = Deployment/hosting platform
- Hosts the static HTML/JS files for your Shinylive dashboard
- Serves the dashboard at yourusername.github.io/package/articles/dashboard.html
- Generated via pkgdown from your package vignettes
- No server-side R required

### WebAssembly Deployment Flow

```
Your Package (GitHub)
    ↓
R-Universe GitHub App
    ↓
WebAssembly Binaries (yourusername.r-universe.dev)
    ↓
Shinylive Dashboard (in Quarto vignette)
    ↓
pkgdown build
    ↓
GitHub Pages (yourusername.github.io/package)
    ↓
User's Browser loads dashboard → fetches packages from R-Universe
```

### Separation of Concerns

- Keep Shinylive app code separate from package simulation code
- Use package functions loaded from R-Universe WebAssembly repository
- Maintain single source of truth for core logic in package
- Test package code independently of GUI

### Package Distribution via R-Universe

- Publish packages to R-Universe for automatic WebAssembly compilation
- Use `packages.json` to configure which packages to build
- Wait for WebAssembly binaries to build (~30-60 minutes initial)
- Browser-based app loads packages from R-Universe at runtime

## How It Works

### Complete Setup Overview

**Final Result:**
- Package hosted at: `https://github.com/yourusername/yourpackage`
- R-Universe repo: `https://yourusername.r-universe.dev`
- Dashboard URL: `https://yourusername.github.io/yourpackage/articles/dashboard.html`

### 1. Setup WebAssembly Build (Choose One Approach)

#### Option A: GitHub Release + webr::mount() (Recommended for Most Cases)

**Step 1: Add wasm-release workflow**

Create `.github/workflows/wasm-release.yaml`:

```yaml
# Workflow derived from https://github.com/r-wasm/actions
on:
  release:
    types: [ published ]

name: Build and deploy wasm R package image

jobs:
  release-file-system-image:
    uses: r-wasm/actions/.github/workflows/release-file-system-image.yml@v2
    permissions:
      contents: write
      repository-projects: read
```

**Step 2: Publish a release**

When you publish a GitHub release, this workflow:
- Builds WebAssembly file system image with your package
- Attaches `library.data` to the release as an asset

**Step 3: Use in dashboard**

```r
# Mount from GitHub release
webr::mount(
  mountpoint = "/mypackage-lib",
  source = "https://github.com/username/mypackage/releases/latest/download/library.data"
)

.libPaths(c("/mypackage-lib", .libPaths()))
library(mypackage)
```

---

#### Option B: R-Universe Setup (For Public Package Distribution)

**Create universe repository:**

```bash
# On GitHub: Create new repo named "universe"
# Add packages.json file:
```

```json
[
  {
    "package": "randomwalk",
    "url": "https://github.com/JohnGavin/randomwalk"
  }
]
```

**Install R-Universe GitHub App:**

1. Visit https://github.com/apps/r-universe/installations/new
2. Grant access to your universe repository
3. Wait for build at https://yourusername.r-universe.dev/

**Use in dashboard:**

```r
# Load from R-Universe
options(repos = c(
  yourusername = 'https://yourusername.r-universe.dev',
  CRAN = 'https://cloud.r-project.org'
))
library(mypackage)
```

---

### 2. Create Quarto Document with Shinylive

**Basic structure:**

```yaml
---
title: "Interactive Dashboard"
format: html
filters:
  - shinylive
---

# Your Dashboard

```{shinylive-r}
#| standalone: true
#| viewerHeight: 800

# Set R-Universe repository
options(repos = c(
  yourusername = 'https://yourusername.r-universe.dev',
  CRAN = 'https://cloud.r-project.org'
))

library(shiny)
library(yourpackage)  # Load from R-Universe

# Define UI
ui <- fluidPage(
  titlePanel("My Interactive App"),

  sidebarLayout(
    sidebarPanel(
      sliderInput("param1", "Parameter 1:",
                  min = 1, max = 100, value = 10),
      selectInput("param2", "Parameter 2:",
                  choices = c("Option A", "Option B")),
      actionButton("run", "Run Simulation")
    ),

    mainPanel(
      tabsetPanel(
        tabPanel("Plot", plotOutput("main_plot")),
        tabPanel("Data", tableOutput("data_table")),
        tabPanel("Stats", verbatimTextOutput("stats"))
      )
    )
  )
)

# Define server
server <- function(input, output, session) {
  # Use package functions
  result <- eventReactive(input$run, {
    yourpackage::run_simulation(
      param1 = input$param1,
      param2 = input$param2
    )
  })

  output$main_plot <- renderPlot({
    req(result())
    yourpackage::plot_result(result())
  })

  output$data_table <- renderTable({
    req(result())
    result()$data
  })

  output$stats <- renderPrint({
    req(result())
    result()$statistics
  })
}

shinyApp(ui = ui, server = server)
```
```

### 3. File Structure

```
package/
├── vignettes/
│   └── dashboard.qmd          # Shinylive dashboard
├── inst/
│   └── qmd/
│       └── dashboard.qmd      # Source file
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

## Common Patterns

### Pattern 1: Simple Interactive Plot

```r
```{shinylive-r}
#| standalone: true

library(shiny)
library(ggplot2)

ui <- fluidPage(
  sliderInput("bins", "Number of bins:", 10, 50, 30),
  plotOutput("histogram")
)

server <- function(input, output) {
  output$histogram <- renderPlot({
    ggplot(data.frame(x = rnorm(1000)), aes(x)) +
      geom_histogram(bins = input$bins)
  })
}

shinyApp(ui, server)
```
```

### Pattern 2: Using Package Functions

```r
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

  sidebarPanel(
    numericInput("grid_size", "Grid Size:", 20, 5, 100),
    numericInput("n_walkers", "Walkers:", 8, 1, 50),
    selectInput("neighborhood", "Neighborhood:",
                choices = c("4-hood", "8-hood")),
    selectInput("boundary", "Boundary:",
                choices = c("terminate", "wrap")),
    actionButton("run_sim", "Run Simulation",
                 class = "btn-primary")
  ),

  mainPanel(
    tabsetPanel(
      tabPanel("Grid", plotOutput("grid_plot")),
      tabPanel("Paths", plotOutput("paths_plot")),
      tabPanel("Statistics", verbatimTextOutput("stats_output"))
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

  output$grid_plot <- renderPlot({
    req(sim_result())
    plot_grid(sim_result())
  })

  output$paths_plot <- renderPlot({
    req(sim_result())
    plot_walker_paths(sim_result())
  })

  output$stats_output <- renderPrint({
    req(sim_result())
    sim_result()$statistics
  })
}

shinyApp(ui, server)
```
```

### Pattern 3: Modular Shiny Components

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

# In Shinylive app:
```{shinylive-r}
library(yourpackage)

ui <- fluidPage(
  sim_control_ui("sim"),
  plotOutput("result")
)

server <- function(input, output, session) {
  params <- sim_control_server("sim")

  output$result <- renderPlot({
    req(params())
    # Use params()
  })
}

shinyApp(ui, server)
```
```

## Integration with pkgdown

### Configure _pkgdown.yml

```yaml
url: https://yourusername.github.io/yourpackage

template:
  bootstrap: 5

navbar:
  structure:
    left: [intro, articles, reference]
    right: [dashboard, github]
  components:
    dashboard:
      text: "Live Dashboard"
      href: articles/dashboard.html
      icon: fa-play-circle

articles:
  - title: Get Started
    contents:
      - introduction
      - usage-examples

  - title: Interactive
    contents:
      - dashboard

  - title: Details
    contents:
      - architecture
      - telemetry
```

### Build Site

```r
# Build vignettes including Shinylive
pkgdown::build_site()

# Or just articles
pkgdown::build_articles()
```

## Testing Shiny Components

### Unit Tests for Shiny Modules

```r
# tests/testthat/test-shiny-modules.R
library(shiny)
library(testthat)

test_that("sim_control_ui creates correct inputs", {
  ui <- sim_control_ui("test")

  expect_s3_class(ui, "shiny.tag.list")
  # Additional UI structure tests
})

test_that("sim_control_server returns reactive values", {
  testServer(sim_control_server, {
    # Simulate button click
    session$setInputs(
      grid_size = 25,
      n_walkers = 10,
      run = 1
    )

    result <- session$returned()

    expect_equal(result()$grid_size, 25)
    expect_equal(result()$n_walkers, 10)
  })
})
```

### Interactive Testing with shinytest2

```r
# tests/testthat/test-shiny-app.R
library(shinytest2)

test_that("Dashboard loads and runs simulation", {
  app <- AppDriver$new(
    name = "dashboard-test",
    height = 800,
    width = 1200
  )

  # Set inputs
  app$set_inputs(grid_size = 20)
  app$set_inputs(n_walkers = 8)
  app$click("run_sim")

  # Wait for outputs
  app$wait_for_idle()

  # Check outputs exist
  expect_true(app$get_value(output = "grid_plot"))

  # Take screenshot
  app$expect_screenshot()
})
```

## Deployment

### Understanding the Two-Part System

**Part 1: R-Universe (Package Compilation)**
- Automatically compiles your package to WebAssembly
- Makes package available at `https://yourusername.r-universe.dev`
- Browser loads your package from here at runtime
- You configure this ONCE via universe repository

**Part 2: GitHub Pages (Dashboard Hosting)**
- Deploys the static HTML/JS dashboard files
- Makes dashboard available at `https://yourusername.github.io/yourpackage/articles/dashboard.html`
- Dashboard code references R-Universe for package loading
- Updated automatically via GitHub Actions on each push

### GitHub Pages Deployment via pkgdown

```yaml
# .github/workflows/pkgdown.yaml
name: pkgdown

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

jobs:
  pkgdown:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Nix
        uses: DeterminateSystems/nix-installer-action@main

      - name: Setup Nix cache
        uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Build site (includes Shinylive dashboard)
        run: |
          nix-shell default.nix --run "Rscript -e 'pkgdown::build_site()'"

      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs
```

**Note:** The pkgdown build process automatically processes your Quarto vignettes, including the Shinylive code blocks, generating the necessary HTML/JS files.

### Enable GitHub Pages

1. Go to repository Settings > Pages
2. Source: Deploy from a branch
3. Branch: gh-pages / root
4. Save

**Your dashboard will be at:** `https://yourusername.github.io/yourpackage/articles/dashboard.html`

### What Happens When User Opens Dashboard

1. Browser loads HTML/JS from GitHub Pages
2. WebR initializes in browser
3. Dashboard code executes: `options(repos = c(yourusername = 'https://yourusername.r-universe.dev'))`
4. Browser fetches WebAssembly-compiled package from R-Universe
5. Package loads in browser's WebAssembly environment
6. Shiny app runs entirely client-side

## Performance Considerations

### Keep Apps Lightweight

```r
# Good: Load only needed packages
library(shiny)
library(ggplot2)

# Bad: Load heavy packages unnecessarily
# library(tidyverse)  # Too heavy for WebAssembly
```

### Optimize Data Loading

```r
# Pre-process data in package, not in Shinylive
# R/data.R
#' Pre-processed example data
#' @export
example_data <- # ... processed data

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

## Troubleshooting

### Package not loading in Shinylive

**Check R-Universe build status:**
```r
# Visit: https://yourusername.r-universe.dev/
# Check if WebAssembly binary is available
```

### Vignette not rendering

**Ensure Quarto extension installed:**
```bash
quarto add quarto-ext/shinylive
```

### Slow app performance

**Profile and optimize:**
```r
# Use profvis in local testing
library(profvis)

profvis({
  # Your simulation code
})
```

## Best Practices

1. **Separate package logic from UI**: Core functions in R/, UI in vignettes
2. **Test package functions independently**: Don't rely on Shinylive for testing
3. **Use R-Universe for distribution**: Easier than bundling dependencies
4. **Keep apps focused**: One clear purpose per dashboard
5. **Document inputs and outputs**: Clear labels and help text
6. **Provide examples**: Include preset configurations
7. **Monitor bundle size**: Keep WebAssembly bundle reasonable
8. **Version control**: Commit Quarto source, not rendered HTML

## Example Complete Workflow

```r
# === STEP 1: Create Package with Core Functions ===
# R/simulation.R
#' @export
run_simulation <- function(...) { }

# === STEP 2: Setup R-Universe (WebAssembly Compilation) ===
# On GitHub: Create new repo named "universe"
# Add packages.json referencing your package repo
# Install R-Universe GitHub App
# Wait ~30-60 min for first WebAssembly build
# Verify at: https://yourusername.r-universe.dev

# === STEP 3: Create Shinylive Dashboard Vignette ===
# vignettes/dashboard.qmd
# Include shinylive code block that loads package from R-Universe
# ```{shinylive-r}
# options(repos = c(yourusername = 'https://yourusername.r-universe.dev'))
# library(yourpackage)
# shinyApp(ui, server)
# ```

# === STEP 4: Test Locally ===
quarto::quarto_preview("vignettes/dashboard.qmd")

# === STEP 5: Build pkgdown Site ===
# This processes Quarto vignettes and generates static HTML/JS
pkgdown::build_site()

# === STEP 6: Deploy to GitHub Pages ===
# Push to trigger pkgdown GitHub Action workflow
# Dashboard will be at: https://yourusername.github.io/yourpackage/articles/dashboard.html

# === HOW IT ALL CONNECTS ===
# User visits: GitHub Pages URL (Step 6)
#   ↓
# Browser loads: Static HTML/JS dashboard (Step 5)
#   ↓
# Dashboard requests: R package from R-Universe (Step 2)
#   ↓
# Package loaded: WebAssembly runs in browser
#   ↓
# Shiny app runs: Entirely client-side using package functions (Step 1)
```

## Resources

- **Shinylive for R**: https://posit-dev.github.io/r-shinylive/
- **Quarto Shinylive**: https://quarto-ext.github.io/shinylive/
- **WebR**: https://docs.r-wasm.org/webr/latest/
- **R-Universe**: https://docs.r-universe.dev/
- **shinytest2**: https://rstudio.github.io/shinytest2/
- **Example demos**: https://github.com/coatless-quarto/r-shinylive-demo
- **Blog tutorial**: https://nrennie.rbind.io/blog/webr-shiny-tidytuesday/

## Related Skills

- r-package-workflow
- nix-rix-r-environment
- targets-vignettes
