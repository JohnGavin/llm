# Navigation & Interactive Features

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
