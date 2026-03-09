# Site Structure & Content Patterns

## Package Website Structure

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

## Converting from pkgdown

### 1. Vignettes to Articles

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

### 2. Function Reference

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

### 3. Package README as Homepage

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

## Pre-computed Vignettes Strategy

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
