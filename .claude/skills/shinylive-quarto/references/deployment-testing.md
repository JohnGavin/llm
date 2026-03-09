# Deployment and Testing

## GitHub Pages Deployment via pkgdown

### Understanding the Two-Part System

**Part 1: R-Universe (Package Compilation)**
- Automatically compiles your package to WebAssembly
- Makes package available at `https://yourusername.r-universe.dev`
- Browser loads your package from here at runtime
- Configure once via the universe repository

**Part 2: GitHub Pages (Dashboard Hosting)**
- Deploys the static HTML/JS dashboard files
- Makes dashboard available at `https://yourusername.github.io/yourpackage/articles/dashboard.html`
- Dashboard code references R-Universe for package loading
- Updated automatically via GitHub Actions on each push

### pkgdown GitHub Actions Workflow

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

The pkgdown build process automatically processes your Quarto vignettes, including Shinylive code blocks, generating the necessary HTML/JS files.

### Enable GitHub Pages

1. Go to repository Settings > Pages
2. Source: Deploy from a branch
3. Branch: gh-pages / root
4. Save

Dashboard will be at: `https://yourusername.github.io/yourpackage/articles/dashboard.html`

---

## Configure _pkgdown.yml

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

### Build Locally

```r
# Build vignettes including Shinylive
pkgdown::build_site()

# Or just articles
pkgdown::build_articles()

# Preview locally
quarto::quarto_preview("vignettes/dashboard.qmd")
```

---

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

  app$set_inputs(grid_size = 20)
  app$set_inputs(n_walkers = 8)
  app$click("run_sim")

  app$wait_for_idle()

  expect_true(app$get_value(output = "grid_plot"))

  app$expect_screenshot()
})
```

---

## Complete End-to-End Workflow

```
STEP 1: Core package functions in R/
STEP 2: Setup WebAssembly build (wasm-release.yaml or R-Universe)
STEP 3: Create Shinylive vignette (vignettes/dashboard.qmd)
STEP 4: Test locally with quarto::quarto_preview()
STEP 5: Build pkgdown site (processes Quarto vignettes -> static HTML/JS)
STEP 6: Push to trigger pkgdown GitHub Action
         -> Dashboard live at: https://yourusername.github.io/yourpackage/articles/dashboard.html

HOW IT CONNECTS:
  User visits GitHub Pages URL
    |
  Browser loads static HTML/JS dashboard
    |
  Dashboard requests R package from R-Universe (or GitHub release)
    |
  Package loaded as WebAssembly in browser
    |
  Shiny app runs entirely client-side using package functions
```
