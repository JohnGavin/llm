# README.qmd Standard for R Packages

## Purpose
Ensure all R package README files include Nix installation instructions and auto-updating project structure.

## Required Sections for README.qmd

### 1. Installation Section Structure

```markdown
## Installation

### From GitHub (Standard R)
```r
# Install development version from GitHub
remotes::install_github("username/packagename")
```

### From Nix (Reproducible Environment)

For a fully reproducible environment with all dependencies:

```bash
# One-time setup: Install Nix (if not already installed)
curl -L https://nixos.org/nix/install | sh

# Enter the package's Nix environment
nix-shell -p R rPackages.remotes --run "R -e 'remotes::install_github(\"username/packagename\")'"

# Or clone and use the project's Nix shell
git clone https://github.com/username/packagename.git
cd packagename
nix-shell  # or ./default.sh if available
```

### Using with rix

For integration with existing R projects:

```r
library(rix)
rix(
  r_ver = "4.5.0",
  git_pkgs = list(
    package_name = "username/packagename"
  ),
  ide = "code",
  project_path = "."
)
# Then: nix-shell
```
```

### 2. Project Structure Section (Near End)

```markdown
## Project Structure

```{r project-structure, echo=FALSE, comment=""}
#| eval: true
#| echo: false

# Auto-generate project tree
project_files <- list.files(
  path = ".",
  recursive = TRUE,
  all.files = FALSE,
  full.names = TRUE
)

# Filter out unwanted paths
exclude_patterns <- c(
  "^\\./.git/", "^\\./.Rproj.user/", "^\\./renv/",
  "^\\./_targets/", "^\\./docs/", "^\\./man/",
  "^\\./.Rhistory$", "^\\./.RData$", "^\\./.DS_Store$",
  "^\\./nix-shell-root$"
)

project_files <- project_files[!grepl(
  paste(exclude_patterns, collapse = "|"),
  project_files
)]

# Create tree structure
library(fs)
tree_output <- capture.output(
  fs::dir_tree(
    path = ".",
    recurse = TRUE,
    type = "any",
    regexp = "^(?!\\.|_targets|docs|man|renv|nix-shell-root).*"
  )
)

cat(tree_output, sep = "\n")
```
```

### 3. Targets Plan for README Generation

Create `R/tar_plans/plan_documentation.R`:

```r
# Documentation pipeline
library(targets)
library(tarchetypes)

documentation_plan <- list(
  # Track vignettes
  tar_target(
    vignette_files,
    list.files("vignettes", pattern = "\\.Rmd$|\\.qmd$", full.names = TRUE),
    format = "file"
  ),

  # Track README.qmd
  tar_target(
    readme_qmd,
    "README.qmd",
    format = "file"
  ),

  # Render README when vignettes change
  tar_target(
    readme_md,
    {
      # Trigger on vignette changes
      vignette_files

      # Render README.qmd to README.md
      quarto::quarto_render(
        input = readme_qmd,
        output_format = "gfm"  # GitHub Flavored Markdown
      )

      # Return the output file
      "README.md"
    },
    format = "file"
  ),

  # Update pkgdown site
  tar_target(
    pkgdown_site,
    {
      readme_md  # Depend on README
      pkgdown::build_site()
      "docs/index.html"
    },
    format = "file"
  )
)

documentation_plan
```

### 4. Complete README.qmd Template

```markdown
---
output: github_document
always_allow_html: true
---

<!-- README.md is generated from README.qmd. Please edit that file -->

```{r setup, include = FALSE}
knitr::opts_chunk$set(
  collapse = TRUE,
  comment = "#>",
  fig.path = "man/figures/README-",
  out.width = "100%"
)
```

# packagename

<!-- badges: start -->
[![R-CMD-check](https://github.com/username/packagename/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/username/packagename/actions/workflows/R-CMD-check.yaml)
[![Codecov](https://codecov.io/gh/username/packagename/branch/main/graph/badge.svg)](https://codecov.io/gh/username/packagename)
<!-- badges: end -->

## Overview

Package description here.

## Installation

### From GitHub (Standard R)

```r
# Install development version from GitHub
remotes::install_github("username/packagename")
```

### From Nix (Reproducible Environment)

For a fully reproducible environment with all dependencies:

```bash
# Clone and use the project's Nix shell
git clone https://github.com/username/packagename.git
cd packagename

# Generate Nix environment from DESCRIPTION
Rscript default.R  # Creates default.nix

# Enter Nix shell with GC root (fast after first run)
chmod +x default.sh
./default.sh
```

### Using with rix

For integration with existing R projects:

```r
library(rix)
rix(
  r_ver = "4.5.0",
  r_pkgs = c("devtools", "tidyverse"),
  git_pkgs = list(
    package_name = "username/packagename"
  ),
  ide = "code",
  project_path = "."
)
# Then: nix-shell
```

## Usage

Basic examples here.

## Project Structure

```{r project-structure, echo=FALSE, comment=""}
#| eval: true
#| echo: false

# Auto-generate project tree
suppressMessages(library(fs))

# Use fs::dir_tree for cleaner output
tree_output <- capture.output(
  fs::dir_tree(
    path = ".",
    recurse = TRUE,
    type = "any",
    regexp = "^[^._]",  # Exclude hidden and _ prefixed
    max_depth = 3
  )
)

# Filter out common build artifacts
tree_output <- tree_output[!grepl(
  "nix-shell-root|docs/|man/|Meta/|help/",
  tree_output
)]

cat(tree_output, sep = "\n")
```

## Development

To contribute:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make changes following the 9-step workflow
4. Run checks in Nix environment
5. Submit a Pull Request

## License

Package license here.
```

## Implementation Checklist

When creating/updating a README.qmd:

1. ✅ Include standard R installation (remotes/devtools)
2. ✅ Include Nix installation with default.sh method
3. ✅ Include rix integration example
4. ✅ Add auto-updating project structure section
5. ✅ Create targets plan for auto-regeneration
6. ✅ Ensure README.qmd → README.md conversion works
7. ✅ Test that structure updates when files change
8. ✅ Verify pkgdown picks up the changes

## GitHub Actions Integration

Add to `.github/workflows/render-readme.yaml`:

```yaml
name: Render README

on:
  push:
    paths:
      - README.qmd
      - vignettes/**

jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: quarto-dev/quarto-actions/setup@v2
      - name: Render README
        run: |
          quarto render README.qmd --to gfm
      - name: Commit README.md
        run: |
          git config --local user.email "action@github.com"
          git config --local user.name "GitHub Action"
          git add README.md
          git diff --quiet && git diff --staged --quiet || git commit -m "Auto-update README.md"
          git push
```

## Key Points

1. **Always include Nix instructions** - Critical for reproducibility
2. **Use README.qmd as source** - Never edit README.md directly
3. **Auto-generate structure** - Keeps documentation current
4. **Integrate with targets** - Automated updates on vignette changes
5. **Show both installation methods** - Standard R and Nix
6. **Include rix example** - For existing project integration