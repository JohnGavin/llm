# Shinylive Deployment Workflow

## Description

Automated deployment of Shiny apps as static websites using Shinylive (WebAssembly). Apps run entirely in the browser without a server, deployable to GitHub Pages, Netlify, or any static host.

## Purpose

Use this skill when:
- Deploying Shiny apps without server infrastructure
- Creating portable, shareable R applications
- Building package vignettes with interactive demos
- Reducing hosting costs (no Shiny Server needed)
- Creating offline-capable R applications

## Key Concepts

### How Shinylive Works

```
Traditional Shiny:
┌────────────┐     ┌────────────┐
│  Browser   │ ←─→ │  R Server  │
│    (UI)    │     │  (Logic)   │
└────────────┘     └────────────┘
     Network dependency, server costs

Shinylive:
┌─────────────────────────────────┐
│           Browser               │
│  ┌───────────┐  ┌───────────┐  │
│  │    UI     │  │  WebR/R   │  │
│  │  (HTML)   │←→│  (WASM)   │  │
│  └───────────┘  └───────────┘  │
└─────────────────────────────────┘
     No server, runs offline
```

### Size Implications

```
Base Shinylive download:
├── webR core:        ~40 MB
├── shiny package:    ~15 MB
├── Base R libs:      ~5 MB
└── Total minimum:    ~60 MB

With additional packages:
├── ggplot2:          +~10 MB
├── dplyr:            +~5 MB
├── Your package:     +varies
└── Typical app:      ~70-100 MB
```

**Trade-offs:**
- User downloads ~60-100MB on first visit
- Cached for subsequent visits
- NOT mobile-friendly (bandwidth)
- No server costs
- Works offline after initial load

## Conversion Workflow

### Method 1: Direct Export (Simplest)

```r
# Convert app directory to static site
shinylive::export(
  appdir = "myapp/",      # Directory containing app.R or ui.R/server.R
  destdir = "_site/"      # Output directory
)

# Result: _site/ contains deployable static files
```

### Method 2: GitHub Actions Automation

Create `.github/workflows/shinylive-deploy.yaml`:

```yaml
name: Deploy Shinylive App

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pages: write
      id-token: write

    steps:
      - uses: actions/checkout@v4

      - uses: r-lib/actions/setup-r@v2
        with:
          use-public-rspm: true

      - name: Install dependencies
        run: |
          install.packages(c("shinylive", "httpuv"))
        shell: Rscript {0}

      - name: Export Shinylive app
        run: |
          shinylive::export(".", "_site")
        shell: Rscript {0}

      - name: Setup Pages
        uses: actions/configure-pages@v4

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: '_site'

      - name: Deploy to GitHub Pages
        uses: actions/deploy-pages@v4
```

### Method 3: Quarto Integration

For Shinylive within Quarto documents, see the `shinylive-quarto` skill.

## Project Structure

### Standalone App

```
myapp/
├── app.R                           # Shiny app
├── .github/
│   └── workflows/
│       └── shinylive-deploy.yaml   # Automation
└── README.md
```

### Package Vignette

```
mypackage/
├── R/
│   └── functions.R
├── vignettes/
│   └── interactive-demo.qmd        # Shinylive in Quarto
├── .github/
│   └── workflows/
│       ├── R-CMD-check.yaml
│       └── pkgdown.yaml            # Builds site including vignettes
└── _pkgdown.yml
```

## Deployment Targets

### GitHub Pages

```yaml
# In workflow after shinylive::export()
- name: Deploy to GitHub Pages
  uses: peaceiris/actions-gh-pages@v3
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    publish_dir: ./_site
```

Enable in repo: Settings → Pages → Source: gh-pages branch

### Netlify

```bash
# netlify.toml
[build]
  command = "Rscript -e \"shinylive::export('.', '_site')\""
  publish = "_site"
```

### Any Static Host

```bash
# Export locally
Rscript -e "shinylive::export('.', '_site')"

# Upload _site/ directory to any static host:
# - Vercel
# - Cloudflare Pages
# - AWS S3 + CloudFront
# - Azure Static Web Apps
```

## Package Loading Strategies

### Strategy 1: webr::install() (Simplest)

```r
# Inside Shinylive app
webr::install("dplyr")
webr::install("ggplot2")
library(dplyr)
library(ggplot2)
```

### Strategy 2: R-Universe Repository

```r
# Load from R-Universe (includes your custom packages)
options(repos = c(
  yourusername = "https://yourusername.r-universe.dev",
  CRAN = "https://repo.r-wasm.org"  # WebR CRAN mirror
))

library(yourpackage)
```

### Strategy 3: GitHub Release Mount

```r
# Mount pre-built library from GitHub release
webr::mount(
  mountpoint = "/mylib",
  source = "https://github.com/user/repo/releases/latest/download/library.data"
)
.libPaths(c("/mylib", .libPaths()))
library(mypackage)
```

## Limitations

### What Doesn't Work in Shinylive

```r
# ❌ Server-side operations
crew::crew_controller_local()  # No background processes in WASM
future::plan(multisession)     # No multiprocessing
DBI::dbConnect(...)            # No database connections
httr::GET(...)                 # Limited HTTP (CORS restrictions)

# ❌ System dependencies
rJava                          # No JVM in browser
reticulate                     # No Python in browser
Rcpp with system libs          # Limited C++ support

# ❌ File system
write.csv(df, "output.csv")    # Virtual filesystem, not persistent
saveRDS(obj, "data.rds")       # Lost on page refresh
```

### What Works in Shinylive

```r
# ✅ Pure R computation
dplyr::mutate(), filter(), summarize()
ggplot2::ggplot() + geom_*()
stats::lm(), glm(), t.test()

# ✅ Reactive programming
shiny::reactive(), observe(), render*()

# ✅ Data manipulation
tidyr::pivot_longer(), pivot_wider()
stringr::str_*()

# ✅ Visualization
plotly (with limitations)
DT::datatable()
```

## Performance Optimization

### Pre-process Data

```r
# ❌ SLOW: Processing in browser
server <- function(input, output, session) {
  data <- reactive({
    read.csv("large_file.csv") |>  # Slow download
      mutate(...) |>                # Slow in WASM
      filter(...)
  })
}

# ✅ FAST: Pre-processed data in package
# R/data.R
#' @export
processed_data <- readRDS("inst/extdata/preprocessed.rds")

# In Shinylive app
data <- yourpackage::processed_data
```

### Minimize Package Dependencies

```r
# ❌ Heavy: Loads entire tidyverse
library(tidyverse)

# ✅ Light: Only what you need
library(dplyr)
library(ggplot2)
```

### Use Caching

```r
server <- function(input, output, session) {
  # Cache expensive computations
  result <- reactive({
    expensive_function(input$params)
  }) |> bindCache(input$params)
}
```

## Testing Locally

### Quick Preview

```r
# Serve locally for testing
shinylive::export("myapp/", "_site/")
httpuv::runStaticServer("_site/")
# Opens http://127.0.0.1:port
```

### Browser DevTools Debugging

1. Open app in browser
2. Press F12 → Console tab
3. Look for:
   - 404 errors (missing packages)
   - CORS errors (blocked requests)
   - WASM errors (unsupported operations)
   - Service Worker status

### Common Console Errors

```
# Package not found
Error: package 'mypackage' not found
→ Add to webr::install() or check R-Universe availability

# CORS blocked
Access to fetch blocked by CORS policy
→ Can't make cross-origin requests; use bundled data

# Service Worker
Service Worker registration failed
→ Serve from HTTP server, not file://
```

## Complete Example: GitHub Actions Workflow

```yaml
# .github/workflows/shinylive.yaml
name: Build and Deploy Shinylive

on:
  push:
    branches: [main]
    paths:
      - 'app.R'
      - 'R/**'
      - '.github/workflows/shinylive.yaml'

jobs:
  build-deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pages: write
      id-token: write

    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}

    steps:
      - uses: actions/checkout@v4

      - uses: r-lib/actions/setup-r@v2
        with:
          r-version: 'release'
          use-public-rspm: true

      - name: Install R packages
        run: |
          install.packages(c("shinylive", "httpuv"))
        shell: Rscript {0}

      - name: Build Shinylive app
        run: |
          shinylive::export(
            appdir = ".",
            destdir = "_site",
            subdir = ""
          )
        shell: Rscript {0}

      - name: List output
        run: ls -la _site/

      - name: Setup Pages
        uses: actions/configure-pages@v4

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: '_site'

      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

## Checklist Before Deployment

- [ ] App works locally with `shiny::runApp()`
- [ ] All packages available in WebR (`webr::install()` or R-Universe)
- [ ] No server-side dependencies (databases, APIs, file writes)
- [ ] Data pre-processed and bundled (not fetched at runtime)
- [ ] Tested in browser with DevTools open (no console errors)
- [ ] Service Worker loads correctly
- [ ] Acceptable initial load time (~5-15s on fast connection)
- [ ] README documents the deployed URL

## Resources

- [Shinylive for R](https://posit-dev.github.io/r-shinylive/)
- [WebR Documentation](https://docs.r-wasm.org/webr/latest/)
- [r-wasm/actions](https://github.com/r-wasm/actions)
- [convert-shiny-app-r-shinylive](https://github.com/JohnGavin/convert-shiny-app-r-shinylive)
- [Quarto Shinylive Extension](https://quarto-ext.github.io/shinylive/)

## Related Skills

- shinylive-quarto (Shinylive in Quarto documents)
- shiny-async-patterns (note: async doesn't work in WASM)
- pkgdown-deployment (for package vignettes)
- ci-workflows-github-actions (automation patterns)
