# Package Loading Approaches

Two approaches for loading your R package in Shinylive dashboards.

## Approach 1: GitHub Release + webr::mount() (Recommended)

Use when you control the package and can build WebAssembly files.

### How It Works

- Use `r-wasm/actions` workflow to build a WebAssembly file system image
- The image (`library.data`) is attached to GitHub releases as an asset
- Dashboard mounts this directly via `webr::mount()`
- No external services needed

### Setup: wasm-release.yaml

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

When you publish a GitHub release, this workflow:
- Builds the WebAssembly file system image with your package
- Attaches `library.data` to the release as an asset

### Use in Dashboard

```r
webr::mount(
  mountpoint = "/mypackage-lib",
  source = "https://github.com/username/mypackage/releases/latest/download/library.data"
)

.libPaths(c("/mypackage-lib", .libPaths()))
library(mypackage)
```

### Advantages

- Simpler setup (one workflow file)
- Direct: GitHub -> Browser
- Versioned (tied to releases)
- Full control over build

---

## Approach 2: R-Universe (For Public Package Distribution)

Use when publishing packages for others to use in their Shinylive apps.

### How It Works

- R-Universe compiles packages to WebAssembly automatically
- Browser loads packages via `options(repos = ...)`
- Like CRAN but for WebAssembly

### Setup

**Create universe repository on GitHub** named "universe" and add `packages.json`:

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
3. Wait for build at https://yourusername.r-universe.dev/ (~30-60 minutes initial)

### Use in Dashboard

```r
options(repos = c(
  yourusername = 'https://yourusername.r-universe.dev',
  CRAN = 'https://cloud.r-project.org'
))
library(mypackage)
```

### Deployment Flow

```
Your Package (GitHub)
    |
R-Universe GitHub App
    |
WebAssembly Binaries (yourusername.r-universe.dev)
    |
Shinylive Dashboard (in Quarto vignette)
    |
pkgdown build
    |
GitHub Pages (yourusername.github.io/package)
    |
User's Browser loads dashboard -> fetches packages from R-Universe
```

### Advantages

- Good for distributing packages to others
- Automatic updates on push
- CRAN-like experience for users

---

## What Happens at Runtime (R-Universe approach)

1. Browser loads HTML/JS from GitHub Pages
2. WebR initializes in browser
3. Dashboard code executes `options(repos = c(yourusername = 'https://yourusername.r-universe.dev'))`
4. Browser fetches WebAssembly-compiled package from R-Universe
5. Package loads in browser's WebAssembly environment
6. Shiny app runs entirely client-side
