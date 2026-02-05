# Quarto Websites Skill

Build modern documentation websites for R packages, project sites, blogs, and books using Quarto. Offers a powerful alternative or complement to pkgdown with better support for mixed content, interactive elements, and modern web features.

## Quick Start

### Basic R Package Documentation Site

```yaml
# _quarto.yml
project:
  type: website
  output-dir: docs

website:
  title: "mypackage"
  navbar:
    background: primary
    left:
      - href: index.qmd
        text: Home
      - href: reference/index.qmd
        text: Reference
      - href: articles/index.qmd
        text: Articles
    right:
      - icon: github
        href: https://github.com/username/mypackage

format:
  html:
    theme: cosmo
    css: styles.css
    toc: true
```

### Initialize a Website Project

```bash
# Create new website
quarto create project website mysite

# Create blog
quarto create project blog myblog

# Create book
quarto create project book mybook
```

## Navigation Patterns

### 1. Top Navigation (Navbar)

Best for smaller sites with clear sections:

```yaml
website:
  navbar:
    background: primary
    search: true
    logo: logo.png
    title: "My Package"
    left:
      - text: "Get Started"
        href: getting-started.qmd
      - text: "Reference"
        menu:
          - href: reference/functions.qmd
            text: "Functions"
          - href: reference/data.qmd
            text: "Datasets"
      - text: "Articles"
        href: articles/index.qmd
    right:
      - icon: github
        href: https://github.com/username/repo
      - icon: twitter
        href: https://twitter.com/username
```

### 2. Side Navigation (Sidebar)

Better for documentation-heavy sites:

```yaml
website:
  sidebar:
    style: "docked"
    search: true
    background: light
    contents:
      - section: "Getting Started"
        contents:
          - index.qmd
          - installation.qmd
          - quickstart.qmd
      - section: "User Guide"
        contents:
          - guide/concepts.qmd
          - guide/workflow.qmd
          - guide/advanced.qmd
      - section: "Reference"
        contents:
          - reference/functions.qmd
          - reference/datasets.qmd
      - section: "Articles"
        contents:
          - articles/*.qmd
```

### 3. Hybrid Navigation

For large documentation sites (100+ pages):

```yaml
website:
  navbar:
    background: primary
    left:
      - text: "User Guide"
        href: guide/index.qmd
      - text: "Reference"
        href: reference/index.qmd
      - text: "Articles"
        href: articles/index.qmd

  sidebar:
    - id: guide
      title: "User Guide"
      style: "floating"
      contents:
        - guide/index.qmd
        - section: "Basics"
          contents: guide/basics/*.qmd
        - section: "Advanced"
          contents: guide/advanced/*.qmd

    - id: reference
      title: "Reference"
      contents:
        - reference/index.qmd
        - reference/functions/*.qmd
```

## R Package Documentation

### Package Website Structure

```
mypackage/
├── _quarto.yml            # Site configuration
├── index.qmd              # Homepage
├── getting-started.qmd    # Quick start guide
├── reference/
│   ├── index.qmd         # Function reference index
│   └── *.qmd             # Individual function docs
├── articles/             # Vignettes as articles
│   ├── index.qmd
│   └── *.qmd
├── news/
│   └── index.qmd         # Package news/changelog
└── _site/                # Generated site output
```

### Converting from pkgdown

#### 1. Vignettes → Articles

```r
# Copy vignettes to articles/
fs::dir_copy("vignettes", "articles")

# Update YAML frontmatter in each article
# Add to each .Rmd:
---
title: "Article Title"
description: "Article description"
author: "Your Name"
date: last-modified
categories: [tutorial, analysis]
---
```

#### 2. Function Reference

Create `reference/index.qmd`:

```markdown
---
title: "Function Reference"
listing:
  contents:
    - "*.qmd"
  type: table
  fields: [title, description]
  sort: "title asc"
---

## Package Functions

Browse the complete reference for all exported functions.
```

Generate function documentation pages:

```r
# R script to create function docs
library(mypackage)
fns <- ls("package:mypackage")

for (fn in fns) {
  doc <- utils::help(fn, package = "mypackage")
  # Convert Rd to markdown and save as reference/{fn}.qmd
}
```

#### 3. Package README as Homepage

```markdown
---
title: "mypackage"
subtitle: "A brief description of the package"
---

:::{.callout-tip}
## Installation

```r
# Install from CRAN
install.packages("mypackage")

# Or development version
devtools::install_github("username/mypackage")
```
:::

[Rest of README content...]
```

### Pre-computed Vignettes Strategy

For reproducible vignettes with heavy computation:

```r
# _targets.R or compute script
library(targets)
tar_make()

# Extract and save vignette data
tar_load(c(results, plots))
saveRDS(
  list(results = results, plots = plots),
  "inst/extdata/vignette_data.rds"
)
```

In vignette:

```r
#| eval: !expr file.exists(system.file("extdata/vignette_data.rds", package = "mypackage"))
data <- readRDS(system.file("extdata/vignette_data.rds", package = "mypackage"))
results <- data$results
plots <- data$plots
```

## Blog Integration

### Adding a Blog to Package Docs

```yaml
# In _quarto.yml
website:
  navbar:
    left:
      - text: "Blog"
        href: blog/index.qmd
```

Create `blog/index.qmd`:

```markdown
---
title: "Blog"
listing:
  contents: posts
  sort: "date desc"
  type: default
  categories: true
  feed: true
page-layout: full
---
```

### Blog Post Structure

```
blog/
├── index.qmd              # Blog listing page
├── posts/
│   ├── _metadata.yml     # Shared post settings
│   ├── 2024-01-15-announcement/
│   │   ├── index.qmd
│   │   └── images/
│   └── 2024-01-20-tutorial/
│       └── index.qmd
```

Post frontmatter:

```yaml
---
title: "New Feature Announcement"
author: "Package Author"
date: "2024-01-15"
categories: [news, features]
image: "thumbnail.jpg"
draft: false
---
```

## Search Configuration

### Full-Text Search

```yaml
website:
  search:
    location: navbar  # or sidebar
    type: overlay    # or textbox
    copy-button: true
```

### Algolia Search (Advanced)

```yaml
website:
  search:
    algolia:
      application-id: "YOUR_APP_ID"
      search-api-key: "YOUR_SEARCH_KEY"
      index-name: "YOUR_INDEX"
```

## Publishing and Deployment

### GitHub Pages with GitHub Actions

```yaml
# .github/workflows/publish.yml
name: Publish Quarto Site

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Quarto
        uses: quarto-dev/quarto-actions/setup@v2

      - name: Setup R
        uses: r-lib/actions/setup-r@v2

      - name: Setup R Dependencies
        uses: r-lib/actions/setup-renv@v2

      - name: Render and Publish
        uses: quarto-dev/quarto-actions/publish@v2
        with:
          target: gh-pages
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Deployment Strategy: Artifacts vs. Branches

**Crucial Note:** Modern Quarto GitHub Actions (`quarto-dev/quarto-actions/publish@v2`) typically use the GitHub Pages API to deploy from an **artifact**, rather than pushing files to the `gh-pages` branch.

-   **Do not check `git log origin/gh-pages`** to verify deployment. The branch may be stale or empty.
-   **Check `gh run list`** to see the workflow status.
-   **Check the live site** footer or "Last Updated" timestamp to verify changes.

### Local Publishing

```bash
# First time setup (creates _publish.yml)
quarto publish gh-pages

# Subsequent publishes
quarto publish gh-pages --no-prompt

# Or render to docs/ and let GitHub Pages serve it
quarto render
git add docs/
git commit -m "Update site"
git push
```

### Freeze Computations for CI

```yaml
# _quarto.yml
execute:
  freeze: auto  # or true
```

This caches computation results in `_freeze/` directory, avoiding re-execution in CI.

## Theming and Customization

### Built-in Themes

```yaml
format:
  html:
    theme: cosmo  # Bootstrap 5 themes
    # Options: default, cerulean, cosmo, darkly, flatly, journal,
    # litera, lumen, lux, materia, minty, morph, pulse, quartz,
    # sandstone, simplex, sketchy, slate, solar, spacelab,
    # superhero, united, vapor, yeti, zephyr
```

### Custom Theme

Create `custom.scss`:

```scss
/*-- scss:defaults --*/
$primary: #0d6efd;
$secondary: #6c757d;
$font-family-sans-serif: "Inter", system-ui, -apple-system, sans-serif;

/*-- scss:rules --*/
.navbar-brand {
  font-weight: 700;
}

.sidebar nav[role="doc-toc"] {
  font-size: 0.875rem;
}
```

Apply:

```yaml
format:
  html:
    theme: [cosmo, custom.scss]
```

### Dark Mode Support

```yaml
format:
  html:
    theme:
      light: flatly
      dark: darkly
```

## Advanced Features

### Table of Contents

```yaml
format:
  html:
    toc: true
    toc-depth: 3
    toc-location: left  # or right, body
    toc-title: "On this page"
    toc-expand: 2
```

### Code Annotations

````markdown
```r
library(ggplot2)
ggplot(mtcars, aes(x = mpg, y = wt)) +
  geom_point() + # <1>
  theme_minimal() # <2>
```
1. Add points to the plot
2. Apply minimal theme
````

### Tabsets

```markdown
::: {.panel-tabset}

## R Code
```r
plot(mtcars$mpg, mtcars$wt)
```

## Python Code
```python
import matplotlib.pyplot as plt
plt.scatter(mtcars['mpg'], mtcars['wt'])
```

:::
```

### Callout Blocks

```markdown
:::{.callout-note}
This is a note callout.
:::

:::{.callout-warning}
This is a warning callout.
:::

:::{.callout-important}
This is important information.
:::

:::{.callout-tip}
## Pro Tip
Tips can have custom titles.
:::

:::{.callout-caution collapse="true"}
## Click to expand
Collapsible content here.
:::
```

### Cross-References

```markdown
See @fig-scatter for the visualization.

![Scatterplot of mpg vs wt](plot.png){#fig-scatter}
```

## Website Tools

### Development Server

```bash
# Live preview with hot reload
quarto preview

# Preview a specific format
quarto preview --to html

# Preview on a different port
quarto preview --port 4000
```

### Rendering

```bash
# Render entire site
quarto render

# Render specific file
quarto render index.qmd

# Render specific directory
quarto render articles/
```

### Site Management

```yaml
# _quarto.yml
project:
  type: website
  output-dir: _site
  render:
    - "!private/"     # Exclude private directory
    - "!draft-*.qmd"  # Exclude draft files
  resources:
    - "data/*.csv"    # Include data files
    - "images/**"     # Include all images
```

## Integration with R Packages

### Using Quarto from R

```r
library(quarto)

# Render site
quarto_render()

# Render specific file
quarto_render("index.qmd")

# Preview site
quarto_preview()

# Publish to GitHub Pages
quarto_publish_site(
  server = "gh-pages",
  render = TRUE
)
```

### Metadata from DESCRIPTION

```r
# Generate metadata from DESCRIPTION
desc <- desc::desc()

metadata <- list(
  title = desc$get("Package")[[1]],
  subtitle = desc$get("Title")[[1]],
  author = desc$get_authors(),
  version = desc$get_version()
)

# Use in Quarto docs
yaml::write_yaml(metadata, "_metadata.yml")
```

## pkgdown vs Quarto Comparison

| Feature | pkgdown | Quarto |
|---------|---------|---------|
| **Purpose** | R package docs | General purpose + packages |
| **Setup** | `use_pkgdown()` | `quarto create project website` |
| **Reference** | Auto-generated | Manual or scripted |
| **Vignettes** | Automatic | Convert to articles |
| **News** | Automatic from NEWS.md | Manual page |
| **Search** | Built-in | Built-in with more options |
| **Themes** | Bootstrap 3/4 | Bootstrap 5 + more |
| **Customization** | Limited | Extensive |
| **Interactive** | Basic | Shiny, Observable, WebR |
| **Formats** | HTML only | HTML, PDF, ePub, etc. |
| **CI/CD** | r-lib/actions | quarto-actions + r-lib |

### When to Use Each

**Use pkgdown when:**
- You want zero-config setup for R packages
- Standard package documentation is sufficient
- You prefer automatic reference generation
- You're already using it and it works

**Use Quarto when:**
- You need mixed content (blogs, tutorials, books)
- You want modern web features (dark mode, better search)
- You need interactive elements (Shinylive, Observable)
- You want more control over layout and design
- You're creating documentation beyond just package reference

## Common Patterns

### Multi-Language Documentation

```markdown
---
title: "Data Analysis"
---

::: {.panel-tabset}

## R

```r
library(dplyr)
mtcars %>%
  group_by(cyl) %>%
  summarise(mean_mpg = mean(mpg))
```

## Python

```python
import pandas as pd
mtcars.groupby('cyl')['mpg'].mean()
```

:::
```

### Package Changelog

Create `news/index.qmd`:

```markdown
---
title: "News"
listing:
  contents:
    - "releases/*.qmd"
  sort: "date desc"
  type: table
  fields: [date, title, description]
---

## Package Changelog

Track all package updates and releases.
```

### FAQ Page

```markdown
---
title: "Frequently Asked Questions"
toc: true
toc-location: right
---

## Installation Issues

<details>
<summary>How do I install from GitHub?</summary>

```r
devtools::install_github("username/package")
```
</details>

<details>
<summary>What R version is required?</summary>

R >= 4.0.0 is required for this package.
</details>
```

## Troubleshooting

### Common Issues

1. **Site not rendering**
   - Check `_quarto.yml` syntax
   - Verify all referenced files exist
   - Run `quarto check` for diagnostics

2. **GitHub Pages 404**
   - Ensure `output-dir: docs` if publishing from docs/
   - Check GitHub Pages settings point to correct branch/folder
   - Verify `.nojekyll` file exists in output

3. **Search not working**
   - Ensure `search: true` in website config
   - Check JavaScript console for errors
   - Verify site URL is set for production

4. **Images not showing**
   - Use relative paths from document location
   - Include images in `resources:` if needed
   - Check case sensitivity on Linux/Mac

5. **Freeze not working**
   - Add `execute: freeze: auto` to `_quarto.yml`
   - Commit `_freeze/` directory to git
   - Don't gitignore the freeze directory

## Best Practices

1. **Structure articles hierarchically** - Use sections and consistent navigation
2. **Pre-compute heavy vignettes** - Use targets or similar for reproducibility
3. **Enable freeze for CI** - Avoid re-running computations
4. **Use GitHub Actions** - Automate publishing on every push
5. **Version your data** - Include data snapshots for vignettes
6. **Optimize images** - Compress before including
7. **Test locally** - Always preview before publishing
8. **Use consistent theming** - Define styles in one place
9. **Document your API** - Even if manually creating reference pages
10. **Keep NEWS updated** - Users rely on changelogs

## Related Skills

- **pkgdown-deployment**: Traditional R package documentation
- **quarto-dashboards**: Interactive dashboards with Quarto
- **shinylive-quarto**: WebAssembly Shiny apps in Quarto
- **ci-workflows-github-actions**: Automation for publishing
- **quarto-dynamic-content**: Dynamic content generation
- **readme-qmd-standard**: README best practices

## Resources

- [Quarto Websites Documentation](https://quarto.org/docs/websites/)
- [Quarto Guide for R Users](https://quarto.org/docs/computations/r.html)
- [Publishing to GitHub Pages](https://quarto.org/docs/publishing/github-pages.html)
- [Bootstrap 5 Themes](https://bootswatch.com/)
- [Quarto Gallery](https://quarto.org/docs/gallery/#websites)
